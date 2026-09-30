defmodule SalixAgent.SessionHistory.Source do
  @moduledoc "Read-only, sequence-addressed access to the original internal Session log."
  alias SalixAgent.{InternalSession, InternalSessionStore, InternalSessionArchiveReader}

  def read(agent, session) do
    with {:ok, state} <- InternalSessionStore.read(agent, session) do
      if InternalSession.storage_format(state) in [2, 3],
        do: {:ok, state},
        else: {:error, :unsupported_storage_format}
    end
  end

  def page(agent, state, after_seq) do
    with true <- InternalSession.storage_format(state) in [2, 3],
         {:ok, records} <- records_at(agent, state, after_seq + 1) do
      page = records |> Enum.filter(&(&1.seq > after_seq)) |> Enum.take(32)
      seqs = Enum.map(page, & &1.seq)
      expected = if page == [], do: [], else: Enum.to_list((after_seq + 1)..List.last(seqs))

      if seqs == expected and (page != [] or after_seq >= InternalSession.get(state, :last_seq)),
        do: {:ok, page},
        else: {:error, :source_gap}
    else
      false -> {:error, :unsupported_storage_format}
      error -> error
    end
  end

  def record(agent, state, seq) when is_integer(seq) and seq > 0 do
    with {:ok, records} <- records_at(agent, state, seq) do
      case Enum.find(records, &(&1.seq == seq)) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  defp records_at(agent, state, seq) do
    if seq <= InternalSession.archived_through(state) do
      with {:ok, spans} <- InternalSessionArchiveReader.committed_spans(state),
           span when is_map(span) <- Enum.find(spans, &(&1.first <= seq and seq <= &1.last)) do
        InternalSessionArchiveReader.read(agent, state, [span])
      else
        nil -> {:error, :source_gap}
        error -> error
      end
    else
      {:ok, InternalSessionStore.window_records_shaped(state)}
    end
  end
end
