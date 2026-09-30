defmodule Comma.GroupFiles do
  @moduledoc """
  Chat attachments written into the current Group Router's VFS.
  """

  @image_upload_extensions ~w(.png .jpg .jpeg .gif .webp)
  @text_upload_extensions ~w(.md .markdown .txt .csv .tsv .json .jsonl .xml .yaml .yml .toml .html .htm .log)
  # Stored verbatim for the agent; only the image set is ever read back as media.
  @document_upload_extensions ~w(.pdf .doc .docx .xls .xlsx .ppt .pptx .svg)
  @media_upload_extensions ~w(.mp3 .wav .m4a .aac .flac .ogg .mp4 .mov .m4v .webm)
  @max_upload_bytes 10_000_000
  @max_image_read_bytes @max_upload_bytes + 1
  @max_upload_path_bytes 4_096
  @max_image_edge 4_096
  @max_image_pixels 16_777_216
  @max_jpeg_header_bytes 1_048_576
  @jpeg_sof_markers [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
  @jpeg_standalone_markers [0x01, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8]
  @upload_image_path ~r|\A/uploads/[A-Za-z0-9_-]{22}-[A-Za-z0-9._-]+\z|
  @image_content_types %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }

  def allowed_extensions,
    do:
      @image_upload_extensions ++
        @text_upload_extensions ++ @document_upload_extensions ++ @media_upload_extensions
  def max_upload_bytes, do: @max_upload_bytes

  def store(group_scope, filename, binary)
      when is_map(group_scope) and is_binary(binary) do
    name = filename |> filename_to_string() |> nonblank("file")

    with :ok <- validate_extension(name),
         :ok <- validate_size(binary),
         path <- upload_path(name),
         {:ok, _result} <-
           Comma.Salix.Client.impl().write_agent_file(group_scope, path, binary) do
      {:ok, %{"path" => path, "name" => name, "size" => byte_size(binary)}}
    end
  end

  @doc """
  Read one uploaded image through its compatibility Router VFS locator.

  The path shape and extension are admission checks, not trusted media
  identity: the bounded body is also checked against the corresponding image
  signature and header dimensions. Invalid paths, non-images, missing objects,
  oversized dimensions, and bodies outside the upload bound all fail closed as
  `:not_found`.
  """
  @spec fetch_image(map(), term()) :: {:ok, String.t(), binary()} | {:error, term()}
  def fetch_image(group_scope, path) when is_map(group_scope) do
    with {:ok, content_type} <- image_content_type(path),
         {:ok, body} when is_binary(body) <-
           Comma.Salix.Client.impl().read_agent_file(
             group_scope,
             path,
             @max_image_read_bytes
           ),
         true <- byte_size(body) <= @max_upload_bytes,
         {:ok, width, height} <- image_dimensions(content_type, body),
         true <- valid_image_dimensions?(width, height) do
      {:ok, content_type, body}
    else
      false -> {:error, :not_found}
      {:error, :too_large} -> {:error, :not_found}
      {:ok, _invalid_body} -> {:error, :workspace_file_unavailable}
      {:error, _reason} = error -> error
      _invalid -> {:error, :workspace_file_unavailable}
    end
  end

  def fetch_image(_group_scope, _path), do: {:error, :not_found}

  defp validate_extension(filename) do
    if String.downcase(Path.extname(filename)) in allowed_extensions() do
      :ok
    else
      {:error, :unsupported_file_type}
    end
  end

  defp validate_size(binary) when byte_size(binary) > @max_upload_bytes,
    do: {:error, :file_too_large}

  defp validate_size(_binary), do: :ok

  defp image_content_type(path)
       when is_binary(path) and byte_size(path) <= @max_upload_path_bytes do
    if String.valid?(path) and Regex.match?(@upload_image_path, path) do
      case Map.fetch(@image_content_types, String.downcase(Path.extname(path))) do
        {:ok, content_type} -> {:ok, content_type}
        :error -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp image_content_type(_path), do: {:error, :not_found}

  defp image_dimensions(
         "image/gif",
         <<version::binary-size(6), width::little-16, height::little-16,
           _descriptor::binary-size(3), _rest::binary>>
       )
       when version in ["GIF87a", "GIF89a"],
       do: {:ok, width, height}

  defp image_dimensions(
         "image/png",
         <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32,
           _ihdr_tail_and_crc::binary-size(9), _rest::binary>>
       ),
       do: {:ok, width, height}

  defp image_dimensions("image/jpeg", <<0xFF, 0xD8, rest::binary>>) do
    header_bytes = min(byte_size(rest), @max_jpeg_header_bytes)
    rest |> binary_part(0, header_bytes) |> jpeg_dimensions()
  end

  defp image_dimensions(
         "image/webp",
         <<"RIFF", _riff_size::little-32, "WEBP", "VP8X", chunk_size::little-32,
           _flags_and_reserved::binary-size(4), width_minus_one::little-24,
           height_minus_one::little-24, _rest::binary>>
       )
       when chunk_size >= 10,
       do: {:ok, width_minus_one + 1, height_minus_one + 1}

  defp image_dimensions(
         "image/webp",
         <<"RIFF", _riff_size::little-32, "WEBP", "VP8 ", chunk_size::little-32,
           _frame_tag::binary-size(3), 0x9D, 0x01, 0x2A, width_bits::little-16,
           height_bits::little-16, _rest::binary>>
       )
       when chunk_size >= 10,
       do: {:ok, Bitwise.band(width_bits, 0x3FFF), Bitwise.band(height_bits, 0x3FFF)}

  defp image_dimensions(
         "image/webp",
         <<"RIFF", _riff_size::little-32, "WEBP", "VP8L", chunk_size::little-32, 0x2F,
           dimension_bits::little-32, _rest::binary>>
       )
       when chunk_size >= 5 do
    width = Bitwise.band(dimension_bits, 0x3FFF) + 1
    height = Bitwise.band(Bitwise.bsr(dimension_bits, 14), 0x3FFF) + 1
    {:ok, width, height}
  end

  defp image_dimensions(_content_type, _body), do: {:error, :not_found}

  defp jpeg_dimensions(<<0xFF, 0xFF, rest::binary>>),
    do: jpeg_dimensions(<<0xFF, rest::binary>>)

  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>) when marker in @jpeg_sof_markers do
    with {:ok, payload, _tail} <- jpeg_segment(rest),
         <<_precision, height::16, width::16, _components::binary>> <- payload do
      {:ok, width, height}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>)
       when marker in @jpeg_standalone_markers,
       do: jpeg_dimensions(rest)

  defp jpeg_dimensions(<<0xFF, marker, _rest::binary>>) when marker in [0x00, 0xD9, 0xDA],
    do: {:error, :not_found}

  defp jpeg_dimensions(<<0xFF, _marker, rest::binary>>) do
    with {:ok, _payload, tail} <- jpeg_segment(rest) do
      jpeg_dimensions(tail)
    end
  end

  defp jpeg_dimensions(_body), do: {:error, :not_found}

  defp jpeg_segment(<<length::16, rest::binary>>) when length >= 2 do
    payload_bytes = length - 2

    if byte_size(rest) >= payload_bytes do
      <<payload::binary-size(^payload_bytes), tail::binary>> = rest
      {:ok, payload, tail}
    else
      {:error, :not_found}
    end
  end

  defp jpeg_segment(_body), do: {:error, :not_found}

  defp valid_image_dimensions?(width, height) do
    is_integer(width) and is_integer(height) and width > 0 and height > 0 and
      width <= @max_image_edge and height <= @max_image_edge and
      width * height <= @max_image_pixels
  end

  defp upload_path(filename) do
    safe =
      filename
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> safe_upload_name(filename)

    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    "/uploads/#{token}-#{safe}"
  end

  defp safe_upload_name("", filename), do: "file" <> String.downcase(Path.extname(filename))
  defp safe_upload_name("." <> _rest = ext_only, _filename), do: "file" <> ext_only
  defp safe_upload_name(name, _filename), do: name

  defp nonblank("", fallback), do: fallback
  defp nonblank(value, _fallback), do: value

  defp filename_to_string(nil), do: ""
  defp filename_to_string(filename), do: to_string(filename)
end
