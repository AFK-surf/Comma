defmodule Salix.RemoteShellTLSTest.Socket do
  @behaviour WebSock
  def init(state), do: {:ok, state}
  def handle_in(_, state), do: {:ok, state}
  def handle_info(_, state), do: {:ok, state}
end

defmodule Salix.RemoteShellTLSTest.Edge do
  def init(opts), do: opts

  def call(conn, owner) do
    send(owner, {:tls_authenticated, Plug.Conn.get_req_header(conn, "authorization")})
    WebSockAdapter.upgrade(conn, Salix.RemoteShellTLSTest.Socket, %{}, [])
  end
end

defmodule Salix.RemoteShellTLSTest do
  use ExUnit.Case, async: false

  test "real WSS trusts the CA but rejects wrong hostnames and untrusted roots" do
    Application.ensure_all_started(:websockex)
    Application.ensure_all_started(:bandit)

    dir =
      Path.join(
        System.tmp_dir!(),
        "comma-shell-tls-#{Base.encode16(:crypto.strong_rand_bytes(9))}"
      )

    File.mkdir_p!(dir)

    # The OTP CA cache is global, so this test must not run asynchronously.
    on_exit(fn ->
      :public_key.cacerts_load()
      File.rm_rf!(dir)
    end)

    openssl = fn args ->
      {output, status} = System.cmd("openssl", args, cd: dir, stderr_to_stdout: true)
      assert status == 0, output
    end

    openssl.([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=Comma Test CA",
      "-keyout",
      "ca.key",
      "-out",
      "ca.pem"
    ])

    openssl.([
      "req",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      "/CN=localhost",
      "-keyout",
      "server.key",
      "-out",
      "server.csr"
    ])

    File.write!(
      Path.join(dir, "extensions"),
      "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n"
    )

    openssl.([
      "x509",
      "-req",
      "-in",
      "server.csr",
      "-CA",
      "ca.pem",
      "-CAkey",
      "ca.key",
      "-CAcreateserial",
      "-days",
      "1",
      "-extfile",
      "extensions",
      "-out",
      "server.pem"
    ])

    server =
      start_supervised!(
        {Bandit,
         plug: {Salix.RemoteShellTLSTest.Edge, self()},
         scheme: :https,
         port: 0,
         ip: {127, 0, 0, 1},
         certfile: Path.join(dir, "server.pem"),
         keyfile: Path.join(dir, "server.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(socket) end)

    handle = %Salix.Drive.Handle{
      group_id: "tls-group",
      base_url: "https://localhost:#{port}",
      org_slug: "org",
      network: "default",
      space: "comma-drive",
      token: "test-only-token"
    }

    device = %{key: String.duplicate("b", 52), controller: String.duplicate("y", 52)}

    assert :ok = :public_key.cacerts_load(Path.join(dir, "ca.pem"))

    assert {:error, :gateway_unavailable} =
             Salix.RemoteShell.Gateway.open(
               %{handle | base_url: "https://127.0.0.1:#{port}"},
               device,
               socket
             )

    refute_received {:tls_authenticated, _}

    assert {:ok, gateway} = Salix.RemoteShell.Gateway.open(handle, device, socket)
    assert_receive {:tls_authenticated, ["Bearer test-only-token"]}
    monitor = Process.monitor(gateway)
    Process.exit(gateway, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^gateway, _}

    assert :ok = :public_key.cacerts_load()
    {:ok, untrusted_socket} = :gen_tcp.listen(0, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(untrusted_socket) end)

    assert {:error, :gateway_unavailable} =
             Salix.RemoteShell.Gateway.open(handle, device, untrusted_socket)

    refute_received {:tls_authenticated, _}
  end
end
