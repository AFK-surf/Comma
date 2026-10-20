defmodule SalixAgent.MemoryConsultationRuntime do
  @moduledoc false

  alias SalixAgent.{
    Compaction,
    InternalSession,
    InternalSessionStore,
    LLM,
    LlmResolver
  }

  @consultation_instruction """
  You are answering a memory consultation from an existing Worker Session.
  Use only the Session context below. Do not call tools, do not send messages,
  and do not perform new work. Answer the question directly. If the context is
  insufficient, say so briefly.
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

  defp consultation_result({:ok, answer}, snapshot) do
    {:ok, %{"status" => "answered", "answer" => answer, "source_snapshot" => snapshot}}
  end

  defp consultation_result(:no_answer, snapshot),
    do: {:ok, %{"status" => "no_answer", "source_snapshot" => snapshot}}

  defp consultation_result({:error, reason}, _snapshot), do: {:error, reason}

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
