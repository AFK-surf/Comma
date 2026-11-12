defmodule SalixMedia.ImageInput do
  require SystemsRuntime.Proc

  @moduledoc """
  Bounded previews for model input; original attachment bytes are never changed.

  Small images pass through. Larger images use the runtime's existing FFmpeg
  to produce a single JPEG preview, without metadata, at most 1536 pixels per
  side and 512 KiB. Failed conversion never falls back to the original bytes.

  HEIC and HEIF always convert, because no provider takes them. libheif decodes
  them: FFmpeg reads one tile of the grid an iPhone photo is stored as, and
  reports success. BMP, TIFF and AVIF always convert with FFmpeg, for the same
  reason.
  """

  @max_bytes 512 * 1024
  @max_source_bytes 10 * 1024 * 1024
  @heif_mimes ~w(image/heic image/heif)
  @converted_mimes ~w(image/bmp image/x-ms-bmp image/tiff image/avif)
  @convert_ms 10_000

  def prepare(body, mime) when mime in @heif_mimes and byte_size(body) <= @max_source_bytes do
    case System.find_executable("heif-dec") do
      nil -> {:error, :image_preview_unavailable}
      executable -> convert_heif(body, executable)
    end
  end

  def prepare(body, mime) when mime in @converted_mimes and byte_size(body) <= @max_source_bytes,
    do: preview(body, mime)

  def prepare(body, mime) when is_binary(body) and byte_size(body) <= @max_bytes,
    do: {:ok, body, mime}

  def prepare(body, mime) when is_binary(body) and byte_size(body) <= @max_source_bytes,
    do: preview(body, mime)

  def prepare(_body, _mime), do: {:error, :oversized}

  defp convert_heif(body, executable) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-heif-#{Base.url_encode64(SystemsRuntime.Proc.random_bytes(18))}"
      )

    try do
      File.mkdir!(dir)
      File.chmod!(dir, 0o700)
      input = Path.join(dir, "input.heic")
      File.write!(input, body)

      # A file with several images writes output-1.jpg, output-2.jpg and so on.
      args = ["-q", "85", input, Path.join(dir, "output.jpg")]
      port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])

      try do
        with :ok <- await_exit(port, SystemsClock.monotonic_time(:millisecond) + @convert_ms),
             [output | _] <- dir |> Path.join("output*.jpg") |> Path.wildcard() |> Enum.sort(),
             {:ok, jpeg} <- File.read(output) do
          prepare(jpeg, "image/jpeg")
        else
          {:error, :image_preview_timeout} = timeout -> timeout
          _ -> {:error, :image_preview_unavailable}
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    rescue
      _ -> {:error, :image_preview_unavailable}
    after
      File.rm_rf(dir)
    end
  end

  defp await_exit(port, deadline) do
    remaining = max(deadline - SystemsClock.monotonic_time(:millisecond), 0)

    SystemsRuntime.Proc.receive do
      {^port, {:data, _output}} -> await_exit(port, deadline)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _}} -> {:error, :image_preview_unavailable}
    after
      remaining -> {:error, :image_preview_timeout}
    end
  end

  defp preview(body, mime) do
    case System.find_executable("ffmpeg") do
      nil -> {:error, :image_preview_unavailable}
      executable -> preview(body, mime, executable)
    end
  end

  defp preview(body, mime, executable) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-image-#{Base.url_encode64(SystemsRuntime.Proc.random_bytes(18))}"
      )

    try do
      File.mkdir!(dir)
      File.chmod!(dir, 0o700)
      input = Path.join(dir, "input")
      File.write!(input, body)

      # Force an image decoder: a disguised playlist must not read files or URLs.
      {format, decoder} =
        %{
          "image/png" => {"image2pipe", "png"},
          "image/jpeg" => {"image2pipe", "mjpeg"},
          "image/webp" => {"image2pipe", "webp"},
          "image/gif" => {"image2pipe", "gif"},
          "image/bmp" => {"image2pipe", "bmp"},
          "image/x-ms-bmp" => {"image2pipe", "bmp"},
          "image/tiff" => {"image2pipe", "tiff"},
          "image/avif" => {"mov", "libdav1d"}
        }[mime] || raise("unsupported image format")

      args = [
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "quiet",
        "-protocol_whitelist",
        "file",
        "-f",
        format,
        "-c:v",
        decoder,
        "-max_pixels",
        "40000000",
        "-threads",
        "1",
        "-i",
        input,
        "-frames:v",
        "1",
        "-an",
        "-map_metadata",
        "-1",
        "-vf",
        "scale=w='min(1536,iw)':h='min(1536,ih)':force_original_aspect_ratio=decrease",
        "-threads",
        "1",
        "-c:v",
        "mjpeg",
        "-q:v",
        "8",
        "-f",
        "image2pipe",
        "pipe:1"
      ]

      port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])

      try do
        collect(port, SystemsClock.monotonic_time(:millisecond) + 10_000, "")
      after
        if Port.info(port), do: Port.close(port)
      end
    rescue
      _ -> {:error, :image_preview_unavailable}
    after
      File.rm_rf(dir)
    end
  end

  defp collect(port, deadline, output) do
    remaining = max(deadline - SystemsClock.monotonic_time(:millisecond), 0)

    SystemsRuntime.Proc.receive do
      {^port, {:data, data}} ->
        if byte_size(output) + byte_size(data) <= @max_bytes,
          do: collect(port, deadline, output <> data),
          else: {:error, :oversized}

      {^port, {:exit_status, 0}} ->
        case output do
          <<0xFF, 0xD8, _::binary>> -> {:ok, output, "image/jpeg"}
          _ -> {:error, :image_preview_unavailable}
        end

      {^port, {:exit_status, _}} ->
        {:error, :image_preview_unavailable}
    after
      remaining -> {:error, :image_preview_timeout}
    end
  end
end
