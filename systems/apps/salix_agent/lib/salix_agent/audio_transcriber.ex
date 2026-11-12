defmodule SalixAgent.AudioTranscriber do
  @moduledoc "Agent-owned port for transcribing a workspace file."

  @type chunk :: %{
          index: non_neg_integer(),
          offset_seconds: non_neg_integer(),
          transcript: String.t()
        }

  @type result :: %{
          transcript: String.t(),
          duration_seconds: pos_integer(),
          chunks: [chunk()]
        }

  @callback transcribe(agent_id :: String.t(), visible_path :: String.t()) ::
              {:ok, result()} | {:error, term()}

  @doc """
  `terms` are names and words whose spelling the transcript keeps.
  `glossary_of: {group_id, tenant_id}` transcribes a meeting recording with
  the terms of that Group's glossary and its corrections applied to the
  transcript text; the chunks stay as the model returned them. `locale` is
  the app locale of the person the transcript is for: it chooses the script
  of spoken Chinese.
  """
  @callback transcribe(
              agent_id :: String.t(),
              visible_path :: String.t(),
              opts :: [
                terms: [String.t()],
                glossary_of: {String.t(), String.t()},
                locale: String.t()
              ]
            ) ::
              {:ok, result()} | {:error, term()}
  @optional_callbacks transcribe: 3

  @spec transcribe(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def transcribe(agent_id, path, opts \\ [])

  def transcribe(agent_id, path, opts) when is_binary(agent_id) and is_binary(path) do
    case SystemsRuntime.get_env(:salix_agent, :audio_transcriber_mod) do
      nil ->
        {:error, :asr_not_configured}

      module ->
        if opts != [] and function_exported?(module, :transcribe, 3),
          do: module.transcribe(agent_id, path, opts),
          else: module.transcribe(agent_id, path)
    end
  end

  def transcribe(_agent_id, _path, _opts), do: {:error, :invalid_asr_source}

  @doc """
  What a log line may say about a failed transcription: the step that failed
  and, for a chunk, its index and cause. Never a path or provider text.
  """
  @spec failure_reason(term()) :: String.t()
  def failure_reason({:asr_chunk_failed, index, reason}),
    do: "asr_chunk_failed index=#{index} cause=#{failure_reason(reason)}"

  def failure_reason({:asr_part_failed, index, reason}),
    do: "part_#{index}_#{failure_reason(reason)}"

  def failure_reason({:asr_http, status, _body}), do: "asr_http_#{status}"

  def failure_reason({:asr_incomplete_transcript, finish}) when is_binary(finish),
    do: "asr_incomplete_transcript_#{finish}"

  def failure_reason(%{__exception__: true} = error), do: inspect(error.__struct__)
  def failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def failure_reason(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  def failure_reason(_reason), do: "other"

  @failure_classes ~w(rate_limited provider_4xx provider_5xx content_filter length provider_error
                      transport timeout audio_decode too_large empty_audio no_speech not_found
                      not_configured crash other)

  @doc "The failure classes `failure_class/1` answers: a bounded metric label."
  def failure_classes, do: @failure_classes

  @doc "The class of a failed transcription, from a bounded set (`failure_classes/0`)."
  @spec failure_class(term()) :: String.t()
  def failure_class({tag, _index, reason}) when tag in [:asr_chunk_failed, :asr_part_failed],
    do: failure_class(reason)

  def failure_class({:asr_http, 429, _body}), do: "rate_limited"
  def failure_class({:asr_http, status, _body}) when status >= 500, do: "provider_5xx"
  def failure_class({:asr_http, _status, _body}), do: "provider_4xx"

  def failure_class({:asr_incomplete_transcript, finish}) when is_binary(finish) do
    cond do
      String.starts_with?(finish, "content_filter") -> "content_filter"
      finish == "length" -> "length"
      true -> "provider_error"
    end
  end

  def failure_class(reason)
      when reason in [:asr_provider_error, :asr_response_incomplete, :asr_stream_incomplete],
      do: "provider_error"

  def failure_class({:invalid_asr_chunk_response, _other}), do: "provider_error"
  def failure_class({:asr_chunk_exit, _kind, _reason}), do: "crash"
  def failure_class({:asr_chunk_exception, _message}), do: "crash"
  def failure_class(%Req.TransportError{}), do: "transport"

  def failure_class(reason)
      when reason in [:asr_batch_timeout, :ffmpeg_timeout, :ffprobe_timeout, :timeout],
      do: "timeout"

  def failure_class(:asr_audio_too_large), do: "too_large"
  def failure_class(:asr_audio_empty), do: "empty_audio"
  def failure_class(:asr_empty_transcript), do: "no_speech"
  def failure_class(:asr_declined), do: "content_filter"
  def failure_class(:not_found), do: "not_found"
  def failure_class(:asr_not_configured), do: "not_configured"

  def failure_class(reason) when is_atom(reason) or is_tuple(reason) do
    tag = if is_tuple(reason), do: elem(reason, 0), else: reason

    if is_atom(tag) and
         String.starts_with?(Atom.to_string(tag), ~w(ffmpeg ffprobe silk audio_ asr_audio_)),
       do: "audio_decode",
       else: "other"
  end

  def failure_class(_reason), do: "other"
end
