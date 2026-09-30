defmodule SalixCluster.Nodes do
  @moduledoc """
  Cluster node inventory and summary API.
  """

  alias SalixStore.{Keys, S3}

  @node_freshness_window_ms 30_000

  def stats do
    nodes = list()
    active_nodes = Enum.filter(nodes, &(&1["status"] == "active"))

    %{
      active_nodes: length(active_nodes),
      total_nodes: length(nodes),
      total_agents: Enum.sum(Enum.map(active_nodes, &(&1["agent_count"] || 0))),
      total_capacity: Enum.sum(Enum.map(active_nodes, &(&1["max_agents"] || 0)))
    }
  end

  def list do
    now = now()
    current = local_node_record(now)

    durable =
      Keys.ctl_nodes_prefix()
      |> list_records()
      |> Enum.map(&node_json(&1, now))
      |> Map.new(&{&1["node_id"], &1})

    mesh =
      Node.list(:visible)
      |> Map.new(fn n -> {to_string(n), peer_node_record(n, now)} end)
      |> Map.put(current["node_id"], current)

    durable
    |> Map.merge(mesh)
    |> Map.values()
    |> Enum.sort_by(& &1["node_id"])
  end

  def put(node_id, attrs) when is_map(attrs) do
    now = now()

    rec =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "node_id" => node_id,
        "address" => attrs["address"] || attrs[:address] || node_id,
        "started_at" => attrs["started_at"] || attrs[:started_at] || now,
        "heartbeat_at" => attrs["heartbeat_at"] || attrs[:heartbeat_at] || now,
        "agent_count" => attrs["agent_count"] || attrs[:agent_count] || 0,
        "max_agents" => attrs["max_agents"] || attrs[:max_agents] || 1000,
        "status" => attrs["status"] || attrs[:status] || "active",
        "updated_at" => now
      })

    upsert_record(Keys.ctl_node(node_id), rec, fn existing ->
      existing
      |> Map.merge(rec)
      |> Map.put("updated_at", now)
    end)
  end

  @doc """
  This node's admin record. Public so peers can fetch it over `:erpc`.
  """
  def node_summary, do: local_node_record(now())

  defp local_node_record(now) do
    running_agents = local_running_agents()
    node_id = local_node_id()

    %{
      "node_id" => node_id,
      "address" => "local",
      "started_at" => now,
      "heartbeat_at" => now,
      "agent_count" => running_agents,
      "max_agents" => 1000,
      "status" => "active",
      "registry" => %{
        "status" => "active",
        "running_agents" => running_agents,
        "max_agents" => 1000,
        "timestamp" => now,
        "last_seen_at" => now,
        "last_seen_age_ms" => 0,
        "fresh_for_handoff" => true
      }
    }
  end

  defp local_node_id do
    case System.get_env("SALIX_NODE_ID") do
      id when is_binary(id) and id != "" -> id
      _ -> to_string(node())
    end
  end

  defp peer_node_record(n, now) do
    case safe_node_summary(n) do
      {:ok, %{} = rec} -> Map.put(rec, "node_id", to_string(n))
      _ -> minimal_peer_record(n, now)
    end
  end

  defp safe_node_summary(n) do
    {:ok, :erpc.call(n, __MODULE__, :node_summary, [], 2_000)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp minimal_peer_record(n, now) do
    %{
      "node_id" => to_string(n),
      "address" => n |> to_string() |> String.split("@") |> List.last(),
      "started_at" => now,
      "heartbeat_at" => now,
      "agent_count" => 0,
      "max_agents" => 1000,
      "status" => "active"
    }
  end

  defp node_json(rec, now) do
    node_id = rec["node_id"] || rec["id"] || "node-" <> random_id()
    heartbeat_at = rec["heartbeat_at"] || rec["updated_at"] || now
    max_agents = rec["max_agents"] || 1000
    agent_count = rec["agent_count"] || rec["running_agents"] || 0

    %{
      "node_id" => node_id,
      "address" => rec["address"] || rec["addr"] || node_id,
      "started_at" => rec["started_at"] || heartbeat_at,
      "heartbeat_at" => heartbeat_at,
      "agent_count" => agent_count,
      "max_agents" => max_agents,
      "status" => rec["status"] || "active"
    }
    |> put_optional("registry", registry_json(rec["registry"], now, agent_count, max_agents))
  end

  defp registry_json(nil, _now, _agent_count, _max_agents), do: nil

  defp registry_json(registry, now, agent_count, max_agents) when is_map(registry) do
    last_seen_at = registry["last_seen_at"] || registry["timestamp"] || now
    last_seen_age_ms = max((now - last_seen_at) * 1000, 0)

    %{
      "status" => registry["status"] || "active",
      "running_agents" => registry["running_agents"] || agent_count,
      "max_agents" => registry["max_agents"] || max_agents,
      "timestamp" => registry["timestamp"] || last_seen_at,
      "last_seen_at" => last_seen_at,
      "last_seen_age_ms" => registry["last_seen_age_ms"] || last_seen_age_ms,
      "fresh_for_handoff" =>
        Map.get(registry, "fresh_for_handoff", last_seen_age_ms <= @node_freshness_window_ms)
    }
  end

  defp local_running_agents do
    Registry.count(SalixAgent.Registry)
  rescue
    _ -> 0
  end

  defp list_records(prefix) do
    case S3.list_all(prefix) do
      {:ok, objects} ->
        objects
        |> Enum.flat_map(fn %{key: key} ->
          case get_record(key) do
            {:ok, rec} -> [rec]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp get_record(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_record(key, new_rec, update_fun), do: upsert_record(key, new_rec, update_fun, 5)

  defp upsert_record(_key, _new_rec, _update_fun, 0), do: {:error, :precondition_failed}

  defp upsert_record(key, new_rec, update_fun, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        current = Jason.decode!(body)
        updated = update_fun.(current)

        case S3.put(key, Jason.encode!(updated), if_match: etag) do
          {:ok, _} -> {:ok, updated}
          {:error, :precondition_failed} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        case S3.put(key, Jason.encode!(new_rec), if_none_match: "*") do
          {:ok, _} -> {:ok, new_rec}
          {:error, :precondition_failed} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: System.system_time(:second)
end
