defmodule SalixAgent.MemoryConsultationRuntime do
  @moduledoc false

  alias SalixAgent.{
    Compaction,
    ExternalSessionRecords,
    InternalSession,
    InternalSessionStore,
    LLM,
    LlmResolver
  }

  alias SalixStore.SegmentLog

  @external_record_limit 256
  @external_text_bytes 512 * 1024
  @external_segment_limit 4
  @external_raw_bytes 8 * 1024 * 1024
  @external_source_scope "salix_session_records"
  @no_answer_token "NO_ANSWER"

  @consultation_instruction """
  You are answering a memory consultation from an existing Worker Session.
  Use only the Session context below. Do not call tools, do not send messages,
  and do not perform new work. Answer the question directly. If the context is
  insufficient, say so briefly.
  """

  @external_consultation_instruction """
  You are answering a memory consultation about an existing Worker Session.
  Use only the committed Salix Session records below. Do not call tools, send
  messages, or perform new work. Answer the question directly. The records can
  be truncated and do not include uncommitted native-runtime history. If the
  records do not contain enough evidence to answer, return exactly NO_ANSWER.
  """

  @spec consult_internal(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def consult_internal(agent_id, session_id, question)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(question) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id),
         {:ok, llm_opts} <- LlmResolver.resolve_runtime(agent_id) do
      messages =
        [%{role: "summary", content: @consultation_instruction}] ++
          Compaction.context(session) ++ [%{role: "user", content: question}]

      result =
        LLM.complete(messages, [], consultation_llm_opts(llm_opts, session),
          agent_id: agent_id,
          session_id: session_id
        )

      result
      |> answer_text()
      |> consultation_result(snapshot_id(session))
    end
  end

  @spec capture_external(String.t(), String.t(), SegmentLog.t()) ::
          {:ok, map()} | {:error, term()}
  def capture_external(
        worker_agent_id,
        session_id,
        %SegmentLog{} = cache
      )
      when is_binary(worker_agent_id) and is_binary(session_id) do
    with {:ok, records, storage_truncated} <-
           ExternalSessionRecords.bounded_tail(
             worker_agent_id,
             session_id,
             cache,
             @external_record_limit,
             @external_segment_limit,
             @external_raw_bytes
           ) do
      {text, text_truncated, record_ids} = bounded_record_text(records)

      {:ok,
       %{
         text: text,
         metadata: %{
           "source_scope" => @external_source_scope,
           "source_snapshot" => %{
             "schema" => "salix.external-session-records.v1",
             "watermark" => cache.last_id,
             "record_ids" => record_ids
           },
           "truncated" => storage_truncated or text_truncated
         }
       }}
    end
  end

  @spec consult_external(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def consult_external(question, router_agent_id, session_id, %{text: text, metadata: metadata})
      when is_binary(question) and is_binary(router_agent_id) and is_binary(session_id) and
             is_binary(text) and is_map(metadata) do
    if text == "" do
      {:ok, Map.put(metadata, "status", "no_answer")}
    else
      with {:ok, llm_opts} <- LlmResolver.resolve_runtime(router_agent_id) do
        messages = [
          %{role: "summary", content: @external_consultation_instruction},
          %{role: "summary", content: text},
          %{role: "user", content: question}
        ]

        LLM.complete(messages, [], llm_opts,
          agent_id: router_agent_id,
          session_id: session_id
        )
        |> answer_text()
        |> external_consultation_result(metadata)
      end
    end
  end

  defp consultation_result({:ok, answer}, snapshot) do
    {:ok, %{"status" => "answered", "answer" => answer, "source_snapshot" => snapshot}}
  end

  defp consultation_result(:no_answer, snapshot),
    do: {:ok, %{"status" => "no_answer", "source_snapshot" => snapshot}}

  defp consultation_result({:error, reason}, _snapshot), do: {:error, reason}

  defp external_consultation_result({:ok, @no_answer_token}, metadata),
    do: {:ok, Map.put(metadata, "status", "no_answer")}

  defp external_consultation_result({:ok, answer}, metadata) do
    {:ok, metadata |> Map.put("status", "answered") |> Map.put("answer", answer)}
  end

  defp external_consultation_result(:no_answer, metadata),
    do: {:ok, Map.put(metadata, "status", "no_answer")}

  defp external_consultation_result({:error, reason}, _metadata), do: {:error, reason}

  defp bounded_record_text(records) do
    records
    |> Enum.reverse()
    |> Enum.reduce({[], [], 0, false}, fn record, {lines, ids, bytes, truncated} ->
      line = normalize_record(record)
      line_bytes = byte_size(line)

      cond do
        line == "" ->
          {lines, ids, bytes, truncated}

        line_bytes > @external_text_bytes ->
          {lines, ids, bytes, true}

        bytes + line_bytes + 1 > @external_text_bytes ->
          {lines, ids, bytes, true}

        true ->
          {[line | lines], [record["id"] | ids], bytes + line_bytes + 1, truncated}
      end
    end)
    |> then(fn {lines, ids, _bytes, truncated} ->
      {Enum.join(lines, "\n"), truncated, ids}
    end)
  end

  defp normalize_record(%{"id" => id, "type" => type, "data" => data})
       when is_binary(id) and is_binary(type) and is_map(data) do
    Jason.encode!(%{"id" => id, "type" => type, "data" => data})
  end

  defp normalize_record(_record), do: ""

  defp consultation_llm_opts(opts, session) when is_map(opts) do
    Map.put(opts, "billing_context", InternalSession.get(session, :billing_context) || %{})
  end

  defp consultation_llm_opts(opts, session) when is_list(opts) do
    Keyword.put(opts, :billing_context, InternalSession.get(session, :billing_context) || %{})
  end

  defp answer_text({:final, text}), do: normalized_answer(text)
  defp answer_text({:final, text, _trace}), do: normalized_answer(text)
  defp answer_text({:final, text, _provider, _trace}), do: normalized_answer(text)
  defp answer_text({:assistant, text, _calls}), do: normalized_answer(text)
  defp answer_text({:assistant, text, _calls, _provider}), do: normalized_answer(text)
  defp answer_text({:assistant, text, _calls, _provider, _trace}), do: normalized_answer(text)
  defp answer_text({:error, reason}), do: {:error, reason}
  defp answer_text(other), do: {:error, {:unexpected_llm_result, other}}

  defp normalized_answer(text) when is_binary(text) do
    case String.trim(text) do
      "" -> :no_answer
      answer -> {:ok, answer}
    end
  end

  defp normalized_answer(_text), do: :no_answer

  defp snapshot_id(session), do: InternalSession.query(session, :session_snapshot_id)
end
