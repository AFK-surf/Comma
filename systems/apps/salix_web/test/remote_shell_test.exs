defmodule Salix.RemoteShellTest.Gateway do
  require SystemsRuntime.Proc

  @behaviour WebSock
  def init(state) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, state.port, [:binary, active: :once], 5000)

    {:push, {:text, Jason.encode!(%{t: "socketopened", controller: state.controller})},
     Map.put(state, :socket, socket)}
  end

  def handle_in({bytes, [opcode: :binary]}, state) do
    :ok = :gen_tcp.send(state.socket, bytes)
    {:push, {:text, ~s({"t":"credit","n":1})}, state}
  end

  def handle_in({_body, [opcode: :text]}, state) do
    :inet.setopts(state.socket, active: :once)
    {:ok, state}
  end

  def handle_info({:tcp, _, bytes}, state), do: {:push, {:binary, bytes}, state}
  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def terminate(_, state), do: :gen_tcp.close(state.socket)
end

defmodule Salix.RemoteShellTest.Edge do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    if get_req_header(conn, "authorization") != ["Bearer " <> opts.token] do
      send_resp(conn, 403, "")
    else
      cond do
        String.ends_with?(conn.request_path, "/sockets/connect") ->
          conn = fetch_query_params(conn)
          SystemsRuntime.Proc.send(opts.owner, {:opened, conn.params})
          WebSockAdapter.upgrade(conn, Salix.RemoteShellTest.Gateway, opts, timeout: 20_000)

        String.ends_with?(conn.request_path, "/sockets") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{controller: opts.controller}))

        conn.method in ["PUT", "DELETE"] ->
          {:ok, body, conn} = read_body(conn)
          SystemsRuntime.Proc.send(opts.owner, {:mutation, conn.method, conn.request_path, body})
          conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))
      end
    end
  end
end

