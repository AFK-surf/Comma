defmodule SalixWeb.Migrations.StationTaskStarts do
  @moduledoc """
  Keep the `start` of each station's Session of a Task invited before `start`
  was kept (`SalixStore.StationTaskSessions`). Until this pass, such a station
  that lost the Task was invited again with a `start` made from the Task's
  Worker as it was bound then: the Worker asks, with the runtime and model of
  its station binding (`SalixAgent.StationBinding`). The pass keeps that
  `start`, as the Worker is bound when the pass runs. A Worker no longer there
  (deleted or archived) gives no runtime or model. After the pass, a station
  is invited again as it was first, however its Worker is bound later.

  Run during a rolling release. Each page reads at most 100 rows with no
  `start`, in key order after the last row read, and at most one Agent record
  for each Worker in the page. A row gets `start` only while it has none: a
  row invited again during the pass keeps its own, and a pass run again
  changes nothing. An Agent record that cannot be read stops the pass with an
  error; the pass can be run again.
  """

  alias SalixStore.StationTaskSessions

  @page 100

  @doc "Keep the `start` of every row that has none. Answers how many were kept, and in how many pages."
  def run(opts \\ []), do: page(nil, Keyword.get(opts, :page, @page), %{kept: 0, pages: 0})

  defp page(cursor, limit, counts) do
    case StationTaskSessions.without_start(cursor, limit) do
      {:ok, []} ->
        {:ok, counts}

      {:ok, rows} ->
        with {:ok, kept} <- keep(rows) do
          counts = %{counts | kept: counts.kept + kept, pages: counts.pages + 1}
          last = List.last(rows)
          cursor = {last.group_id, last.conversation_id, last.device_id, last.session}
          if length(rows) < limit, do: {:ok, counts}, else: page(cursor, limit, counts)
        end

      {:error, _} = error ->
        error
    end
  end

  defp keep(rows) do
    rows
    |> Enum.reduce_while({:ok, 0, %{}}, fn row, {:ok, kept, models} ->
      with {:ok, model, models} <- model(row.agent_id, models),
           start = SalixIM.TaskConversationInput.station_start(row.agent_id, model),
           {:ok, now?} <- StationTaskSessions.keep_start(row, start) do
        {:cont, {:ok, if(now?, do: kept + 1, else: kept), models}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, kept, _models} -> {:ok, kept}
      error -> error
    end
  end

  # The runtime model of the Worker's station binding, as each re-invite read
  # it before this pass.
  defp model(agent_id, models) when is_map_key(models, agent_id),
    do: {:ok, models[agent_id], models}

  defp model(agent_id, models) do
    case SalixIM.GroupDirectory.get_agent(agent_id) do
      {:ok, agent} ->
        model = (SalixAgent.StationBinding.get(agent) || %{})["model"]
        {:ok, model, Map.put(models, agent_id, model)}

      {:error, :not_found} ->
        {:ok, nil, Map.put(models, agent_id, nil)}

      {:error, reason} ->
        {:error, {:agent_unreadable, agent_id, reason}}
    end
  end
end
