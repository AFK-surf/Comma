defmodule CommaWeb.StationEndpointsTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  alias Comma.{Accounts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixStore.Ids

  @origin "https://api.comma.test"

  defmodule Station do
    use WebSockex

    def start(base, station, opts \\ []) do
      ts = Keyword.get(opts, :ts, SystemsClock.system_time(:second))

      message =
        "comma-station-connect-v1:#{Keyword.get(opts, :origin, "https://api.comma.test")}:#{station.id}:#{ts}"

      WebSockex.start(
        String.replace(base, "http", "ws") <> "/v1/comma/stations/connect",
        __MODULE__,
        %{test: SystemsRuntime.Proc.self(), as: Keyword.get(opts, :as)},
        extra_headers: [
          {"x-stillfail-station", station.id},
          {"x-stillfail-ts", "#{ts}"},
          {"x-stillfail-signature", CommaWeb.StationEndpointsTest.sign(station, message)},
          {"x-stillfail-version", "0.1.9"}
        ]
      )
    end

    @impl true
    def handle_frame({:text, "pong"}, state) do
      SystemsRuntime.Proc.send(state.test, :pong)
      {:ok, state}
    end

    def handle_frame({:text, text}, %{as: nil} = state) do
      SystemsRuntime.Proc.send(state.test, {:frame, Jason.decode!(text)})
      {:ok, state}
    end

    # One of several stations of a test: its frames say which.
    def handle_frame({:text, text}, state) do
      SystemsRuntime.Proc.send(state.test, {:frame, state.as, Jason.decode!(text)})
      {:ok, state}
    end

    @impl true
    def handle_cast({:send, text}, state), do: {:reply, {:text, text}, state}

    @impl true
    def handle_disconnect(%{reason: reason}, state) do
      SystemsRuntime.Proc.send(state.test, {:closed, reason})
      {:ok, state}
    end
  end

  defmodule RelayClient do
    use WebSockex

    def start(url), do: WebSockex.start(url, __MODULE__, %{})

    @impl true
    def handle_cast(:close, state), do: {:close, state}
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    Comma.AuthChallengeStore.Memory.reset!()
    prior = SystemsRuntime.get_env(:comma_core, :stations)
    prior_salix = SystemsRuntime.get_env(:salix_store, :stations)
    # Salix keeps the roster and its keys outside this test's transaction.
    SalixStore.Repo.delete_all(SalixStore.Stations.SigningKeys.Key)
    SystemsRuntime.put_env(:salix_store, :stations, kek: SystemsRuntime.Proc.random_bytes(32))

    SystemsRuntime.put_env(:comma_core, :stations,
      origin: @origin,
      relay_urls: ["https://relay.comma.test"],
      gateway_keys: [String.duplicate("cd", 32)],
      release_manifest: %{
        "version" => "0.1.42",
        "build" => 42,
        "commit" => String.duplicate("ab", 20)
      }
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :stations, prior || [])
      SystemsRuntime.put_env(:salix_store, :stations, prior_salix || [])
      CommaWeb.TestRepoSandbox.stop_owner(owner)
    end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "station-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    workspace = workspace!(user)

    server =
      start_supervised!(
        {Bandit, plug: CommaWeb.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{user: user, session: session, workspace: workspace, base: "http://127.0.0.1:#{port}"}
  end

  test "a member's device relays its packets to the Group's stations through Comma, once per ticket",
       ctx do
    ticket = fn session ->
      Req.post!(ctx.base <> "/v1/comma/workspaces/#{ctx.workspace.id}/station-relay",
        headers: auth(session),
        json: %{},
        retry: false
      )
    end

    assert %{status: 200, body: %{"ticket" => first, "url" => url}} = ticket.(ctx.session)
    assert url == "wss://api.comma.test/v1/comma/station-relay"
    local = String.replace(ctx.base, "http", "ws") <> "/v1/comma/station-relay?ticket="

    # A ticket opens one socket; another is refused before the upgrade.
    {:ok, opened} = RelayClient.start(local <> URI.encode_www_form(first))
    WebSockex.cast(opened, :close)

    assert {:error, %WebSockex.RequestError{code: 401}} =
             RelayClient.start(local <> URI.encode_www_form(first))

    # The socket, as its process: the device proves its endpoint key, as a station's Connector does.
    %{status: 200, body: %{"ticket" => second}} = ticket.(ctx.session)
    {:ok, member} = Comma.Stations.redeem_relay_ticket(second)
    assert {:push, {:text, text}, state} = CommaWeb.ClientRelaySocket.init(member)
    %{"type" => "challenge", "challenge" => challenge} = Jason.decode!(text)

    device = keypair()
    [ticket_id, _secret] = String.split(second, ".", parts: 2)

    signature =
      SystemsRuntime.Proc.sign(
        :eddsa,
        :none,
        "comma-salix-relay-v1:#{ticket_id}:#{challenge}",
        [device.seed, :ed25519]
      )
      |> Base.encode64()

    register = %{"type" => "register", "endpoint_id" => device.id, "signature" => signature}

    assert {:push, {:text, ~s({"type":"registered"})}, state} =
             CommaWeb.ClientRelaySocket.handle_in({Jason.encode!(register), opcode: :text}, state)

    # A station of the Group carries its own endpoint: the device's packet reaches it, and its answer the device.
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}
    station_key = Base.decode16!(keypair().id, case: :lower)
    device_key = Base.decode16!(device.id, case: :lower)

    :ok =
      :pg.join(
        SalixWeb.StationRelay.PG,
        {:endpoint, scope, station_key},
        SystemsRuntime.Proc.self()
      )

    assert {:ok, state} =
             CommaWeb.ClientRelaySocket.handle_in(
               {<<1, station_key::binary, "hello">>, opcode: :binary},
               state
             )

    assert_received {:station_relay_packet, ^device_key, ^scope, "hello"}

    assert {:push, {:binary, <<1, ^station_key::binary-size(32), "back">>}, _state} =
             CommaWeb.ClientRelaySocket.handle_info(
               {:station_relay_packet, station_key, scope, "back"},
               state
             )

    # A registration whose signature does not prove the key is refused.
    %{status: 200, body: %{"ticket" => third}} = ticket.(ctx.session)
    {:ok, member} = Comma.Stations.redeem_relay_ticket(third)
    {:push, _challenge, state} = CommaWeb.ClientRelaySocket.init(member)

    assert {:stop, :normal, {4003, "registration_refused"}, _state} =
             CommaWeb.ClientRelaySocket.handle_in({Jason.encode!(register), opcode: :text}, state)

    # Someone outside the Workspace gets no ticket.
    {:ok, stranger} =
      Accounts.create_user(%{
        "email" =>
          "relay-stranger-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, stranger_session} =
      Accounts.create_session(stranger["id"], client_kind: "ios", client_platform: "ios")

    assert %{status: 404} = ticket.(stranger_session)
  end

  test "install script and release manifest are public", ctx do
    assert %{status: 200, body: script} =
             Req.get!(ctx.base <> "/stations/install.sh", retry: false)

    assert script =~ ~s(origin="#{@origin}")
    assert script =~ ~s(token="${1:-}")
    assert script =~ ~s(station enroll "$origin" "$token" --provider comma)
    assert script =~ ~s(releases="https://app.still.fail/releases")
    assert script =~ ~s(release_commit="#{String.duplicate("ab", 20)}")

    assert script =~
             ~s(artifact="https://app.still.fail/releases/stillfail-station-darwin-arm64.tar.gz")

    assert %{status: 200, body: %{"version" => "0.1.42", "build" => 42}} =
             Req.get!(ctx.base <> "/stations/releases/station.json", retry: false)

    assert %{status: 404} =
             Req.get!(ctx.base <> "/stations/releases/station-beta.json", retry: false)

    # Without an inline manifest it follows the manifest URL (still.fail's stable
    # one by default); an unreachable source answers 503.
    SystemsRuntime.put_env(
      :comma_core,
      :stations,
      SystemsRuntime.get_env(:comma_core, :stations)
      |> Keyword.delete(:release_manifest)
      |> Keyword.put(:release_manifest_url, "http://127.0.0.1:1/station.json")
    )

    assert %{status: 503} = Req.get!(ctx.base <> "/stations/releases/station.json", retry: false)
  end

  test "device tools ride the presence socket: sent, answered, unreachable and lost", ctx do
    token = enrollment_token(ctx)
    station = keypair()
    assert %{status: 200} = enroll(ctx, station, token)
    {:ok, socket} = Station.start(ctx.base, station)
    assert_receive {:frame, %{"type" => "state"}}, 5_000

    request = fn id ->
      %{"op" => "exec", "id" => id, "args" => %{"command" => "true"}, "context" => %{}}
    end

    call =
      SystemsRuntime.Task.async(fn -> CommaWeb.StationTools.call(station.id, request.("r1")) end)

    assert_receive {:frame, %{"type" => "tool", "id" => "r1", "request" => %{"op" => "exec"}}},
                   5_000

    WebSockex.cast(
      socket,
      {:send,
       Jason.encode!(%{
         "type" => "tool_result",
         "id" => "r1",
         "response" => %{"ok" => true, "result" => %{"exit_code" => 0}}
       })}
    )

    assert SystemsRuntime.Task.await(call, :infinity) == {:ok, %{"exit_code" => 0}}

    # A tool error comes back as the station's own error.
    call =
      SystemsRuntime.Task.async(fn -> CommaWeb.StationTools.call(station.id, request.("r2")) end)

    assert_receive {:frame, %{"type" => "tool", "id" => "r2"}}, 5_000

    WebSockex.cast(
      socket,
      {:send,
       Jason.encode!(%{
         "type" => "tool_result",
         "id" => "r2",
         "response" => %{"ok" => false, "error" => %{"code" => "forbidden", "message" => "off"}}
       })}
    )

    assert SystemsRuntime.Task.await(call, :infinity) ==
             {:error, {:tool, %{"code" => "forbidden", "message" => "off"}}}

    # The socket ends while a call waits: the outcome is unknown.
    call =
      SystemsRuntime.Task.async(fn -> CommaWeb.StationTools.call(station.id, request.("r3")) end)

    assert_receive {:frame, %{"type" => "tool", "id" => "r3"}}, 5_000
    SystemsRuntime.Proc.exit(socket, :kill)

    assert {:error, {:gateway, "station_disconnected", _}} =
             SystemsRuntime.Task.await(call, :infinity)

    # No socket at all: nothing was sent.
    SystemsRuntime.put_env(:comma_web, :station_tools_ack_ms, 200)
    on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :station_tools_ack_ms) end)

    assert {:error, {:gateway, "station_unreachable", _}} =
             CommaWeb.StationTools.call(keypair().id, request.("r4"))
  end

  # Runs only in a temporary HOME/STILLFAIL_DATA with a fake curl first on PATH: never on the host's station.
  test "install script leaves a station enrolled elsewhere untouched unless asked to move it",
       ctx do
    %{status: 200, body: script} = Req.get!(ctx.base <> "/stations/install.sh", retry: false)

    root =
      Path.join(
        System.tmp_dir!(),
        "station-install-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    data = Path.join(root, ".stillfail")
    bin = Path.join(root, "bin")
    File.mkdir_p!(Path.join(data, "mesh"))
    File.mkdir_p!(bin)
    File.write!(Path.join(root, "install.sh"), script)
    marker = Path.join(root, "curl-called")
    File.write!(Path.join(bin, "curl"), "#!/bin/sh\ntouch #{marker}\nexit 22\n")
    File.chmod!(Path.join(bin, "curl"), 0o755)

    run = fn args ->
      File.rm(marker)

      {output, status} =
        System.cmd("sh", [Path.join(root, "install.sh") | args],
          env: [
            {"HOME", root},
            {"STILLFAIL_DATA", data},
            {"PATH", bin <> ":/usr/bin:/bin"}
          ],
          stderr_to_stdout: true
        )

      {status, output, File.exists?(marker)}
    end

    cloud = Path.join(data, "mesh/cloud.json")
    File.write!(cloud, ~s({"origin":"https://app.still.fail","station":"ab","workspace":"w"}))

    assert {3, output, false} = run.([])
    assert output =~ "Nothing was changed"
    assert {3, output, false} = run.(["tok_1.secret"])
    assert output =~ "--move-station"
    # Moving is explicit; it then goes on to download (the fake curl fails it here).
    assert {status, _output, true} = run.(["tok_1.secret", "--move-station"])
    assert status != 0

    # Another Comma origin is "elsewhere" too; this Comma's own station is updated.
    File.write!(cloud, ~s({"provider":"comma","origin":"https://other.comma.test"}))
    assert {3, _output, false} = run.([])
    File.write!(cloud, ~s({"provider": "comma", "origin": "#{@origin}"}))
    assert {status, _output, true} = run.([])
    assert status != 0
  end

  # Temporary HOME/STILLFAIL_DATA and a fake curl that serves a prepared bundle: never the host's station.
  test "install script installs only the release the manifest pins", ctx do
    root =
      Path.join(
        System.tmp_dir!(),
        "station-pin-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    bin = Path.join(root, "bin")
    File.mkdir_p!(Path.join(root, "bundle/stillfail"))
    File.mkdir_p!(bin)
    File.write!(Path.join(root, "bundle/stillfail/VERSION"), String.duplicate("cd", 20) <> "\n")
    bundle = Path.join(root, "bundle.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", bundle, "-C", Path.join(root, "bundle"), "stillfail"])
    urls = Path.join(root, "urls")

    File.write!(Path.join(bin, "curl"), """
    #!/bin/sh
    out=""; url=""
    while [ $# -gt 0 ]; do
      case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac
      shift
    done
    echo "$url" >> #{urls}
    cp #{bundle} "$out"
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)

    run = fn manifest ->
      SystemsRuntime.put_env(
        :comma_core,
        :stations,
        Keyword.put(SystemsRuntime.get_env(:comma_core, :stations), :release_manifest, manifest)
      )

      %{status: 200, body: script} = Req.get!(ctx.base <> "/stations/install.sh", retry: false)
      data = Path.join(root, "data-#{SystemsRuntime.Proc.unique_integer([:positive])}")
      File.write!(Path.join(root, "install.sh"), script)
      File.rm(urls)

      {output, status} =
        System.cmd("sh", [Path.join(root, "install.sh"), "ws.usr.tok.secret"],
          env: [{"HOME", root}, {"STILLFAIL_DATA", data}, {"PATH", bin <> ":/usr/bin:/bin"}],
          stderr_to_stdout: true
        )

      {status, output, File.read!(urls), File.exists?(Path.join(data, "app"))}
    end

    pinned = fn sha ->
      for platform <- ~w(darwin-arm64 linux-x64 linux-arm64), into: %{} do
        {platform, %{"url" => "https://mirror.comma.test/#{platform}.tar.gz", "sha256" => sha}}
      end
    end

    # The manifest's own artifact, checked against its sha256.
    {status, output, fetched, installed?} =
      run.(%{"version" => "0.1.5", "artifacts" => pinned.(String.duplicate("0", 64))})

    assert status == 1 and not installed?
    assert fetched =~ "https://mirror.comma.test/"
    assert output =~ "does not match the sha256"

    # The release base's bundle is taken only when it is built from the pinned commit.
    {status, output, fetched, installed?} =
      run.(%{"version" => "0.1.6", "commit" => String.duplicate("ef", 20)})

    assert status == 1 and not installed?
    assert fetched =~ "https://app.still.fail/releases/stillfail-station-"
    assert output =~ "not the release Comma pins"

    # An unsafe manifest value is refused rather than written into the script.
    SystemsRuntime.put_env(
      :comma_core,
      :stations,
      Keyword.put(SystemsRuntime.get_env(:comma_core, :stations), :release_manifest, %{
        "version" => "0.1.7",
        "artifacts" => %{"linux-x64" => %{"url" => "https://x.test/a;rm -rf ~"}}
      })
    )

    assert %{status: 503} = Req.get!(ctx.base <> "/stations/install.sh", retry: false)
  end

  test "station events stop when the session is revoked, whatever the event traffic", ctx do
    SystemsRuntime.put_env(:comma_web, :station_events_heartbeat_ms, 200)
    on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :station_events_heartbeat_ms) end)
    events = sse(ctx)
    :ok = Accounts.revoke_session(ctx.user["id"], ctx.session["id"])
    assert_sse_closed(events)
  end

  test "enrollment over HTTP is single use and checks the station's proof", ctx do
    assert %{status: 401} =
             post(ctx, nil, "/v1/comma/workspaces/#{ctx.workspace.id}/stations/enrollments", %{})

    token = enrollment_token(ctx)
    station = keypair()

    bad = %{
      "token" => token,
      "station" => station.id,
      "signature" => sign(keypair(), "x"),
      "version" => "1"
    }

    assert %{status: 401, body: %{"error" => "invalid_signature"}} =
             post(ctx, nil, "/v1/comma/stations/enroll", bad)

    assert %{status: 200, body: %{"provider" => "comma", "station" => id}} =
             enroll(ctx, station, token)

    assert id == station.id

    assert %{status: 410, body: %{"error" => "token_expired_or_used"}} =
             enroll(ctx, keypair(), token)

    assert %{status: 400} = post(ctx, nil, "/v1/comma/stations/enroll", %{"token" => 1})
  end

  test "presence socket: state, ping/pong, online, revoke frames, and 4004 on removal", ctx do
    station = keypair()
    %{status: 200} = enroll(ctx, station, enrollment_token(ctx))

    events = sse(ctx)
    {:ok, socket} = Station.start(ctx.base, station)

    assert_receive {:frame, state}

    assert %{
             "type" => "state",
             "peers" => [%{"id" => peer, "name" => "Station", "version" => "0.1.9"}],
             "workspace" => workspace_id,
             "workspace_name" => "Station team",
             "name" => "Station",
             "origin" => @origin,
             "relay_urls" => ["https://relay.comma.test"],
             "grant_keys" => %{"keys" => [_ | _]},
             "gateway_keys" => [_],
             "revocations" => []
           } = state

    assert peer == station.id
    # The Group is the workspace a station is in.
    assert workspace_id == ctx.workspace.salix_group_id

    WebSockex.cast(socket, {:send, "ping"})
    assert_receive :pong

    assert_sse(events, "station", %{"id" => station.id, "online" => true})

    assert %{
             status: 200,
             body: %{"stations" => [%{"id" => _, "online" => true, "enrolled_by" => by}]}
           } =
             get(ctx, "/v1/comma/workspaces/#{ctx.workspace.id}/stations")

    assert by == ctx.user["id"]

    # A rename is a state change.
    assert %{status: 200} =
             patch(ctx, "/v1/comma/workspaces/#{ctx.workspace.id}/stations/#{station.id}", %{
               "name" => "Desk"
             })

    assert_receive {:frame, %{"type" => "state", "name" => "Desk"}}
    assert_sse(events, "stations", %{})

    # Signing out a Comma session revokes its credentials at the station.
    {:ok, other} = Accounts.create_session(ctx.user["id"])
    :ok = Accounts.revoke_session_token(other["token"])
    other_id = other["id"]

    assert_receive {:frame, %{"type" => "revoke", "kind" => "sid", "id" => ^other_id, "at" => _}}

    assert %{status: 200} =
             delete(ctx, "/v1/comma/workspaces/#{ctx.workspace.id}/stations/#{station.id}")

    assert_receive {:closed, {:remote, 4004, "station_removed"}}

    assert {:error, %WebSockex.RequestError{code: 404}} = Station.start(ctx.base, station)
  end

  test "where a station may be reached: told its peers and clients while it is online, never stored",
       ctx do
    a = keypair()
    b = keypair()
    %{status: 200} = enroll(ctx, a, enrollment_token(ctx))
    %{status: 200} = enroll(ctx, b, enrollment_token(ctx))
    {:ok, socket_a} = Station.start(ctx.base, a, as: :a)
    state_frame(:a)
    {:ok, _socket_b} = Station.start(ctx.base, b, as: :b)
    %{"peers" => peers} = state_frame(:b)
    # A station that said nothing has no hints.
    assert Enum.all?(peers, &(Map.keys(&1) == ["id", "name", "version"]))
    events = sse(ctx)

    reach = fn body ->
      WebSockex.cast(socket_a, {:send, Jason.encode!(Map.put(body, "type", "reach"))})
    end

    # What is not a relay URL or an `ip:port` is left out.
    reach.(%{
      "home_relay" => "https://relay.comma.test/",
      "addrs" => ["192.168.1.5:4770", "[fe80::1%3]:4770", "bogus", "10.0.0.1:0", 7]
    })

    told = %{
      "home_relay" => "https://relay.comma.test/",
      "addrs" => ["192.168.1.5:4770", "[fe80::1%3]:4770"]
    }

    assert peer_told(:b, a.id, told)
    assert_sse(events, "station", Map.put(told, "id", a.id))

    assert listed(ctx, a.id) |> Map.take(["online", "home_relay", "addrs"]) ==
             Map.put(told, "online", true)

    refute Map.has_key?(listed(ctx, b.id), "home_relay")

    # A new home relay is told again; a station that says nothing usable has none.
    reach.(%{"home_relay" => "https://relay2.comma.test/", "addrs" => ["192.168.1.5:4770"]})

    assert peer_told(:b, a.id, %{
             "home_relay" => "https://relay2.comma.test/",
             "addrs" => ["192.168.1.5:4770"]
           })

    reach.(%{"home_relay" => "ftp://relay.comma.test/", "addrs" => "192.168.1.5:4770"})
    assert peer_told(:b, a.id, %{})
    reach.(%{"addrs" => ["192.168.1.6:4770"]})
    assert peer_told(:b, a.id, %{"addrs" => ["192.168.1.6:4770"]})

    # Offline: the hints go with the socket.
    SystemsRuntime.Proc.exit(socket_a, :kill)
    assert peer_told(:b, a.id, %{})

    assert listed(ctx, a.id) |> Map.take(["online", "home_relay", "addrs"]) == %{
             "online" => false
           }
  end

  describe "while servers of the release before still run" do
    setup ctx do
      phase!("window")

      on_exit(fn ->
        phase!("complete")
        Comma.Stations.Window.forget()
      end)

      # As a server of the release before enrolls a station: a row in Comma's table only.
      enrolled = fn station ->
        Repo.insert!(%Comma.Stations.Station{
          id: station.id,
          workspace_id: ctx.workspace.id,
          name: "Enrolled there",
          version: "0.1.8",
          enrolled_by: ctx.user["id"],
          enrolled_at: ~U[2026-10-01 00:00:00.000000Z],
          last_seen_at: nil
        })
      end

      # A presence socket of this server, as its process: what it pushed first and its state.
      socket = fn station ->
        assert {:push, {:text, text}, state} =
                 CommaWeb.StationSocket.init(%{
                   station_id: station.id,
                   version: "0.1.9",
                   origin: @origin
                 })

        {Jason.decode!(text), state}
      end

      %{enrolled: enrolled, socket: socket, old_bus: CommaWeb.PubSub}
    end
  end

  test "a newer socket replaces the older one; bad or stale proofs are refused", ctx do
    station = keypair()
    %{status: 200} = enroll(ctx, station, enrollment_token(ctx))
    {:ok, _first} = Station.start(ctx.base, station)
    assert_receive {:frame, %{"type" => "state"}}
    {:ok, _second} = Station.start(ctx.base, station)
    assert_receive {:closed, {:remote, 4000, "replaced"}}

    assert {:error, %WebSockex.RequestError{code: 401}} =
             Station.start(ctx.base, station, origin: "https://elsewhere.test")

    assert {:error, %WebSockex.RequestError{code: 400}} =
             Station.start(ctx.base, station, ts: SystemsClock.system_time(:second) - 600)

    assert {:error, %WebSockex.RequestError{code: 404}} = Station.start(ctx.base, keypair())
  end

  test "a station of a suspended or deleted Workspace is refused with 404, as a removed one",
       ctx do
    import Ecto.Query
    station = keypair()
    %{status: 200} = enroll(ctx, station, enrollment_token(ctx))

    for status <- ~w(suspended deleted) do
      Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
        set: [status: status]
      )

      assert {:error, %WebSockex.RequestError{code: 404}} = Station.start(ctx.base, station)
    end

    Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
      set: [status: "active"]
    )

    # The row stayed: the active Workspace's station connects again.
    assert {:ok, _socket} = Station.start(ctx.base, station)
  end

  test "credential, me and notify endpoints", ctx do
    station = keypair()
    %{status: 200} = enroll(ctx, station, enrollment_token(ctx))

    assert %{status: 200, body: %{"credential" => credential, "relay_urls" => [_]}} =
             post(
               ctx,
               ctx.session,
               "/v1/comma/workspaces/#{ctx.workspace.id}/station-credential",
               %{
                 "device" => keypair().id
               }
             )

    assert [_, claims, _] = String.split(credential, ".")

    # The credential is for the Group, which is what the station holds as its workspace.
    assert %{"ws" => ws, "role" => "owner"} =
             claims |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert ws == ctx.workspace.salix_group_id

    # Clients still name their Comma Workspace.
    assert %{
             status: 200,
             body: %{
               "user" => %{"id" => uid},
               "workspaces" => [%{"id" => listed, "role" => "owner"}]
             }
           } =
             get(ctx, "/v1/comma/stations/me")

    assert listed == ctx.workspace.id

    assert uid == ctx.user["id"]

    body = Jason.encode!(%{"notices" => []})
    ts = SystemsClock.system_time(:second)
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    signature = sign(station, "comma-station-notify-v1:#{@origin}:#{station.id}:#{ts}:#{digest}")

    headers = fn sig ->
      [
        {"content-type", "application/json"},
        {"x-stillfail-station", station.id},
        {"x-stillfail-ts", "#{ts}"},
        {"x-stillfail-signature", sig}
      ]
    end

    assert %{status: 200, body: %{}} =
             Req.post!(ctx.base <> "/v1/comma/stations/notify",
               body: body,
               headers: headers.(signature),
               retry: false
             )

    assert %{status: 401} =
             Req.post!(ctx.base <> "/v1/comma/stations/notify",
               body: body,
               headers: headers.(sign(keypair(), "x")),
               retry: false
             )
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Salix's marker is outside this test's transaction.
  defp phase!(phase) do
    SalixStore.Repo.query!(
      """
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('station_roster_v1', TIMESTAMPTZ '2026-01-01 00:00:00Z', $1)
      ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence
      """,
      [%{"phase" => phase}]
    )

    Comma.Stations.Window.forget()
  end

  defp workspace!(user) do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_station_web_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "station-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "station-test",
        name: "Station team",
        status: "active"
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    workspace
  end

  defp enrollment_token(ctx) do
    %{status: 200, body: %{"token" => token, "command" => command}} =
      post(ctx, ctx.session, "/v1/comma/workspaces/#{ctx.workspace.id}/stations/enrollments", %{})

    assert command =~ "#{@origin}/stations/install.sh"
    token
  end

  defp enroll(ctx, station, token) do
    post(ctx, nil, "/v1/comma/stations/enroll", %{
      "token" => token,
      "station" => station.id,
      "signature" => sign(station, "comma-station-enroll-v1:#{@origin}:#{token}:#{station.id}"),
      "version" => "0.1.8"
    })
  end

  # The next `state` frame station `tag` is told in which peer `id` has the
  # hints `expected` (an exact match of what is beside its id, name and version).
  defp peer_told(tag, id, expected) do
    %{"peers" => peers} = state_frame(tag)
    peer = Enum.find(peers, &(&1["id"] == id))

    if Map.drop(peer, ["id", "name", "version"]) == expected,
      do: true,
      else: peer_told(tag, id, expected)
  end

  # The next `state` frame station `tag` is sent: waited for, not timed.
  defp state_frame(tag) do
    SystemsRuntime.Proc.receive do
      {:frame, ^tag, %{"type" => "state"} = frame} -> frame
    end
  end

  defp listed(ctx, id) do
    %{status: 200, body: %{"stations" => stations}} =
      get(ctx, "/v1/comma/workspaces/#{ctx.workspace.id}/stations")

    Enum.find(stations, &(&1["id"] == id))
  end

  defp sse(ctx) do
    resp =
      Req.get!(ctx.base <> "/v1/comma/workspaces/#{ctx.workspace.id}/stations/events",
        headers: auth(ctx.session),
        into: :self,
        retry: false,
        receive_timeout: 10_000
      )

    assert resp.status == 200
    resp
  end

  defp assert_sse(resp, event, expected, buffer \\ "") do
    case String.split(buffer, "\n\n", parts: 2) do
      [frame, rest] ->
        if String.contains?(frame, "event: #{event}\n") do
          [_, data] = String.split(frame, "data: ", parts: 2)
          decoded = Jason.decode!(data)
          assert Map.take(decoded, Map.keys(expected)) == expected
        else
          assert_sse(resp, event, expected, rest)
        end

      [_partial] ->
        SystemsRuntime.Proc.receive do
          message
          when message != :pong and
                 not (is_tuple(message) and elem(message, 0) in [:frame, :closed]) ->
            case Req.parse_message(resp, message) do
              {:ok, chunks} ->
                data = for {:data, d} <- chunks, into: "", do: d
                assert_sse(resp, event, expected, buffer <> data)

              :unknown ->
                assert_sse(resp, event, expected, buffer)
            end
        after
          5_000 -> flunk("no SSE #{event} event")
        end
    end
  end

  defp assert_sse_closed(resp) do
    SystemsRuntime.Proc.receive do
      message
      when message != :pong and
             not (is_tuple(message) and elem(message, 0) in [:frame, :closed]) ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} -> if :done in chunks, do: :ok, else: assert_sse_closed(resp)
          {:error, _} -> :ok
          :unknown -> assert_sse_closed(resp)
        end
    after
      5_000 -> flunk("SSE stream still open")
    end
  end

  defp auth(nil), do: []
  defp auth(session), do: [{"authorization", "Bearer " <> session["token"]}]

  defp post(ctx, session, path, body),
    do: Req.post!(ctx.base <> path, json: body, headers: auth(session), retry: false)

  defp get(ctx, path), do: Req.get!(ctx.base <> path, headers: auth(ctx.session), retry: false)

  defp patch(ctx, path, body),
    do: Req.patch!(ctx.base <> path, json: body, headers: auth(ctx.session), retry: false)

  defp delete(ctx, path),
    do: Req.delete!(ctx.base <> path, headers: auth(ctx.session), retry: false)

  defp keypair do
    {public, seed} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    %{id: Base.encode16(public, case: :lower), seed: seed}
  end

  def sign(station, message),
    do:
      SystemsRuntime.Proc.sign(:eddsa, :none, message, [station.seed, :ed25519])
      |> Base.encode16(case: :lower)
end
