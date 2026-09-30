defmodule SalixAgent.ExecutionSurface do
  @moduledoc """
  Private, owner-local execution measurements for Session history. This is an
  observational overlay, never a transcript, activity or execution authority.
  Requests and tools publish at their execution seams. Exact-owner reads avoid
  accepting a previous node's cache after placement changes. Missing observations
  remain unknown. Modeled in tla/session-history/ExecutionHistoryObservation.tla;
  network admission is modeled by SessionHistoryLive.tla in the same directory.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, %{entries: %{}, refs: %{}, targets: %{}}}

  def observe(%{agent_id: agent, session_id: session}, record)
      when is_binary(agent) and is_binary(session) do
    GenServer.cast(__MODULE__, {:observe, {agent, session}, self(), record})
  end

  def observe(_, _), do: :ok

  def get(agent, session), do: GenServer.call(__MODULE__, {:get, {agent, session}})

  def handle_cast({:observe, target, pid, record}, state) do
    key = {target, record["id"]}
    {entry, entries} = Map.pop(state.entries, key)
    if entry, do: Process.demonitor(entry.ref, [:flush])
    ref = Process.monitor(pid)
    now = System.monotonic_time(:millisecond)
    entries = Map.put(entries, key, %{record: record, pid: pid, ref: ref, at: now})
    # Bounded diagnostic memory even with abandoned Sessions. Canonical history
    # remains complete; evicted or expired measurements are simply unavailable.
    entries =
      entries
      |> Enum.filter(fn {_, e} -> now - e.at <= 180_000 or e.record["execution"]["live"] end)
      |> Enum.sort_by(fn {_, e} -> e.at end, :desc)
      |> Enum.take(4096)
      |> Map.new()

    for {old_key, old} <- state.entries,
        not Map.has_key?(entries, old_key),
        do: Process.demonitor(old.ref, [:flush])

    SalixAgent.Notifier.notify(elem(target, 0), {:execution_history_updated, elem(target, 1)})

    {:noreply,
     %{
       entries: entries,
       refs: Map.new(entries, fn {k, e} -> {e.ref, k} end),
       targets: target_index(entries)
     }}
  end

  def handle_call({:get, target}, _from, state) do
    now = System.monotonic_time(:millisecond)

    records =
      for entry <- Map.get(state.targets, target, []),
          now - entry.at <= 180_000 or entry.record["execution"]["live"],
          do: entry.record

    {:reply, records, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, {target, _} = key} ->
        entry = state.entries[key]
        record = put_in(entry.record, ["execution", "live"], false)
        SalixAgent.Notifier.notify(elem(target, 0), {:execution_history_updated, elem(target, 1)})
        entries = Map.put(state.entries, key, %{entry | record: record})

        {:noreply,
         %{
           state
           | entries: entries,
             refs: Map.delete(state.refs, ref),
             targets: target_index(entries)
         }}

      :error ->
        {:noreply, state}
    end
  end

  defp target_index(entries) do
    Enum.group_by(entries, fn {{target, _}, _} -> target end, fn {_, entry} -> entry end)
  end

  def record(id, lane, timing, content, live) do
    %{
      "id" => "execution:" <> lane <> ":" <> id,
      "kind" => if(lane == "model", do: "assistant", else: "tool"),
      "content" => content,
      "timestamp_ms" => timing["started_at_ms"],
      "execution" =>
        timing
        |> Map.drop(["version"])
        |> Map.merge(%{"id" => id, "lane" => lane, "live" => live})
    }
  end
end
