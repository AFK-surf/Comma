defmodule SalixAgent.Tailnet do
  require SystemsRuntime.Proc

  @moduledoc """
  A Group's node in its own Tailscale network (tailnet), so its Agents can
  reach the devices there.

  A Group has at most one node, in one tailnet. A tailnet admin approves it
  once with a login link; the node keeps its keys in the Group's lease
  record, so it survives restarts and moves between Salix nodes. One Salix
  node at a time holds the lease and runs the node in its gateway
  (`SalixAgent.Tailnet.Owner`, `SalixAgent.Tailnet.Gateway`). Agents on
  other nodes reach it through `SalixAgent.Tailnet.Relay`.

  Settings come from the Comma app, the BFT dashboard, the Salix dashboard
  and the Group's router Agent, all through `connect/3` and `disconnect/2`.
  Dials reach only peers and approved subnet routes of that tailnet; the
  tailnet's own policy decides which devices and ports answer.
  """

  alias SalixAgent.Tailnet.{Config, Gateway, NodeRecord, Owner, Relay}

  @connect_wait_ms 15_000
  @ensure_timeout_ms 20_000

  @type error :: %{required(String.t()) => String.t()}

  @doc """
  The Group's tailnet settings and node status. Never starts the node.

  `"state"` is one of `disabled`, `idle` (the node is offline until the next
  use), `starting`, `needs_login` (with `"login_url"`), `needs_approval`,
  `running` or `error`.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  def status(group_id) do
    with {:ok, config} <- Config.get(group_id) do
      record =
        case NodeRecord.read(group_id) do
          {:ok, record} -> record
          {:error, :not_found} -> nil
          {:error, _} -> nil
        end

      {:ok, project(config, record)}
    end
  end

  @doc """
  Enable the Group's node with `attrs` and start it. Waits up to 15 seconds
  for a login link or a running node, then returns `status/1`.
  `actor` is `agent:<id>`, `comma_user:<id>`, `bft_member:<id>` or
  `salix_admin`.
  """
  @spec connect(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def connect(group_id, attrs, actor) do
    with {:ok, _config} <- Config.enable(group_id, attrs, actor) do
      Gateway.config_changed(group_id)
      _ = ensure(group_id, @connect_wait_ms)
      status(group_id)
    end
  end

  @doc """
  Disable the Group's node. Its owner logs it out of the tailnet and clears
  its keys; returns `status/1` after at most 15 seconds.
  """
  @spec disconnect(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def disconnect(group_id, actor) do
    with {:ok, _config} <- Config.disable(group_id, actor) do
      Gateway.config_changed(group_id)

      # A saved node without an owner still needs one to log it out. Then
      # wait for the owner to finish.
      case ensure(group_id, 0) do
        {:ok, endpoint} ->
          on_owner(
            endpoint.node,
            :local_await_stopped,
            [group_id, @connect_wait_ms],
            @connect_wait_ms + 5_000
          )

        _error ->
          :ok
      end

      status(group_id)
    end
  end

  @doc "Remove the Group's tailnet data. Logs the node out first, best effort."
  def delete_group_data(group_id) do
    _ = disconnect(group_id, "system")
    _ = NodeRecord.delete(group_id)
    _ = Config.delete(group_id)
    :ok
  end

  @doc """
  Dial `host`:`port` in the Group's tailnet. Returns a passive raw binary
  socket owned by the caller and the gateway's reply (`"addr"`, `"peer"`,
  `"tailnet"`).
  """
  @spec dial(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, :gen_tcp.socket(), map()} | {:error, error()}
  def dial(group_id, host, port, timeout_ms) do
    with {:ok, endpoint} <- ensure(group_id, 0) do
      if endpoint.node == node(),
        do: local_dial(group_id, host, port, timeout_ms),
        else: Relay.dial(endpoint.node, group_id, host, port, timeout_ms)
    end
  end

  @doc "One page of the tailnet's peers: `%{\"peers\" => [...], \"next\" => cursor}`."
  @spec peers(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, error()}
  def peers(group_id, cursor \\ 0) do
    with {:ok, endpoint} <- ensure(group_id, 0) do
      on_owner(endpoint.node, :local_peers, [group_id, cursor])
    end
  end

  @doc "Stop this node's tailnet owners and release their leases. For drain."
  def drain, do: Owner.drain()

  # ---- owner placement -------------------------------------------------------------

  # The live lease holder runs the node; with none, this node takes the lease.
  defp ensure(group_id, await_ms, attempts \\ 2) do
    with {:ok, config} <- Config.get(group_id),
         :ok <- enabled_or_saved(group_id, config),
         {:ok, owner_node} <- owner_node(group_id) do
      case on_owner(
             owner_node,
             :local_ensure,
             [group_id, await_ms],
             await_ms + @ensure_timeout_ms
           ) do
        {:error, {:held_by, _holder}} when attempts > 1 ->
          ensure(group_id, await_ms, attempts - 1)

        {:error, {:held_by, _holder}} ->
          {:error, busy()}

        other ->
          other
      end
    end
  end

  defp enabled_or_saved(_group_id, %{"enabled" => true}), do: :ok

  defp enabled_or_saved(group_id, _config) do
    case NodeRecord.read(group_id) do
      {:ok, %{"body" => %{"state" => state}}} when is_map(state) and map_size(state) > 0 -> :ok
      _ -> {:error, not_configured()}
    end
  end

  defp owner_node(group_id) do
    case NodeRecord.read(group_id) do
      {:ok, record} ->
        if NodeRecord.live?(record) do
          holder = NodeRecord.holder_node(record["holder"])

          case Enum.find([node() | Node.list()], &(to_string(&1) == holder)) do
            nil -> {:error, busy()}
            owner -> {:ok, owner}
          end
        else
          {:ok, node()}
        end

      {:error, :not_found} ->
        {:ok, node()}

      {:error, reason} ->
        {:error, Gateway.unavailable(reason)}
    end
  end

  defp on_owner(owner, function, args, timeout \\ @ensure_timeout_ms)

  defp on_owner(owner, function, args, _timeout) when owner == node(),
    do: apply(__MODULE__, function, args)

  defp on_owner(owner, function, args, timeout) do
    :erpc.call(owner, __MODULE__, function, args, timeout)
  catch
    :error, {:erpc, reason} -> {:error, Gateway.unavailable({:owner_unreachable, reason})}
    :exit, reason -> {:error, Gateway.unavailable({:owner_unreachable, reason})}
  end

  @doc false
  def local_ensure(group_id, await_ms, attempts \\ 2) do
    case Owner.ensure(group_id) do
      {:ok, pid} -> Owner.endpoint(pid, await_ms)
      {:error, {:held_by, _holder}} = held -> held
      {:error, %{"code" => _} = error} -> {:error, error}
      {:error, reason} -> {:error, Gateway.unavailable(reason)}
    end
  catch
    # The owner stopped (idle, drained) between the lookup and the call;
    # the next attempt starts a new one.
    :exit, _ when attempts > 1 -> local_ensure(group_id, await_ms, attempts - 1)
    :exit, _ -> {:error, Gateway.unavailable(:owner_stopped)}
  end

  @doc false
  def local_dial(group_id, host, port, timeout_ms, attempts \\ 2) do
    with {:ok, endpoint} <- local_ensure(group_id, 0),
         :ok <- runnable(endpoint) do
      case Gateway.dial(group_id, endpoint.run, host, port, timeout_ms) do
        # The owner restarted its node between the lookup and the dial.
        {:error, %{"code" => "tailnet_not_running"}} when attempts > 1 ->
          local_dial(group_id, host, port, timeout_ms, attempts - 1)

        other ->
          other
      end
    end
  end

  @doc false
  def local_peers(group_id, cursor) do
    with {:ok, endpoint} <- local_ensure(group_id, 0),
         :ok <- runnable(endpoint),
         {:ok, reply} <- Gateway.peers(group_id, endpoint.run, cursor, 10_000) do
      {:ok,
       %{
         "tailnet" => reply["tailnet"],
         "peers" => reply["peers"] || [],
         "next" => reply["next"] || 0
       }}
    end
  end

  defp runnable(%{run: run}) when is_integer(run), do: :ok

  defp runnable(%{status: status}),
    do:
      {:error,
       %{
         "code" => status["code"] || "tailnet_unavailable",
         "message" => status["message"] || "The Group's tailnet node is not running."
       }}

  @doc false
  def local_await_stopped(group_id, wait_ms) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Tailnet.Registry, group_id) do
      [{pid, _}] ->
        ref = SystemsRuntime.Proc.monitor(pid)

        SystemsRuntime.Proc.receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          SystemsClock.timeout(wait_ms) ->
            SystemsRuntime.Proc.demonitor(ref, [:flush])
            :timeout
        end

      [] ->
        :ok
    end
  end

  # ---- projection ------------------------------------------------------------------

  defp project(config, record) do
    body = (record && record["body"]) || %{}
    node_status = Map.get(body, "status") || %{}
    live? = record != nil and NodeRecord.live?(record)

    state =
      cond do
        not config["enabled"] -> "disabled"
        live? -> node_status["status"] || "starting"
        node_status["status"] == "error" -> "error"
        true -> "idle"
      end

    %{
      "enabled" => config["enabled"],
      "state" => state,
      "approved" => body["approved"] == true,
      "login_url" => if(live? and state == "needs_login", do: node_status["auth_url"]),
      "tailnet" => node_status["tailnet"],
      "node_name" => node_status["node_name"],
      "login_name" => node_status["login_name"],
      "node_tags" => node_status["tags"] || [],
      "addresses" => node_status["self_ips"] || [],
      "key_expiry" => node_status["key_expiry"],
      "error" =>
        if(state == "error" or node_status["code"] == "tailnet_mismatch",
          do: %{"code" => node_status["code"], "message" => node_status["message"]}
        ),
      "settings" => Map.take(config, ["tags", "accept_routes", "expected_tailnet"]),
      "updated_by" => config["updated_by"],
      "updated_at" => config["updated_at"],
      "status_updated_at" => node_status["updated_at"],
      "owner" =>
        if(live?,
          do: %{
            "node" => NodeRecord.holder_node(record["holder"]),
            "epoch" => record["epoch"],
            "lease_until" => record["lease_until"]
          }
        )
    }
  end

  defp not_configured,
    do: %{
      "code" => "tailnet_not_configured",
      "message" =>
        "The Group has no tailnet. The router Agent or a Group admin connects one first."
    }

  defp busy,
    do: %{
      "code" => "tailnet_unavailable",
      "message" => "The Group's tailnet node is moving between Salix nodes. Retry shortly."
    }
end
