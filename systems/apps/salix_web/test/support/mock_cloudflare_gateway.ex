defmodule SalixWeb.MockCloudflareGateway do
  require SystemsRuntime.Proc

  @moduledoc false
  # The Cloud VM Gateway and its Containers, for tests. Ensuring a Sandbox
  # starts its Container as the image does: a start that names an archive
  # unpacks it onto the disk first (its chunks read from the S3 store under
  # the keys of their signed URLs) and exits with 65, starting no station,
  # when it cannot; then the station (`Station`) starts, connects out to Salix
  # with the server and credential it was given, says hello with the Tasks
  # its disk holds, and answers what Salix asks it: lifecycle, exec, Tasks
  # and the archive export. A Container's disk (its restore receipt, its
  # Tasks, its exports) lives as long as the Container. The Gateway keeps how
  # a Container last stopped.

  use GenServer

  @chunk_size 4 * 1024 * 1024

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def base_url(pid), do: GenServer.call(pid, :base_url)
  def calls(pid), do: GenServer.call(pid, :calls)
  @doc "The restore receipt on the Sandbox's disk, as its Container's start left it."
  def set_import(pid, sandbox, value), do: GenServer.call(pid, {:set_import, sandbox, value})

  @doc """
  The image Containers start from now on: `:current`, or `:before_restore`,
  one from before the restore moved into the start, which starts its station
  on the empty disk whatever the start names.
  """
  def set_image(pid, image) when image in [:current, :before_restore],
    do: GenServer.call(pid, {:set_image, image})

  @doc "How far the Sandbox's station has each Task, on its disk."
  def tasks(pid, sandbox), do: GenServer.call(pid, {:tasks, sandbox})
  def set_connect_delay(pid, delay_ms), do: GenServer.call(pid, {:set_connect_delay, delay_ms})
  def set_profiles(pid, enabled?), do: GenServer.call(pid, {:set_profiles, enabled?})

  @doc "What the Gateway holds for the Sandbox: its control record and whether its Container runs."
  def control(pid, sandbox), do: GenServer.call(pid, {:control, sandbox, nil})

  def set_terminal(pid, sandbox, control, terminal),
    do: GenServer.call(pid, {:set_terminal, sandbox, control, terminal})

  def lose_next_control_open_response(pid),
    do: GenServer.call(pid, :lose_next_control_open_response)

  def lose_next_ensure_response(pid), do: GenServer.call(pid, :lose_next_ensure_response)

  def set_export(pid, sandbox, operation, data, sessions \\ 0),
    do: GenServer.call(pid, {:set_export, sandbox, operation, data, sessions})

  @doc "The Sandbox's station, if its Container runs."
  def station(pid, sandbox), do: GenServer.call(pid, {:station, sandbox})

  @doc """
  Silences every running Container's station, which stays running without a
  connection: a test then connects its own fake as the VM's device.
  """
  def detach_stations do
    case SystemsRuntime.Proc.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :detach_stations)
    end
  end

  @doc "Where stations connect from now on, whatever server Salix gave them (another node, in multi-node tests)."
  def set_station_server(pid, url), do: GenServer.call(pid, {:set_station_server, url})

  @doc "The Sandbox's station loses its connection and connects again (after the connect delay)."
  def restart_station(pid, sandbox) do
    SystemsRuntime.Proc.send(pid, {:restart_station, sandbox})
    :ok
  end

  @doc "The Sandbox's station asks Salix something (a `share.*` request): Salix's answer."
  def station_asks(pid, sandbox, method, params) do
    case GenServer.call(pid, {:station, sandbox}) do
      {station, _} when SystemsRuntime.Proc.is_process(station) ->
        __MODULE__.Station.ask(station, method, params)

      _ ->
        {:error, :not_connected}
    end
  end

  @doc "Makes the named operations fail from now on; `[]` lets every operation succeed again."
  def fail_ops(pid, ops), do: GenServer.call(pid, {:fail_ops, MapSet.new(ops)})

  @doc """
  Stops the Sandbox's Container (its station's connection ends). `error:` is
  the stop's message as the runtime gives it, in place of the exit-code one.
  """
  def stop_container(pid, sandbox, opts \\ []),
    do: GenServer.call(pid, {:stop_container, sandbox, false, opts[:error]})

  @doc """
  R2 as Salix reaches it in tests (`config :salix_web, :cloud_vm_archive_r2_req,
  plug: &#{inspect(__MODULE__)}.r2/1`): the object each signed URL names, in the
  S3 store the stations' parts are in.
  """
  def r2(conn) do
    key = store_key(Elixir.Plug.Conn.request_url(conn))

    case conn.method do
      "PUT" ->
        {:ok, body, conn} = Elixir.Plug.Conn.read_body(conn, length: 8_000_000)
        {:ok, _} = SalixStore.S3.put(key, body)
        Elixir.Plug.Conn.send_resp(conn, 200, "")

      method when method in ["GET", "HEAD"] ->
        case SalixStore.S3.get(key) do
          {:ok, %{body: body}} ->
            conn
            |> Elixir.Plug.Conn.put_resp_header("content-length", "#{byte_size(body)}")
            |> Elixir.Plug.Conn.send_resp(200, if(method == "HEAD", do: "", else: body))

          _ ->
            Elixir.Plug.Conn.send_resp(conn, 404, "")
        end
    end
  end

  @doc "The Ed25519 key (hex) the station of `sandbox` answers `station_identity` with."
  def station_key(sandbox), do: :crypto.hash(:sha256, sandbox) |> Base.encode16(case: :lower)

  @impl true
  def init(opts) do
    SystemsRuntime.Proc.trap_exit(true)

    {:ok, bandit} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, SystemsRuntime.Proc.self()},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    {:ok,
     %{
       port: port,
       calls: [],
       imports: %{},
       tasks: %{},
       stops: %{},
       uncommanded_stops: %{},
       image: :current,
       controls: %{},
       stations: %{},
       parked: %{},
       lose_ensure_response: false,
       lose_control_open_response: false,
       exports: %{},
       connect_delay_ms: 0,
       station_server: nil,
       # A pre-profile Worker answers 404 for every `/internal/v1/profiles/` path.
       profiles: Keyword.get(opts, :profiles, true),
       fail_ops: MapSet.new(Keyword.get(opts, :fail_ops, []))
     }}
  end

  @impl true
  def handle_call(:base_url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}
  def handle_call(:profiles?, _from, state), do: {:reply, state.profiles, state}

  def handle_call({:set_profiles, enabled?}, _from, state),
    do: {:reply, :ok, %{state | profiles: enabled?}}

  def handle_call({:set_station_server, url}, _from, state),
    do: {:reply, :ok, %{state | station_server: url}}

  def handle_call({:set_connect_delay, delay_ms}, _from, state),
    do: {:reply, :ok, %{state | connect_delay_ms: delay_ms}}

  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:control, sandbox, nil}, _from, state) do
    control = state.controls[sandbox]
    settled = is_map(control) and control["sealed"] == true and is_nil(control["pending"])

    {:reply,
     %{
       "control" => control,
       "managed_commands_settled" => settled,
       "running" => Map.has_key?(state.stations, sandbox),
       "last_stop" => state.stops[sandbox],
       "last_uncommanded_stop" => state.uncommanded_stops[sandbox]
     }, state}
  end

  def handle_call({:set_image, image}, _from, state), do: {:reply, :ok, %{state | image: image}}

  def handle_call({:connected, sandbox}, _from, state) do
    tasks =
      for {task, fetched} <- Map.get(state.tasks, sandbox, %{}),
          do: %{"task" => task, "fetched" => fetched}

    {:reply, tasks, record_call(state, :connect, sandbox, %{"tasks" => tasks})}
  end

  def handle_call({:tasks, sandbox}, _from, state),
    do: {:reply, Map.get(state.tasks, sandbox, %{}), state}

  def handle_call({:set_terminal, sandbox, control, terminal}, _from, state) do
    value = control |> Map.put("last_terminal", terminal) |> Map.put("pending", nil)
    {:reply, :ok, %{state | controls: Map.put(state.controls, sandbox, value)}}
  end

  def handle_call({:control, sandbox, %{"action" => action, "control" => permit}}, _from, state) do
    current = state.controls[sandbox]

    result =
      case action do
        "open" -> open_control(current, permit)
        "seal" -> seal_control(current, permit)
      end

    case result do
      {:ok, control} ->
        settled = control["sealed"] == true and is_nil(control["pending"])

        {:reply, {:ok, %{"control" => control, "managed_commands_settled" => settled}},
         %{state | controls: Map.put(state.controls, sandbox, control)}}

      {:error, _code} = error ->
        {:reply, error, record_call(state, :control_refused, sandbox, %{"action" => action})}
    end
  end

  # A command on the Container carrier: admitted only under the current
  # permit, and its completion is the control's last terminal. A client
  # without an owner (no Group) sends no permit; the Gateway would refuse
  # it, and this mock lets it through.
  def handle_call({:admit, _sandbox, nil, _action}, _from, state), do: {:reply, :ok, state}

  def handle_call({:admit, sandbox, permit, action}, _from, state) do
    case admit_command(state.controls[sandbox], permit, action) do
      {:ok, control} ->
        {:reply, :ok, %{state | controls: Map.put(state.controls, sandbox, control)}}

      {:error, _code} = error ->
        {:reply, error, record_call(state, :control_refused, sandbox, %{"action" => action})}
    end
  end

  def handle_call(:lose_next_control_open_response, _from, state),
    do: {:reply, :ok, %{state | lose_control_open_response: true}}

  def handle_call(:consume_control_open_response, _from, state),
    do: {:reply, state.lose_control_open_response, %{state | lose_control_open_response: false}}

  def handle_call(:lose_next_ensure_response, _from, state),
    do: {:reply, :ok, %{state | lose_ensure_response: true}}

  def handle_call(:consume_ensure_response, _from, state),
    do: {:reply, state.lose_ensure_response, %{state | lose_ensure_response: false}}

  def handle_call({:set_import, sandbox, value}, _from, state),
    do: {:reply, :ok, %{state | imports: Map.put(state.imports, sandbox, value)}}

  def handle_call({:set_export, sandbox, operation, data, sessions}, _from, state),
    do:
      {:reply, :ok,
       %{state | exports: Map.put(state.exports, {sandbox, operation}, {data, sessions})}}

  def handle_call({:record, call}, _from, state),
    do: {:reply, :ok, %{state | calls: [call | state.calls]}}

  def handle_call({:fail?, op}, _from, state),
    do: {:reply, MapSet.member?(state.fail_ops, op), state}

  def handle_call({:fail_ops, ops}, _from, state), do: {:reply, :ok, %{state | fail_ops: ops}}

  def handle_call({:station, sandbox}, _from, state),
    do: {:reply, state.stations[sandbox], state}

  def handle_call({:running?, sandbox}, _from, state),
    do: {:reply, Map.has_key?(state.stations, sandbox), state}

  def handle_call({:start_container, sandbox, station}, _from, state) do
    if Map.has_key?(state.stations, sandbox) do
      {:reply, :running, state}
    else
      {:reply, :started, start_container(state, sandbox, station)}
    end
  end

  def handle_call(:detach_stations, _from, state) do
    stations =
      Map.new(state.stations, fn {sandbox, {pid, station}} ->
        if SystemsRuntime.Proc.is_process(pid) do
          SystemsRuntime.Proc.unlink(pid)
          SystemsRuntime.Proc.exit(pid, :kill)
        end

        {sandbox, {nil, station}}
      end)

    {:reply, :ok, %{state | stations: stations}}
  end

  # The Container stops by itself (`stop_container/3`), or by the destroy
  # Salix commanded.
  def handle_call({:stop_container, sandbox, requested, error}, _from, state) do
    stopped =
      if Map.has_key?(state.stations, sandbox) do
        stop = stopped(state, sandbox, 137, requested)
        if error, do: Map.put(stop, "error", error), else: stop
      end

    state = state |> stop_station(sandbox) |> lose_disk(sandbox)

    {:reply, :ok, if(stopped, do: put_stop(state, sandbox, stopped), else: state)}
  end

  def handle_call({:station_request, sandbox, method, params}, _from, state) do
    state = record_call(state, :frame, sandbox, %{"method" => method, "params" => params})
    {reply, state} = station_request(state, sandbox, method, params)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:restart_station, sandbox}, state) do
    case state.stations[sandbox] do
      {_pid, station} -> {:noreply, start_station(stop_station(state, sandbox), sandbox, station)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:stops_by_itself, sandbox}, state) do
    stop = stopped(state, sandbox, 0, false)
    {:noreply, state |> stop_station(sandbox) |> lose_disk(sandbox) |> put_stop(sandbox, stop)}
  end

  def handle_info({:connect_station, sandbox, station}, state) do
    case state.stations[sandbox] do
      {:starting, ^station} -> {:noreply, connect_station(state, sandbox, station)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    stations =
      state.stations
      |> Enum.reject(fn {_sandbox, {station, _}} -> station == pid end)
      |> Map.new()

    {:noreply, %{state | stations: stations}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The Container starts as its image does (`entrypoint.sh`): the archive the
  # start names goes onto the disk before the station starts, and a Container
  # that cannot restore it exits with 65 and starts none. An image from
  # before that starts its station on the empty disk.
  defp start_container(%{image: :before_restore} = state, sandbox, station),
    do: start_station(state, sandbox, station)

  defp start_container(state, sandbox, %{"restore" => restore} = station) do
    case restore_disk(state, sandbox, restore) do
      {:ok, state} ->
        start_station(state, sandbox, station)

      {:error, state} ->
        put_stop(state, sandbox, stopped(state, sandbox, 65, false))
    end
  end

  defp start_container(state, sandbox, station), do: start_station(state, sandbox, station)

  # What the image's restore does with the start's instruction (base64 of
  # the JSON `operation`, `bytes`, `manifest_url`): the manifest read from
  # the store, then every part it lists read whole; then the disk is that
  # archive and holds its receipt.
  defp restore_disk(state, sandbox, restore) do
    with false <- fail?(state, :archive_restore),
         {:ok, json} <- Base.decode64(restore),
         {:ok, %{"operation" => operation, "bytes" => bytes, "manifest_url" => manifest_url}} <-
           Jason.decode(json),
         {:ok, %{body: manifest}} <- SalixStore.S3.get(store_key(manifest_url)),
         {:ok, %{"operation" => ^operation, "bytes" => ^bytes, "parts" => [_ | _] = parts}} <-
           Jason.decode(manifest),
         {:ok, data} <- download(parts),
         true <- byte_size(data) == bytes do
      state =
        record_call(state, :archive_restore, sandbox, %{
          "operation" => operation,
          "bytes" => bytes,
          "parts" => length(parts)
        })

      # What the image's restore puts on the disk and how long each of its
      # steps took (ms from its start), as the station's receipt says.
      receipt = %{
        "operation" => operation,
        "phase" => "restored",
        "bytes" => bytes,
        "entries" => 2,
        "files" => 1,
        "timings" => %{
          "manifest_ms" => 40,
          "first_byte_ms" => 90,
          "downloaded_ms" => 700,
          "written_ms" => 2500,
          "synced_ms" => 2600,
          "total_ms" => 2610
        }
      }

      {:ok,
       %{
         state
         | imports: Map.put(state.imports, sandbox, receipt),
           tasks: Map.put(state.tasks, sandbox, disk_tasks(data))
       }}
    else
      _ -> {:error, record_call(state, :archive_restore_failed, sandbox, %{})}
    end
  end

  defp download(parts) do
    Enum.reduce_while(parts, {:ok, <<>>}, fn %{"get_url" => url, "bytes" => bytes}, {:ok, data} ->
      case SalixStore.S3.get(store_key(url)) do
        {:ok, %{body: chunk}} when byte_size(chunk) == bytes -> {:cont, {:ok, data <> chunk}}
        _ -> {:halt, :error}
      end
    end)
  end

  # A station's own export carries how far it has each Task; another archive
  # (a test's bytes) carries none.
  defp disk_tasks(data) do
    case Jason.decode(data) do
      {:ok, %{"tasks" => %{} = tasks}} -> tasks
      _ -> %{}
    end
  end

  # The Gateway keeps how a Container last stopped and, apart from it, the
  # last stop nobody commanded.
  defp put_stop(state, sandbox, %{"requested" => true} = stop),
    do: %{state | stops: Map.put(state.stops, sandbox, stop)}

  defp put_stop(state, sandbox, stop) do
    %{
      state
      | stops: Map.put(state.stops, sandbox, stop),
        uncommanded_stops: Map.put(state.uncommanded_stops, sandbox, stop)
    }
  end

  defp stopped(state, sandbox, exit_code, requested) do
    %{
      "at" => SystemsClock.system_time(:millisecond),
      "exit_code" => exit_code,
      "error" => "Container exited with unexpected exit code: #{exit_code}",
      "requested" => requested,
      "operation_id" => get_in(state.controls, [sandbox, "operation_id"]),
      "started_at" => SystemsClock.system_time(:millisecond),
      "seen_by" => "monitor"
    }
  end

  # As on Cloudflare, a Container's disk lives as long as the Container: a
  # stopped one starts again empty, without its restore receipt, its Tasks
  # or its export state.
  defp lose_disk(state, sandbox) do
    exports =
      state.exports |> Enum.reject(fn {{owner, _op}, _} -> owner == sandbox end) |> Map.new()

    %{
      state
      | imports: Map.delete(state.imports, sandbox),
        tasks: Map.delete(state.tasks, sandbox),
        exports: exports
    }
  end

  # A Container's station connects once it has started: after the test's
  # connect delay, on the test clock.
  defp start_station(%{connect_delay_ms: 0} = state, sandbox, station),
    do: connect_station(state, sandbox, station)

  defp start_station(state, sandbox, station) do
    SystemsClock.send_after(
      SystemsRuntime.Proc.self(),
      {:connect_station, sandbox, station},
      state.connect_delay_ms
    )

    %{state | stations: Map.put(state.stations, sandbox, {:starting, station})}
  end

  defp connect_station(state, sandbox, station) do
    target =
      if state.station_server, do: %{station | "server" => state.station_server}, else: station

    {:ok, pid} = __MODULE__.Station.start_link(SystemsRuntime.Proc.self(), sandbox, target)

    %{state | stations: Map.put(state.stations, sandbox, {pid, station})}
  end

  defp stop_station(state, sandbox) do
    case state.stations[sandbox] do
      {pid, _station} ->
        if SystemsRuntime.Proc.is_process(pid) do
          SystemsRuntime.Proc.unlink(pid)
          SystemsRuntime.Proc.exit(pid, :kill)
        end

        %{
          state
          | stations: Map.delete(state.stations, sandbox),
            parked: Map.delete(state.parked, sandbox)
        }

      nil ->
        state
    end
  end

  # The Gateway's rules for its Container control record, as
  # `systems/cloudflare/salix-vm-gateway/src/control.ts` enforces them: a new
  # permit opens only a sealed control, and a command runs only under the
  # current permit.
  @permit_keys ~w(owner_id operation_id generation revision)

  defp open_control(nil, permit), do: {:ok, opened(permit, nil)}

  defp open_control(control, permit) do
    cond do
      not control_owner?(control, permit) -> {:error, "stale_control_owner"}
      control_matches?(control, permit) and not control["sealed"] -> {:ok, control}
      control["pending"] -> {:error, "control_command_unsettled"}
      not control["sealed"] -> {:error, "control_seal_required"}
      permit["revision"] <= control["revision"] -> {:error, "stale_control_permit"}
      true -> {:ok, opened(permit, control["last_terminal"])}
    end
  end

  defp opened(permit, last_terminal) do
    permit
    |> Map.take(@permit_keys)
    |> Map.merge(%{"sealed" => false, "pending" => nil, "last_terminal" => last_terminal})
  end

  defp seal_control(nil, _permit), do: {:error, "control_owner_unbound"}

  defp seal_control(control, permit) do
    cond do
      not control_owner?(control, permit) ->
        {:error, "stale_control_owner"}

      permit["revision"] < control["revision"] or
          (permit["revision"] == control["revision"] and not control_matches?(control, permit)) ->
        {:error, "stale_control_permit"}

      true ->
        {:ok, control |> Map.merge(Map.take(permit, @permit_keys)) |> Map.put("sealed", true)}
    end
  end

  defp admit_command(nil, _permit, _action), do: {:error, "control_owner_unbound"}

  defp admit_command(control, permit, action) do
    cond do
      not control_owner?(control, permit) ->
        {:error, "stale_control_owner"}

      not control_matches?(control, permit) ->
        {:error, "stale_control_permit"}

      action == "ensure" and control["sealed"] ->
        {:error, "control_sealed"}

      action == "destroy" and not control["sealed"] ->
        {:error, "control_seal_required"}

      control["pending"] ->
        {:error, "control_command_unsettled"}

      get_in(control, ["last_terminal", "claim_id"]) == permit["claim_id"] ->
        {:error, "control_command_completed"}

      true ->
        terminal =
          permit
          |> Map.take(["claim_id" | @permit_keys])
          |> Map.merge(%{"action" => action, "outcome" => "completed"})

        {:ok, Map.put(control, "last_terminal", terminal)}
    end
  end

  defp control_owner?(control, permit),
    do:
      control["owner_id"] == permit["owner_id"] and
        permit["generation"] >= control["generation"]

  defp control_matches?(control, permit),
    do: Map.take(control, @permit_keys) == Map.take(permit, @permit_keys)

  defp fail?(state, op), do: MapSet.member?(state.fail_ops, op)

  defp record_call(state, op, sandbox, body),
    do: %{state | calls: [%{op: op, sandbox_id: sandbox, body: body} | state.calls]}

  defp station_request(state, sandbox, "cloud_runtime_quiesce", params) do
    state = record_call(state, :quiesce, sandbox, params)

    cond do
      fail?(state, :runtime_quiesce_unconfirmed) ->
        {{:error, "timeout"}, state}

      fail?(state, :runtime_not_quiet) ->
        {{:ok, %{"quiet" => false}}, state}

      true ->
        continued = state.parked[sandbox] == params["token"]

        {{:ok, %{"quiet" => true, "continued" => continued}},
         %{state | parked: Map.put(state.parked, sandbox, params["token"])}}
    end
  end

  defp station_request(state, sandbox, "cloud_runtime_resume", params) do
    state = record_call(state, :resume, sandbox, params)

    if fail?(state, :runtime_not_quiet),
      do: {{:ok, %{"resumed" => false}}, state},
      else: {{:ok, %{"resumed" => true}}, %{state | parked: Map.delete(state.parked, sandbox)}}
  end

  defp station_request(state, sandbox, "cloud_runtime_release", params) do
    {{:ok, %{"released" => true}}, record_call(state, :release, sandbox, params)}
  end

  defp station_request(state, sandbox, "station_profiles", params),
    do: {{:ok, %{"received" => true}}, record_call(state, :station_profiles, sandbox, params)}

  # A sandbox's station keeps one key.
  defp station_request(state, sandbox, "station_identity", _params),
    do: {{:ok, %{"station" => station_key(sandbox), "version" => "test"}}, state}

  defp station_request(state, sandbox, "station_place", params),
    do: {{:ok, %{"placed" => true}}, record_call(state, :station_place, sandbox, params)}

  # A Session of the station takes part in the Task: its disk has a thread
  # of it, with nothing given yet.
  defp station_request(state, sandbox, "task.invite", %{"task" => task} = params) do
    tasks = state.tasks |> Map.get(sandbox, %{}) |> Map.put_new(task, 0)

    {{:ok, %{"session" => "s1"}},
     record_call(
       %{state | tasks: Map.put(state.tasks, sandbox, tasks)},
       :task_invite,
       sandbox,
       params
     )}
  end

  # A Task the disk has no thread of is unknown to the station (it lost it).
  defp station_request(state, sandbox, "task.put", %{"task" => task} = params) do
    state = record_call(state, :task_put, sandbox, params)

    case state.tasks[sandbox] do
      %{^task => fetched} = tasks ->
        through = max(fetched, params["through"] || fetched)

        {{:ok, %{"through" => through}},
         %{state | tasks: Map.put(state.tasks, sandbox, Map.put(tasks, task, through))}}

      _ ->
        {{:ok, %{"unknown" => true, "gone" => true}}, state}
    end
  end

  defp station_request(state, _sandbox, "exec", _params),
    do: {{:ok, %{"stdout" => "", "stderr" => "", "exit_code" => 0}}, state}

  defp station_request(state, sandbox, "archive_export", params) do
    operation = params["operation"]

    state =
      record_call(state, :archive_export, sandbox, %{
        "operation" => operation,
        "scope" => params["scope"],
        "transfers" => length(params["transfers"] || [])
      })

    cond do
      fail?(state, :archive_export) ->
        {{:error, "archive export failed"}, state}

      not Map.has_key?(state.parked, sandbox) ->
        {{:error, "managed archive requires quiescence"}, state}

      # The export starts, then fails: its status says so.
      fail?(state, :archive_export_failed) ->
        {{:ok, %{"operation" => operation, "phase" => "preparing"}},
         %{state | exports: Map.put(state.exports, {sandbox, operation}, :failed)}}

      true ->
        # Without a prepared export the station packs its own disk: how far
        # it has each Task.
        export =
          case state.exports[{sandbox, operation}] do
            {_data, _sessions} = export ->
              export

            _ ->
              tasks = Map.get(state.tasks, sandbox, %{})
              {Jason.encode!(%{"disk" => sandbox, "tasks" => tasks}), map_size(tasks)}
          end

        :ok = upload(elem(export, 0), params["transfers"])

        {{:ok, %{"operation" => operation, "phase" => "preparing"}},
         %{state | exports: Map.put(state.exports, {sandbox, operation}, export)}}
    end
  end

  # `:container_stops_at_receipt`: the Container stops by itself once its
  # station connected, before it answers (as Cloudflare stops one to roll out
  # a new image). Once.
  defp station_request(state, sandbox, "archive_status", %{"kind" => "import"} = params) do
    operation = params["operation"]

    cond do
      fail?(state, :container_stops_at_receipt) ->
        SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:stops_by_itself, sandbox})

        {{:error, "container stopping"},
         %{state | fail_ops: MapSet.delete(state.fail_ops, :container_stops_at_receipt)}}

      match?(%{"operation" => ^operation}, state.imports[sandbox]) ->
        {{:ok, state.imports[sandbox]}, state}

      true ->
        {{:error, "archive import unavailable"}, state}
    end
  end

  defp station_request(state, sandbox, "archive_status", %{"operation" => operation}) do
    case state.exports[{sandbox, operation}] do
      :cancelled ->
        {{:ok, %{"operation" => operation, "phase" => "cancelled"}}, state}

      :failed ->
        {{:ok, %{"operation" => operation, "phase" => "failed"}}, state}

      {data, sessions} ->
        {{:ok,
          %{
            "operation" => operation,
            "phase" => "exported",
            "scope" => "full",
            "format" => "tar_zst",
            "bytes" => byte_size(data),
            "uploaded_bytes" => byte_size(data),
            "sessions" => sessions
          }}, state}

      nil ->
        {{:error, "archive export unavailable"}, state}
    end
  end

  defp station_request(state, sandbox, "archive_cancel", %{"operation" => operation}) do
    {{:ok, %{"operation" => operation, "phase" => "cancelled"}},
     %{state | exports: Map.put(state.exports, {sandbox, operation}, :cancelled)}}
  end

  defp station_request(state, _sandbox, method, _params),
    do: {{:error, "unsupported method #{method}"}, state}

  # Each chunk to the store key its signed URL names (`/<bucket>/<key>`).
  defp upload(data, transfers) do
    data
    |> chunks()
    |> Enum.zip(transfers)
    |> Enum.each(fn {chunk, %{"put_url" => url}} ->
      {:ok, _} = SalixStore.S3.put(store_key(url), chunk)
    end)
  end

  defp store_key(url) do
    [_bucket, key] =
      url |> URI.parse() |> Map.fetch!(:path) |> String.split("/", parts: 3) |> tl()

    URI.decode(key)
  end

  defp chunks(<<>>), do: []

  defp chunks(data) when byte_size(data) <= @chunk_size, do: [data]

  defp chunks(<<chunk::binary-size(@chunk_size), rest::binary>>), do: [chunk | chunks(rest)]

  defmodule Station do
    @moduledoc false
    # A Container's station: it connects out to the server it was given, with
    # its Workload's credential, says hello with how far its disk has each
    # Task, and asks the Gateway mock for each answer.
    use WebSockex

    def start_link(mock, sandbox, station) do
      # Tests run without a public URL: the station then reaches this node's endpoint.
      server =
        case station["server"] do
          "" -> SalixWeb.Application.base_url()
          server -> server
        end

      url = String.replace_prefix(server, "http", "ws") <> "/v1/connect?name=Cloud%20VM"

      WebSockex.start_link(url, __MODULE__, %{mock: mock, sandbox: sandbox, asks: %{}},
        async: true,
        handle_initial_conn_failure: true,
        extra_headers: [
          {"authorization", "Bearer " <> station["credential"]},
          {"x-salix-credential-kind", "workload"}
        ]
      )
    end

    def ask(station, method, params) do
      ref = SystemsRuntime.Proc.make_ref()
      SystemsRuntime.Proc.send(station, {:ask, SystemsRuntime.Proc.self(), ref, method, params})

      SystemsRuntime.Proc.receive do
        {^ref, answer} -> answer
      after
        10_000 -> {:error, :timeout}
      end
    end

    @impl true
    def handle_info({:ask, from, ref, method, params}, state) do
      id = "ask-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))
      frame = %{"type" => "request", "id" => id, "method" => method, "params" => params}
      {:reply, {:text, Jason.encode!(frame)}, put_in(state, [:asks, id], {from, ref})}
    end

    def handle_info({:hello, tasks}, state) do
      id = "hello-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

      frame = %{
        "type" => "request",
        "id" => id,
        "method" => "task.hello",
        "params" => %{"tasks" => tasks}
      }

      {:reply, {:text, Jason.encode!(frame)}, state}
    end

    # The station that comes online says hello, with how far its disk has
    # each Task (`systems/station/docs/tasks.md`).
    @impl true
    def handle_connect(_conn, state) do
      tasks = GenServer.call(state.mock, {:connected, state.sandbox})
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:hello, tasks})
      {:ok, state}
    end

    @impl true
    def handle_disconnect(_status, state) do
      SystemsClock.sleep(100)
      {:reconnect, state}
    end

    @impl true
    def handle_frame({:text, raw}, state) do
      case Jason.decode!(raw) do
        %{"type" => "heartbeat"} ->
          {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, state}

        %{"type" => type, "id" => id} = answer when type in ["response", "error"] ->
          case Map.pop(state.asks, id) do
            {{from, ref}, asks} ->
              SystemsRuntime.Proc.send(
                from,
                {ref,
                 if(type == "response",
                   do: {:ok, answer["result"]},
                   else: {:error, answer["error"]}
                 )}
              )

              {:ok, %{state | asks: asks}}

            {nil, _} ->
              {:ok, state}
          end

        %{"type" => "request", "id" => id, "method" => method} = request ->
          reply =
            case GenServer.call(
                   state.mock,
                   {:station_request, state.sandbox, method, request["params"] || %{}}
                 ) do
              {:ok, result} ->
                %{"type" => "response", "id" => id, "result" => result}

              # As the station's connector answers one: the method, then why.
              {:error, error} ->
                %{"type" => "error", "id" => id, "error" => "#{method}: #{error}"}
            end

          {:reply, {:text, Jason.encode!(reply)}, state}

        _ ->
          {:ok, state}
      end
    end

    def handle_frame(_frame, state), do: {:ok, state}
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(pid), do: pid

    @impl true
    def call(%{path_info: ["internal", "v1", "profiles", "cf-standard-1" | rest]} = conn, pid) do
      if GenServer.call(pid, :profiles?) do
        call(%{conn | path_info: ["internal", "v1" | rest]}, pid)
      else
        record(pid, :unsupported_profile, "cf-standard-1")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{
            "ok" => false,
            "error" => %{"code" => "not_found", "message" => "not_found"}
          })
        )
      end
    end

    def call(
          %{method: method, path_info: ["internal", "v1", "sandboxes", sandbox, "control"]} = conn,
          pid
        )
        when method in ["GET", "POST"] do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      if is_map(body) and body["action"] == "open" and
           GenServer.call(pid, :consume_control_open_response) do
        send_resp(conn, 503, "response lost before carrier open")
      else
        case GenServer.call(pid, {:control, sandbox, body}) do
          {:ok, observation} -> json(conn, versioned(observation, conn))
          {:error, code} -> control_error(conn, code)
          observation -> json(conn, versioned(observation, conn))
        end
      end
    end

    def call(
          %{method: "GET", path_info: ["internal", "v1", "sandboxes", sandbox, "status"]} = conn,
          pid
        ) do
      record(pid, :status, sandbox)

      json(conn, %{
        "status" => if(GenServer.call(pid, {:running?, sandbox}), do: "running", else: "stopped")
      })
    end

    def call(%{method: "GET", path_info: ["healthz"]} = conn, pid) do
      record(pid, :healthz, "gateway")

      if fail?(pid, :healthz) do
        send_resp(conn, 503, "unhealthy")
      else
        json(conn, versioned(%{"ok" => true}, conn))
      end
    end

    def call(%{method: "POST", path_info: ["internal", "v1", "sandboxes"]} = conn, pid) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)
      sandbox_id = body["sandbox_id"]
      record(pid, :ensure, sandbox_id, Map.put(headers(conn), "station", body["station"]))

      cond do
        fail?(pid, :ensure) ->
          send_resp(conn, 500, "ensure failed")

        true ->
          case GenServer.call(pid, {:admit, sandbox_id, permit(conn, body), "ensure"}) do
            {:error, code} ->
              control_error(conn, code)

            :ok ->
              started = GenServer.call(pid, {:start_container, sandbox_id, body["station"]})

              if GenServer.call(pid, :consume_ensure_response) do
                send_resp(conn, 500, "ensure response lost")
              else
                json(
                  conn,
                  versioned(
                    %{
                      "ok" => true,
                      "sandbox_id" => sandbox_id,
                      "status" => "started",
                      "running" => started in [:started, :running]
                    },
                    conn
                  )
                )
              end
          end
      end
    end

    def call(
          %{method: "POST", path_info: ["internal", "v1", "sandboxes", sandbox_id, op]} = conn,
          pid
        )
        when op in ["destroy", "keepalive"] do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      op_atom = String.to_existing_atom(op)
      record(pid, op_atom, sandbox_id, body)

      with false <- fail?(pid, op_atom),
           :ok <- GenServer.call(pid, {:admit, sandbox_id, permit(conn, body), op}) do
        if op == "destroy", do: GenServer.call(pid, {:stop_container, sandbox_id, true, nil})

        json(
          conn,
          versioned(
            %{"ok" => true, "sandbox_id" => sandbox_id, "keep_alive" => body["keep_alive"]},
            conn
          )
        )
      else
        true -> send_resp(conn, 500, "#{op} failed")
        {:error, code} -> control_error(conn, code)
      end
    end

    def call(conn, _pid), do: send_resp(conn, 404, "not found")

    # The permit rides in the body or, as Salix sends it, in the query.
    defp permit(conn, body) do
      case body["control"] || fetch_query_params(conn).query_params["salix_control"] do
        nil -> nil
        raw when is_binary(raw) -> Jason.decode!(raw)
        permit -> permit
      end
    end

    defp control_error(conn, code) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        409,
        Jason.encode!(%{"ok" => false, "error" => %{"code" => code, "message" => code}})
      )
    end

    defp record(pid, op, sandbox_id, body \\ %{}),
      do: GenServer.call(pid, {:record, %{op: op, sandbox_id: sandbox_id, body: body}})

    defp fail?(pid, op), do: GenServer.call(pid, {:fail?, op})

    defp headers(conn) do
      %{
        "worker_version_key" =>
          get_req_header(conn, "cloudflare-workers-version-key") |> List.first(),
        "worker_version_overrides" =>
          get_req_header(conn, "cloudflare-workers-version-overrides") |> List.first()
      }
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    defp versioned(body, conn) do
      version = override_version(conn) || "version-1"

      Map.merge(body, %{
        "worker_version_id" => version,
        "worker_version_tag" => "tag-1",
        "gateway_build_id" => "build-1",
        "connector_image_version" => "connector-1"
      })
    end

    defp override_version(nil), do: nil

    defp override_version(conn) do
      conn
      |> get_req_header("cloudflare-workers-version-overrides")
      |> List.first()
      |> case do
        nil ->
          nil

        value ->
          case Regex.run(~r/="([^"]+)"/, value) do
            [_, version] -> version
            _ -> nil
          end
      end
    end
  end
end
