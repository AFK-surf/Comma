defmodule SalixSignal.VoiceNote do
  @moduledoc """
  Voice notes: attachments with the voice-message flag (CRS-10 section
  11.1), transcribed for the Router.

  Senders use different containers: AAC in an ADTS stream (Android), MP3
  (Desktop) and AAC in an MP4 container (iOS). The receiver decodes by
  sniffing the container, not by trusting the content type alone.

  Transcription goes to `SalixLlm.Transcribe` by default. The caller passes
  the ASR configuration (`SalixLlm.Transcribe` `cfg`), which the product
  layer resolves; this module adds no configuration of its own.
  """

  import Bitwise

  alias SalixSignal.Attachments
  alias SalixSignalProto.Attachment.Pointer

  @prompt "Transcribe this voice message verbatim as plain text. Keep the spoken " <>
            "language unchanged. If there is no speech, return an empty string. " <>
            "Do not add commentary or markdown fences."

  @extensions %{adts: ".aac", mp3: ".mp3", mp4: ".m4a"}
  @content_types %{
    "audio/aac" => ".aac",
    "audio/mpeg" => ".mp3",
    "audio/mp4" => ".m4a",
    "audio/x-m4a" => ".m4a"
  }

  @type container :: :adts | :mp3 | :mp4 | :unknown

  @doc "True when the pointer carries the voice-message flag."
  @spec voice_note?(Pointer.t()) :: boolean()
  def voice_note?(%Pointer{} = pointer), do: Pointer.voice_message?(pointer)

  @doc """
  The audio container, from the first bytes: an MP4 `ftyp` box, an ID3 tag
  or an MPEG audio frame (MP3), or an ADTS frame (AAC).
  """
  @spec container(binary()) :: container()
  def container(<<_size::binary-size(4), "ftyp", _::binary>>), do: :mp4
  def container(<<"ID3", _::binary>>), do: :mp3

  # 12-bit sync, then the MPEG id bit, two layer bits and the protection
  # bit. ADTS has layer 00; MPEG audio layers I-III have a non-zero layer.
  def container(<<0xFF, second, _::binary>>) when (second &&& 0xF6) == 0xF0, do: :adts

  def container(<<0xFF, second, _::binary>>)
      when (second &&& 0xE0) == 0xE0 and (second &&& 0x06) != 0,
      do: :mp3

  def container(_audio), do: :unknown

  @doc """
  A file name whose extension names the container, for the transcoder.
  Unrecognized bytes fall back to the content type; otherwise
  `{:error, :unsupported_audio}`.
  """
  @spec file_name(binary(), String.t() | nil) :: {:ok, String.t()} | {:error, :unsupported_audio}
  def file_name(audio, content_type \\ nil) do
    extension =
      case container(audio) do
        :unknown -> Map.get(@content_types, content_type)
        known -> Map.fetch!(@extensions, known)
      end

    if extension, do: {:ok, "voice-note" <> extension}, else: {:error, :unsupported_audio}
  end

  @doc """
  Transcribes decrypted voice-note audio.

  Options: `:content_type` (fallback when the container is not
  recognized), `:transcriber` (a module with
  `transcribe_audio_with_metadata/5`, default `SalixLlm.Transcribe`) and
  `:transcribe_opts`.
  """
  @spec transcribe(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def transcribe(audio, cfg, opts \\ []) when is_binary(audio) and is_map(cfg) do
    transcriber = Keyword.get(opts, :transcriber, SalixLlm.Transcribe)

    with {:ok, name} <- file_name(audio, opts[:content_type]) do
      transcriber.transcribe_audio_with_metadata(
        cfg,
        audio,
        name,
        @prompt,
        Keyword.get(opts, :transcribe_opts, [])
      )
    end
  end

  @doc """
  Downloads, verifies and decrypts a voice-note attachment, then transcribes
  it. A pointer without the voice-message flag is `{:error, :not_a_voice_note}`.
  `opts` are passed to `SalixSignal.Attachments.download/2` and
  `transcribe/3`.
  """
  @spec download_and_transcribe(Pointer.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def download_and_transcribe(%Pointer{} = pointer, cfg, opts \\ []) do
    if voice_note?(pointer) do
      with {:ok, audio} <- Attachments.download(pointer, opts) do
        transcribe(audio, cfg, Keyword.put_new(opts, :content_type, pointer.content_type))
      end
    else
      {:error, :not_a_voice_note}
    end
  end
end
