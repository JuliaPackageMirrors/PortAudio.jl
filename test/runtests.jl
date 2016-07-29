#!/usr/bin/env julia

if VERSION >= v"0.5.0-dev+7720"
    using Base.Test
else
    using BaseTestNext
end
using PortAudio
using SampledSignals
using RingBuffers

# these test are currently set up to run on OSX

@testset "PortAudio Tests" begin
    devs = PortAudio.devices()
    i = findfirst(d -> d.maxinchans > 0, devs)
    indev = i > 0 ? devs[i] : nothing
    i = findfirst(d -> d.maxoutchans > 0, devs)
    outdev = i > 0 ? devs[i] : nothing
    i = findfirst(d -> d.maxoutchans > 0 && d.maxinchans > 0, devs)
    duplexdev = i > 0 ? devs[i] : nothing

    @testset "Reports version" begin
        io = IOBuffer()
        PortAudio.versioninfo(io)
        result = takebuf_string(io)
        # make sure this is the same version I tested with
        @test result ==
            """PortAudio V19-devel (built Aug  6 2014 17:54:39)
            Version Number: 1899
            """
    end

    @testset "PortAudio Callback works and doesn't allocate" begin
        inbuf = rand(Float32, 16) # simulate microphone input
        sourcebuf = LockFreeRingBuffer(Float32, 64) # the microphone input should end up here
        testin = zeros(Float32, 16)

        outbuf = zeros(Float32, 24) # this is where the output should go
        sinkbuf = LockFreeRingBuffer(Float32, 64) # the callback should copy this to outbuf
        testout = rand(Float32, 24)
        write(sinkbuf, testout) # fill the output ringbuffer

        info = PortAudio.CallbackInfo(2, sourcebuf, 3, sinkbuf)

        # handle any conversions here so they don't mess with the allocation
        inptr = pointer(inbuf)
        outptr = pointer(outbuf)
        nframes = Culong(8)
        flags = Culong(0)
        infoptr = Ptr{PortAudio.CallbackInfo{Float32}}(pointer_from_objref(info))

        ret = PortAudio.portaudio_callback(inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test isa(ret, Cint)
        @test ret == PortAudio.paContinue
        @test outbuf == testout
        read!(sourcebuf, testin)
        @test inbuf == testin

        # call again (underrun)
        ret = PortAudio.portaudio_callback(inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test isa(ret, Cint)
        @test ret == PortAudio.paContinue
        @test outbuf == zeros(Float32, 24)

        write(sinkbuf, testout) # fill the output ringbuffer
        # test allocation
        alloc = @allocated PortAudio.portaudio_callback(inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test alloc == 0
        # now test allocation in underrun state
        alloc = @allocated PortAudio.portaudio_callback(inptr, outptr, nframes, C_NULL, flags, infoptr)
        @test alloc == 0
    end

    @testset "Open Default Device" begin
        stream = PortAudioStream()
        buf = read(stream, 0.001s)
        @test size(buf) == (round(Int, 0.001s * samplerate(stream)), nchannels(stream.source))
        write(stream, buf)
        close(stream)
    end
    @testset "Open Device by name" begin
        stream = PortAudioStream("Built-in Microph", "Built-in Output")
        buf = read(stream, 0.001s)
        @test size(buf) == (round(Int, 0.001s * samplerate(stream)), nchannels(stream.source))
        write(stream, buf)
        io = IOBuffer()
        show(io, stream)
        @test takebuf_string(io) == """
        PortAudio.PortAudioStream{Float32,SIUnits.SIQuantity{Int64,0,0,-1,0,0,0,0,0,0}}
          Samplerate: 48000 s⁻¹
          Buffer Size: 4096 frames
          2 channel sink: "Built-in Output"
          2 channel source: "Built-in Microph\""""
        close(stream)
    end
    @testset "Error on wrong name" begin
        @test_throws ErrorException PortAudioStream("foobarbaz")
    end
    # no way to check that the right data is actually getting read or written here,
    # but at least it's not crashing.
    @testset "Queued Writing" begin
        stream = PortAudioStream(0, 2)
        buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.sink)), samplerate(stream))
        t1 = @async write(stream, buf)
        t2 = @async write(stream, buf)
        @test wait(t1) == 48000
        @test wait(t2) == 48000
        close(stream)
    end
    @testset "Queued Reading" begin
        stream = PortAudioStream(2, 0)
        buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.source)), samplerate(stream))
        t1 = @async read!(stream, buf)
        t2 = @async read!(stream, buf)
        @test wait(t1) == 48000
        @test wait(t2) == 48000
        close(stream)
    end
end
