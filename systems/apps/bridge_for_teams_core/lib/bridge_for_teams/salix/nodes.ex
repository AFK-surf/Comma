defmodule BridgeForTeams.Salix.Nodes do
  @moduledoc """
  Salix node selection (design §4.1). The salix control-plane is S3-CAS so any
  salix node can serve a control call and agent/bridge commands are re-routed by
  salix's own ring placement — BridgeForTeams only needs *a* live salix node.

  Discover from the current node plus `Node.list(:visible)` filtered by the salix
  capability; hash by `project_id` for stickiness, round-robin on failure, retry
  on `:unavailable`.

  Capability detection is a runtime, name-based probe — BridgeForTeams never
  compile-depends on the salix apps. A node "is salix" if it answers a one-shot
  `:erpc.call(node, :application, :get_application, [Salix.Control])`
  with `{:ok, :salix_web}` (i.e. the public control API's app is loaded there).
  Unreachable / non-salix nodes are dropped.
  """

  @cap_probe_timeout 2_000

  @doc """
  List visible nodes advertising the salix capability.

  The result is sorted for a stable order so `pick/1`'s hashing is deterministic
  across calls on a stable cluster.
  """
  @spec salix_nodes() :: [node()]
  def salix_nodes do
    case Application.get_env(:bridge_for_teams_core, :salix_nodes_override) do
      nodes when is_list(nodes) ->
        Enum.sort(nodes)

      _ ->
        local_nodes()
        |> Kernel.++(Node.list(:visible))
        |> Enum.filter(&salix?/1)
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  @doc """
  Pick a live salix node, optionally sticky by a hint (e.g. project_id) for
  cache locality. `{:error, :unavailable}` when none are reachable.

  Stickiness: the hint is hashed onto the sorted node list, so the same project
  consistently lands on the same node while the cluster is stable. Without a
  hint a node is chosen at random (round-robin-ish across callers).
  """
  @spec pick(term()) :: {:ok, node()} | {:error, :unavailable}
  def pick(hint \\ nil) do
    case salix_nodes() do
      [] ->
        {:error, :unavailable}

      nodes ->
        {:ok, choose(nodes, hint)}
    end
  end

  defp choose(nodes, nil) do
    Enum.random(nodes)
  end

  defp choose(nodes, hint) do
    idx = :erlang.phash2(hint, length(nodes))
    Enum.at(nodes, idx)
  end

  defp local_nodes do
    started? =
      Application.started_applications()
      |> Enum.any?(fn {app, _description, _version} -> app == :salix_web end)

    if started?, do: [Node.self()], else: []
  end

  # Probe a node for the salix public control API by name (no compile-time dep).
  # Any error (noconnection, timeout, undef) means "not salix / not live".
  defp salix?(node) do
    case :erpc.call(
           node,
           :application,
           :get_application,
           [Salix.Control],
           @cap_probe_timeout
         ) do
      {:ok, :salix_web} -> true
      _ -> false
    end
  catch
    _kind, _reason -> false
  end
end
