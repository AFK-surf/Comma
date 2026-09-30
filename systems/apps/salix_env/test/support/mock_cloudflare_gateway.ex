defmodule SalixEnv.VM.Providers.Cloudflare.MockGateway do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def base_url(pid), do: GenServer.call(pid, :base_url)
  def calls(pid), do: GenServer.call(pid, :calls)
  def calls(pid, op), do: Enum.filter(calls(pid), &(&1.op == op))
  def set_error(pid, status, body), do: GenServer.call(pid, {:set_error, status, body})

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
    {:ok, %{port: port, calls: [], error: Keyword.get(opts, :error)}}
  end

  @impl true
  def handle_call(:base_url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:set_error, status, body}, _from, state),
    do: {:reply, :ok, %{state | error: {status, body}}}

  def handle_call({:request, op, sandbox_id, conn, body}, _from, state) do
    call = %{
      op: op,
      sandbox_id: sandbox_id,
      path: "/" <> Enum.join(conn.path_info, "/"),
      method: conn.method,
      signature: header(conn, "x-salix-signature"),
      timestamp: header(conn, "x-salix-timestamp"),
      nonce: header(conn, "x-salix-nonce"),
      request_id: header(conn, "x-salix-request-id"),
      worker_version_key: header(conn, "cloudflare-workers-version-key"),
      worker_version_overrides: header(conn, "cloudflare-workers-version-overrides"),
      body: body
    }

    state = %{state | calls: [call | state.calls]}

    case state.error do
      {status, error_body} ->
        {:reply, {status, error_body}, %{state | error: nil}}

      _ ->
        {:reply, response(op, sandbox_id, body), state}
    end
  end

  defp response(:ensure, sandbox_id, _body),
    do: {200, versioned(%{"ok" => true, "sandbox_id" => sandbox_id, "status" => "ready"})}

  defp response(:status, sandbox_id, _body),
    do: {200, versioned(%{"ok" => true, "sandbox_id" => sandbox_id, "status" => "ready"})}

  defp response(:destroy, sandbox_id, _body),
    do: {200, versioned(%{"ok" => true, "sandbox_id" => sandbox_id})}

  defp response(:checkpoint, sandbox_id, _body),
    do:
      {200, versioned(%{"ok" => true, "sandbox_id" => sandbox_id, "archive" => %{"id" => "a1"}})}

  defp response(:restore, sandbox_id, _body),
    do:
      {200,
       versioned(%{"ok" => true, "sandbox_id" => sandbox_id, "restore" => %{"restored" => true}})}

  defp response(:keepalive, sandbox_id, body),
    do:
      {200,
       versioned(%{"ok" => true, "sandbox_id" => sandbox_id, "keep_alive" => body["keep_alive"]})}

  defp response(:proxy, _sandbox_id, _body), do: {200, %{"ok" => true, "proxied" => true}}
  defp response(:not_found, _sandbox_id, _body), do: {404, %{"error" => "not_found"}}

  defp versioned(body) do
    Map.merge(body, %{
      "worker_version_id" => "version-1",
      "worker_version_tag" => "tag-1",
      "gateway_build_id" => "build-1",
      "connector_image_version" => "connector-1"
    })
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(pid), do: pid

    @impl true
    def call(conn, pid) do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      {op, sandbox_id} = route(conn, body)
      {status, response} = GenServer.call(pid, {:request, op, sandbox_id, conn, body})

      conn =
        if op == :proxy,
          do: put_resp_header(conn, "x-salix-container-response", "1"),
          else: conn

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end

    defp route(%{method: "POST", path_info: ["internal", "v1", "sandboxes"]}, body) do
      {:ensure, body["sandbox_id"]}
    end

    defp route(%{path_info: ["internal", "v1", "profiles", "cf-standard-1" | rest]} = conn, body),
      do: route(%{conn | path_info: ["internal", "v1" | rest]}, body)

    defp route(%{path_info: ["internal", "v1", "sandboxes", sandbox_id, "status"]}, _body),
      do: {:status, sandbox_id}

    defp route(%{path_info: ["internal", "v1", "sandboxes", sandbox_id, "destroy"]}, _body),
      do: {:destroy, sandbox_id}

    defp route(%{path_info: ["internal", "v1", "sandboxes", sandbox_id, "checkpoint"]}, _body),
      do: {:checkpoint, sandbox_id}

    defp route(%{path_info: ["internal", "v1", "sandboxes", sandbox_id, "restore"]}, _body),
      do: {:restore, sandbox_id}

    defp route(%{path_info: ["internal", "v1", "sandboxes", sandbox_id, "keepalive"]}, _body),
      do: {:keepalive, sandbox_id}

    defp route(%{path_info: ["internal", "v1", "sandboxes", sandbox_id, "proxy" | _]}, _body),
      do: {:proxy, sandbox_id}

    defp route(_conn, _body), do: {:not_found, nil}
  end
end
