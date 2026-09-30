defmodule SalixMedia.TestImage do
  @moduledoc false

  # A real, deliberately uncompressed PNG, bigger than the old 3 MiB request
  # frame once base64 encoded. No private incident attachment is checked in.
  def large_png do
    width = 1800
    height = 800
    pixels = :binary.copy(<<0>> <> :binary.copy(<<32, 100, 180>>, width), height)
    z = :zlib.open()

    compressed =
      try do
        :ok = :zlib.deflateInit(z, 0)
        :zlib.deflate(z, pixels, :finish) |> IO.iodata_to_binary()
      after
        :zlib.close(z)
      end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", compressed) <> chunk("IEND", "")
  end

  defp chunk(type, bytes),
    do: <<byte_size(bytes)::32>> <> type <> bytes <> <<:erlang.crc32(type <> bytes)::32>>
end
