defmodule SalixAgent.SessionHistory.Source do
  @moduledoc "Bounded original-history reads from one PG body-location snapshot."
  alias SalixAgent.InternalSessionStore.PG

  def read(agent, session), do: PG.history_info(agent, session)

  def page(agent, %{session_id: session, last_seq: target}, after_seq) do
    with {:ok, records} <- PG.history_page(agent, session, after_seq, target) do
      seqs = Enum.map(records, & &1.seq)
      expected = if records == [], do: [], else: Enum.to_list((after_seq + 1)..List.last(seqs))

      if seqs == expected and (records != [] or after_seq >= target),
        do: {:ok, records},
        else: {:error, :source_gap}
    end
  end

  def record(agent, %{session_id: session}, seq) when is_integer(seq) and seq > 0 do
    with {:ok, records} <- PG.history_page(agent, session, seq - 1, seq) do
      case records do
        [%{seq: ^seq} = record] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    end
  end
end
