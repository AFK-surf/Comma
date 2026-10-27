defmodule Comma.MiniApps.CoverTest do
  use ExUnit.Case, async: true

  alias Comma.MiniApps.Cover

  # Each format keeps its size in its own header; a cover past 1200 pixels a side is refused.
  test "reads the size of WebP, JPEG and PNG covers from their headers" do
    lossy = webp("VP8 ", <<0, 0, 0, 0x9D, 0x01, 0x2A, 780::little-16, 585::little-16>>)
    bits = 779 + Bitwise.bsl(584, 14)
    lossless = webp("VP8L", <<0x2F, bits::little-32>>)
    extended = webp("VP8X", <<0::32, 779::little-24, 584::little-24>>)

    for cover <- [lossy, lossless, extended], do: assert(:ok = Cover.check(cover, "image/webp"))

    # An APP0 segment and a stand-alone marker before the frame header.
    jpeg =
      <<0xFF, 0xD8, 0xFF, 0xE0, 16::16, 0::112, 0xFF, 0xD0, 0xFF, 0xC0, 17::16, 8, 585::16,
        780::16>>

    assert :ok = Cover.check(jpeg, "image/jpeg")

    png = <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 1600::32, 1200::32>>
    assert {:error, [message]} = Cover.check(png, "image/png")
    assert message =~ "1600 × 1200 pixels"

    assert {:error, [_]} = Cover.check("not an image", "image/png")
  end

  defp webp(chunk, payload),
    do: <<"RIFF", 0::32, "WEBP", chunk::binary, byte_size(payload)::little-32, payload::binary>>
end
