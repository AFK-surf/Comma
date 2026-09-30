defmodule SalixAgent.Tools.Media do
  @moduledoc "Agent-facing image, video, and audio tools."

  alias SalixAgent.{AudioTranscriber, FileBackend, MediaResolver, RuntimeFiles, SkillProjection}

  @image_desc """
  Generate or edit an image using the agent template's configured image model and save it into the agent-visible filesystem.

  Params: prompt (required), input_image_paths (optional array of absolute visible file paths), output_path (absolute visible file path; defaults to /artifacts/generated-image-<id>.jpg), size, aspect_ratio, quality, format, image_size.
  """

  @video_desc """
  Generate a video using the agent template's configured video model and save it into the agent-visible filesystem.

  Params: prompt (required unless input_image_paths is provided), input_image_paths (optional one or two absolute visible file paths), output_path (absolute visible file path; defaults to /artifacts/generated-video-<id>.mp4), resolution, ratio, duration, seed, generate_audio, watermark.
  """

  @audio_transcribe_desc """
  Transcribe an audio or video file from the current agent-visible workspace and save the complete transcript as a text artifact.

  Params: path (required absolute VFS file path, at most 30 MiB), output_path (optional absolute .txt artifact path).

  For video download and transcription requests, the Router delegates a Task to a Worker. The Worker completes these steps:
  1. Download the media in an authorized execution environment that permits file reads.
  2. Use env.copy to import the media into its own VFS.
  3. Call audio.transcribe with that VFS path after the copy succeeds.
  4. Attach the transcript as a file block in a Task Message.

  For Slack files, im_api.slack.fetch_file downloads directly into the calling Worker VFS and returns vfs_path. Use an existing VFS file directly when available.

  The Router reads the exact result Message with im_api.internal.read_conversation. It uses the returned reader-local attachment path to deliver the transcript to the original destination. For Slack, use im_api.slack.upload_file with that path and the original channel/thread. If an existing provider participant already delivers the attachment there, avoid duplicate delivery. A Slack Task card alone does not deliver the file.

  With output_path, a .json sidecar preserves complete ASR chunks and the source path. For immutable meeting attachments, reuse the same source and output_path on retries. The tool reuses the committed transcript without another ASR request. Use a new output_path for changed source bytes. The result reports transcript_path, metadata_path, source duration, and chunk count.
  """

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  @spec defs() :: [
          {String.t(), String.t(), (map(), map() -> term()), pos_integer()}
          | {String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}
        ]
  def defs do
    [
      {"image.generate", String.trim(@image_desc), &__MODULE__.generate_image/2,
       @normal_auto_wait_seconds},
      {"video.generate", String.trim(@video_desc), &__MODULE__.generate_video/2,
       @normal_auto_wait_seconds},
      {"audio.transcribe", String.trim(@audio_transcribe_desc), &__MODULE__.transcribe_audio/2,
       @normal_auto_wait_seconds, safety: "write"}
    ]
  end

  def generate_image(args, ctx) do
    prompt = args |> arg("prompt") |> String.trim()
    if prompt == "", do: raise("prompt is required")

    output =
      output_path(first_arg(args, ["output_path", "path"]), "/artifacts/generated-image-", ".jpg")

    reject_runtime_output!(output)

    cfg = config!(ctx, "image_config")

    inputs = read_input_images(ctx, args["input_image_paths"] || args[:input_image_paths] || [])

    opts =
      [
        config: cfg,
        size: blank_nil(arg(args, "size")),
        aspect_ratio: blank_nil(arg(args, "aspect_ratio")),
        quality: blank_nil(arg(args, "quality")),
        format: blank_nil(first_arg(args, ["format"]) || "jpeg"),
        image_size: blank_nil(arg(args, "image_size")),
        input_images: inputs
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    subscription? = match?(%{"provider_config" => %{"account_pool" => "codex"}}, cfg)

    result =
      if subscription? do
        SalixAgent.LLM.generate_image(prompt, opts, ctx)
      else
        SalixMedia.ImageGen.generate(prompt, opts)
      end

    case result do
      {:ok, %{b64: b64} = result} ->
        bytes = decode_b64!(b64, "image generation failed")
        mime = result[:mime_type] || result["mime_type"] || mime_for_image_path(output)
        output = ensure_ext(output, image_ext(mime))
        write_result(ctx, "image", output, bytes, cfg, prompt, result)

      {:ok, %{url: url}} ->
        "[Generated image available at: #{url}]"

      {:error, _reason} ->
        if subscription?,
          do:
            raise(
              "Codex image generation failed. Check the template's subscription accounts and quota."
            ),
          else: raise("image generation failed")
    end
  end

  def generate_video(args, ctx) do
    input_paths = args["input_image_paths"] || args[:input_image_paths] || []
    prompt = args |> arg("prompt") |> String.trim()
    if prompt == "" and input_paths == [], do: raise("prompt is required")
    unless is_list(input_paths), do: raise("input_image_paths must be an array")

    if length(input_paths) > 2,
      do: raise("at most two input images are supported (first frame, last frame)")

    output =
      output_path(first_arg(args, ["output_path", "path"]), "/artifacts/generated-video-", ".mp4")

    reject_runtime_output!(output)

    cfg = config!(ctx, "video_config")

    inputs = read_input_images(ctx, input_paths)

    opts =
      [
        config: cfg,
        resolution: blank_nil(arg(args, "resolution")),
        ratio: blank_nil(arg(args, "ratio")),
        duration: int_or_nil(args["duration"] || args[:duration]),
        seed: int_or_nil(args["seed"] || args[:seed]),
        generate_audio: bool_or_nil(args["generate_audio"] || args[:generate_audio]),
        watermark: bool_or_nil(args["watermark"] || args[:watermark]),
        input_images: inputs
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case SalixMedia.VideoGen.generate(prompt, opts) do
      {:ok, %{b64: b64} = result} ->
        bytes = decode_b64!(b64, "video generation failed")
        mime = result[:mime_type] || result["mime_type"] || "video/mp4"
        output = ensure_ext(output, video_ext(mime))
        write_result(ctx, "video", output, bytes, cfg, prompt, result)

      {:ok, %{url: url}} ->
        "[Generated video available at: #{url}]"

      {:error, {:http, status, body}} when status in 400..499 ->
        raise "video generation failed: #{client_error_message(body)}"

      {:error, _reason} ->
        raise "video generation failed"
    end
  end

  def transcribe_audio(args, ctx) do
    path = args |> arg("path") |> to_string() |> String.trim()
    validate_audio_path!(path)

    output = blank_nil(arg(args, "output_path"))

    if output do
      validate_audio_path!(output)
      unless String.ends_with?(output, ".txt"), do: raise("output_path must end in .txt")
      reject_runtime_output!(output)
    end

    case cached_transcript(ctx, path, output) do
      {:ok, content} -> {content, []}
      :missing -> transcribe_audio_source(ctx, path, output)
    end
  end

  defp transcribe_audio_source(ctx, path, output) do
    case AudioTranscriber.transcribe(ctx.agent_id, path) do
      {:ok, %{transcript: transcript, duration_seconds: duration_seconds, chunks: chunks}}
      when is_binary(transcript) and transcript != "" and is_integer(duration_seconds) and
             duration_seconds > 0 and is_list(chunks) ->
        write_transcript_result(ctx, path, transcript, duration_seconds, chunks, output)

      {:ok, _invalid_result} ->
        raise "audio transcription failed"

      {:error, :asr_not_configured} ->
        raise "audio transcription is not configured"

      {:error, :not_found} ->
        raise "audio file not found"

      {:error, :asr_audio_empty} ->
        raise "audio file is empty"

      {:error, :asr_audio_too_large} ->
        raise "audio file exceeds the supported size"

      {:error, reason} when reason in [:asr_batch_timeout, :ffmpeg_timeout, :ffprobe_timeout] ->
        raise "audio transcription timed out"

      {:error, _reason} ->
        raise "audio transcription failed"
    end
  end

  defp validate_audio_path!(path) do
    cond do
      path == "" -> raise "path is required"
      not String.starts_with?(path, "/") -> raise "path must be an absolute visible file path"
      not FileBackend.normal_path?(path) -> raise "path must be a normal visible file path"
      true -> :ok
    end
  end

  # This sidecar is a resumable output, not a security proof or a source freshness check.
  # Meeting attachments are immutable; generic callers must choose a new output for changed bytes.
  defp cached_transcript(_ctx, _source, nil), do: :missing

  defp cached_transcript(ctx, source, output) do
    case FileBackend.read(ctx, Path.rootname(output) <> ".json") do
      {:error, :not_found} ->
        :missing

      {:ok, body, _} ->
        with {:ok, %{"source_path" => ^source, "transcript_path" => ^output} = result} <-
               Jason.decode(body),
             {:ok, transcript, _} when byte_size(transcript) > 0 <- FileBackend.read(ctx, output) do
          {:ok, Jason.encode!(Map.drop(result, ["chunks", "calibration"]))}
        else
          _ ->
            raise "Saved transcript cannot be reused. Inspect the existing artifacts before retrying."
        end

      {:error, _} ->
        raise "Cannot read saved transcript. Retry when workspace storage is available."
    end
  end

  defp write_transcript_result(ctx, source_path, transcript, duration_seconds, chunks, requested) do
    output =
      requested ||
        "/artifacts/transcripts/audio-transcript-" <>
          Integer.to_string(System.unique_integer([:positive])) <> ".txt"

    result = %{
      "source_path" => source_path,
      "transcript_path" => output,
      "duration_seconds" => duration_seconds,
      "chunk_count" => length(chunks)
    }

    with {:ok, event} <- FileBackend.prepare_write(ctx, output, transcript) do
      if requested do
        metadata_path = Path.rootname(output) <> ".json"
        result = Map.put(result, "metadata_path", metadata_path)

        metadata =
          result
          |> Map.put("chunks", chunks)
          |> Map.put("calibration", %{
            "status" => "unavailable",
            "reason" => "No independent captions were supplied to audio.transcribe."
          })

        case FileBackend.prepare_write(ctx, metadata_path, Jason.encode!(metadata)) do
          {:ok, metadata_event} -> {Jason.encode!(result), [event, metadata_event]}
          {:error, _} -> raise "write audio transcript metadata failed"
        end
      else
        {Jason.encode!(result), [event]}
      end
    else
      {:error, :too_large} -> raise "audio transcript exceeds the workspace file size limit"
      {:error, _} -> raise "write audio transcript failed"
    end
  end

  defp config!(ctx, key) do
    cfg =
      case MediaResolver.resolve(ctx.agent_id) do
        {:ok, nil} -> %{}
        {:ok, media} -> media[key] || %{}
        {:error, reason} -> raise "resolve media config failed: #{inspect(reason)}"
      end

    if MediaResolver.generation_configured?(cfg),
      do: cfg,
      else: raise("#{key} is not configured for this agent")
  end

  defp read_input_images(ctx, paths) when is_list(paths) do
    Enum.map(paths, fn raw ->
      path = raw |> to_string() |> String.trim()

      unless String.starts_with?(path, "/"),
        do: raise("input image path must be an absolute visible file path")

      case FileBackend.read(ctx, path) do
        {:ok, bytes, false} ->
          %{
            data: bytes,
            mime_type: mime_for_image_path(path),
            filename: Path.basename(path),
            size: byte_size(bytes)
          }

        {:ok, _bytes, true} ->
          raise "input image is too large"

        {:error, :not_found} ->
          raise "input image not found"

        {:error, reason} ->
          raise "read input image failed: #{inspect(reason)}"
      end
    end)
  end

  defp read_input_images(_ctx, _), do: raise("input_image_paths must be an array")

  defp write_result(ctx, kind, path, bytes, cfg, prompt, provider_result) do
    case FileBackend.prepare_write(ctx, path, bytes) do
      {:ok, event} ->
        model = cfg["model"] || cfg[:model] || ""
        text = "[Generated #{kind}: #{path}, #{byte_size(bytes)} bytes, model: #{model}]"
        text = append_revised_prompt(text, provider_result)
        {text <> "\nGeneration prompt: " <> prompt, [event]}

      {:error, :too_large} ->
        raise "generated #{kind} exceeds the 10MB cap"

      {:error, reason} ->
        raise "write generated #{kind} failed: #{inspect(reason)}"
    end
  end

  defp append_revised_prompt(text, result) do
    revised = result[:revised_prompt] || result["revised_prompt"] || ""

    if String.trim(to_string(revised)) == "",
      do: text,
      else: text <> "\nRevised prompt: " <> String.trim(to_string(revised))
  end

  defp output_path(path, prefix, ext) do
    path = to_string(path || "") |> String.trim()

    cond do
      path == "" -> prefix <> Integer.to_string(System.unique_integer([:positive])) <> ext
      String.starts_with?(path, "/") -> path
      true -> raise("output_path must be an absolute visible file path")
    end
  end

  defp reject_runtime_output!(path) do
    if RuntimeFiles.matches?(path) and not SkillProjection.matches?(path),
      do: raise("#{RuntimeFiles.prefix()} is read-only")
  end

  defp ensure_ext(path, ""), do: path
  defp ensure_ext(path, ext), do: if(Path.extname(path) == "", do: path <> ext, else: path)

  defp decode_b64!(b64, error) do
    case Base.decode64(b64) do
      {:ok, bytes} -> bytes
      :error -> raise error
    end
  end

  defp image_ext("image/png"), do: ".png"
  defp image_ext("image/webp"), do: ".webp"
  defp image_ext(_), do: ".jpg"
  defp video_ext(_), do: ".mp4"

  defp mime_for_image_path(path) do
    case String.downcase(Path.extname(path)) do
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  defp client_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp client_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp client_error_message(body) when is_binary(body), do: body
  defp client_error_message(body), do: inspect(body)

  defp blank_nil(v), do: if(String.trim(to_string(v || "")) == "", do: nil, else: to_string(v))
  defp int_or_nil(v) when is_integer(v), do: v
  defp int_or_nil(v) when is_binary(v), do: if(v == "", do: nil, else: String.to_integer(v))
  defp int_or_nil(_), do: nil
  defp bool_or_nil(v) when is_boolean(v), do: v
  defp bool_or_nil(_), do: nil

  defp arg(args, key), do: args[key] || args[String.to_atom(key)] || ""

  defp first_arg(args, keys) do
    Enum.find_value(keys, fn key ->
      value = arg(args, key) |> to_string() |> String.trim()
      if value == "", do: nil, else: value
    end)
  end
end
