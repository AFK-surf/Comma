defmodule SalixAgent.ActivitySurface do
  @moduledoc """
  Agent-owner-local, in-memory cache of the last live activity signal per
  (agent, session) — the state behind the `{:activity, map}` notifications
  (`SalixAgent.ActivityEvent`), so a late subscriber (a dashboard page
  refresh, an SSE reconnect) can seed its status surface instead of waiting
  for the next emission.

  Deliberately NOT persistent: the surface is a liveness hint, never
  correctness state. It dies with the agent owner node, `idle` deletes its
  session's entry, and reads drop anything stale. A product consumer never
  subscribes to this Session-keyed surface directly: its exact Conversation
  Participant owner routes a combined snapshot read to the agent owner, then
  filters and republishes the admissible status.

  Producer epoch restart and presentation reducer admission are modeled in
  `tla/salix/ActivityPresentation.tla`; Participant routing is outside that
  historical transport model.
  """

  use GenServer

  @table __MODULE__
  @producer_epoch_key {__MODULE__, :producer_epoch}
  @producer_epoch_bytes 18

  # A lost terminal idle must not pin a "Thinking" line forever; anything this
  # old is treated as gone. Generous enough for long tool runs.
  @stale_after_ms 10 * 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # `ActivityEvent.sequence` is monotonic only for one runtime incarnation.
    # Publish a new opaque equality fence whenever this surface owner starts so
    # reconnecting consumers never compare a post-restart sequence with an old
    # VM/surface sequence. The event hot path reads this immutable projection
    # without a GenServer call.
    producer_epoch = new_producer_epoch()
    :persistent_term.put(@producer_epoch_key, producer_epoch)

    {:ok, %{producer_epoch: producer_epoch}}
  end

  @doc "The opaque equality fence for the current activity producer incarnation."
  @spec producer_epoch() :: String.t() | nil
  def producer_epoch do
    :persistent_term.get(@producer_epoch_key, nil)
  end

  @doc """
  Record `activity` as its session's current surface; an idle signal clears
  the session. Best-effort — without the table (app booting or shutting
  down) the hint is simply dropped.
  """
  @spec put(map()) :: :ok
  def put(%{"agent_id" => agent_id, "session_id" => session_id} = activity)
      when is_binary(agent_id) and is_binary(session_id) do
    if activity["phase"] == "idle" or activity["status"] == "idle" do
      :ets.delete(@table, {agent_id, session_id})
    else
      :ets.insert(@table, {{agent_id, session_id}, activity, now_ms()})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(_activity), do: :ok

  @doc "The agent's current (non-stale) activities, freshest first."
  @spec list_agent(String.t()) :: [map()]
  def list_agent(agent_id) when is_binary(agent_id) do
    now = now_ms()

    @table
    |> :ets.match_object({{agent_id, :_}, :_, :_})
    |> Enum.flat_map(fn {{_agent_id, _session_id}, activity, at} ->
      if now - at <= @stale_after_ms, do: [activity], else: []
    end)
    |> Enum.sort_by(&(&1["sequence"] || 0), :desc)
  rescue
    ArgumentError -> []
  end

  def list_agent(_agent_id), do: []

  @doc "One session's current non-stale activity, if any."
  @spec get_session(String.t(), String.t()) :: map() | nil
  def get_session(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    case :ets.lookup(@table, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, activity, at}] ->
        if now_ms() - at <= @stale_after_ms do
          activity
        else
          :ets.delete(@table, {agent_id, session_id})
          nil
        end

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  def get_session(_agent_id, _session_id), do: nil

  defp new_producer_epoch do
    @producer_epoch_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