defmodule Salix.RemoteShellTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  alias Salix.RemoteShell
  @key String.duplicate("y", 52)
  @device String.duplicate("b", 52)
  @moduletag :tmp_dir

  # The clock moves only when a test advances it: no deadline or expiry passes
  # while a test waits. It starts before the first test, outside its time.
  setup_all do
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
  end

  setup %{tmp_dir: dir} do
    Application.ensure_all_started(:ssh)
    Application.ensure_all_started(:websockex)
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:req)

    {_, 0} =
      System.cmd("ssh-keygen", [
        "-t",
        "ed25519",
        "-N",
        "",
        "-f",
        Path.join(dir, "ssh_host_ed25519_key")
      ])

    owner = SystemsRuntime.Proc.self()

    shell = fn _user ->
      SystemsRuntime.Proc.spawn(fn ->
        line = IO.gets("")
        SystemsRuntime.Proc.send(owner, {:shell_input, line})

        cond do
          # Never answers: the client's timeout ends the command.
          to_string(line) =~ Base.encode64("hang") -> receive(do: (:never -> :ok))
          to_string(line) =~ Base.encode64("flood") -> IO.write(String.duplicate("x", 1_048_577))
          true -> IO.puts("fixture command output")
        end
      end)
    end

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        system_dir: String.to_charlist(dir),
        no_auth_needed: true,
        shell: shell
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    token = "synch_" <> String.duplicate("secret", 12)
    opts = %{port: info[:port], controller: @key, owner: owner, token: token}

    {:ok, server} =
      Bandit.start_link(plug: {Salix.RemoteShellTest.Edge, opts}, port: 0, ip: {127, 0, 0, 1})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    handle = %Salix.Drive.Handle{
      group_id: "group-a",
      base_url: "http://127.0.0.1:#{port}",
      org_slug: "org-a",
      network: "default",
      space: "comma-drive",
      token: token
    }

    on_exit(fn ->
      :ssh.stop_daemon(daemon)

      try do
        if SystemsRuntime.Proc.alive?(server), do: GenServer.stop(server)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, handle: handle}
  end

  test "the target launcher preserves consent and automatically registers with cleanup" do
    {output, status} =
      System.cmd("python3", [Path.join(__DIR__, "remote_shell_client_test.py")],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "the target submits once over HTTP and wakes a session-bound registration wait", %{
    handle: original
  } do
    handle = %{
      original
      | group_id: "group-auto-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    }

    {:ok, _} =
      Salix.Control.DriveBindings.put(handle.group_id, %{
        "base_url" => handle.base_url,
        "org_slug" => handle.org_slug,
        "network" => handle.network,
        "api_key" => handle.token
      })

    on_exit(fn -> Salix.Control.DriveBindings.delete(handle.group_id) end)
    listener = start_supervised!({Bandit, plug: SalixWeb.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    base = "http://127.0.0.1:#{port}"
    scope = {"router", "session"}
    assert {:ok, invitation} = RemoteShell.perform(handle, scope, %{"action" => "prepare"})
    url = base <> "/v1/remote-shell/#{handle.group_id}/registrations/#{invitation.request_id}"

    post = fn ticket, body ->
      Req.post!(url, json: body, headers: [{"authorization", "Bearer " <> ticket}], retry: false)
    end

    payload = %{device_key: @device, expires_at: invitation.expires_at}
    assert post.("wrong-ticket", payload).status == 403

    assert post.(invitation.request, %{payload | expires_at: invitation.expires_at + 1}).status ==
             400

    assert post.(invitation.request, Map.put(payload, :spaces, ["arbitrary"])).status == 400

    waiter =
      SystemsRuntime.Task.async(fn ->
        RemoteShell.perform(
          handle,
          scope,
          %{"action" => "register", "request" => invitation.request, "timeout_seconds" => 5},
          fn -> Salix.Control.DriveBindings.handle(handle.group_id) end
        )
      end)

    # The wait has found nothing submitted and waits for the submission.
    SystemsClock.settle(scope: ["Elixir.Salix.RemoteShell"])
    assert SystemsRuntime.Task.yield(waiter, 0) == nil
    assert post.(invitation.request, payload).status == 200
    assert {:ok, result} = SystemsRuntime.Task.await(waiter, :infinity)
    assert is_binary(result.target)
    assert result.expires_at == invitation.expires_at
    assert_received {:mutation, "PUT", _, body}
    assert Jason.decode!(body)["spaces"] == ["temporary-shell-" <> String.slice(@device, 0, 16)]
    assert post.(invitation.request, payload).status == 200
    assert post.(invitation.request, %{payload | device_key: @key}).status == 409

    assert {:ok, cached} =
             RemoteShell.perform(handle, scope, %{
               "action" => "register",
               "request" => invitation.request
             })

    assert cached["target"] == result.target
    assert cached["expires_at"] == result.expires_at

    assert {:error, :expired_or_foreign_registration} =
             RemoteShell.perform(handle, {"router", "another-session"}, %{
               "action" => "register",
               "request" => invitation.request
             })

    assert {:ok, %{revoked: true}} =
             RemoteShell.perform(handle, scope, %{"action" => "revoke", "target" => result.target})

    assert_received {:mutation, "DELETE", _, _}

    assert {:error, :registration_cancelled} =
             RemoteShell.perform(handle, scope, %{
               "action" => "register",
               "request" => invitation.request
             })

    assert {:error, :registration_cancelled} =
             RemoteShell.perform(handle, scope, %{
               "action" => "exec",
               "target" => result.target,
               "command" => "must not run"
             })

    refute_received {:mutation, "PUT", _, _}
    assert Req.get!(base <> "/v1/remote-shell/client.py").status == 200
  end

  test "real HTTP, websocket credits and SSH preserve scoped targets and command completion", %{
    handle: handle
  } do
    scope = {"router-a", "session-a"}
    expires = SystemsClock.system_time(:second) + 120

    assert {:ok, %{target: target}} =
             RemoteShell.perform(handle, scope, %{
               "action" => "register",
               "device_key" => @device,
               "expires_at" => expires
             })

    assert_received {:mutation, "PUT", path, body}
    assert path =~ "/org-a/networks/default/delegations/" <> @device

    assert Jason.decode!(body) == %{
             "spaces" => ["temporary-shell-" <> String.slice(@device, 0, 16)],
             "expires_at" => expires
           }

    assert_received {:opened, %{"origin" => "key:" <> @device, "socket" => "temporary-shell"}}

    for foreign <- [{"router-b", "session-a"}, {"router-a", "session-b"}] do
      assert {:error, :expired_or_foreign_target} =
               RemoteShell.perform(handle, foreign, %{
                 "action" => "exec",
                 "target" => target,
                 "command" => "echo no"
               })
    end

    assert {:error, :expired_or_foreign_target} =
             RemoteShell.perform(%{handle | group_id: "other"}, scope, %{
               "action" => "revoke",
               "target" => target
             })

    assert {:error, :expired_or_foreign_target} =
             RemoteShell.perform(%{handle | token: "rotated-secret"}, scope, %{
               "action" => "revoke",
               "target" => target
             })

    for changed <- [
          %{handle | base_url: handle.base_url <> "/moved"},
          %{handle | org_slug: "other-org"},
          %{handle | network: "different-network"}
        ],
        action <- ["exec", "revoke"] do
      assert {:error, :expired_or_foreign_target} =
               RemoteShell.perform(changed, scope, %{
                 "action" => action,
                 "target" => target,
                 "command" => "echo no"
               })

      refute_received {:mutation, _, _, _}
      refute_received {:opened, _}
    end

    assert {:ok, %{exit_code: 0, output: output}} =
             RemoteShell.perform(handle, scope, %{
               "action" => "exec",
               "target" => target,
               "command" => "printf hello"
             })

    assert output =~ "fixture command output"
    assert_received {:shell_input, line}
    assert to_string(line) =~ Base.encode64("printf hello")

    assert {:ok, %{revoked: true}} =
             RemoteShell.perform(handle, scope, %{"action" => "revoke", "target" => target})

    assert_received {:mutation, "DELETE", _, ""}
  end

  test "host-key changes, expired targets, timeout and output flood fail closed", %{
    handle: handle
  } do
    device = %{key: @device, controller: @key, expires: SystemsClock.system_time(:second) + 120}
    assert {:ok, host} = Salix.RemoteShell.Transport.pin(handle, device, 5000)
    device = Map.put(device, :host_key, host)

    assert {:error, :ssh_authentication_or_connect_failed} =
             Salix.RemoteShell.Transport.run(
               handle,
               %{device | host_key: :changed},
               "echo no",
               5000
             )

    hang =
      SystemsRuntime.Task.async(fn ->
        Salix.RemoteShell.Transport.run(handle, device, "hang", 300)
      end)

    SystemsRuntime.Proc.receive do
      {:shell_input, line} -> assert to_string(line) =~ Base.encode64("hang")
    end

    # The command runs and waits for its 300 ms limit, which passes on the clock.
    SystemsClock.settle(scope: ["Elixir.Salix.RemoteShell"])
    SystemsClock.advance(300)
    assert {:error, :command_timeout_or_disconnect} = SystemsRuntime.Task.await(hang, :infinity)

    assert {:error, :output_limit} =
             Salix.RemoteShell.Transport.run(handle, device, "flood", 5000)

    token =
      Phoenix.Token.sign(
        :crypto.hash(:sha256, handle.token),
        "comma-temporary-shell-v1",
        {handle.group_id, {"router", "session"},
         {handle.base_url, handle.org_slug, handle.network},
         %{device | expires: SystemsClock.system_time(:second) - 1}}
      )

    assert {:error, :expired_or_foreign_target} =
             RemoteShell.perform(handle, {"router", "session"}, %{
               "action" => "exec",
               "target" => token,
               "command" => "echo no"
             })
  end

  test "gateway enforces admission, controller identity and one input credit" do
    state = %{
      socket: nil,
      controller: @key,
      owner: SystemsRuntime.Proc.self(),
      opened: false,
      credit: false,
      ready: false
    }

    assert {:close, _, _} = Salix.RemoteShell.Gateway.handle_frame({:binary, "early"}, state)

    assert {:close, _, _} =
             Salix.RemoteShell.Gateway.handle_frame(
               {:text, Jason.encode!(%{t: "socketopened", controller: @device})},
               state
             )

    assert {:ok, opened} =
             Salix.RemoteShell.Gateway.handle_frame(
               {:text, Jason.encode!(%{t: "socketopened", controller: @key})},
               state
             )

    assert {:reply, {:binary, "chunk"}, waiting} =
             Salix.RemoteShell.Gateway.handle_info({:tcp, nil, "chunk"}, opened)

    assert {:close, _, _} = Salix.RemoteShell.Gateway.handle_info({:tcp, nil, "extra"}, waiting)

    assert {:ok, %{credit: true}} =
             Salix.RemoteShell.Gateway.handle_frame({:text, ~s({"t":"credit","n":1})}, waiting)

    assert {:close, _, _} =
             Salix.RemoteShell.Gateway.handle_frame({:text, ~s({"t":"credit","n":1})}, opened)
  end
end
