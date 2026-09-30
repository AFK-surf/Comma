defmodule SalixSignal.CallMedia.OpusTest do
  use ExUnit.Case, async: true

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

  test "lost audio is concealed with the requested length" do
    {:ok, encoder} = Opus.encoder()
    {:ok, decoder} = Opus.decoder()
    [a, b, c] = Audio.frames(Audio.sine(300, 180), Opus.frame_bytes())
    {:ok, pa} = Opus.encode(encoder, a)
    {:ok, _pb} = Opus.encode(encoder, b)
    {:ok, pc} = Opus.encode(encoder, c)

    {:ok, _} = Opus.decode(decoder, pa)
    assert {:ok, fec} = Opus.conceal(decoder, pc, 1440)
    assert byte_size(fec) == 2880
    assert {:ok, plc} = Opus.conceal(decoder, nil, 480)
    assert byte_size(plc) == 960
  end

  test "invalid input is refused before it reaches libopus" do
    {:ok, encoder} = Opus.encoder()
    {:ok, decoder} = Opus.decoder()
    assert {:error, :bad_arg} = Opus.encode(encoder, :binary.copy(<<0, 0>>, 1000))
    assert_raise ArgumentError, fn -> Opus.encode(encoder, <<1, 2, 3>>) end
    assert {:error, :invalid_packet} = Opus.samples(<<>>)
    assert {:error, _} = Opus.decode(decoder, <<0xFF, 0xFF, 0xFF>>)
  end
end
