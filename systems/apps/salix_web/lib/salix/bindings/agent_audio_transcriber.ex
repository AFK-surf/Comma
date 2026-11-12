defmodule Salix.Bindings.AgentAudioTranscriber do
  @moduledoc false

  @behaviour SalixAgent.AudioTranscriber

  alias Salix.Bindings.MeetingGlossary
  alias SalixAgent.FileBackend
  alias SalixLlm.Transcribe

  @max_audio_bytes 30 * 1024 * 1024

  @impl true
  def transcribe(agent_id, path) do
    transcribe(agent_id, path, [])
  end

  @impl true
  def transcribe(agent_id, path, opts)
      when is_binary(agent_id) and is_binary(path) and is_list(opts) do
    stream_fun = Keyword.get(opts, :stream_fun, &FileBackend.stream/2)
    transcriber = Keyword.get(opts, :transcriber, Transcribe)
    config_fun = Keyword.get(opts, :config_fun, &asr_config/0)
    {prompt, corrections} = prompt_and_corrections(opts)

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
             prompt,
             voice: true
           ) do
      {:ok, correct_transcript(result, corrections)}
    end
  end

  # `glossary_of: {group_id, tenant_id}` (audio.transcribe) asks with the
  # meeting-recording prompt and the terms of that Group Router's glossary, and
  # applies the glossary's corrections to the transcript text; the chunks stay
  # as the model returned them. `terms:` (the bot path) keeps its own prompt.
  defp prompt_and_corrections(opts) do
    case Keyword.get(opts, :glossary_of) do
      {group_id, tenant_id} when is_binary(group_id) and is_binary(tenant_id) ->
        glossary_fun = Keyword.get(opts, :glossary_fun, &group_glossary/2)
        {terms, corrections} = read_glossary(glossary_fun, group_id, tenant_id)
        {meeting_recording_prompt(terms, Keyword.get(opts, :locale)), corrections}

      _ ->
        {recording_prompt(Keyword.get(opts, :terms, [])), []}
    end
  end

  # A glossary that cannot be read never fails the transcription.
  defp read_glossary(glossary_fun, group_id, tenant_id) do
    case glossary_fun.(group_id, tenant_id) do
      {terms, corrections} when is_list(terms) and is_list(corrections) -> {terms, corrections}
      _ -> {[], []}
    end
  rescue
    _ -> {[], []}
  catch
    _kind, _reason -> {[], []}
  end

  defp group_glossary(group_id, tenant_id) do
    case MeetingGlossary.router_agent(group_id, tenant_id) do
      {:ok, router} -> {MeetingGlossary.load_terms(router), MeetingGlossary.load(router)}
      _ -> {[], []}
    end
  end

  defp correct_transcript(result, []), do: result

  defp correct_transcript(%{transcript: transcript} = result, corrections)
       when is_binary(transcript),
       do: %{result | transcript: MeetingGlossary.apply_to(transcript, corrections)}

  defp correct_transcript(result, _corrections), do: result

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
    transcribe_opts = Keyword.merge(transcribe_opts, Keyword.take(opts, [:transcribe_fun]))

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

  @doc """
  The words of one live dictation segment, 16 kHz mono s16le PCM, as
  dictation: what `CommaWeb.DictationSocket` sends as the segment's final words.

  On short audio the model can answer with a whole made-up request (a second
  of speech gave four sentences about Notion and Slack). Dictation is asked
  with voice facts (`asr_options/1`), so words more than anyone says in the
  audio's voiced time are dropped, and the answer is `:asr_empty_transcript`.
  """
  def transcribe_dictation(pcm, opts \\ []) when is_binary(pcm) do
    wav = wav(pcm)

    case transcribe_upload([wav], byte_size(wav), "dictation.wav", [purpose: :dictation] ++ opts) do
      {:ok, %{transcript: transcript}} -> {:ok, transcript}
      {:error, _reason} = error -> error
    end
  end

  # The chunker checks that its MP3 keeps every sample; MP3 frames hold 1152,
  # so silence pads the audio to whole frames.
  defp wav(pcm) do
    rate = 16_000
    pcm = pcm <> :binary.copy(<<0>>, rem(2_304 - rem(byte_size(pcm), 2_304), 2_304))
    size = byte_size(pcm)

    <<"RIFF", size + 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", size::little-32>> <>
      pcm
  end

  # A person waits for dictation: the model answers without long reasoning, a
  # request the provider is slow to answer (or fails) is asked once more after
  # 3.5 s, and the server gives up before the client core's 10 s. Reasoning
  # effort low needs a tier model that accepts `reasoning_effort`, as Gemini
  # 3 Flash does; it cut the median from 3.6 s to 2.1 s with the same words.
  #
  # The model writes a whole made-up request for audio without speech (measured
  # 2026-11 on room noise, typing and a cough: 24 of 48 answers), so dictation
  # goes with voice facts too: a clip or segment without one voiced frame is not
  # asked, and words more than its voiced time can hold are dropped. The floor
  # is one 40 ms frame, not a recording's second, because a whole clip can be
  # one short word.
  defp asr_options(:dictation) do
    {%{"reasoning_effort" => "low"},
     [
       transcribe_fun: Transcribe.hedged(&Transcribe.transcribe/4, 3_500),
       batch_timeout_ms: 9_000,
       voice: true,
       min_voiced_seconds: 0.04
     ]}
  end

  # A recording is cut at pauses, and chunks without speech are not asked
  # (`SalixLlm.Transcribe`'s `voice: true`).
  defp asr_options(:recording), do: {%{}, [voice: true]}

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

  # The meeting's own names: its participants and the terms in its team's
  # glossary. Without them the model writes what it hears for a team's own
  # product and people names.
  @max_recording_terms 100

  @doc false
  def recording_prompt(terms) do
    case clean_terms(terms) do
      [] ->
        asr_prompt(:recording)

      terms ->
        asr_prompt(:recording) <>
          " Spell these names as written here: " <> Enum.join(terms, ", ") <> "."
    end
  end

  # A desktop meeting recording: measured on a 25-minute team meeting, this
  # gave consistent speaker numbers, one Chinese script, fewer filler lines,
  # and the team's product and model names spelled as listed. Each word keeps
  # the language it was spoken in; only the script of spoken Chinese, which
  # the audio does not decide, comes from the person's app locale. The script
  # stays inside the first sentence, as measured in Cue #5141 (no traditional
  # characters); as a sentence of its own (Cue #5186) a zh-CN user's
  # transcript still had over 200.
  @doc false
  def meeting_recording_prompt(terms, locale \\ nil) do
    base =
      "Transcribe this meeting audio verbatim. Keep each word in the language it " <>
        "was spoken in" <>
        chinese_script(locale) <>
        ". One line " <>
        "per speaker turn, in the format [MM:SS] Speaker N: text. Number the speakers " <>
        "by voice in order of first appearance (Speaker 1, Speaker 2, ...) and keep " <>
        "the same number for the same voice through the whole audio. Use Unknown only " <>
        "for a voice you cannot tell apart. Never use a person's name as the speaker " <>
        "label. Join one speaker's consecutive fragments into one line and leave out " <>
        "lines that are only filler sounds such as 呃, 嗯 or um. If there is no speech, " <>
        "return an empty string. Do not add commentary or markdown fences."

    case clean_terms(terms) do
      [] ->
        base

      terms ->
        base <>
          "\n\nReference spellings. These are names this team uses; they are not part " <>
          "of the audio. When a speaker says one of them, write it exactly as below, " <>
          "also when a Chinese pronunciation of a romanized name is said. Never add one " <>
          "where it was not said, and never write a model or product name that was not " <>
          "said.\nNames: " <> Enum.join(terms, ", ")
    end
  end

  defp chinese_script(locale) when is_binary(locale) do
    case locale |> String.downcase() |> String.replace("_", "-") do
      "zh-" <> region when region in ["tw", "hk", "mo", "hant"] -> traditional()
      "zh-hant" <> _ -> traditional()
      "zh" <> _ -> " and write Mandarin in simplified Chinese characters"
      _ -> ""
    end
  end

  defp chinese_script(_locale), do: ""

  defp traditional, do: " and write Mandarin in traditional Chinese characters"

  defp clean_terms(terms) do
    terms
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_recording_terms)
  end
end
