defmodule SalixWeb.MockCloudflareGateway do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def base_url(pid), do: GenServer.call(pid, :base_url)
  def calls(pid), do: GenServer.call(pid, :calls)
  def set_import(pid, sandbox, value), do: GenServer.call(pid, {:set_import, sandbox, value})
  def set_connect_delay(pid, delay_ms), do: GenServer.call(pid, {:set_connect_delay, delay_ms})
  def set_profiles(pid, enabled?), do: GenServer.call(pid, {:set_profiles, enabled?})

  def set_terminal(pid, sandbox, control, terminal),
    do: GenServer.call(pid, {:set_terminal, sandbox, control, terminal})

  def lose_next_control_open_response(pid),
    do: GenServer.call(pid, :lose_next_control_open_response)

  def lose_next_ensure_response(pid), do: GenServer.call(pid, :lose_next_ensure_response)

  def lose_next_import_finish_response(pid),
    do: GenServer.call(pid, :lose_next_import_finish_response)

  def set_export(pid, sandbox, operation, data, sessions \\ 0),
    do: GenServer.call(pid, {:set_export, sandbox, operation, data, sessions})

  def wait_for_call(pid, op, timeout_ms \\ 2_000), do: wait_until(pid, &(&1.op == op), timeout_ms)

  @impl true
  def init(opts) do
    {:ok, bandit} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, self()},
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
       controls: %{},
       lose_import_finish_response: false,
       lose_ensure_response: false,
       lose_control_open_response: false,
       exports: %{},
       export_formats: %{},
       export_scopes: %{},
       never_admitted: Keyword.get(opts, :never_admitted, false),
       runtime_url: Keyword.get(opts, :runtime_url),
       managed_runtime: Keyword.get(opts, :managed_runtime, false),
       connect_delay_ms: 0,
       # A pre-profile Worker answers 404 for every `/internal/v1/profiles/` path.
       profiles: Keyword.get(opts, :profiles, true),
       fail_ops: MapSet.new(Keyword.get(opts, :fail_ops, []))
     }}
  end

  @impl true
  def handle_call(:base_url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}

  def handle_call(:runtime_url, _from, state), do: {:reply, state.runtime_url, state}
  def handle_call(:managed_runtime?, _from, state), do: {:reply, state.managed_runtime, state}
  def handle_call(:never_admitted?, _from, state), do: {:reply, state.never_admitted, state}
  def handle_call(:connect_delay_ms, _from, state), do: {:reply, state.connect_delay_ms, state}

  def handle_call(:profiles?, _from, state), do: {:reply, state.profiles, state}

  def handle_call({:set_profiles, enabled?}, _from, state),
    do: {:reply, :ok, %{state | profiles: enabled?}}

  def handle_call({:set_connect_delay, delay_ms}, _from, state),
    do: {:reply, :ok, %{state | connect_delay_ms: delay_ms}}

  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:control, sandbox, nil}, _from, state) do
    control = state.controls[sandbox]
    settled = is_map(control) and control["sealed"] == true and is_nil(control["pending"])
    {:reply, %{"control" => control, "managed_commands_settled" => settled}, state}
  end

  def handle_call({:set_terminal, sandbox, control, terminal}, _from, state) do
    value = control |> Map.put("last_terminal", terminal) |> Map.put("pending", nil)
    {:reply, :ok, %{state | controls: Map.put(state.controls, sandbox, value)}}
  end

  def handle_call({:control, sandbox, body}, _from, state) do
    control =
      body["control"]
      |> Map.delete("claim_id")
      |> Map.put("sealed", body["action"] == "seal")
      |> Map.put("pending", nil)

    {:reply, %{"control" => control, "managed_commands_settled" => control["sealed"]},
     %{state | controls: Map.put(state.controls, sandbox, control)}}
  end

  def handle_call(:lose_next_control_open_response, _from, state),
    do: {:reply, :ok, %{state | lose_control_open_response: true}}

  def handle_call(:consume_control_open_response, _from, state),
    do: {:reply, state.lose_control_open_response, %{state | lose_control_open_response: false}}

  def handle_call(:lose_next_ensure_response, _from, state),
    do: {:reply, :ok, %{state | lose_ensure_response: true}}

  def handle_call(:consume_ensure_response, _from, state),
    do: {:reply, state.lose_ensure_response, %{state | lose_ensure_response: false}}

  def handle_call(:lose_next_import_finish_response, _from, state),
    do: {:reply, :ok, %{state | lose_import_finish_response: true}}

  def handle_call(:consume_import_finish_response, _from, state),
    do: {:reply, state.lose_import_finish_response, %{state | lose_import_finish_response: false}}

  def handle_call({:set_import, sandbox, value}, _from, state),
    do: {:reply, :ok, %{state | imports: Map.put(state.imports, sandbox, value)}}

  def handle_call({:clear_import, sandbox}, _from, state),
    do: {:reply, :ok, %{state | imports: Map.delete(state.imports, sandbox)}}

  def handle_call({:set_export, sandbox, operation, data, sessions}, _from, state),
    do:
      {:reply, :ok,
       %{state | exports: Map.put(state.exports, {sandbox, operation}, {data, sessions})}}

  def handle_call({:set_export_format, sandbox, operation, format}, _from, state),
    do:
      {:reply, :ok,
       %{state | export_formats: Map.put(state.export_formats, {sandbox, operation}, format)}}

  def handle_call({:set_export_scope, sandbox, operation, scope}, _from, state),
    do:
      {:reply, :ok,
       %{state | export_scopes: Map.put(state.export_scopes, {sandbox, operation}, scope)}}

  def handle_call({:export, sandbox, operation, offset}, _from, state) do
    case state.exports[{sandbox, operation}] do
      :cancelled ->
        {:reply, %{"operation" => operation, "phase" => "cancelled"}, state}

      {data, sessions} ->
        result = %{
          "operation" => operation,
          "phase" => "exported",
          "bytes" => byte_size(data),
          "sessions" => sessions,
          "scope" => Map.get(state.export_scopes, {sandbox, operation}, "full"),
          "format" => Map.get(state.export_formats, {sandbox, operation}, "tar_gz")
        }

        result =
          if is_integer(offset) do
            Map.merge(result, %{
              "offset" => offset,
              "data" =>
                data
                |> binary_part(offset, min(4 * 1024 * 1024, byte_size(data) - offset))
                |> Base.encode64()
            })
          else
            result
          end

        {:reply, result, state}

      nil ->
        {:reply, %{"phase" => "failed"}, state}
    end
  end

  def handle_call({:cancel_export, sandbox, operation}, _from, state) do
    {:reply, %{"operation" => operation, "phase" => "cancelled"},
     %{state | exports: Map.put(state.exports, {sandbox, operation}, :cancelled)}}
  end

  def handle_call({:record, call}, _from, state),
    do: {:reply, :ok, %{state | calls: [call | state.calls]}}

  def handle_call({:fail?, op}, _from, state),
    do: {:reply, MapSet.member?(state.fail_ops, op), state}

  def handle_call({:import, sandbox, body}, _from, state) do
    current =
      Map.get(state.imports, sandbox, %{
        "phase" => "",
        "next_offset" => 0,
        "missing_native_count" => 0
      })

    next =
      case body["action"] do
        "part" ->
          Map.merge(current, %{
            "phase" => "receiving",
            "next_offset" => body["offset"] + byte_size(Base.decode64!(body["data"]))
          })

        "finish" ->
          current
          |> Map.put("phase", "restored")
          |> Map.put("bytes", body["bytes"])
          |> Map.put("sessions", body["sessions"])
          |> Map.put("missing_native_count", if(body["sessions"] > 0, do: 1, else: 0))

        "stream" ->
          current
          |> Map.put("phase", "restored")
          |> Map.put("bytes", body["bytes"])
          |> Map.put("sessions", body["sessions"])
          |> Map.put("next_offset", body["bytes"])

        "status" ->
          current
      end

    {:reply, next, %{state | imports: Map.put(state.imports, sandbox, next)}}
  end

  defp wait_until(pid, fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(pid, fun, deadline)
  end

  defp do_wait_until(pid, fun, deadline) do
    case Enum.find(calls(pid), fun) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          do_wait_until(pid, fun, deadline)
        end

      call ->
        {:ok, call}
    end
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
        json(conn, GenServer.call(pid, {:control, sandbox, body}))
      end
    end

    def call(
          %{
            method: "GET",
            path_info: ["internal", "v1", "sandboxes", sandbox, "status"]
          } = conn,
          pid
        ) do
      record(pid, :status, sandbox)
      json(conn, %{"status" => "ready"})
    end

    def call(
          %{
            method: "GET",
            path_info: ["internal", "v1", "sandboxes", sandbox, "receipt"]
          } = conn,
          pid
        ) do
      conn = fetch_query_params(conn)

      json(
        conn,
        GenServer.call(
          pid,
          {:import, sandbox,
           %{"action" => "status", "operation" => conn.query_params["operation"]}}
        )
      )
    end

    def call(
          %{
            method: "POST",
            path_info: ["internal", "v1", "sandboxes", _sandbox, "proxy", "control"]
          } = conn,
          pid
        ) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)

      if not GenServer.call(pid, :managed_runtime?),
        do: send_resp(conn, 404, "Connector control unsupported"),
        else:
          json(conn, %{
            "control" => Map.put(body["control"], "sealed", body["action"] == "seal"),
            "quiet" => body["action"] == "seal",
            "never_admitted" => GenServer.call(pid, :never_admitted?)
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
      sandbox_id = Jason.decode!(raw)["sandbox_id"]
      record(pid, :ensure, sandbox_id, headers(conn))

      if fail?(pid, :ensure) or GenServer.call(pid, :consume_ensure_response) do
        send_resp(conn, 500, "ensure failed")
      else
        json(
          conn,
          versioned(%{"ok" => true, "sandbox_id" => sandbox_id, "status" => "ready"}, conn)
        )
      end
    end

    def call(
          %{
            method: method,
            path_info: ["internal", "v1", "sandboxes", sandbox_id, "proxy", "archive", "export"]
          } = conn,
          pid
        )
        when method in ["GET", "POST", "PUT", "DELETE"] do
      conn = fetch_query_params(conn)
      operation = conn.query_params["operation"]

      offset =
        if conn.query_params["offset"],
          do: String.to_integer(conn.query_params["offset"]),
          else: nil

      signed = method == "PUT"

      record(pid, :archive_export, sandbox_id, %{
        "method" => method,
        "operation" => operation,
        "offset" => offset,
        "format" => conn.query_params["format"],
        "signed" => signed
      })

      if method == "POST",
        do:
          GenServer.call(
            pid,
            {:set_export_scope, sandbox_id, operation, conn.query_params["scope"] || "full"}
          )

      conn =
        if method == "POST" and conn.query_params["format"] == "tar_zst" do
          {:ok, raw, conn} = read_body(conn)
          %{"transfers" => transfers} = Jason.decode!(raw)
          true = length(transfers) == 1024
          :ok = GenServer.call(pid, {:set_export_format, sandbox_id, operation, "tar_zst"})

          :ok =
            GenServer.call(
              pid,
              {:set_export_scope, sandbox_id, operation, conn.query_params["scope"] || "full"}
            )

          conn
        else
          conn
        end

      if signed && fail?(pid, :archive_direct) do
        send_resp(conn, 405, "method not allowed")
      else
        result =
          cond do
            method == "DELETE" ->
              GenServer.call(pid, {:cancel_export, sandbox_id, operation})

            signed ->
              {:ok, raw, _conn} = read_body(conn)
              %{"put_url" => put_url, "get_url" => get_url} = Jason.decode!(raw)
              true = URI.parse(put_url).host == URI.parse(get_url).host
              %{"data" => encoded} = GenServer.call(pid, {:export, sandbox_id, operation, offset})

              %{
                "operation" => operation,
                "next_offset" => offset + byte_size(Base.decode64!(encoded))
              }

            true ->
              GenServer.call(pid, {:export, sandbox_id, operation, offset})
          end

        json(conn, result)
      end
    end

    def call(
          %{
            method: "GET",
            path_info: ["internal", "v1", "sandboxes", sandbox_id, "proxy", "readyz"]
          } = conn,
          pid
        ) do
      record(pid, :readyz, sandbox_id)

      if fail?(pid, :readyz) do
        send_resp(conn, 503, "starting")
      else
        send_resp(conn, 200, "ok")
      end
    end

    def call(
          %{
            method: "GET",
            path_info: ["internal", "v1", "sandboxes", sandbox_id, "proxy", "archive"]
          } = conn,
          pid
        ) do
      record(pid, :archive, sandbox_id)

      if fail?(pid, :archive_get) do
        send_resp(conn, 500, "archive unavailable")
      else
        send_resp(conn, 200, "archive:#{sandbox_id}")
      end
    end

    def call(
          %{
            method: "PUT",
            path_info: ["internal", "v1", "sandboxes", sandbox_id, "proxy", "archive"]
          } = conn,
          pid
        ) do
      {:ok, raw, conn} = read_body(conn)
      record(pid, :archive_restore, sandbox_id, %{"bytes" => byte_size(raw)})

      if fail?(pid, :archive_put) do
        send_resp(conn, 500, "restore failed")
      else
        json(conn, %{"ok" => true, "restored" => true})
      end
    end

    def call(
          %{
            method: "POST",
            path_info: ["internal", "v1", "sandboxes", sandbox_id, "proxy", "archive"]
          } = conn,
          pid
        ) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)
      record(pid, :migration_import, sandbox_id, body)
      result = GenServer.call(pid, {:import, sandbox_id, body})

      if body["action"] == "finish" and GenServer.call(pid, :consume_import_finish_response) do
        send_resp(conn, 503, "response lost")
      else
        json(conn, result)
      end
    end

    def call(
          %{method: "GET", path_info: ["internal", "v1", "sandboxes", sandbox_id, "connect"]} =
            conn,
          pid
        ) do
      record(pid, :connect, sandbox_id, headers(conn))
      Process.sleep(GenServer.call(pid, :connect_delay_ms))

      upgrade_adapter(
        conn,
        :websocket,
        {SalixWeb.MockCloudflareGateway.WS,
         [pid: pid, sandbox_id: sandbox_id, runtime_url: GenServer.call(pid, :runtime_url)], []}
      )
    end

    def call(
          %{method: "POST", path_info: ["internal", "v1", "sandboxes", sandbox_id, op]} = conn,
          pid
        )
        when op in ["checkpoint", "restore", "destroy", "keepalive"] do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      op_atom = String.to_existing_atom(op)
      record(pid, op_atom, sandbox_id, body)

      if fail?(pid, op_atom) do
        send_resp(conn, 500, "#{op} failed")
      else
        if op == "destroy", do: GenServer.call(pid, {:clear_import, sandbox_id})

        json(
          conn,
          versioned(
            %{
              "ok" => true,
              "sandbox_id" => sandbox_id,
              "archive" => %{"id" => "archive-#{sandbox_id}"},
              "restore" => %{"restored" => true},
              "keep_alive" => body["keep_alive"]
            },
            conn
          )
        )
      end
    end

    def call(conn, _pid), do: send_resp(conn, 404, "not found")

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

  defmodule WS do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init([{:runtime_proxy, url}]) do
      {:ok, upstream} = SalixWeb.MockCloudflareGateway.Upstream.start_link(url, self())
      {:ok, %{upstream: upstream}}
    end

    def init(opts) do
      pid = Keyword.fetch!(opts, :pid)
      sandbox_id = Keyword.fetch!(opts, :sandbox_id)

      if url = opts[:runtime_url] do
        init(runtime_proxy: url)
      else
        metadata = Jason.encode!(%{"type" => "metadata", "capabilities" => %{"exec" => true}})
        {:push, {:text, metadata}, %{pid: pid, sandbox_id: sandbox_id}}
      end
    end

    @impl true
    def handle_in(frame, %{upstream: upstream} = state) do
      {data, [opcode: opcode]} = frame
      :ok = WebSockex.send_frame(upstream, {opcode, data})
      {:ok, state}
    end

    def handle_in({frame, [opcode: :text]}, state) do
      message = Jason.decode!(frame)
      safe_record(state.pid, %{op: :frame, sandbox_id: state.sandbox_id, body: message})

      case message do
        %{"type" => "request", "id" => id, "method" => method}
        when method in ["cloud_runtime_quiesce", "cloud_runtime_resume", "cloud_runtime_release"] ->
          response =
            cond do
              method == "cloud_runtime_quiesce" and
                  GenServer.call(state.pid, {:fail?, :runtime_quiesce_unconfirmed}) ->
                %{"type" => "error", "id" => id, "error" => "timeout"}

              method in ["cloud_runtime_quiesce", "cloud_runtime_resume"] and
                  GenServer.call(state.pid, {:fail?, :runtime_not_quiet}) ->
                %{
                  "type" => "response",
                  "id" => id,
                  "result" => %{"quiet" => false, "resumed" => false}
                }

              true ->
                result = %{"quiet" => true, "resumed" => true, "released" => true}

                result =
                  if method == "cloud_runtime_quiesce" and
                       GenServer.call(state.pid, :managed_runtime?),
                     do: Map.put(result, "continued", true),
                     else: result

                %{
                  "type" => "response",
                  "id" => id,
                  "result" => result
                }
            end

          {:push, {:text, Jason.encode!(response)}, state}

        %{"type" => "request", "id" => id, "method" => "exec"} ->
          reply =
            Jason.encode!(%{
              "type" => "response",
              "id" => id,
              "result" => %{"stdout" => "", "stderr" => "", "exit_code" => 0}
            })

          {:push, {:text, reply}, state}

        _ ->
          {:ok, state}
      end
    end

    def handle_in(_frame, state), do: {:ok, state}

    defp safe_record(pid, call) do
      GenServer.call(pid, {:record, call})
    catch
      :exit, _ -> :ok
    end

    @impl true
    def handle_info({:upstream_frame, frame}, state), do: {:push, frame, state}

    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, %{upstream: upstream}) do
      GenServer.stop(upstream, :normal)
    catch
      :exit, _ -> :ok
    end

    def terminate(_reason, _state), do: :ok
  end

  defmodule Upstream do
    use WebSockex

    def start_link(url, parent),
      do:
        WebSockex.start_link(
          String.replace_prefix(url, "http", "ws") <> "/connect",
          __MODULE__,
          parent
        )

    def handle_frame(frame, parent) do
      send(parent, {:upstream_frame, frame})
      {:ok, parent}
    end
  end
end
