defmodule SalixAgent.Tailnet.Owner do
  require SystemsRuntime.Proc

  @moduledoc """
  The owner of one Group's tailnet node on this node. At most one owner in
  the cluster holds a Group's lease (`SalixAgent.Tailnet.NodeRecord`); only
  that owner runs the Group's node in its gateway and writes its state.

  The owner:

    * takes the lease in `init/1`, or does not start;
    * starts the node in the gateway with the saved state and the Group's
      settings, under a new run number;
    * saves every state change the gateway reports (`persist`) under the
      lease before the gateway continues, and records status changes;
    * renews the lease every 10 seconds; a lost lease stops the node at once;
    * applies a new settings generation: disabled means log out and clear
      the state; other changes restart the node;
    * stops when the gateway does not start the node, keeping the state, so
      the next use retries with a new owner;
    * stops an idle node: no connection for 15 minutes, or a login link
      nobody approved for 30 minutes. The lease is released and the state
      kept, so the next use restores the same node;
    * logs the node out and clears its state when it joins a tailnet other
      than `expected_tailnet`;
    * keeps the state when a logout does not leave the tailnet, so a later
      disconnect (or, after a mismatch, a later connect) logs it out again.

  It keeps nothing that the lease record does not hold.
  """

  use SystemsRuntime.Server, restart: :temporary

  require Logger

  alias SalixAgent.Tailnet.{Config, Gateway, NodeRecord}

  @registry SalixAgent.Tailnet.Registry
  @supervisor SalixAgent.Tailnet.Owners
  @renew_ms 10_000
  @check_ms 60_000
  @idle_ms 15 * 60_000
  @login_ms 30 * 60_000
  @stop_timeout_ms 20_000
  @settled ~w(needs_login needs_approval running error)

  # ---- client ------------------------------------------------------------------

  @doc false
  def child_spec(group_id),
    do: %{
      id: {__MODULE__, group_id},
      start: {__MODULE__, :start_link, [group_id]},
      restart: :temporary
    }

  def start_link(group_id),
    do:
      SystemsRuntime.Server.start_link(__MODULE__, group_id,
        name: {:via, SystemsRuntime.Registry, {@registry, group_id}}
      )

  @doc """
  This node's owner of the Group, started when needed. Returns
  `{:error, {:held_by, holder}}` when another node holds the lease.
  """
  def ensure(group_id) do
    # The Registry drops a stopped owner's entry only after its exit.
    case SystemsRuntime.Registry.lookup(@registry, group_id) do
      [{pid, _}] -> if SystemsRuntime.Proc.alive?(pid), do: {:ok, pid}, else: start(group_id)
      [] -> start(group_id)
    end
  end

  defp start(group_id) do
    case SystemsRuntime.DynamicSupervisor.start_child(@supervisor, {__MODULE__, group_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:shutdown, {:held_by, holder}}} -> {:error, {:held_by, holder}}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The owner's run number and status. With `await_ms`, waits until the node
  settles (running, waiting for login or approval, or failed).
  """
  def endpoint(pid, await_ms \\ 0),
    do: SystemsClock.call(pid, {:endpoint, await_ms}, await_ms + 5_000)

  @doc false
  def notify(group_id, message) do
    case SystemsRuntime.Registry.lookup(@registry, group_id) do
      [{pid, _}] -> SystemsRuntime.Proc.send(pid, message)
      [] -> :ok
    end
  end

  @doc false
  def notify_all(message) do
    for {_, pid, _, _} <- SystemsRuntime.DynamicSupervisor.which_children(@supervisor),
        SystemsRuntime.Proc.is_process(pid),
        do: SystemsRuntime.Proc.send(pid, message)

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  def config_changed(group_id), do: notify(group_id, :config_changed)

  @doc "Stop every owner on this node and release their leases. For drain."
  def drain do
    owners =
      for {_, pid, _, _} <- SystemsRuntime.DynamicSupervisor.which_children(@supervisor),
          SystemsRuntime.Proc.is_process(pid),
          do: pid

    owners
    |> SystemsClock.async_stream(&drain_one/1,
      timeout: @stop_timeout_ms + 6_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  catch
    :exit, _ -> :ok
  end

  # An owner that stops by itself first exits the call; the task is linked to
  # the caller, so that exit must not leave the task.
  defp drain_one(pid) do
    SystemsClock.call(pid, :drain, @stop_timeout_ms + 5_000)
  catch
    :exit, _ -> :ok
  end

  # ---- server ------------------------------------------------------------------

  @impl true
  def init(group_id) do
    holder =
      "#{node()}|" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)

    with {:ok, config} <- Config.get(group_id),
         {:ok, lease} <- NodeRecord.acquire(group_id, holder) do
      state = %{
        group_id: group_id,
        lease: lease,
        config: config,
        run: nil,
        status: status_of(lease.body),
        conns: 0,
        active_at: now(),
        started_at: now(),
        stopping: nil,
        waiters: []
      }

      SystemsClock.send_after(SystemsRuntime.Proc.self(), :renew, @renew_ms)
      SystemsClock.send_after(SystemsRuntime.Proc.self(), :check, @check_ms)
      {:ok, state, {:continue, :start}}
    else
      {:error, {:held_by, holder, _until}} -> {:stop, {:shutdown, {:held_by, holder}}}
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_continue(:start, state) do
    cond do
      state.config["enabled"] ->
        start_node(state)

      saved_state(state) != %{} ->
        # Disabled with a saved node: start it only to log it out. If it
        # does not start, the state stays for the next disconnect.
        case start_node(state) do
          {:noreply, state} -> begin_stop(state, :remove)
          stopped -> stopped
        end

      true ->
        finish(state, cleared_body(state, "disabled"))
    end
  end

  @impl true
  def handle_call({:endpoint, await_ms}, from, state) do
    if await_ms > 0 and not settled?(state) do
      ref = SystemsRuntime.Proc.make_ref()
      SystemsClock.send_after(SystemsRuntime.Proc.self(), {:await_timeout, ref}, await_ms)
      {:noreply, %{state | waiters: [{ref, from} | state.waiters]}}
    else
      {:reply, {:ok, endpoint_info(state)}, state}
    end
  end

  def handle_call(:drain, _from, state) do
    state = stop_and_wait(state)
    NodeRecord.release(state.lease)
    {:stop, :normal, :ok, %{state | lease: nil}}
  end

  @impl true
  def handle_info({:tailnet_gateway, :down}, state) do
    Logger.warning("tailnet gateway stopped; releasing the lease of #{state.group_id}")
    {:stop, :normal, state}
  end

  def handle_info({:tailnet_gateway, %{"epoch" => run} = frame}, %{run: run} = state),
    do: gateway_frame(frame, state)

  def handle_info({:tailnet_gateway, %{"type" => "persist", "seq" => seq}}, state) do
    # A frame from an earlier run: never save its state.
    Gateway.persisted(seq, false)
    {:noreply, state}
  end

  def handle_info({:tailnet_gateway, _stale}, state), do: {:noreply, state}

  def handle_info(:renew, state) do
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :renew, @renew_ms)

    case NodeRecord.write(state.lease, state.lease.body) do
      {:ok, lease} -> {:noreply, %{state | lease: lease}}
      {:error, :lost} -> lost(state)
      {:error, reason} -> lost(state, reason)
    end
  end

  def handle_info(:check, state) do
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :check, @check_ms)
    state = maybe_apply_config(state)
    idle_for = now() - state.active_at

    cond do
      state.stopping != nil ->
        {:noreply, state}

      state.status["status"] == "running" and state.conns == 0 and idle_for > @idle_ms ->
        begin_stop(state, :idle)

      state.status["status"] in ["needs_login", "needs_approval", "starting"] and
          now() - state.started_at > @login_ms ->
        begin_stop(state, :idle)

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:config_changed, state), do: {:noreply, maybe_apply_config(state)}

  def handle_info({:await_timeout, ref}, state) do
    case List.keytake(state.waiters, ref, 0) do
      {{^ref, from}, waiters} ->
        SystemsRuntime.Server.reply(from, {:ok, endpoint_info(state)})
        {:noreply, %{state | waiters: waiters}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:stop_timeout, run}, %{run: run, stopping: reason} = state) when reason != nil,
    do: node_stopped(state, false)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{lease: lease} = state) when lease != nil do
    if state.run != nil and state.stopping == nil,
      do: Gateway.stop_node(state.group_id, state.run, false)

    NodeRecord.release(lease)
  end

  def terminate(_reason, _state), do: :ok

  # ---- gateway frames ------------------------------------------------------------

  defp gateway_frame(%{"type" => "persist", "seq" => seq, "state" => node_state}, state)
       when is_map(node_state) do
    body = Map.put(state.lease.body, "state", node_state)

    case NodeRecord.write(state.lease, body) do
      {:ok, lease} ->
        Gateway.persisted(seq, true)
        {:noreply, %{state | lease: lease}}

      {:error, reason} ->
        Gateway.persisted(seq, false)
        lost(state, reason)
    end
  end

  # A node being stopped reports what its logout does (needs_login); the
  # reason it stops is the status to keep.
  defp gateway_frame(%{"type" => "status"}, %{stopping: stopping} = state) when stopping != nil,
    do: {:noreply, state}

  defp gateway_frame(%{"type" => "status"} = frame, state) do
    status = status_from(frame)

    if mismatch?(state.config, status) and state.stopping == nil do
      mismatch =
        Map.merge(status, %{
          "status" => "error",
          "code" => "tailnet_mismatch",
          "message" =>
            "The login link was approved in tailnet #{status["tailnet"]}, not #{state.config["expected_tailnet"]}. The node left that tailnet; connect again for a new link."
        })

      # The approval was for another tailnet; it no longer counts.
      lease = %{state.lease | body: Map.put(state.lease.body, "approved", false)}
      %{state | lease: lease} |> record_status(mismatch) |> begin_stop(:mismatch)
    else
      state = record_status(state, status)

      if status["status"] == "error" and state.stopping == nil,
        do: begin_stop(state, :failed),
        else: {:noreply, state}
    end
  end

  defp gateway_frame(%{"type" => "activity", "conns" => conns}, state) when is_integer(conns),
    do: {:noreply, %{state | conns: conns, active_at: now()}}

  defp gateway_frame(%{"type" => "stopped"} = frame, state),
    do: node_stopped(state, frame["logged_out"] == true)

  defp gateway_frame(_frame, state), do: {:noreply, state}

  # ---- node lifecycle ------------------------------------------------------------

  defp start_node(state) do
    run = SystemsRuntime.Proc.unique_integer([:positive, :monotonic])

    opts = %{
      hostname: hostname(state.group_id),
      tags: state.config["tags"],
      accept_routes: state.config["accept_routes"],
      state: saved_state(state)
    }

    state = %{state | run: run, started_at: now(), active_at: now(), stopping: nil}

    case Gateway.start_node(state.group_id, run, opts) do
      :ok ->
        {:noreply,
         record_status(
           state,
           Map.merge(state.status, %{"status" => "starting", "auth_url" => nil})
         )}

      {:error, error} ->
        # A start whose call timed out can still reach the gateway; without
        # this stop, its node would run with no owner.
        Gateway.stop_node(state.group_id, run, false)
        status = %{"status" => "error", "code" => error["code"], "message" => error["message"]}
        # Keep the state and release the lease: the next connect or dial
        # starts a new owner, which tries again.
        after_stop(%{record_status(state, status) | run: nil, stopping: nil})
    end
  end

  defp begin_stop(%{run: nil} = state, reason), do: after_stop(%{state | stopping: reason})

  defp begin_stop(state, reason) do
    Gateway.stop_node(state.group_id, state.run, reason in [:remove, :mismatch])

    SystemsClock.send_after(
      SystemsRuntime.Proc.self(),
      {:stop_timeout, state.run},
      @stop_timeout_ms
    )

    {:noreply, %{state | stopping: reason}}
  end

  # A logout that did not leave the tailnet keeps the keys, so a later
  # disconnect logs the node out instead of leaving it in the tailnet.
  defp node_stopped(%{stopping: reason} = state, false) when reason in [:remove, :mismatch] do
    status = %{
      "status" => "error",
      "code" => "tailnet_logout_failed",
      "message" =>
        "The Group's node did not leave its tailnet. Disconnect again to retry, or remove the device in the Tailscale admin console."
    }

    after_stop(%{record_status(state, status) | run: nil, stopping: nil})
  end

  defp node_stopped(state, _logged_out), do: after_stop(state)

  defp after_stop(%{stopping: :restart} = state), do: start_node(%{state | stopping: nil})

  defp after_stop(%{stopping: :remove} = state),
    do: finish(%{state | run: nil}, cleared_body(state, "disabled"))

  defp after_stop(%{stopping: :mismatch} = state),
    do: finish(%{state | run: nil}, cleared_body(state, state.status))

  defp after_stop(state) do
    # Idle, failed, or the node stopped by itself: keep the state.
    status =
      if state.status["status"] in ["error"],
        do: state.status,
        else: Map.put(state.status, "status", "idle")

    finish(
      %{state | run: nil},
      Map.put(state.lease.body, "status", Map.put(status, "auth_url", nil))
    )
  end

  defp finish(state, body) do
    lease =
      case NodeRecord.write(state.lease, body) do
        {:ok, lease} -> lease
        {:error, _} -> state.lease
      end

    NodeRecord.release(lease)
    reply_waiters(state)
    {:stop, :normal, %{state | lease: nil}}
  end

  defp stop_and_wait(%{run: nil} = state), do: state

  defp stop_and_wait(state) do
    Gateway.stop_node(state.group_id, state.run, false)
    run = state.run

    SystemsRuntime.Proc.receive do
      {:tailnet_gateway, %{"type" => "stopped", "epoch" => ^run}} -> %{state | run: nil}
    after
      SystemsClock.timeout(@stop_timeout_ms) -> %{state | run: nil}
    end
  end

  defp lost(state, reason \\ :lost) do
    Logger.warning("tailnet lease of #{state.group_id} lost: #{inspect(reason)}")
    if state.run != nil, do: Gateway.stop_node(state.group_id, state.run, false)
    reply_waiters(state)
    {:stop, :normal, %{state | lease: nil, run: nil}}
  end

  defp maybe_apply_config(%{stopping: stopping} = state) when stopping != nil, do: state

  defp maybe_apply_config(state) do
    with {:ok, config} <- Config.get(state.group_id),
         true <- config["generation"] != state.config["generation"] do
      previous = state.config
      state = %{state | config: config}

      cond do
        not config["enabled"] ->
          {:noreply, state} = begin_stop(state, :remove)
          state

        Config.node_settings(config) != Config.node_settings(previous) ->
          {:noreply, state} = begin_stop(state, :restart)
          state

        true ->
          state
      end
    else
      _ -> state
    end
  end

  # ---- status ----------------------------------------------------------------------

  defp record_status(state, status) do
    status = Map.put(status, "updated_at", DateTime.to_iso8601(SystemsClock.utc_now()))
    approved = state.lease.body["approved"] == true or status["status"] == "running"
    body = state.lease.body |> Map.put("status", status) |> Map.put("approved", approved)

    state =
      if Map.drop(status, ["updated_at"]) == Map.drop(state.status, ["updated_at"]) do
        %{state | status: status}
      else
        case NodeRecord.write(state.lease, body) do
          {:ok, lease} -> %{state | lease: lease, status: status}
          {:error, _} -> %{state | status: status}
        end
      end

    if settled?(state), do: reply_waiters(state), else: state
  end

  defp status_from(frame) do
    frame
    |> Map.take(
      ~w(status auth_url tailnet magic_dns_suffix node_name login_name tags self_ips key_expiry code message)
    )
  end

  defp status_of(body), do: Map.get(body, "status") || %{"status" => "starting"}

  defp settled?(state),
    do:
      state.status["status"] in @settled and
        (state.status["status"] != "needs_login" or is_binary(state.status["auth_url"]))

  defp reply_waiters(state) do
    for {_ref, from} <- state.waiters,
        do: SystemsRuntime.Server.reply(from, {:ok, endpoint_info(state)})

    %{state | waiters: []}
  end

  defp endpoint_info(state),
    do: %{
      node: node(),
      run: state.run,
      status: state.status,
      epoch: state.lease && state.lease.epoch
    }

  defp mismatch?(%{"expected_tailnet" => expected}, %{"status" => "running"} = status)
       when is_binary(expected) do
    expected not in Enum.map(
      [status["tailnet"], status["magic_dns_suffix"]],
      &normalize_tailnet/1
    )
  end

  defp mismatch?(_config, _status), do: false

  defp normalize_tailnet(nil), do: nil
  defp normalize_tailnet(name), do: name |> String.trim_trailing(".") |> String.downcase()

  defp saved_state(state), do: Map.get(state.lease.body, "state") || %{}

  defp cleared_body(_state, "disabled"),
    do: %{"state" => nil, "approved" => false, "status" => %{"status" => "disabled"}}

  defp cleared_body(_state, status) when is_map(status),
    do: %{"state" => nil, "approved" => false, "status" => Map.put(status, "auth_url", nil)}

  # A DNS label: "comma-" and the Group's own part of its id.
  @doc false
  def hostname(group_id) do
    suffix =
      group_id
      |> String.split("_")
      |> List.last()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "")
      |> String.slice(-16, 16)

    "comma-" <> suffix
  end

  defp now, do: SystemsClock.monotonic_time(:millisecond)
end
