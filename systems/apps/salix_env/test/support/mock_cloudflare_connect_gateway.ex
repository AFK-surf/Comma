defmodule SalixEnv.VM.Providers.Cloudflare.MockConnectGateway do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def base_url(pid), do: GenServer.call(pid, :base_url)
  def frames(pid), do: GenServer.call(pid, :frames)

  def wait_for_frame(pid, fun, timeout_ms \\ 2_000) when is_function(fun, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_frame_until(pid, fun, deadline)
  end

  @impl true
  def init(opts) do
    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {__MODULE__.Plug,
           %{
             pid: self(),
             hold_commands: Keyword.get(opts, :hold_commands, [])
           }},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, %{port: port, frames: [], drop_heartbeats: Keyword.get(opts, :drop_heartbeats, 0)}}
  end

  @impl true
  def handle_call(:base_url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}

  def handle_call(:frames, _from, state), do: {:reply, Enum.reverse(state.frames), state}

  def handle_call({:record_frame, sandbox_id, frame}, _from, state) do
    {:reply, :ok, %{state | frames: [%{sandbox_id: sandbox_id, frame: frame} | state.frames]}}
  end

  def handle_call({:record_http, op, sandbox_id}, _from, state) do
    {:reply, :ok,
     %{state | frames: [%{sandbox_id: sandbox_id, frame: %{"http_op" => op}} | state.frames]}}
  end

  def handle_call({:record_http, op, sandbox_id, attrs}, _from, state) do
    frame = Map.put(attrs, "http_op", op)
    {:reply, :ok, %{state | frames: [%{sandbox_id: sandbox_id, frame: frame} | state.frames]}}
  end

  def handle_call(:drop_heartbeat?, _from, %{drop_heartbeats: remaining} = state)
      when remaining > 0 do
    {:reply, true, %{state | drop_heartbeats: remaining - 1}}
  end

  def handle_call(:drop_heartbeat?, _from, state), do: {:reply, false, state}

  defp wait_for_frame_until(pid, fun, deadline) do
    case Enum.find(frames(pid), fn %{frame: frame} -> fun.(frame) end) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          wait_for_frame_until(pid, fun, deadline)
        end

      frame ->
        {:ok, frame}
    end
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", path_info: ["internal", "v1", "sandboxes"]} = conn, opts) do
      pid = Map.fetch!(opts, :pid)
      {:ok, raw, conn} = read_body(conn)
      sandbox_id = Jason.decode!(raw)["sandbox_id"]
      :ok = GenServer.call(pid, {:record_http, "ensure", sandbox_id})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"ok" => true, "sandbox_id" => sandbox_id, "status" => "ready"})
      )
    end

    def call(
          %{
            method: "GET",
            path_info: ["internal", "v1", "sandboxes", sandbox_id, "proxy", "readyz"]
          } = conn,
          opts
        ) do
      pid = Map.fetch!(opts, :pid)
      :ok = GenServer.call(pid, {:record_http, "readyz", sandbox_id})
      send_resp(conn, 200, "ok")
    end

    def call(
          %{method: "POST", path_info: ["internal", "v1", "sandboxes", sandbox_id, "destroy"]} =
            conn,
          opts
        ) do
      pid = Map.fetch!(opts, :pid)
      {:ok, _raw, conn} = read_body(conn)
      :ok = GenServer.call(pid, {:record_http, "destroy", sandbox_id})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"ok" => true, "sandbox_id" => sandbox_id}))
    end

    def call(
          %{method: "GET", path_info: ["internal", "v1", "sandboxes", sandbox_id, "connect"]} =
            conn,
          opts
        ) do
      pid = Map.fetch!(opts, :pid)

      :ok =
        GenServer.call(pid, {
          :record_http,
          "connect",
          sandbox_id,
          %{"nonce" => get_req_header(conn, "x-salix-nonce") |> List.first()}
        })

      upgrade_adapter(
        conn,
        :websocket,
        {SalixEnv.VM.Providers.Cloudflare.MockConnectGateway.WS,
         [
           pid: pid,
           sandbox_id: sandbox_id,
           hold_commands: Map.get(opts, :hold_commands, [])
         ], []}
      )
    end

    def call(conn, _opts) do
      send_resp(conn, 404, "not found")
    end
  end

  defmodule WS do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(opts) do
      pid = Keyword.fetch!(opts, :pid)
      sandbox_id = Keyword.fetch!(opts, :sandbox_id)
      hold_commands = Keyword.get(opts, :hold_commands, [])

      metadata =
        Jason.encode!(%{
          "type" => "metadata",
          "capabilities" => %{"exec" => true},
          "skills" => ["shell"],
          "agent_runtimes" => [%{"id" => "shell"}],
          "system_info" => %{"boot_id" => "boot-test", "connector_version" => "test"}
        })

      {:push, {:text, metadata},
       %{
         pid: pid,
         sandbox_id: sandbox_id,
         hold_commands: hold_commands
       }}
    end

    @impl true
    def handle_in({frame, [opcode: :text]}, state) do
      message = Jason.decode!(frame)
      :ok = safe_record(state.pid, {:record_frame, state.sandbox_id, message})

      case message do
        %{"type" => "heartbeat"} ->
          if drop_heartbeat?(state.pid) do
            {:ok, state}
          else
            {:push, {:text, Jason.encode!(%{"type" => "heartbeat"})}, state}
          end

        %{"type" => "request", "id" => id, "method" => "exec", "params" => params} ->
          if params["command"] in state.hold_commands do
            {:ok, state}
          else
            reply =
              Jason.encode!(%{
                "type" => "response",
                "id" => id,
                "result" => %{
                  "stdout" => if(params["command"] == "true", do: "", else: "ok"),
                  "stderr" => "",
                  "exit_code" => 0
                }
              })

            {:push, {:text, reply}, state}
          end

        _ ->
          {:ok, state}
      end
    end

    def handle_in(_frame, state), do: {:ok, state}

    defp safe_record(pid, message) do
      GenServer.call(pid, message)
    catch
      :exit, _ -> :ok
    end

    defp drop_heartbeat?(pid) do
      GenServer.call(pid, :drop_heartbeat?)
    catch
      :exit, _ -> false
    end

    @impl true
    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
