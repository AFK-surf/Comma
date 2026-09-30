defmodule SalixMCP.Connection do
  @moduledoc false

  use GenServer

  alias SalixMCP.{Config, ExecutionPolicy, JSONRPC, RemoteClient}
  alias SalixEnv.Connector.Live, as: ConnectorLive

  @request_timeout 120_000

  def child_spec(opts) do
    binding = Keyword.fetch!(opts, :binding)

    %{
      id: {__MODULE__, key(binding)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts) do
    binding = Keyword.fetch!(opts, :binding)
    GenServer.start_link(__MODULE__, opts, name: via(binding))
  end

  def ensure_started(binding, definition) do
    case Registry.lookup(SalixMCP.ConnectionRegistry, key(binding)) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          start_connection(binding, definition)
        end

      [{_dead_pid, _}] ->
        start_connection(binding, definition)

      [] ->
        start_connection(binding, definition)
    end
  end

  defp start_connection(binding, definition) do
    case DynamicSupervisor.start_child(
           SalixMCP.ConnectionSupervisor,
           {__MODULE__, binding: binding, definition: definition}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :disconnected}

      other ->
        other
    end
  end

  def stop(binding) do
    case Registry.lookup(SalixMCP.ConnectionRegistry, key(binding)) do
      [{pid, _}] ->
        GenServer.stop(pid, :normal, 5_000)

      [] ->
        :ok
    end

    :ok
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, :noproc -> :ok
  end

  def request(binding, definition, method, params, timeout \\ @request_timeout, opts \\ []) do
    with {:ok, pid} <- ensure_started(binding, definition) do
      safe_call(pid, {:request, method, params, timeout, opts}, timeout + 5_000)
    end
  end

  def cancel_request(binding, _definition, request_id, reason) do
    case Registry.lookup(SalixMCP.ConnectionRegistry, key(binding)) do
      [{pid, _}] ->
        send(pid, {:mcp_cancel_request, to_string(request_id), to_string(reason || "")})

      [] ->
        :ok
    end

    :ok
  end

  def notify(binding, definition, method, params) do
    with {:ok, pid} <- ensure_started(binding, definition) do
      safe_call(pid, {:notify, method, params}, 5_000)
    end
  end

  def initialize(binding, definition) do
    with {:ok, pid} <- ensure_started(binding, definition) do
      safe_call(pid, :initialize, @request_timeout + 5_000)
    end
  end

  defp safe_call(pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :disconnected}
    :exit, {:normal, _} -> {:error, :disconnected}
    :exit, {:shutdown, _} -> {:error, :disconnected}
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    binding = Keyword.fetch!(opts, :binding)
    definition = Keyword.fetch!(opts, :definition)

    {:ok,
     %{
       binding: binding,
       definition: definition,
       config: nil,
       mode: nil,
       port: nil,
       buffer: "",
       next_id: 1,
       remote_headers: %{},
       initialize_result: nil,
       initialized?: false,
       device: nil,
       device_offset: 0,
       sse_endpoint: nil,
       sse_task: nil
     }}
  end

  @impl true
  def handle_call({:request, method, params, timeout, opts}, _from, state) do
    case ensure_transport(state) do
      {:ok, state} ->
        case do_request(state, method, params || %{}, timeout, opts) do
          {:ok, result, state} -> {:reply, {:ok, result}, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:initialize, _from, %{initialized?: true} = state),
    do: {:reply, {:ok, initialize_info(state.initialize_result)}, state}

  def handle_call(:initialize, _from, state) do
    case ensure_transport(state) do
      {:ok, state} ->
        case do_request(state, "initialize", initialize_params(), @request_timeout, []) do
          {:ok, result, state} ->
            case do_notify(state, "notifications/initialized", %{}) do
              {:ok, state} ->
                {:reply, {:ok, initialize_info(result)},
                 %{state | initialized?: true, initialize_result: result}}

              {:error, reason, state} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    case ensure_transport(state) do
      {:ok, state} ->
        case do_notify(state, method, params || %{}) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({_port, {:data, {:eol, line}}}, state) do
    state =
      state
      |> Map.update!(:buffer, &(&1 <> line <> "\n"))
      |> maybe_mark_discovery_changed(discovery_changed_notification?(line))

    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    {:noreply,
     %{
       state
       | port: nil,
         initialized?: false,
         buffer: state.buffer <> "\n[process exited #{status}]\n"
     }}
  end

  def handle_info({:mcp_sse_endpoint, pid, endpoint}, %{sse_task: pid} = state) do
    {:noreply, %{state | sse_endpoint: endpoint}}
  end

  def handle_info({:mcp_sse_response, pid, response}, %{sse_task: pid} = state)
      when is_map(response) do
    state =
      state
      |> Map.put(:buffer, append_json_line(state.buffer, response))
      |> maybe_mark_discovery_changed(discovery_changed_notification?(response))

    {:noreply, state}
  end

  def handle_info({:mcp_sse_error, pid, reason}, %{sse_task: pid} = state) do
    {:noreply,
     %{
       state
       | sse_task: nil,
         sse_endpoint: nil,
         initialized?: false,
         buffer: state.buffer <> "\n[sse error #{inspect(reason)}]\n"
     }}
  end

  def handle_info({:mcp_sse_closed, pid}, %{sse_task: pid} = state) do
    {:noreply, %{state | sse_task: nil, sse_endpoint: nil, initialized?: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state[:port])
    stop_sse_task(state[:sse_task])

    if state[:mode] == :device do
      _ = device_stop(state)
    end

    :ok
  end

  defp close_port(port) when not is_nil(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp close_port(_port), do: :ok

  defp stop_sse_task(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
  catch
    _, _ -> :ok
  end

  defp stop_sse_task(_pid), do: :ok

  defp ensure_transport(%{config: nil, mode: :sse, sse_task: pid} = state) when is_pid(pid),
    do: {:ok, state}

  defp ensure_transport(%{config: nil} = state) do
    with {:ok, config} <- Config.resolve(state.definition, state.binding) do
      mode = transport_mode(state.binding, config)
      state = %{state | mode: mode}

      case mode do
        :remote -> {:ok, %{state | config: nil}}
        :sse -> start_sse_stream(%{state | config: nil}, config)
        :server -> start_server_process(%{state | config: config})
        :device -> start_device_process(%{state | config: config})
        :device_remote -> start_device_remote(%{state | config: nil})
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_transport(%{config: config, mode: :server, port: nil} = state) when is_map(config),
    do: start_server_process(%{state | initialized?: false})

  defp ensure_transport(%{mode: :sse, sse_task: nil} = state),
    do: ensure_transport(%{state | config: nil, initialized?: false, sse_endpoint: nil})

  defp ensure_transport(%{config: config, mode: :device, device: nil} = state)
       when is_map(config),
       do: start_device_process(%{state | initialized?: false})

  defp ensure_transport(%{config: config, mode: :device_remote, device: nil} = state)
       when is_map(config),
       do: start_device_remote(%{state | initialized?: false})

  defp ensure_transport(state), do: {:ok, state}

  defp transport_mode(%{"placement" => "device"}, %{"kind" => "remote"}), do: :device_remote
  defp transport_mode(_binding, %{"kind" => "remote", "transport" => "sse"}), do: :sse
  defp transport_mode(_binding, %{"kind" => "remote"}), do: :remote
  defp transport_mode(%{"placement" => "device"}, _config), do: :device
  defp transport_mode(_binding, _config), do: :server

  defp start_server_process(%{port: port} = state) when not is_nil(port), do: {:ok, state}

  defp start_server_process(state) do
    with {:ok, config} <- Config.resolve(state.definition, state.binding),
         :ok <- ExecutionPolicy.validate_server_process(state.definition, state.binding, config),
         {:ok, spawn} <- ExecutionPolicy.server_process_spawn(config, state.binding) do
      port =
        Port.open({:spawn_executable, spawn.executable}, [
          :binary,
          :exit_status,
          {:line, 1_048_576},
          {:args, spawn.args},
          {:cd, spawn.cd},
          {:env, env_list(spawn.env)}
        ])

      {:ok, %{state | port: port, config: scrub_process_config(config)}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  rescue
    e -> {:error, Exception.message(e), state}
  end

  defp start_device_process(state) do
    binding = state.binding

    with {:ok, device} <- resolve_device(binding) do
      start_device_process_on_device(state, device)
    end
  end

  defp start_device_process_on_device(state, device) do
    binding = state.binding

    with {:ok, config} <- Config.resolve(state.definition, state.binding),
         run_id when is_binary(run_id) and run_id != "" <- device["connector_run_id"],
         :ok <- stop_existing_device_process(run_id, binding),
         {:ok, _started} <-
           ConnectorLive.request(run_id, "process_start", %{
             "process_name" => process_name(binding),
             "command" => config["command"],
             "args" => config["args"] || [],
             "env" => config["env"] || %{},
             "working_dir" => config["working_dir"] || ".",
             "enforce_root" => true,
             "root_grants" => binding["root_grants"] || []
           }) do
      {:ok,
       %{
         state
         | config: scrub_process_config(config),
           device: device,
           device_offset: 0,
           buffer: "",
           initialized?: false
       }}
    else
      nil -> {:error, :disconnected, state}
      "" -> {:error, :disconnected, state}
      {:error, reason} -> {:error, normalize_device_process_error(reason), state}
    end
  end

  defp stop_existing_device_process(run_id, binding) do
    case ConnectorLive.request(run_id, "process_stop", %{
           "process_name" => process_name(binding)
         }) do
      {:ok, _stopped} -> :ok
      {:error, reason} -> ignore_missing_process(reason)
    end
  end

  defp ignore_missing_process(reason) when is_binary(reason) do
    if Regex.match?(~r/^(process_stop: )?process .+ not found$/, reason) do
      :ok
    else
      {:error, reason}
    end
  end

  defp ignore_missing_process(reason), do: {:error, reason}

  defp normalize_device_process_error("process working_dir is outside root_grants" = reason),
    do: {:missing_root, reason}

  defp normalize_device_process_error(
         "process_start: process working_dir is outside root_grants" = reason
       ),
       do: {:missing_root, reason}

  defp normalize_device_process_error("empty root grant" = reason), do: {:missing_root, reason}

  defp normalize_device_process_error("process_start: empty root grant" = reason),
    do: {:missing_root, reason}

  defp normalize_device_process_error(reason), do: reason

  defp start_device_remote(state) do
    binding = state.binding

    with {:ok, device} <- resolve_device(binding) do
      {:ok, %{state | device: device}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_sse_stream(state, config) do
    {:ok, pid} = RemoteClient.start_sse(config, self())
    {:ok, %{state | sse_task: pid, sse_endpoint: nil}}
  end

  defp scrub_process_config(config) when is_map(config),
    do: Map.drop(config, ["env", "headers", "variables"])

  defp do_request(%{mode: mode, initialized?: false} = state, method, params, timeout, opts)
       when mode in [:sse, :server, :device, :device_remote] and method != "initialize" do
    case do_request(state, "initialize", initialize_params(), @request_timeout, []) do
      {:ok, _result, state} ->
        case do_notify(state, "notifications/initialized", %{}) do
          {:ok, state} -> do_request(%{state | initialized?: true}, method, params, timeout, opts)
          {:error, reason, state} -> {:error, reason, state}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp do_request(%{mode: :remote} = state, method, params, timeout, opts) do
    with {:ok, config} <- request_config(state) do
      if method == "initialize" do
        case RemoteClient.initialize(config) do
          {:ok, result, headers} ->
            {:ok, result, %{state | remote_headers: headers, initialized?: true}}

          {:error, reason} ->
            {:error, reason, state}
        end
      else
        case ensure_remote_initialized(state, config) do
          {:ok, state} ->
            id =
              request_id(
                method,
                opts,
                "mcp-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
              )

            params = request_params(method, params, opts)

            case remote_request_with_cancel(state, config, id, method, params, timeout, opts) do
              {:ok, result, headers} ->
                state = %{
                  state
                  | remote_headers:
                      Map.merge(state.remote_headers, RemoteClient.session_headers(headers))
                }

                {:ok, result, state}

              {:error, reason} ->
                {:error, reason, state}
            end

          {:error, reason, state} ->
            {:error, reason, state}
        end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_request(%{mode: :sse} = state, method, params, timeout, opts) do
    id = request_id(method, opts, state.next_id)
    params = request_params(method, params, opts)
    msg = JSONRPC.request(id, method, params)

    with {:ok, state} <- ensure_sse_endpoint(state, System.monotonic_time(:millisecond) + timeout),
         {:ok, config} <- request_config(state),
         :ok <- RemoteClient.sse_post(config, state.sse_endpoint, msg, timeout) do
      wait_sse_response(
        %{state | next_id: state.next_id + 1},
        id,
        System.monotonic_time(:millisecond) + timeout,
        opts
      )
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_request(%{mode: :server} = state, method, params, timeout, opts) do
    id = request_id(method, opts, state.next_id)
    params = request_params(method, params, opts)
    msg = JSONRPC.request(id, method, params)
    Port.command(state.port, Jason.encode!(msg) <> "\n")

    wait_stdio_response(
      %{state | next_id: state.next_id + 1},
      id,
      System.monotonic_time(:millisecond) + timeout,
      opts
    )
  rescue
    e -> {:error, Exception.message(e), %{state | port: nil, initialized?: false}}
  end

  defp do_request(%{mode: :device} = state, method, params, timeout, opts) do
    case ensure_current_device(state) do
      {:ok, %{initialized?: false} = state} when method != "initialize" ->
        do_request(state, method, params, timeout, opts)

      {:ok, state} ->
        id = request_id(method, opts, state.next_id)
        params = request_params(method, params, opts)
        msg = JSONRPC.request(id, method, params)

        with :ok <- device_write(state, Jason.encode!(msg) <> "\n") do
          wait_device_response(
            %{state | next_id: state.next_id + 1},
            id,
            System.monotonic_time(:millisecond) + timeout,
            opts
          )
        else
          {:error, reason} -> {:error, reason, clear_device_if_stale(state, reason)}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp do_request(%{mode: :device_remote} = state, method, params, timeout, opts) do
    case ensure_current_device(state) do
      {:ok, %{initialized?: false} = state} when method != "initialize" ->
        do_request(state, method, params, timeout, opts)

      {:ok, state} ->
        with {:ok, config} <- request_config(state) do
          id = request_id(method, opts, state.next_id)
          params = request_params(method, params, opts)
          msg = JSONRPC.request(id, method, params)

          case device_remote_request_with_cancel(state, config, id, msg, timeout, opts) do
            {:ok, response, headers} ->
              state =
                state
                |> Map.put(:next_id, state.next_id + 1)
                |> Map.put(
                  :remote_headers,
                  Map.merge(state.remote_headers, RemoteClient.session_headers(headers))
                )
                |> Map.put(:initialized?, state.initialized? or method == "initialize")

              with {:ok, result} <- JSONRPC.response_result(response) do
                {:ok, result, state}
              else
                {:error, reason} -> {:error, reason, state}
              end

            {:error, reason} ->
              {:error, reason, clear_device_if_stale(state, reason)}
          end
        else
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp request_config(state), do: Config.resolve(state.definition, state.binding)

  defp ensure_remote_initialized(%{initialized?: true} = state, _config), do: {:ok, state}

  defp ensure_remote_initialized(state, config) do
    case RemoteClient.initialize(config) do
      {:ok, _init, headers} ->
        _ = RemoteClient.notify(config, "notifications/initialized", %{}, headers)
        {:ok, %{state | remote_headers: headers, initialized?: true}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp remote_request_with_cancel(state, config, id, method, params, timeout, opts) do
    task =
      Task.Supervisor.async_nolink(SalixMCP.TaskSupervisor, fn ->
        RemoteClient.request(config, method, params, state.remote_headers, timeout,
          request_id: id,
          progress_callback: &maybe_emit_progress(&1, opts)
        )
      end)

    wait_request_task_with_cancel(
      state,
      id,
      task,
      System.monotonic_time(:millisecond) + timeout,
      fn reason ->
        RemoteClient.notify(
          config,
          "notifications/cancelled",
          cancel_params(id, reason),
          state.remote_headers
        )
      end
    )
  end

  defp device_remote_request_with_cancel(state, config, id, msg, timeout, opts) do
    task =
      Task.Supervisor.async_nolink(SalixMCP.TaskSupervisor, fn ->
        device_http_jsonrpc(state, config, msg, timeout, opts)
      end)

    wait_request_task_with_cancel(
      state,
      id,
      task,
      System.monotonic_time(:millisecond) + timeout,
      fn reason ->
        device_http_jsonrpc(
          state,
          config,
          JSONRPC.notification("notifications/cancelled", cancel_params(id, reason)),
          @request_timeout
        )
      end
    )
  end

  defp wait_request_task_with_cancel(_state, id, task, deadline, cancel_fun) do
    if System.monotonic_time(:millisecond) >= deadline do
      Task.shutdown(task, :brutal_kill)
      {:error, :timeout}
    else
      receive do
        {ref, result} when ref == task.ref ->
          Process.demonitor(task.ref, [:flush])
          result

        {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
          {:error, {:request_failed, inspect(reason)}}

        {:mcp_cancel_request, request_id, reason} ->
          if same_request_id?(request_id, id) do
            _ = cancel_fun.(reason)
            Task.shutdown(task, :brutal_kill)
            {:error, :cancelled}
          else
            wait_request_task_with_cancel(nil, id, task, deadline, cancel_fun)
          end
      after
        50 -> wait_request_task_with_cancel(nil, id, task, deadline, cancel_fun)
      end
    end
  end

  defp same_request_id?(left, right),
    do: comparable_request_id(left) == comparable_request_id(right)

  defp comparable_request_id(value) when is_binary(value), do: value
  defp comparable_request_id(value) when is_integer(value), do: Integer.to_string(value)
  defp comparable_request_id(value) when is_atom(value), do: Atom.to_string(value)
  defp comparable_request_id(value), do: inspect(value)

  defp request_id("tools/call", opts, fallback) do
    case nonempty(opts[:tool_call_id]) do
      "" -> fallback
      id -> id
    end
  end

  defp request_id(_method, _opts, fallback), do: fallback

  defp request_params("tools/call", params, opts) when is_map(params) do
    case nonempty(opts[:tool_call_id]) do
      "" ->
        params

      token ->
        meta =
          params
          |> Map.get("_meta", %{})
          |> Map.put("progressToken", token)

        Map.put(params, "_meta", meta)
    end
  end

  defp request_params(_method, params, _opts), do: params || %{}

  defp cancel_params(id, reason) do
    %{"requestId" => id}
    |> put_optional_nonblank("reason", reason)
  end

  defp send_cancel_notification(state, id, reason) do
    do_notify(state, "notifications/cancelled", cancel_params(id, reason))
  end

  defp receive_cancel(id, state) do
    receive do
      {:mcp_cancel_request, request_id, reason} ->
        if same_request_id?(request_id, id) do
          _ = send_cancel_notification(state, id, reason)
          {:cancelled, state}
        else
          :none
        end
    after
      0 -> :none
    end
  end

  defp maybe_emit_progress(line, opts) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, message} -> maybe_emit_progress(message, opts)
      _ -> :ok
    end
  end

  defp maybe_emit_progress(%{"method" => "notifications/progress", "params" => params}, opts)
       when is_map(params) do
    tool_call_id = nonempty(opts[:tool_call_id])

    if tool_call_id != "" and progress_token(params) == tool_call_id do
      agent_id = nonempty(opts[:agent_id])
      session_id = nonempty(opts[:session_id])

      if agent_id != "" and session_id != "" do
        _ =
          SalixAgent.update_async_tool_call_progress(
            agent_id,
            session_id,
            tool_call_id,
            progress_payload(params),
            timeout: 1_000
          )
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_emit_progress(_message, _opts), do: :ok

  defp maybe_emit_progress_in_buffer(data, opts) when is_binary(data) do
    case RemoteClient.sse_json_messages(data) do
      [] ->
        data
        |> String.split("\n", trim: true)
        |> Enum.map(&strip_sse_data_prefix/1)
        |> Enum.each(&maybe_emit_progress(&1, opts))

      messages ->
        Enum.each(messages, &maybe_emit_progress(&1, opts))
    end
  end

  defp maybe_emit_progress_in_buffer(_data, _opts), do: :ok

  defp strip_sse_data_prefix(line) do
    if String.starts_with?(line, "data:") do
      String.trim_leading(String.replace_prefix(line, "data:", ""))
    else
      line
    end
  end

  defp progress_token(params),
    do: nonempty(params["progressToken"] || params["progress_token"])

  defp progress_payload(params) do
    params
    |> Map.take(["progressToken", "progress_token", "progress", "total", "message"])
    |> Map.put("received_at", System.system_time(:millisecond))
  end

  defp do_notify(%{mode: :remote} = state, method, params) do
    with {:ok, config} <- request_config(state) do
      case RemoteClient.notify(config, method, params, state.remote_headers) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_notify(%{mode: :sse} = state, method, params) do
    case ensure_sse_endpoint(state, System.monotonic_time(:millisecond) + @request_timeout) do
      {:ok, state} ->
        with {:ok, config} <- request_config(state) do
          case RemoteClient.sse_post(
                 config,
                 state.sse_endpoint,
                 JSONRPC.notification(method, params),
                 @request_timeout
               ) do
            :ok -> {:ok, state}
            {:error, reason} -> {:error, reason, state}
          end
        else
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp do_notify(%{mode: :server} = state, method, params) do
    Port.command(state.port, Jason.encode!(JSONRPC.notification(method, params)) <> "\n")
    {:ok, state}
  rescue
    e -> {:error, Exception.message(e), %{state | port: nil, initialized?: false}}
  end

  defp do_notify(%{mode: :device} = state, method, params) do
    case device_write(state, Jason.encode!(JSONRPC.notification(method, params)) <> "\n") do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_notify(%{mode: :device_remote} = state, method, params) do
    with {:ok, config} <- request_config(state) do
      case device_http_jsonrpc(
             state,
             config,
             JSONRPC.notification(method, params),
             @request_timeout
           ) do
        {:ok, _response, _headers} -> {:ok, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_sse_endpoint(%{sse_endpoint: endpoint} = state, _deadline)
       when is_binary(endpoint) and endpoint != "",
       do: {:ok, state}

  defp ensure_sse_endpoint(%{sse_task: nil} = state, _deadline),
    do: {:error, :disconnected, state}

  defp ensure_sse_endpoint(state, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout, state}
    else
      receive do
        {:mcp_sse_endpoint, pid, endpoint} when pid == state.sse_task ->
          {:ok, %{state | sse_endpoint: endpoint}}

        {:mcp_sse_response, pid, response} when pid == state.sse_task ->
          state =
            state
            |> Map.put(:buffer, append_json_line(state.buffer, response))
            |> maybe_mark_discovery_changed(discovery_changed_notification?(response))

          ensure_sse_endpoint(state, deadline)

        {:mcp_sse_error, pid, reason} when pid == state.sse_task ->
          {:error, reason, %{state | sse_task: nil, sse_endpoint: nil, initialized?: false}}

        {:mcp_sse_closed, pid} when pid == state.sse_task ->
          {:error, :disconnected,
           %{state | sse_task: nil, sse_endpoint: nil, initialized?: false}}
      after
        50 -> ensure_sse_endpoint(state, deadline)
      end
    end
  end

  defp wait_sse_response(state, id, deadline, opts) do
    case pop_response(state.buffer, id) do
      {:ok, response, buffer, list_changed?} ->
        state = maybe_mark_discovery_changed(%{state | buffer: buffer}, list_changed?)

        with {:ok, result} <- JSONRPC.response_result(response) do
          {:ok, result, state}
        else
          {:error, reason} -> {:error, reason, state}
        end

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout, state}
        else
          receive do
            {:mcp_sse_response, pid, response} when pid == state.sse_task ->
              maybe_emit_progress(response, opts)

              state =
                state
                |> Map.put(:buffer, append_json_line(state.buffer, response))
                |> maybe_mark_discovery_changed(discovery_changed_notification?(response))

              wait_sse_response(state, id, deadline, opts)

            {:mcp_sse_endpoint, pid, endpoint} when pid == state.sse_task ->
              wait_sse_response(%{state | sse_endpoint: endpoint}, id, deadline, opts)

            {:mcp_sse_error, pid, reason} when pid == state.sse_task ->
              {:error, reason, %{state | sse_task: nil, sse_endpoint: nil, initialized?: false}}

            {:mcp_sse_closed, pid} when pid == state.sse_task ->
              {:error, :disconnected,
               %{state | sse_task: nil, sse_endpoint: nil, initialized?: false}}

            {:mcp_cancel_request, request_id, reason} ->
              if same_request_id?(request_id, id) do
                _ = send_cancel_notification(state, id, reason)
                {:error, :cancelled, state}
              else
                wait_sse_response(state, id, deadline, opts)
              end
          after
            50 -> wait_sse_response(state, id, deadline, opts)
          end
        end
    end
  end

  defp device_http_jsonrpc(state, config, payload, timeout, opts \\ []) do
    headers =
      config
      |> Map.get("headers", %{})
      |> Map.merge(state.remote_headers)
      |> Map.put_new("accept", "application/json, text/event-stream")
      |> Map.put_new("content-type", "application/json")
      |> Map.put_new("mcp-protocol-version", "2025-06-18")

    params = %{
      "method" => "POST",
      "url" => config["url"],
      "headers" => headers,
      "body" => Jason.encode!(payload),
      "timeout_seconds" => max(div(timeout, 1000), 1),
      "max_bytes" => 10_485_760
    }

    expect_response? = Map.has_key?(payload, "id")

    case ConnectorLive.request(state.device["connector_run_id"], "http_request", params,
           timeout: timeout + 5_000
         ) do
      {:ok, %{"status" => status, "body" => body, "headers" => response_headers}}
      when status in 200..299 ->
        if expect_response? do
          maybe_emit_progress_in_buffer(body, opts)

          with {:ok, response} <- RemoteClient.decode_response(body, payload["id"]) do
            {:ok, response, response_headers || %{}}
          end
        else
          {:ok, %{"result" => %{}}, response_headers || %{}}
        end

      {:ok, %{"status" => status, "body" => body, "headers" => response_headers}} ->
        {:error, {:http_error, status, response_headers || %{}, body || ""}}

      {:ok, %{"status" => status}} ->
        {:error, {:http_error, status, %{}, ""}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_stdio_response(state, id, deadline, opts) do
    case pop_response(state.buffer, id) do
      {:ok, response, buffer, list_changed?} ->
        state = maybe_mark_discovery_changed(state, list_changed?)

        with {:ok, result} <- JSONRPC.response_result(response) do
          {:ok, result, %{state | buffer: buffer}}
        else
          {:error, reason} -> {:error, reason, %{state | buffer: buffer}}
        end

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout, state}
        else
          receive do
            {port, {:data, {:eol, line}}} when port == state.port ->
              maybe_emit_progress(line, opts)

              state =
                state
                |> Map.update!(:buffer, &(&1 <> line <> "\n"))
                |> maybe_mark_discovery_changed(discovery_changed_notification?(line))

              wait_stdio_response(state, id, deadline, opts)

            {port, {:exit_status, status}} when port == state.port ->
              {:error, "MCP process exited #{status}", %{state | port: nil, initialized?: false}}

            {:mcp_cancel_request, request_id, reason} ->
              if same_request_id?(request_id, id) do
                _ = send_cancel_notification(state, id, reason)
                {:error, :cancelled, state}
              else
                wait_stdio_response(state, id, deadline, opts)
              end
          after
            50 -> wait_stdio_response(state, id, deadline, opts)
          end
        end
    end
  end

  defp wait_device_response(state, id, deadline, opts) do
    case device_tail(state, 2) do
      {:ok, data, next_offset, state} ->
        maybe_emit_progress_in_buffer(data, opts)
        buffer = state.buffer <> data

        state =
          maybe_mark_discovery_changed(state, discovery_changed_notification_in_buffer?(data))

        case pop_response(buffer, id) do
          {:ok, response, buffer, list_changed?} ->
            state = maybe_mark_discovery_changed(state, list_changed?)

            with {:ok, result} <- JSONRPC.response_result(response) do
              {:ok, result, %{state | buffer: buffer, device_offset: next_offset}}
            else
              {:error, reason} ->
                {:error, reason, %{state | buffer: buffer, device_offset: next_offset}}
            end

          :pending ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:error, device_timeout_reason(state),
               %{state | buffer: buffer, device_offset: next_offset}}
            else
              state = %{state | buffer: buffer, device_offset: next_offset}

              case receive_cancel(id, state) do
                {:cancelled, state} -> {:error, :cancelled, state}
                :none -> wait_device_response(state, id, deadline, opts)
              end
            end
        end

      {:error, reason} ->
        {:error, reason, clear_device_if_stale(state, reason)}
    end
  end

  defp pop_response(buffer, id) do
    {matches, rest} =
      buffer
      |> String.split("\n", trim: false)
      |> Enum.split_with(fn line ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^id}} -> true
          {:ok, %{"id" => id_text}} -> same_request_id?(id_text, id)
          _ -> false
        end
      end)

    case matches do
      [line | _] ->
        {rest, list_changed?} = consume_list_changed_notifications(rest)
        {:ok, Jason.decode!(line), Enum.join(rest, "\n"), list_changed?}

      [] ->
        :pending
    end
  end

  defp append_json_line(buffer, message) when is_map(message) do
    buffer <> Jason.encode!(message) <> "\n"
  end

  defp consume_list_changed_notifications(lines) do
    Enum.reduce(lines, {[], false}, fn line, {kept, changed?} ->
      case Jason.decode(line) do
        {:ok, %{"method" => method}}
        when method in [
               "notifications/tools/list_changed",
               "notifications/resources/list_changed",
               "notifications/prompts/list_changed"
             ] ->
          {kept, true}

        {:ok, %{"method" => "notifications/progress"}} ->
          {kept, changed?}

        _ ->
          {[line | kept], changed?}
      end
    end)
    |> then(fn {kept, changed?} -> {Enum.reverse(kept), changed?} end)
  end

  defp discovery_changed_notification?(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, message} -> discovery_changed_notification?(message)
      _ -> false
    end
  end

  defp discovery_changed_notification?(%{"method" => method})
       when method in [
              "notifications/tools/list_changed",
              "notifications/resources/list_changed",
              "notifications/prompts/list_changed"
            ],
       do: true

  defp discovery_changed_notification?(_message), do: false

  defp discovery_changed_notification_in_buffer?(data) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.any?(&discovery_changed_notification?/1)
  end

  defp maybe_mark_discovery_changed(state, false), do: state

  defp maybe_mark_discovery_changed(%{binding: binding} = state, true) do
    _ =
      SalixMCP.Store.update_connection(
        binding["tenant_id"],
        binding["group_id"],
        binding["binding_id"],
        fn conn ->
          conn
          |> Map.put("status", "degraded")
          |> Map.put("last_error", %{"reason" => "MCP discovery changed; refresh discovery"})
          |> Map.put(
            "discovery_revision",
            "changed:" <> Integer.to_string(System.system_time(:millisecond))
          )
        end
      )

    state
  end

  defp device_write(state, data) do
    ConnectorLive.request(state.device["connector_run_id"], "process_write", %{
      "process_name" => process_name(state.binding),
      "data" => data,
      "append_newline" => false
    })
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp device_tail(state, wait_seconds) do
    case ConnectorLive.request(state.device["connector_run_id"], "process_tail", %{
           "process_name" => process_name(state.binding),
           "from_offset" => state.device_offset,
           "max_bytes" => 1_048_576,
           "wait_seconds" => wait_seconds
         }) do
      {:ok, result} ->
        {:ok, result["data"] || "", result["next_offset"] || state.device_offset, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp device_timeout_reason(state) do
    case device_stderr_tail(state) do
      "" -> :timeout
      stderr -> {:protocol_error, "timeout waiting for MCP response; stderr tail: " <> stderr}
    end
  end

  defp device_stderr_tail(%{device: %{"connector_run_id" => run_id}, binding: binding}) do
    case ConnectorLive.request(run_id, "process_tail", %{
           "process_name" => process_name(binding),
           "stream" => "stderr",
           "from_offset" => 0,
           "tail_bytes" => 4_096,
           "max_bytes" => 4_096,
           "wait_seconds" => 0
         }) do
      {:ok, %{"data" => data}} when is_binary(data) -> String.trim(data)
      _ -> ""
    end
  end

  defp device_stderr_tail(_state), do: ""

  defp ensure_current_device(%{mode: :device, device: current} = state) do
    with {:ok, device} <- resolve_device(state.binding) do
      if same_connector_run?(current, device) do
        {:ok, state}
      else
        stop_device_process_on_device(state, current)

        start_device_process_on_device(
          %{state | device: nil, initialized?: false, buffer: "", device_offset: 0},
          device
        )
      end
    else
      {:error, reason} -> {:error, reason, clear_device_if_stale(state, reason)}
    end
  end

  defp ensure_current_device(%{mode: :device_remote, device: current} = state) do
    with {:ok, device} <- resolve_device(state.binding) do
      if same_connector_run?(current, device) do
        {:ok, state}
      else
        {:ok, %{state | device: device, initialized?: false, remote_headers: %{}}}
      end
    else
      {:error, reason} -> {:error, reason, clear_device_if_stale(state, reason)}
    end
  end

  defp ensure_current_device(state), do: {:ok, state}

  defp stop_device_process_on_device(%{binding: binding}, %{"connector_run_id" => run_id})
       when is_binary(run_id) and run_id != "" do
    _ =
      ConnectorLive.request(run_id, "process_stop", %{
        "process_name" => process_name(binding)
      })

    :ok
  end

  defp stop_device_process_on_device(_state, _device), do: :ok

  defp resolve_device(binding) do
    case SalixEnv.Control.resolve_device_runtime_binding(
           binding["device_runtime_id"],
           binding["tenant_id"],
           binding["group_id"]
         ) do
      {:error, {:bad_request, "device_runtime_id not found" = reason}} ->
        {:error, {:device_runtime_not_found, reason}}

      {:error, {:bad_request, "device_runtime_id is not connected" = reason}} ->
        {:error, {:device_runtime_unavailable, reason}}

      result ->
        result
    end
  end

  defp same_connector_run?(%{"connector_run_id" => run_id}, %{"connector_run_id" => run_id})
       when is_binary(run_id) and run_id != "",
       do: true

  defp same_connector_run?(_current, _device), do: false

  defp clear_device_if_stale(state, reason) do
    if stale_device_error?(reason) do
      %{state | device: nil, initialized?: false}
    else
      state
    end
  end

  defp stale_device_error?(:disconnected), do: true
  defp stale_device_error?({:request_failed, :disconnected}), do: true
  defp stale_device_error?({:request_failed, "disconnected"}), do: true
  defp stale_device_error?(_reason), do: false

  defp device_stop(%{device: %{"connector_run_id" => run_id}, binding: binding}) do
    ConnectorLive.request(run_id, "process_stop", %{"process_name" => process_name(binding)})
  end

  defp device_stop(_state), do: :ok

  defp initialize_params do
    %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"roots" => %{"listChanged" => true}},
      "clientInfo" => %{"name" => "salix", "version" => "0.1.0"}
    }
  end

  defp initialize_info(result) when is_map(result) do
    %{
      "protocol_version" => result["protocolVersion"] || result["protocol_version"],
      "capabilities" => result["capabilities"] || %{},
      "server_info" => result["serverInfo"] || result["server_info"] || %{}
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp initialize_info(_result), do: %{"capabilities" => %{}, "server_info" => %{}}

  defp process_name(binding), do: "salix-mcp-" <> to_string(binding["binding_id"])

  defp env_list(env) do
    desired =
      env
      |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Map.new()

    unset_parent_env =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(desired, &1))
      |> Enum.map(fn key -> {to_charlist(key), false} end)

    set_desired_env =
      Enum.map(desired, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    unset_parent_env ++ set_desired_env
  end

  defp via(binding), do: {:via, Registry, {SalixMCP.ConnectionRegistry, key(binding)}}
  defp key(binding), do: {binding["group_id"], binding["binding_id"]}

  defp nonempty(nil), do: ""
  defp nonempty(value) when is_binary(value), do: String.trim(value)
  defp nonempty(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp nonempty(value), do: value |> to_string() |> String.trim()

  defp put_optional_nonblank(map, _key, value) when value in [nil, ""], do: map
  defp put_optional_nonblank(map, key, value), do: Map.put(map, key, value)
end
