defmodule SalixAgent.ImageRefs do
  @moduledoc """
  Resolve workspace and temporary device image blocks at LLM-request build time.

  An image reaches a model on exactly one route: the agent read it with a tool,
  and `SalixAgent.MediaResolver.supports_images?/2` says the selected request model
  accepts image input. Both conditions are checked here, at the one seam every
  provider request passes through, so no producer of image blocks can add a
  second route by accident.

  An inbound attachment is never model input. A user who sends a photo gets the
  same treatment as one who sends a PDF: the kernel presents the attachment
  here as a workspace file, and it is announced as a text note carrying its
  filename and VFS path. The agent then inspects it with its own tools —
  `fs.read_file`, which is where the image-capability decision lives and where
  a configured vision describer turns an image into text for a model that
  cannot see it.

  Reading an attachment is tool work, not context. Bytes the agent never asked
  for cost tokens on every later request in the session, and an image sent to a
  model that does not accept one produces a provider rejection that can only be
  classified by string-matching provider error prose.

  The journal keeps only the provider-neutral file reference. Raw bytes are
  materialized only in the outbound request, so session replay stays small and
  deterministic.
  """

  alias SalixAgent.{FileBackend, MediaResolver}

  # Anthropic's hard per-image cap is 5MB; use one cap across providers.
  @max_inline_bytes 5 * 1024 * 1024

  # Keep the outbound image set to formats accepted by both OpenAI Responses
  # and Anthropic. HEIC/HEIF, TIFF and SVG are common provider uploads but are
  # not valid native image inputs; those need an explicit local conversion.
  @native_image_mimes MapSet.new(~w(image/png image/jpeg image/webp image/gif))
  @native_image_extensions %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  @doc "Inline activation-scoped native VFS blocks in request-bound messages."
  def inline(messages, ctx) do
    project(
      {:inline_attachments, messages,
       ctx[:attachment_after_message_id] || ctx["attachment_after_message_id"],
       ctx[:materialize_native_attachments] != false and
         ctx["materialize_native_attachments"] != false},
      ctx
    )
  end

  @doc false
  def trusted_source_blocks(message, ctx \\ %{}),
    do: project({:attachment_source, message}, ctx)

  defp project(args, ctx) do
    session = SalixVerifiedKernel.Session.open(%{__struct__: SalixAgent.InternalSession.State})
    SalixVerifiedKernel.Session.query(session, :provider_request_part, args, reader(ctx))
  end

  @doc false
  def reader(ctx) do
    fn
      {:request_image, block} ->
        resolve_block(block, ctx)

      {:request_result, seq} ->
        case ctx[:async_result_resolver] || ctx["async_result_resolver"] do
          resolver when is_function(resolver, 1) -> resolver.(seq)
          _ -> :error
        end
    end
  end

  # Only a tool read reaches here as an image — the kernel hands every inbound
  # attachment over as a file — so this is the last gate before bytes become
  # model input, and it is the capability one.
  defp resolve_block(
         %{"type" => "image", "file_ref" => %{"environment_id" => "vfs", "path" => path}} = block,
         ctx
       ) do
    if MediaResolver.supports_images?(ctx_agent_id(ctx), ctx) do
      resolve_image(block, path, ctx)
    else
      [workspace_note_block(block, path)]
    end
  end

  defp resolve_block(
         %{
           "type" => "image",
           "file_ref" => %{
             "device_id" => device,
             "environment_id" => environment,
             "path" => path
           }
         } = block,
         ctx
       )
       when is_binary(device) and device != "" and is_binary(environment) and
              environment not in ["", "vfs"] and is_binary(path) do
    if MediaResolver.supports_images?(ctx_agent_id(ctx), ctx) do
      resolve_image(block, path, ctx)
    else
      [image_fallback_block(block, path, :unsupported_model)]
    end
  end

  # A document is never model input, and neither is an inbound attachment of
  # any type. Announce it and let the agent read it with the tools it already
  # has; no provider parses these bytes for us.
  defp resolve_block(%{"type" => "file"} = block, _ctx) do
    path = file_path(block)
    [workspace_note_block(block, path)]
  end

  defp resolve_block(block, _ctx), do: [block]

  defp resolve_image(block, path, ctx) do
    with {:ok, mime} <- native_image_mime(block, path) do
      case read_body(ctx, path, block) do
        {:ok, body} when byte_size(body) <= @max_inline_bytes ->
          if animated_gif?(mime, body) do
            [image_fallback_block(block, path, :animated_gif)]
          else
            case SalixMedia.ImageInput.prepare(body, mime) do
              {:ok, preview, preview_mime} ->
                [
                  %{
                    "type" => "image_url",
                    "image_url" => %{
                      "url" => "data:#{preview_mime};base64," <> Base.encode64(preview)
                    }
                  }
                ]

              {:error, reason} ->
                [image_fallback_block(block, path, reason)]
            end
          end

        {:ok, _body} ->
          [image_fallback_block(block, path, :oversized)]

        {:error, :too_large} ->
          [image_fallback_block(block, path, :oversized)]

        {:error, reason} ->
          [image_fallback_block(block, path, reason)]
      end
    else
      {:error, reason} -> [image_fallback_block(block, path, reason)]
    end
  end

  defp animated_gif?("image/gif", body), do: gif_frame_count(body) > 1
  defp animated_gif?(_mime, _body), do: false

  defp gif_frame_count(
         <<"GIF", _version::binary-size(3), _width::binary-size(2), _height::binary-size(2),
           packed, _background, _aspect, rest::binary>>
       ) do
    table_bytes = if packed >= 0x80, do: 3 * round(:math.pow(2, rem(packed, 8) + 1)), else: 0

    case rest do
      <<_table::binary-size(^table_bytes), blocks::binary>> -> gif_frame_count(blocks, 0)
      _ -> 0
    end
  end

  defp gif_frame_count(_body), do: 0
  defp gif_frame_count(_blocks, count) when count > 1, do: count
  defp gif_frame_count(<<0x3B, _rest::binary>>, count), do: count

  defp gif_frame_count(
         <<0x2C, _descriptor::binary-size(8), packed, rest::binary>>,
         count
       ) do
    table_bytes = if packed >= 0x80, do: 3 * round(:math.pow(2, rem(packed, 8) + 1)), else: 0

    with <<_table::binary-size(^table_bytes), _lzw_code_size, data::binary>> <- rest,
         {:ok, tail} <- skip_gif_subblocks(data) do
      gif_frame_count(tail, count + 1)
    else
      _ -> count
    end
  end

  defp gif_frame_count(<<0x21, _label, data::binary>>, count) do
    case skip_gif_subblocks(data) do
      {:ok, tail} -> gif_frame_count(tail, count)
      _ -> count
    end
  end

  defp gif_frame_count(_blocks, count), do: count

  defp skip_gif_subblocks(<<0, rest::binary>>), do: {:ok, rest}

  defp skip_gif_subblocks(<<size, _data::binary-size(size), rest::binary>>),
    do: skip_gif_subblocks(rest)

  defp skip_gif_subblocks(_), do: :error

  defp native_image_mime(block, path) do
    declared =
      block["mime_type"]
      |> to_string()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.downcase()
      |> String.trim()

    inferred = @native_image_extensions[path |> Path.extname() |> String.downcase()]

    cond do
      MapSet.member?(@native_image_mimes, declared) -> {:ok, declared}
      declared in ["", "application/octet-stream"] and is_binary(inferred) -> {:ok, inferred}
      true -> {:error, :unsupported_format}
    end
  end

  defp read_body(ctx, path, %{
         "file_ref" => %{
           "device_id" => device,
           "environment_id" => environment
         }
       })
       when is_binary(device) and device != "" and is_binary(environment) and
              environment not in ["", "vfs"] do
    target = %{device_id: device, environment_id: environment}
    request = %{"action" => "read_image", "args" => %{"path" => path}}

    with {:ok, %{"ok" => true, "image_base64" => encoded}} when is_binary(encoded) <-
           SalixAgent.EnvDispatch.computer_use(ctx_agent_id(ctx), target, request),
         true <- byte_size(encoded) <= 4 * div(@max_inline_bytes + 2, 3),
         {:ok, body} <- Base.decode64(encoded) do
      {:ok, body}
    else
      false -> {:error, :too_large}
      _ -> {:error, :device_image_unavailable}
    end
  end

  defp read_body(ctx, path, _block) do
    case FileBackend.read(ctx, path) do
      {:ok, body, false} -> {:ok, body}
      {:ok, _body, true} -> {:error, :too_large}
      {:error, _} = err -> err
    end
  end

  defp file_path(%{"path" => path}) when is_binary(path), do: path

  defp file_path(%{"file_ref" => %{"environment_id" => "vfs", "path" => path}})
       when is_binary(path),
       do: path

  defp file_path(_block), do: ""

  defp file_name(block, path) do
    [block["file_name"], block["filename"], block["title"], Path.basename(path || "")]
    |> Enum.find_value(fn
      value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
      _ -> nil
    end)
    |> case do
      nil -> "attachment"
      value -> Path.basename(value)
    end
  end

  defp image_fallback_block(block, path, reason) do
    reason =
      case reason do
        :oversized -> "oversized"
        :unsupported_format -> "unsupported_format"
        :animated_gif -> "animated_gif"
        :not_found -> "not_found"
        :device_image_unavailable -> "device_offline_or_screenshot_expired"
        :unsupported_model -> "model_does_not_support_images"
        _ -> "unavailable"
      end

    location =
      if is_binary(get_in(block, ["file_ref", "device_id"])) and
           get_in(block, ["file_ref", "environment_id"]) != "vfs",
         do: "device screenshot",
         else: "VFS path"

    %{
      "type" => "text",
      "text" =>
        "[Attached image could not be included as native image input: " <>
          "#{file_name(block, path)} (#{location}: #{path}); reason=#{reason}. " <>
          if(location == "device screenshot",
            do:
              "Do not infer image contents. Capture again if the device screenshot has expired.]",
            else: inspect_guidance()
          )
    }
  end

  # Not an error path. Every inbound attachment arrives as this note, and so
  # does an image the template's model cannot accept. Both say the same thing
  # to the model, because the same tool answers both.
  defp workspace_note_block(block, path) do
    noun = if image_attachment?(block, path), do: "image", else: "file"

    %{
      "type" => "text",
      "text" =>
        "[Attached #{noun} is available in the agent workspace, not in this request: " <>
          "#{file_name(block, path)} (VFS path: #{path}). " <> inspect_guidance()
    }
  end

  # Names the attachment, nothing more. Unlike `native_image_mime/2` this
  # accepts the formats no provider takes natively — a HEIC photo is still an
  # image to the person who sent it.
  defp image_attachment?(block, path) do
    declared = block["mime_type"] |> to_string() |> String.downcase() |> String.trim()

    String.starts_with?(declared, "image/") or
      match?({:ok, _mime}, native_image_mime(Map.delete(block, "mime_type"), path))
  end

  defp inspect_guidance do
    "Read it yourself before describing it: fs.read_file for text or an image, or stage " <>
      "it on a connected runner with env.copy and convert it with env.exec. That read is " <>
      "refused when the file is an image, this model takes no image input, and no vision " <>
      "describer is configured. Report the failure explicitly if you cannot read it; never " <>
      "guess at its contents.]"
  end

  defp ctx_agent_id(ctx) when is_map(ctx), do: ctx[:agent_id] || ctx["agent_id"]
  defp ctx_agent_id(_ctx), do: nil
end
