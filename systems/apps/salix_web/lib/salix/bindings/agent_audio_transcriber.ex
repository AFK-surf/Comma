defmodule Salix.Bindings.AgentAudioTranscriber do
  @moduledoc false

  @behaviour SalixAgent.AudioTranscriber

  alias SalixAgent.{FileBackend, Templates}
  alias SalixLlm.Transcribe

  @max_audio_bytes 30 * 1024 * 1024

  @impl true
  def transcribe(agent_id, path) do
    transcribe(agent_id, path, [])
  end

  @doc false
  def transcribe(agent_id, path, opts)
      when is_binary(agent_id) and is_binary(path) and is_list(opts) do
    stream_fun = Keyword.get(opts, :stream_fun, &FileBackend.stream/2)
    transcriber = Keyword.get(opts, :transcriber, Transcribe)
    config_fun = Keyword.get(opts, :config_fun, &asr_config/0)

    with {:ok, cfg} <- config_fun.(),
         :ok <- validate_agent_id(agent_id),
         :ok <- validate_path(path),
         {:ok, stream, size} <- stream_fun.(%{agent_id: agent_id}, path),
         :ok <- validate_audio_stream_size(size),
         {:ok, result} <-
           transcriber.transcribe_audio_stream_with_metadata(
             cfg,
             stream,
             size,
             Path.basename(path),
             asr_prompt()
           ) do
      {:ok, result}
    end
  end

  defp validate_agent_id(""), do: {:error, :agent_id_missing}
  defp validate_agent_id(_agent_id), do: :ok

  @doc "Transcribe an authenticated recording upload with the same ASR configuration as audio.transcribe."
  def transcribe_upload(stream, size, filename, opts \\ []) do
    config_fun = Keyword.get(opts, :config_fun, &asr_config/0)
    transcriber = Keyword.get(opts, :transcriber, Transcribe)

    with {:ok, cfg} <- config_fun.(),
         :ok <- validate_audio_stream_size(size) do
      transcriber.transcribe_audio_stream_with_metadata(cfg, stream, size, filename, asr_prompt())
    end
  end

  defp validate_path(""), do: {:error, :audio_path_missing}

  defp validate_path(path) do
    cond do
      not String.starts_with?(path, "/") -> {:error, :audio_path_not_absolute}
      not FileBackend.normal_path?(path) -> {:error, :audio_path_not_visible}
      true -> :ok
    end
  end

  defp validate_audio_stream_size(size)
       when is_integer(size) and size > 0 and size <= @max_audio_bytes,
       do: :ok

  defp validate_audio_stream_size(0), do: {:error, :asr_audio_empty}

  defp validate_audio_stream_size(size)
       when is_integer(size) and size > @max_audio_bytes,
       do: {:error, :asr_audio_too_large}

  defp validate_audio_stream_size(_size), do: {:error, :asr_audio_size_invalid}

  defp asr_config do
    case Application.get_env(:salix_web, :meeting_asr_template) do
      name when is_binary(name) and name != "" ->
        case Templates.resolve_llm_for_template_ref(name) do
          {:ok, llm} when is_map(llm) -> {:ok, llm}
          other -> {:error, {:asr_template_unavailable, other}}
        end

      _ ->
        {:error, :asr_not_configured}
    end
  end

  defp asr_prompt do
    "Transcribe this audio verbatim as plain text. Keep the spoken language " <>
      "unchanged. One line per utterance, prefer the format [MM:SS] Speaker: " <>
      "text. If speaker identity is unclear, use \"Unknown\". If there is no " <>
      "speech, return an empty string. Do not add commentary or markdown fences."
  end
end
