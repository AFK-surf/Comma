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
  alias SalixAgent.ImageRefs.ScreenshotCache

  # Anthropic's hard per-image cap is 5MB; use one cap across providers.
  @max_inline_bytes 5 * 1024 * 1024

  # Keep the outbound image set to formats accepted by both OpenAI Responses
  # and Anthropic. `SalixMedia.ImageInput` converts HEIC/HEIF, BMP, TIFF and AVIF
  # to JPEG. SVG is a common provider upload but is not a valid native image
  # input; it needs an explicit local conversion.
  @native_image_mimes MapSet.new(
                        ~w(image/png image/jpeg image/webp image/gif image/heic image/heif image/bmp image/x-ms-bmp image/tiff image/avif)
                      )
  @native_image_extensions %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif",
    ".heic" => "image/heic",
    ".heif" => "image/heif",
    ".bmp" => "image/bmp",
    ".tif" => "image/tiff",
    ".tiff" => "image/tiff",
    ".avif" => "image/avif"
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
        projected_block(block, ctx)

      {:request_result, seq} ->
        case ctx[:async_result_resolver] || ctx["async_result_resolver"] do
          resolver when is_function(resolver, 1) -> project_result(resolver.(seq), ctx)
          _ -> :error
        end
    end
  end

  defp project_result({:ok, record} = result, %{ifc_projection: %{} = projection}) do
    block = record["result"] || record[:result] || %{}
    label = SalixAgent.IFC.ContextProjection.label(block) |> SalixIFC.Codec.encode_label()

    if SalixAgent.IFC.ContextProjection.visible_label?(label, projection),
      do: result,
      else: :error
  end

  defp project_result(result, _ctx), do: result

  # Read label and immutable blob ref from one manifest snapshot. A later path
  # replacement cannot substitute bytes after the visibility decision.
  defp projected_block(%{"type" => "image"} = block, %{ifc_projection: %{} = projection} = ctx) do
    case block do
      %{"file_ref" => %{"environment_id" => "vfs", "path" => path}} ->
        with {:ok, entry} <- SalixAgent.AgentWorkspace.entry(ctx_agent_id(ctx), path),
             true <-
               SalixAgent.IFC.ContextProjection.visible_label?(entry["ifc_label"], projection),
             size when is_integer(size) and size <= @max_inline_bytes <- entry["size"],
             {:ok, body} <- SalixStore.Blob.get(ctx_agent_id(ctx), entry["ref"]) do
          resolve_block(block, Map.put(ctx, :ifc_image_body, {path, body}))
        else
          _ -> []
        end

      _ ->
        # A mutable remote path has no owner-held snapshot audience.
        []
    end
  end

  defp projected_block(block, ctx), do: resolve_block(block, ctx)

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
      # Each request of the reply inlines this screenshot again; the cache keeps
      # it the same in all of them, also after the device deletes it.
      ScreenshotCache.key(ctx, device, environment, path)
      |> ScreenshotCache.fetch(fn -> prepare_image(block, path, ctx) end)
      |> image_blocks(block, path)
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

  defp resolve_image(block, path, ctx),
    do: block |> prepare_image(path, ctx) |> image_blocks(block, path)

  defp image_blocks({:ok, blocks}, _block, _path), do: blocks

  defp image_blocks({:error, reason}, block, path),
    do: [image_fallback_block(block, path, reason)]

  defp prepare_image(block, path, ctx) do
    with {:ok, mime} <- native_image_mime(block, path) do
      case read_body(ctx, path, block) do
        {:ok, body} when byte_size(body) <= @max_inline_bytes ->
          if animated_gif?(mime, body) do
            {:error, :animated_gif}
          else
            case SalixMedia.ImageInput.prepare(body, mime) do
              {:ok, preview, preview_mime} ->
                {:ok,
                 [
                   %{
                     "type" => "image_url",
                     "image_url" => %{
                       "url" => "data:#{preview_mime};base64," <> Base.encode64(preview)
                     }
                   }
                 ]}

              {:error, reason} ->
                {:error, reason}
            end
          end

        {:ok, _body} ->
          {:error, :oversized}

        {:error, :too_large} ->
          {:error, :oversized}

        {:error, reason} ->
          {:error, reason}
      end
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

  defp read_body(%{ifc_image_body: {path, body}}, path, _block), do: {:ok, body}

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
      other -> {:error, device_read_failure(other)}
    end
  end

  defp read_body(ctx, path, _block) do
    case FileBackend.read(ctx, path) do
      {:ok, body, false} -> {:ok, body}
      {:ok, _body, true} -> {:error, :too_large}
      {:error, _} = err -> err
    end
  end

  # Why a device screenshot read failed, as the model and a diagnosis need it.
  # The connector answers a missing capture file with this exact text
  # (systems/station/src/connector/computer-use.ts `readImage`); the file is
  # usually gone because the device deletes it 15 minutes after capture.
  defp device_read_failure(
         {:ok, %{"ok" => false, "error" => "screenshot expired or unavailable"}}
       ),
       do: :screenshot_expired

  defp device_read_failure({:ok, %{"ok" => false, "error" => "screenshot exceeds 5 MiB"}}),
    do: :oversized

  # `:no_environment` also covers a device the agent cannot resolve or may not
  # use (`SalixWeb.EnvDispatch.with_vm_operation`); `:disconnected` is a device
  # that dropped during the read (`SalixWeb.ConnectorRecovery`).
  defp device_read_failure({:error, reason}) when reason in [:no_environment, :disconnected],
    do: :device_unreachable

  defp device_read_failure({:error, :timeout}), do: :device_timeout
  defp device_read_failure(_other), do: :device_read_failed

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

  # A screenshot that expired was usually shown in earlier requests. Say so, or
  # the model reads its own earlier description of it as a mistake.
  defp image_fallback_block(block, path, :screenshot_expired) do
    %{
      "type" => "text",
      "text" =>
        "[Device screenshot #{file_name(block, path)} is no longer on the device " <>
          "(reason=screenshot_expired): the device deletes screenshots 15 minutes after capture. " <>
          "An earlier request may have shown it to you, and what you saw then was true at that time. " <>
          "Do not infer its contents now. Capture again if you need the current screen.]"
    }
  end

  defp image_fallback_block(block, path, reason) do
    reason =
      case reason do
        :oversized -> "oversized"
        :unsupported_format -> "unsupported_format"
        :animated_gif -> "animated_gif"
        :not_found -> "not_found"
        :device_unreachable -> "device_unreachable"
        :device_timeout -> "device_timeout"
        :device_read_failed -> "device_read_failed"
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
            do: "Do not infer image contents. Capture again if you need the screen.]",
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
  # accepts the formats no provider takes and nothing here converts — an SVG is
  # still an image to the person who sent it.
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
