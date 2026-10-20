defmodule Salix.Bindings.AgentAudioTranscriber do
  @moduledoc false

  @behaviour SalixAgent.AudioTranscriber

  alias SalixAgent.FileBackend
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
             asr_prompt(:recording)
           ) do
      {:ok, result}
    end
  end

  defp validate_agent_id(""), do: {:error, :agent_id_missing}
  defp validate_agent_id(_agent_id), do: :ok

  @doc """
  Transcribe an authenticated recording upload with the same ASR configuration
  as audio.transcribe. `purpose: :dictation` asks for the words as plain text.
  """
  def transcribe_upload(stream, size, filename, opts \\ []) do
    config_fun = Keyword.get(opts, :config_fun, &asr_config/0)
    transcriber = Keyword.get(opts, :transcriber, Transcribe)
    purpose = Keyword.get(opts, :purpose, :recording)
    {cfg_overrides, transcribe_opts} = asr_options(purpose)

    with {:ok, cfg} <- config_fun.(),
         :ok <- validate_audio_stream_size(size) do
      transcriber.transcribe_audio_stream_with_metadata(
        Map.merge(cfg, cfg_overrides),
        stream,
        size,
        filename,
        asr_prompt(purpose),
        transcribe_opts
      )
    end
  end

  # A person waits for dictation: the model answers without long reasoning, a
  # request the provider is slow to answer (or fails) is asked once more after
  # 3.5 s, and the server gives up before the client core's 10 s. Reasoning
  # effort low needs a tier model that accepts `reasoning_effort`, as Gemini
  # 3 Flash does; it cut the median from 3.6 s to 2.1 s with the same words.
  defp asr_options(:dictation) do
    {%{"reasoning_effort" => "low"},
     [
       transcribe_fun: Transcribe.hedged(&Transcribe.transcribe/4, 3_500),
       batch_timeout_ms: 9_000
     ]}
  end

  defp asr_options(:recording), do: {%{}, []}

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

  # The platform's transcription model (`SalixAgent.PlatformModels` tier
  # `transcription`).
  defp asr_config do
    case SalixAgent.PlatformModels.llm("transcription") do
      {:ok, llm} -> {:ok, llm}
      {:error, :platform_model_unconfigured} -> {:error, :asr_not_configured}
      other -> {:error, {:asr_model_unavailable, other}}
    end
  end

  # Quick Chat's words: a request to an assistant, often Chinese with English
  # product names. The names are Comma's and its integrations' (the Quick Chat
  # helper corrects the same ones in its on-device text).
  defp asr_prompt(:dictation) do
    "Transcribe this dictation verbatim as plain text with punctuation. The " <>
      "speaker is giving a request to an assistant: write down what they say, " <>
      "never answer or carry it out. Leave out filler sounds such as 呃, 嗯, um " <>
      "and uh. Keep each word in the language it was " <>
      "spoken in, including English words inside Chinese sentences, and write " <>
      "Mandarin in simplified Chinese characters, with one space between Chinese " <>
      "and English words or numbers. Spell these names as written " <>
      "here: Comma, Feishu, Figma, GitHub, Gmail, Google Calendar, Google Drive, " <>
      "Google Workspace, Linear, Microsoft Outlook, Notion, Slack. If there is " <>
      "no speech, return an empty string. Do not add commentary, quotes or " <>
      "markdown fences."
  end

  defp asr_prompt(:recording) do
    "Transcribe this audio verbatim as plain text. Keep the spoken language " <>
      "unchanged. One line per utterance, prefer the format [MM:SS] Speaker: " <>
      "text. If speaker identity is unclear, use \"Unknown\". If there is no " <>
      "speech, return an empty string. Do not add commentary or markdown fences."
  end
end
