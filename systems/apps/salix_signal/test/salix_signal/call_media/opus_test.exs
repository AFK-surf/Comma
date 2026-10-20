defmodule SalixSignal.CallMedia.OpusTest do
  use SystemsClock.Case, async: true

  alias SalixSignal.CallMedia.Opus
  alias SalixSignal.Test.Audio

  test "a 60 ms frame of 24 kHz speech-band audio survives an encode and decode" do
    {:ok, encoder} = Opus.encoder()
    {:ok, decoder} = Opus.decoder()

    decoded =
      for frame <- Audio.frames(Audio.sine(440, 600), Opus.frame_bytes()), into: <<>> do
        {:ok, packet} = Opus.encode(encoder, frame)
        assert byte_size(packet) > 2
        # 60 ms at 32 kbit/s CBR.
        assert byte_size(packet) == 240
        assert {:ok, 1440} = Opus.samples(packet)
        {:ok, pcm} = Opus.decode(decoder, packet)
        assert byte_size(pcm) == Opus.frame_bytes()
        pcm
      end

    assert_in_delta Audio.frequency(Audio.skip_ms(decoded, 120)), 440, 20
  end
end
