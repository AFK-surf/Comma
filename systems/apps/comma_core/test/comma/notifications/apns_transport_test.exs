defmodule Comma.Notifications.APNs.TransportTest.Endpoint do
  @behaviour Plug

  def init(options), do: options

  def call(conn, {counter, status}) do
    {:ok, body, conn} =
      Plug.Conn.read_body(conn, length: 4_096, read_length: 4_096, read_timeout: 2_000)

    request = %{
      method: conn.method,
      path: conn.request_path,
      protocol: Plug.Conn.get_http_protocol(conn),
      body: Jason.decode!(body),
      headers: Map.new(conn.req_headers)
    }

    Agent.update(counter, fn {count, requests} ->
      {count + 1, Enum.take([request | requests], 2)}
    end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"reason" => "SyntheticResponse"}))
  end
end

defmodule Comma.Notifications.APNs.TransportTest do
  use SystemsClock.Case, async: false

  alias Comma.Notifications.APNs.Transport

  @finch __MODULE__.Finch
  @moduletag capture_log: true
  @moduletag timeout: 15_000
  @payload %{
    "aps" => %{"alert" => %{"title" => "Synthetic local only", "body" => "No Apple dispatch"}}
  }
  @headers [
    {"authorization", "bearer synthetic-local-only"},
    {"apns-topic", "surf.comma.ios.dev"},
    {"apns-push-type", "alert"},
    {"apns-priority", "10"},
    {"apns-expiration", "0"}
  ]

  setup_all do
    # Only transport dependencies: no Comma applications, Repo or Redis starts.
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)

    dir =
      Path.join(
        System.tmp_dir!(),
        "apns-local-tls-" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(12))
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    certificates = certificates!(dir)

    # The first manual clock on a node loads every module of the loaded
    # applications; on a loaded machine that alone outlasts a test's timeout.
    # Pay it here, where no test timeout runs.
    SystemsClock.manual()
    SystemsClock.reset()

    {:ok, certificates}
  end

  # Failing endpoints never register a pool, so the transport waits out its 5s
  # readiness deadline. The deadline runs on a clock these tests drive; the TLS
  # attempt itself is real I/O, and its outcome is the same either way.
  setup ctx do
    if ctx[:drive_clock] do
      SystemsClock.manual(drive: true, scope: ["Elixir.Comma"])
      on_exit(&SystemsClock.reset/0)
    end

    :ok
  end

  test "first cold call sends one POST with the expected JSON and headers over TLS HTTP/2", ctx do
    {origin, counter} = endpoint(ctx)
    pool_options = trusted_pool(ctx)
    cold_finch(pool_options)

    # find_pool never creates a pool. No test-side start, readiness wait,
    # warm-up request, sleep or retry is allowed before this first call.
    assert :error == Finch.find_pool(@finch, Finch.Pool.new(origin))
    assert :ok == bounded_post(origin, pool_options)
    assert {1, [request]} = Agent.get(counter, & &1)
    assert request.method == "POST"
    assert request.path == "/synthetic-notification"
    assert request.protocol == :"HTTP/2"
    assert request.body == @payload
    for {name, value} <- @headers, do: assert(request.headers[name] == value)
  end

  @tag :drive_clock
  test "an untrusted synthetic CA fails closed before any application request", ctx do
    {origin, counter} = endpoint(ctx)
    # Use the exact product pool options and normal system CA store. The local
    # synthetic root is deliberately not trusted by this fresh Finch instance.
    pool_options = Transport.pool_options()
    cold_finch(pool_options)

    assert {:error, :apns_unreachable} == bounded_post(origin, pool_options)
    assert {0, []} == Agent.get(counter, & &1)
  end

  defp cold_finch(pool_options) do
    start_supervised!({Finch, name: @finch, pools: %{default: pool_options}})
  end

  defp trusted_pool(ctx) do
    # Only the low-level test helper gets synthetic trust. APNs profiles have
    # no host, CA, TLS, finch-name or protocol configuration knobs.
    Keyword.update!(Transport.pool_options(), :conn_opts, fn options ->
      Keyword.update!(options, :transport_opts, &Keyword.put(&1, :cacertfile, ctx.ca))
    end)
  end

  defp bounded_post(origin, pool_options) do
    options = [
      url: origin <> "/synthetic-notification",
      json: @payload,
      headers: @headers,
      retry: false,
      redirect: false,
      receive_timeout: 5_000
    ]

    task =
      SystemsRuntime.Task.async(fn -> Transport.post(origin, options, @finch, pool_options) end)

    case SystemsClock.yield(task, 7_000) || SystemsRuntime.Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> flunk("local transport exceeded the regression test's bounded wait")
    end
  end

  defp endpoint(ctx, options \\ []) do
    counter = start_supervised!({Agent, fn -> {0, []} end})
    http1_only = Keyword.get(options, :http1_only, false)

    server =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.Endpoint, {counter, Keyword.get(options, :status, 200)}},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         certfile: ctx.leaf,
         keyfile: ctx.key,
         startup_log: false,
         http_1_options: [enabled: http1_only],
         http_2_options: [enabled: not http1_only],
         http_options: [
           compress: false,
           log_protocol_errors: false,
           log_client_closures: false,
           log_exceptions_with_status_codes: []
         ],
         thousand_island_options: [num_acceptors: 1, read_timeout: 2_000]}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {"https://#{Keyword.get(options, :host, "localhost")}:#{port}", counter}
  end

  defp certificates!(dir) do
    paths =
      Map.new(~w(ca ca_key key csr leaf extensions), fn name ->
        path = Path.join(dir, name <> ".pem")
        File.write!(path, "", [:exclusive])
        File.chmod!(path, 0o600)
        {String.to_atom(name), path}
      end)

    # Public synthetic P-256 credentials only, generated for this suite. No
    # real signing key, APNs token, profile, private/ path or Apple URL is read.
    openssl!([
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-sha256",
      "-days",
      "1",
      "-subj",
      "/CN=Synthetic APNs Transport Test Root",
      "-addext",
      "basicConstraints=critical,CA:TRUE,pathlen:0",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign",
      "-keyout",
      paths.ca_key,
      "-out",
      paths.ca
    ])

    openssl!([
      "req",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-sha256",
      "-subj",
      "/CN=localhost",
      "-keyout",
      paths.key,
      "-out",
      paths.csr
    ])

    File.write!(paths.extensions, """
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature
    extendedKeyUsage=serverAuth
    subjectAltName=DNS:localhost
    subjectKeyIdentifier=hash
    authorityKeyIdentifier=keyid,issuer
    """)

    openssl!([
      "x509",
      "-req",
      "-in",
      paths.csr,
      "-CA",
      paths.ca,
      "-CAkey",
      paths.ca_key,
      "-set_serial",
      "2",
      "-days",
      "1",
      "-sha256",
      "-extfile",
      paths.extensions,
      "-out",
      paths.leaf
    ])

    Map.take(paths, [:ca, :leaf, :key])
  end

  defp openssl!(arguments) do
    # Keep external fixture generation bounded too. Linux: GNU timeout;
    # macOS: gtimeout. Missing tools fail explicitly, never fetch dependencies.
    timeout = System.find_executable("timeout") || System.find_executable("gtimeout")
    assert timeout, "local TLS tests require GNU timeout (or gtimeout) and OpenSSL"

    {_discarded, status} =
      System.cmd(timeout, ["8s", "openssl" | arguments], stderr_to_stdout: true)

    assert status == 0, "synthetic local TLS certificate generation failed"
  end
end
