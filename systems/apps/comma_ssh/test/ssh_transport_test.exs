defmodule CommaSSH.TestClientKey do
  @behaviour :ssh_client_key_api
  def is_host_key(_, _, _, _, _), do: true
  def add_host_key(_, _, _, _), do: :ok

  def user_key(:"ssh-ed25519", options) do
    key = options[:key_cb_private][:key]

    if options[:key_cb_private][:bad_signature],
      do: {:ok, {:ssh2_pubkey, :ssh_message.ssh2_pubkey_encode(key)}},
      else: {:ok, key}
  end

  def user_key(:"ssh-rsa", options) do
    case options[:key_cb_private][:second_key] do
      nil -> {:error, :unsupported}
      key -> {:ok, key}
    end
  end

  def user_key(_, _), do: {:error, :unsupported}
  def sign(_, _, _), do: :crypto.strong_rand_bytes(64)
end

defmodule CommaSSH.TransportTest do
  use Comma.DataCase, async: false
  alias Comma.Accounts.SSHIdentities

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    Process.register(self(), :comma_email_delivery_test)
    key = :public_key.generate_key({:namedCurve, :ed25519})
    host = :public_key.generate_key({:namedCurve, :ed25519})
    {:ok, daemon} = :ssh.daemon(0, CommaSSH.Listener.daemon_options(host))
    {:ok, info} = :ssh.daemon_info(daemon)
    on_exit(fn -> :ssh.stop_daemon(daemon) end)
    %{port: info[:port], key: key, host: host}
  end

  test "signed unknown key enrolls over a PTY and reconnects without email", %{
    port: port,
    key: key
  } do
    {ssh, channel} = connect(port, key)

    assert :success =
             :ssh_connection.ptty_alloc(ssh, channel, term: ~c"xterm", width: 80, height: 24)

    assert :ok = :ssh_connection.shell(ssh, channel)
    assert read_until(ssh, channel, "Email:") =~ "Sign in"
    email = "ssh-transport-#{System.unique_integer([:positive])}@example.com"
    :ok = :ssh_connection.send(ssh, channel, email <> "\r")
    assert_receive {:comma_login_code, ^email, code}, 5_000
    read_until(ssh, channel, "six-digit")
    :ok = :ssh_connection.send(ssh, channel, code <> "\r")
    assert read_until(ssh, channel, "Workspace setup is in progress") =~ "Workspace"
    blob = :ssh_message.ssh2_pubkey_encode(key)
    assert {:ok, identity} = SSHIdentities.lookup(blob)
    :ssh.close(ssh)

    {ssh, channel} = connect(port, key)
    :success = :ssh_connection.ptty_alloc(ssh, channel, term: ~c"xterm", width: 80, height: 24)
    :ok = :ssh_connection.shell(ssh, channel)
    assert read_until(ssh, channel, "Workspace setup is in progress") =~ "Workspace"
    refute_receive {:comma_login_code, _, _}, 100
    :ok = SSHIdentities.revoke(identity.user_id, identity.id)
    :ok = :ssh_connection.send(ssh, channel, "/workspace\r")
    assert_closed(ssh, channel)
    :ssh.close(ssh)
  end

  test "PTY chat reads and sends the canonical Router Conversation", %{port: port, key: key} do
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "ssh-chat-#{System.unique_integer([:positive])}@example.com"
      )

    workspace = create_ready_workspace!(user, %{"name" => "Primary workspace"})
    {:ok, _} = SSHIdentities.enroll(user, :ssh_message.ssh2_pubkey_encode(key))
    {:ok, token} = SSHIdentities.login(:ssh_message.ssh2_pubkey_encode(key))
    {:ok, _, session} = Comma.Accounts.resolve_session(token)
    {:ok, chat} = Comma.AssistantChats.ensure_chat(user, session, workspace["default_group_id"])

    {:ok, _} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: "comma-ba-#{workspace["id"]}",
        credits: 100,
        valid_from: DateTime.add(DateTime.utc_now(), -60),
        expires_at: DateTime.add(DateTime.utc_now(), 3600),
        source_type: "manual_contract",
        source_id: workspace["id"],
        source_event_id: workspace["id"],
        idempotency_key: workspace["id"]
      })

    {ssh, channel} = connect(port, key)
    :success = :ssh_connection.ptty_alloc(ssh, channel, term: ~c"xterm", width: 80, height: 24)
    :ok = :ssh_connection.shell(ssh, channel)
    # A sole workspace is not a choice, so the terminal opens its chat directly.
    opened = read_until(ssh, channel, "Comma / Primary workspace")
    refute opened =~ "Select a workspace"
    :ok = :ssh_connection.send(ssh, channel, "hello from SSH\r")
    read_until(ssh, channel, "hello from SSH")

    {:ok, snapshot} =
      Comma.Conversations.get(user, session, workspace["default_group_id"], chat["id"])

    assert inspect(snapshot["messages"]) =~ "hello from SSH"
    # A second surface appends to the same conversation; SSH receives its invalidation.
    {:ok, _} =
      Comma.Conversations.send_message(
        user,
        session,
        workspace["default_group_id"],
        chat["id"],
        %{
          "content" => "hello from Comma",
          "client_request_id" => Ecto.UUID.generate()
        }
      )

    read_until(ssh, channel, "hello from Comma")

    # A second workspace restores the picker; the reader chooses again.
    _second = create_additional_ready_workspace!(user, %{"name" => "Second workspace"})
    :ok = :ssh_connection.send(ssh, channel, "/workspace\r")
    picker = read_until(ssh, channel, "Select a workspace")
    picker = read_until(ssh, channel, "Second workspace", picker)
    picker = read_until(ssh, channel, "Primary workspace", picker)
    :ok = :ssh_connection.send(ssh, channel, picker_index(picker, "Primary workspace") <> "\r")
    read_until(ssh, channel, "hello from Comma")

    :ok = :ssh_connection.window_change(ssh, channel, 40, 12)
    :ok = :ssh_connection.send(ssh, channel, "/quit\r")
    assert_closed(ssh, channel)
    :ssh.close(ssh)
  end

  test "OpenSSH completes enrollment with a pinned host key", %{port: port, host: host} do
    directory =
      Path.join(System.tmp_dir!(), "comma-openssh-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    identity = Path.join(directory, "identity")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", identity])
    known_hosts = Path.join(directory, "known_hosts")

    File.write!(
      known_hosts,
      "[127.0.0.1]:#{port} ssh-ed25519 #{Base.encode64(:ssh_message.ssh2_pubkey_encode(host))}\n"
    )

    client =
      Port.open({:spawn_executable, System.find_executable("ssh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        env: [{~c"TERM", ~c"xterm-256color"}],
        args: [
          "-F",
          "/dev/null",
          "-tt",
          "-p",
          to_string(port),
          "-i",
          identity,
          "-o",
          "IdentityAgent=none",
          "-o",
          "IdentitiesOnly=yes",
          "-o",
          "BatchMode=yes",
          "-o",
          "StrictHostKeyChecking=yes",
          "-o",
          "UserKnownHostsFile=#{known_hosts}",
          "comma@127.0.0.1"
        ]
      ])

    on_exit(fn -> if Port.info(client), do: Port.close(client) end)
    read_port(client, "Email:")
    email = "openssh-#{System.unique_integer([:positive])}@example.com"
    Port.command(client, email <> "\r")
    assert_receive {:comma_login_code, ^email, code}, 5_000
    read_port(client, "six-digit")
    Port.command(client, code <> "\r")
    read_port(client, "Workspace setup is in progress")
    [_, encoded | _] = identity |> Kernel.<>(".pub") |> File.read!() |> String.split()
    assert {:ok, _} = SSHIdentities.lookup(Base.decode64!(encoded))
    Port.command(client, "/quit\r")
    restored = read_port(client, "\e[?1049l")
    assert restored =~ "\e[?2004l"
    assert_receive {^client, {:exit_status, 0}}, 5_000
  end

  test "bad signatures and foreign usernames cannot reach the TUI", %{port: port, key: key} do
    assert {:error, _} = connection(port, key, bad_signature: true)
    assert {:error, _} = connection(port, key, user: ~c"root")
    assert {:error, :unknown_key} = SSHIdentities.lookup(:ssh_message.ssh2_pubkey_encode(key))
  end

  test "a failed key followed by a valid key hands off only the valid identity", %{
    port: port,
    key: key
  } do
    second = :public_key.generate_key({:rsa, 2048, 65537})
    {:ok, ssh} = connection(port, key, bad_signature: true, second_key: second)
    {:ok, channel} = :ssh_connection.session_channel(ssh, 2_000)
    :success = :ssh_connection.ptty_alloc(ssh, channel, term: ~c"xterm", width: 100, height: 24)
    :ok = :ssh_connection.shell(ssh, channel)
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = second

    expected =
      :ssh_message.ssh2_pubkey_encode({:RSAPublicKey, modulus, exponent})
      |> SSHIdentities.fingerprint()

    assert read_until(ssh, channel, "Email:") =~ expected
    :ssh.close(ssh)
  end

  test "exec, subsystem, forwarding, and a shell without a PTY are rejected", %{
    port: port,
    key: key
  } do
    {ssh, channel} = connect(port, key)
    assert :failure = :ssh_connection.exec(ssh, channel, ~c"id", 2_000)
    assert :failure = :ssh_connection.subsystem(ssh, channel, ~c"sftp", 2_000)

    assert {:error, _} =
             :ssh.tcpip_tunnel_from_server(ssh, ~c"127.0.0.1", 0, ~c"127.0.0.1", 5432, 2_000)

    :ok = :ssh_connection.shell(ssh, channel)
    assert_closed(ssh, channel)
    :ssh.close(ssh)
  end

  defp picker_index(screen, name) do
    case Regex.run(~r/(\d+)\. #{Regex.escape(name)}/, screen) do
      [_, index] -> index
      _ -> flunk("workspace #{name} is not numbered in #{inspect(screen)}")
    end
  end

  defp connect(port, key) do
    assert {:ok, ssh} = connection(port, key)
    assert {:ok, channel} = :ssh_connection.session_channel(ssh, 2_000)
    {ssh, channel}
  end

  defp connection(port, key, opts \\ []) do
    :ssh.connect(
      ~c"127.0.0.1",
      port,
      [
        user: opts[:user] || ~c"comma",
        auth_methods: ~c"publickey",
        pref_public_key_algs: [:"ssh-ed25519", :"rsa-sha2-256"],
        user_interaction: false,
        silently_accept_hosts: true,
        key_cb:
          {CommaSSH.TestClientKey,
           [key: key, bad_signature: opts[:bad_signature], second_key: opts[:second_key]]}
      ],
      3_000
    )
  end

  defp read_port(port, text, acc \\ "") do
    if String.contains?(acc, text) do
      acc
    else
      receive do
        {^port, {:data, bytes}} -> read_port(port, text, acc <> bytes)
        {^port, {:exit_status, status}} -> flunk("OpenSSH exited #{status}: #{acc}")
      after
        5_000 -> flunk("OpenSSH did not display #{text}: #{acc}")
      end
    end
  end

  defp read_until(ssh, channel, text, acc \\ "") do
    if String.contains?(acc, text) do
      acc
    else
      receive do
        {:ssh_cm, ^ssh, {:data, ^channel, _, bytes}} ->
          read_until(ssh, channel, text, acc <> bytes)

        {:ssh_cm, ^ssh, {:closed, ^channel}} ->
          flunk("channel closed before expected screen")
      after
        5_000 -> flunk("missing screen text #{inspect(text)}: #{inspect(acc)}")
      end
    end
  end

  defp assert_closed(ssh, channel) do
    receive do
      {:ssh_cm, ^ssh, {:closed, ^channel}} -> :ok
      {:ssh_cm, ^ssh, _} -> assert_closed(ssh, channel)
    after
      5_000 -> flunk("revoked channel remained open")
    end
  end
end
