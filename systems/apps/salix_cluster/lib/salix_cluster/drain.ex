defmodule SalixCluster.Drain do
  @moduledoc """
  Graceful node drain: on shutdown, every
  locally-running agent Server is stopped, its lease is **explicitly released**
  (head CAS clearing `owner_node`/`lease_until`, then the `ctl/leases/` index
  entry deleted), and the work is handed to the new ring owner.

  The explicit release matters: `SalixAgent.Server` has no terminate hook that
  releases the lease (only the parked→passivating path does), so a bare stop
  would leave the lease held until TTL expiry and stall takeover. Drain
  therefore grabs the in-memory `Owned` handle via `Server.info/1` *before*
  stopping, stops the Server, and only then calls `SalixStore.Agent.release/1`
  — safe because the Server is no longer committing, and release tolerates a
  lost CAS (a concurrent steal just means there is nothing left to release).

  Handoff is best-effort: when the ring owner is a *different* live node we
  `:erpc.cast` it an `ensure_started`. A lost cast is fine — the released
  lease makes the agent claimable, and any pending session work stays
  discoverable through its durable session state + PG candidate row, which
  the Recovery session-work lanes re-wake through placement (the durable
  backstop; the agent-level queue-marker lane retired with A2 §3.4).
  """

  require Logger

  alias SalixAgent.Fleet

  @registry SalixAgent.Registry

  @type result :: %{
          drained: [String.t()],
          handed_off: non_neg_integer(),
          failed: [{String.t(), term()}],
          agents: map(),
          sessions: map(),
          attachments: map()
        }

  @doc """
  Drain every agent Server running on this node.

  Options:

    * `:handoff` — when `true` (default), `:erpc.cast` the ring owner an
      `ensure_started` for each released agent whose owner is a different live
      node (best effort; Recovery's session-work lanes are the backstop).
    * `:ring` — ring module (default `SalixCluster.Ring`; must export
      `owner/1` and `nodes/0`). Injectable so tests stub a single-node ring.

  Returns `{:ok, %{drained: [agent_id], handed_off: n, failed: [{agent_id,
  reason}]}}`. An agent that stopped on its own between enumeration and drain
  counts as drained (nothing local is left); a release error lands in `failed`
  (the Server is stopped, the lease stays held until TTL — Recovery's stale
  path picks it up).
  """
  @spec drain(keyword()) :: {:ok, result()}
  def drain(opts \\ []) do
    if Keyword.get(opts, :mark_draining, true), do: SalixCluster.NodeLifecycle.mark_draining()

    handoff? = Keyword.get(opts, :handoff, true)
    ring = Keyword.get(opts, :ring, SalixCluster.Ring)
    session_count = length(local_session_keys())

    {drained, handed_off, failed} =
      local_agent_ids()
      |> Enum.reduce({[], 0, []}, fn agent_id, {drained, handed_off, failed} ->
        case drain_one(agent_id, handoff?, ring) do
          {:ok, n} -> {[agent_id | drained], handed_off + n, failed}
          {:error, reason} -> {drained, handed_off, [{agent_id, reason} | failed]}
        end
      end)

    attachments = stop_all(Keyword.get(opts, :attachments_mod, cloudflare_attachments_mod()))
    drained = Enum.reverse(drained)
    failed = Enum.reverse(failed)

    {:ok,
     %{
       drained: drained,
       handed_off: handed_off,
       failed: failed,
       agents: %{completed: length(drained), timeout: 0, error: length(failed)},
       sessions: %{completed: session_count, timeout: 0, error: 0},
       attachments: attachments
     }}
  end

  @doc "Agent ids with local runtime processes registered on this node."
  @spec local_agent_ids() :: [String.t()]
  def local_agent_ids do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> Enum.flat_map(&agent_id_from_registry_key/1)
    |> Enum.uniq()
  end

  @doc "Local session registry keys that will be stopped as part of agent drain."
  @spec local_session_keys() :: [term()]
  def local_session_keys do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> Enum.filter(&session_registry_key?/1)
    |> Enum.uniq()
  end

  # ---- per-agent drain ----

  defp drain_one(agent_id, handoff?, ring) do
    case grab_owned(agent_id) do
      {:ok, owned} ->
        :ok = Fleet.stop_session_actors(agent_id)
        :ok = Fleet.stop(agent_id)

        case SalixStore.Agent.release(owned) do
          :ok ->
            {:ok, hand_off(agent_id, handoff?, ring)}

          {:error, reason} ->
            Logger.warning("drain: release failed for #{agent_id}: #{inspect(reason)}")
            {:error, {:release_failed, reason}}
        end

      {:error, :not_running} ->
        # The root server may have stopped/passivated on its own while a session
        # actor is still local. Session actors are runtime owners too, but they
        # do not hold the agent root lease, so there is no release step here.
        :ok = Fleet.stop_session_actors(agent_id)
        {:ok, 0}
    end
  end

  defp agent_id_from_registry_key(agent_id) when is_binary(agent_id), do: [agent_id]

  defp agent_id_from_registry_key({:internal_session, agent_id, _session_id})
       when is_binary(agent_id), do: [agent_id]

  defp agent_id_from_registry_key({:external_session, agent_id, _session_id})
       when is_binary(agent_id), do: [agent_id]

  defp agent_id_from_registry_key(_key), do: []

  defp session_registry_key?({:internal_session, agent_id, session_id})
       when is_binary(agent_id) and is_binary(session_id),
       do: true

  defp session_registry_key?({:external_session, agent_id, session_id})
       when is_binary(agent_id) and is_binary(session_id),
       do: true

  defp session_registry_key?(_key), do: false

  # Grab the in-memory commit handle BEFORE stopping (it cannot be recovered
  # afterwards). `Server.info/1` raises if the Server is gone and the call
  # exits if it dies mid-flight — both mean "no longer running here".
  defp grab_owned(agent_id) do
    {_lifecycle, owned} = SalixAgent.Server.info(agent_id)
    {:ok, owned}
  rescue
    _ -> {:error, :not_running}
  catch
    :exit, _ -> {:error, :not_running}
  end

  # ---- handoff ----

  defp hand_off(_agent_id, false, _ring), do: 0

  defp hand_off(agent_id, true, ring) do
    owner = ring.owner(agent_id)

    if owner != Node.self() and owner in ring.nodes() do
      :erpc.cast(owner, SalixAgent.Fleet, :ensure_started, [agent_id, []])
      1
    else
      0
    end
  rescue
    e ->
      # Best effort only: a dead ring or unreachable owner is not a drain
      # failure — the released lease plus the PG candidate projection let
      # Recovery re-wake any pending session work elsewhere.
      Logger.warning("drain: handoff for #{agent_id} failed: #{inspect(e)}")
      0
  catch
    :exit, reason ->
      Logger.warning("drain: handoff for #{agent_id} failed: #{inspect(reason)}")
      0
  end

  defp stop_all(mod) do
    case mod.stop_all() do
      %{completed: _, timeout: _, error: _} = summary -> summary
      :ok -> %{completed: 0, timeout: 0, error: 0, errors: []}
      other -> %{completed: 0, timeout: 0, error: 1, errors: [other]}
    end
  catch
    kind, reason ->
      Logger.warning("drain: #{inspect(mod)} stop_all failed: #{inspect({kind, reason})}")
      %{completed: 0, timeout: 0, error: 1, errors: [{kind, reason}]}
  end

  defp cloudflare_attachments_mod,
    do: SalixEnv.VM.Providers.Cloudflare.Attachments
end
