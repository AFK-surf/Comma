defmodule SalixMedia.ImageInput do
  @moduledoc """
  Bounded previews for model input; original attachment bytes are never changed.

  Small images pass through. Larger images use the runtime's existing FFmpeg
  to produce a single JPEG preview, without metadata, at most 1536 pixels per
  side and 512 KiB. Failed conversion never falls back to the original bytes.
  """

  @max_bytes 512 * 1024
  @max_source_bytes 10 * 1024 * 1024

  def prepare(body, mime) when is_binary(body) and byte_size(body) <= @max_bytes,
    do: {:ok, body, mime}

  def prepare(body, mime) when is_binary(body) and byte_size(body) <= @max_source_bytes do
    case System.find_executable("ffmpeg") do
      nil -> {:error, :image_preview_unavailable}
      executable -> preview(body, mime, executable)
    end
  end

  def prepare(_body, _mime), do: {:error, :oversized}

  defp preview(body, mime, executable) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-image-#{Base.url_encode64(:crypto.strong_rand_bytes(18))}"
      )

    try do
      File.mkdir!(dir)
      File.chmod!(dir, 0o700)
      input = Path.join(dir, "input")
      File.write!(input, body)

      # Force an image decoder: a disguised playlist must not read files or URLs.
      decoder =
        %{
          "image/png" => "png",
          "image/jpeg" => "mjpeg",
          "image/webp" => "webp",
          "image/gif" => "gif"
        }[mime]

      if is_nil(decoder), do: raise("unsupported image format")

      args = [
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "quiet",
        "-protocol_whitelist",
        "file",
        "-f",
        "image2pipe",
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
        collect(port, System.monotonic_time(:millisecond) + 10_000, "")
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
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
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
