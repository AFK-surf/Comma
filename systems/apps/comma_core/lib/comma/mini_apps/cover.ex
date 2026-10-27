defmodule Comma.MiniApps.Cover do
  @moduledoc """
  An app's cover: a screenshot of its first screen that the Apps gallery shows
  for a Version (manifest `cover`, a file in the bundle). Every gallery viewer
  downloads and decodes it, so a deploy accepts only a small one: a WebP, JPEG
  or PNG file of at most 160 KiB and 1200 × 1200 pixels. The template makes it
  780 × 585 (a phone's first screen at 2x).

  The size comes from the image header, so a file whose bytes are not the
  image its name says is refused too.
  """

  @max_bytes 160 * 1024
  @max_side 1200
  @labels %{"image/webp" => "WebP", "image/jpeg" => "JPEG", "image/png" => "PNG"}

  def max_bytes, do: @max_bytes

  @doc "Checks a cover's bytes: `:ok` or `{:error, [message]}` for the coding agent."
  def check(data, type) when is_binary(data) do
    case dimensions(data) do
      {^type, width, height} when width <= @max_side and height <= @max_side ->
        :ok

      {^type, width, height} ->
        {:error,
         [
           "the cover is #{width} × #{height} pixels; make it at most #{@max_side} × #{@max_side} (780 × 585 is enough)"
         ]}

      _ ->
        {:error, ["the cover's bytes are not a #{@labels[type]} image, as its name says"]}
    end
  end

  # {MIME type, width, height} from the header, or nil.
  defp dimensions(<<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", w::32, h::32, _::binary>>),
    do: {"image/png", w, h}

  defp dimensions(<<"RIFF", _size::32, "WEBP", chunk::binary>>), do: webp(chunk)
  defp dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest)
  defp dimensions(_data), do: nil

  # Lossy, lossless and extended WebP keep the canvas size in different places.
  defp webp(
         <<"VP8 ", _size::32, _frame::binary-size(3), 0x9D, 0x01, 0x2A, w::little-16,
           h::little-16, _::binary>>
       ),
       do: {"image/webp", Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF)}

  defp webp(<<"VP8L", _size::32, 0x2F, bits::little-32, _::binary>>),
    do:
      {"image/webp", Bitwise.band(bits, 0x3FFF) + 1,
       Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1}

  defp webp(<<"VP8X", _size::32, _flags::32, w::little-24, h::little-24, _::binary>>),
    do: {"image/webp", w + 1, h + 1}

  defp webp(_chunk), do: nil

  # JPEG segments up to the first start-of-frame, which holds the size.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  # Restart and TEM markers stand alone, with no length.
  defp jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD7 or marker == 0x01,
    do: jpeg(rest)

  defp jpeg(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {"image/jpeg", w, h}

  defp jpeg(<<0xFF, _marker, len::16, rest::binary>>)
       when len >= 2 and byte_size(rest) >= len - 2,
       do: jpeg(binary_part(rest, len - 2, byte_size(rest) - (len - 2)))

  defp jpeg(_data), do: nil
end
