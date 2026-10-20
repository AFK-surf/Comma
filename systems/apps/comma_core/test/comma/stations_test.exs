defmodule Comma.StationsTest do
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]

  alias Comma.{Accounts, Stations}
  alias Comma.Auth.OneTimeCredentials
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Notifications.{APNs, Target}
  alias Comma.Stations.{Config, Notices, Signature}
  alias SalixStore.Ids
  alias SalixStore.Repo, as: SalixRepo
  alias SalixStore.Stations, as: Roster
  alias SalixStore.Stations.{Events, Revocations, SigningKeys, Station}

  @origin "https://api.comma.test"

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    SalixStore.RepoTestSetup.ensure!()
    # Salix keeps the keys outside this test's transaction: each test seals its own.
    SalixRepo.delete_all(SigningKeys.Key)
    prior = SystemsRuntime.get_env(:comma_core, :stations)
    prior_salix = SystemsRuntime.get_env(:salix_store, :stations)
    members = SystemsRuntime.get_env(:salix_store, :station_members)
    # Only this product answers here: another product's store is not this test's.
    SystemsRuntime.put_env(:salix_store, :station_members, [Comma.Stations.Members])

    SystemsRuntime.put_env(:comma_core, :stations,
      origin: @origin,
      relay_urls: ["https://relay.comma.test"],
      gateway_keys: [String.duplicate("ab", 32)]
    )

    SystemsRuntime.put_env(:salix_store, :stations, kek: SystemsRuntime.Proc.random_bytes(32))

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :stations, prior || [])
      SystemsRuntime.put_env(:salix_store, :stations, prior_salix || [])
      SystemsRuntime.put_env(:salix_store, :station_members, members || [])
    end)

    {user, session} = user!("owner")
    workspace = workspace!(user, "Team")
    %{user: user, session: session, workspace: workspace}
  end

  describe "configuration defaults" do
    test "derives the KEK from the subscription storage key unless one is set" do
      prior = SystemsRuntime.get_env(:salix_agent, :subscription_storage_key)

      on_exit(fn ->
        if prior,
          do: SystemsRuntime.put_env(:salix_agent, :subscription_storage_key, prior),
          else: SystemsRuntime.delete_env(:salix_agent, :subscription_storage_key)
      end)

      set = SystemsRuntime.get_env(:salix_store, :stations)
      SystemsRuntime.put_env(:salix_store, :stations, [])

      SystemsRuntime.delete_env(:salix_agent, :subscription_storage_key)
      refute Config.enabled?()
      assert SigningKeys.kek() == {:error, :stations_unavailable}

      root = SystemsRuntime.Proc.random_bytes(32)
      SystemsRuntime.put_env(:salix_agent, :subscription_storage_key, root)
      assert Config.enabled?()
      assert {:ok, <<derived::binary-size(32)>>} = SigningKeys.kek()
      # Stable for the same root, and never the root itself.
      assert SigningKeys.kek() == {:ok, derived}
      refute derived == root

      SystemsRuntime.put_env(:salix_store, :stations, set)
      assert SigningKeys.kek() == {:ok, set[:kek]}
    end
  end

  describe "station-signed requests" do
    test "accept a fresh signature and refuse a wrong or stale one" do
      station = keypair()
      body = ~s({"notices":[]})
      ts = SystemsClock.system_time(:second)
      tag = "comma-station-notify-v1"
      sig = sign(station, Signature.request_message(tag, @origin, station.id, ts, body))

      assert :ok = Signature.verify_request(tag, @origin, station.id, "#{ts}", sig, body)

      assert {:error, :invalid_signature} =
               Signature.verify_request(tag, @origin, station.id, "#{ts}", sig, body <> " ")

      other = keypair()

      assert {:error, :invalid_signature} =
               Signature.verify_request(tag, @origin, other.id, "#{ts}", sig, body)

      # Signed for another control plane.
      foreign =
        sign(station, Signature.request_message(tag, "https://x.test", station.id, ts, body))

      assert {:error, :invalid_signature} =
               Signature.verify_request(tag, @origin, station.id, "#{ts}", foreign, body)

      stale = ts - 301
      stale_sig = sign(station, Signature.request_message(tag, @origin, station.id, stale, body))

      assert {:error, :invalid_request} =
               Signature.verify_request(tag, @origin, station.id, "#{stale}", stale_sig, body)

      connect = sign(station, Signature.connect_message(@origin, station.id, ts))
      assert :ok = Signature.verify_connect(@origin, station.id, "#{ts}", connect)

      assert {:error, :invalid_signature} =
               Signature.verify_connect(@origin, station.id, "#{ts}", sig)
    end
  end

  describe "enrollment" do
    test "a token enrolls one station once and answers the contract shape", ctx do
      assert {:ok, enrollment} =
               Stations.create_enrollment(ctx.user, ctx.session, ctx.workspace.id, %{
                 "name" => " Mac  mini "
               })

      assert enrollment["command"] ==
               "curl -fsSL #{@origin}/stations/install.sh | sh -s -- #{enrollment["token"]}"

      station = keypair()
      assert {:ok, response} = enroll(station, enrollment["token"])

      assert %{
               "provider" => "comma",
               "workspace" => workspace_id,
               "workspace_name" => "Team",
               "name" => "Mac mini",
               "station" => station_id,
               "relay_urls" => ["https://relay.comma.test"],
               "grant_keys" => %{"keys" => [%{"kty" => "OKP", "crv" => "Ed25519", "kid" => _}]},
               "gateway_keys" => [_]
             } = response

      # The Group is the workspace a station is in.
      assert workspace_id == ctx.workspace.salix_group_id
      assert station_id == station.id

      assert %Station{kind: "device", tenant_id: tenant_id, enrolled_by: enrolled_by} =
               SalixRepo.get!(Station, station.id)

      assert tenant_id == ctx.workspace.salix_tenant_id
      assert enrolled_by == ctx.user["id"]
      # Comma's own table takes no row.
      assert Repo.aggregate(Comma.Stations.Station, :count) == 0

      assert {:error, :token_expired_or_used} = enroll(keypair(), enrollment["token"])
    end

    test "a bad proof does not burn the token; an expired token is refused", ctx do
      {:ok, enrollment} = Stations.create_enrollment(ctx.user, ctx.session, ctx.workspace.id, %{})
      station = keypair()

      assert {:error, :invalid_signature} =
               Stations.enroll(%{
                 "token" => enrollment["token"],
                 "station" => station.id,
                 "signature" =>
                   sign(
                     keypair(),
                     "comma-station-enroll-v1:#{@origin}:#{enrollment["token"]}:#{station.id}"
                   )
               })

      assert {:ok, %{"name" => "Station"}} = enroll(station, enrollment["token"])

      {:ok, grant} =
        OneTimeCredentials.issue(
          "station_enroll",
          %{
            "tenant_id" => ctx.workspace.salix_tenant_id,
            "group_id" => ctx.workspace.salix_group_id,
            "user_id" => ctx.user["id"],
            "name" => "Old"
          },
          -1,
          ctx.user["id"]
        )

      assert {:error, :token_expired_or_used} =
               enroll(
                 keypair(),
                 Enum.join(
                   [
                     ctx.workspace.salix_tenant_id,
                     ctx.workspace.salix_group_id,
                     ctx.user["id"],
                     grant.id,
                     grant.secret
                   ],
                   "."
                 )
               )

      assert {:error, :invalid_request} =
               Stations.enroll(%{"token" => "t", "station" => "nothex", "signature" => ""})
    end

    test "a member but not a read-only one enrolls a station of their own", ctx do
      {stranger, stranger_session} = user!("stranger")

      assert {:error, :not_found} =
               Stations.create_enrollment(stranger, stranger_session, ctx.workspace.id, %{})

      assert {:error, :not_found} = Stations.list(stranger, stranger_session, ctx.workspace.id)

      {viewer, viewer_session} = user!("viewer")

      for {user, role} <- [{stranger, "member"}, {viewer, "viewer"}] do
        Repo.insert!(%WorkspaceMembership{
          workspace_id: ctx.workspace.id,
          user_id: user["id"],
          role: role,
          status: "active"
        })
      end

      assert {:ok, []} = Stations.list(stranger, stranger_session, ctx.workspace.id)
      assert {:ok, []} = Stations.list(viewer, viewer_session, ctx.workspace.id)

      assert {:error, :forbidden} =
               Stations.create_enrollment(viewer, viewer_session, ctx.workspace.id, %{})

      assert {:ok, enrollment} =
               Stations.create_enrollment(stranger, stranger_session, ctx.workspace.id, %{})

      station = keypair()
      assert {:ok, _placed} = enroll(station, enrollment["token"])
      assert %Station{enrolled_by: enrolled_by} = SalixRepo.get!(Station, station.id)
      assert enrolled_by == stranger["id"]
    end
  end

  describe "member credential" do
    test "is an EdDSA JWT stations verify with the presence grant keys", ctx do
      station = keypair()
      {:ok, _} = enroll(station, token!(ctx, ctx.workspace))
      device = keypair().id
      # The setup session expires 30 days after it was created, which can be a
      # second before now + 30 days. Outlive the credential so its full TTL holds.
      long =
        Map.put(ctx.session, "expires_at", SystemsClock.system_time(:second) + 31 * 24 * 60 * 60)

      assert {:ok, issued} =
               Stations.issue_credential(ctx.user, long, ctx.workspace.id, %{
                 "device" => device
               })

      assert issued["expires_at"] - issued["issued_at"] == 30 * 24 * 60 * 60
      assert issued["relay_urls"] == ["https://relay.comma.test"]

      [head, body, sig] = String.split(issued["credential"], ".")
      header = head |> Base.url_decode64!(padding: false) |> Jason.decode!()
      claims = body |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert %{"alg" => "EdDSA", "typ" => "comma-member+jwt", "kid" => kid} = header
      {:ok, state, _} = Stations.presence_state(station.id)
      jwk = Enum.find(state["grant_keys"]["keys"], &(&1["kid"] == kid))
      public = Base.url_decode64!(jwk["x"], padding: false)

      assert :crypto.verify(
               :eddsa,
               :none,
               head <> "." <> body,
               Base.url_decode64!(sig, padding: false),
               [
                 public,
                 :ed25519
               ]
             )

      assert claims["iss"] == "comma"
      assert claims["sub"] == ctx.user["id"]
      assert claims["email"] == ctx.user["email"]
      # The credential is for the Group the station holds as its workspace.
      assert claims["ws"] == ctx.workspace.salix_group_id
      assert claims["ws"] == state["workspace"]
      assert claims["role"] == "owner"
      assert claims["device"] == device
      assert claims["sid"] == ctx.session["id"]
      # 30 days, but never past the Auth Session that asked for it.
      assert claims["exp"] == claims["iat"] + 30 * 24 * 60 * 60
      short = Map.put(ctx.session, "expires_at", SystemsClock.system_time(:second) + 3600)

      assert {:ok, %{"expires_at" => expires_at}} =
               Stations.issue_credential(ctx.user, short, ctx.workspace.id, %{"device" => device})

      assert expires_at == short["expires_at"]

      assert {:error, :invalid_device} =
               Stations.issue_credential(ctx.user, ctx.session, ctx.workspace.id, %{
                 "device" => "x"
               })
    end

    test "logout and session revocation become sid revocations the stations are told", ctx do
      station = keypair()
      {:ok, _} = enroll(station, token!(ctx, ctx.workspace))
      Events.subscribe(Events.group_topic(ctx.workspace.salix_group_id))

      revocations = fn ->
        Revocations.list(ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id)
      end

      :ok = Accounts.revoke_session_token(ctx.session["token"])
      sid = ctx.session["id"]
      assert_received {:comma_station_ws, :revoke, %{"kind" => "sid", "id" => ^sid}}
      assert [%{"kind" => "sid", "id" => ^sid, "at" => at}] = revocations.()
      assert at >= SystemsClock.system_time(:second) - 5
      assert {:ok, %{"revocations" => [%{"id" => ^sid}]}, _} = Stations.presence_state(station.id)

      {:ok, second} = Accounts.create_session(ctx.user["id"])
      :ok = Accounts.revoke_session(ctx.user["id"], second["id"])
      {:ok, third} = Accounts.create_session(ctx.user["id"])
      {:ok, 1} = Accounts.revoke_all_sessions(ctx.user["id"])

      ids = revocations.() |> Enum.map(& &1["id"]) |> MapSet.new()
      assert MapSet.equal?(ids, MapSet.new([sid, second["id"], third["id"]]))
      # Comma's own table takes no row.
      assert Repo.aggregate(Comma.Stations.Revocations, :count) == 0
    end
  end

  test "a removed station is told station_removed and leaves the roster", ctx do
    station = keypair()
    {:ok, _} = enroll(station, token!(ctx, ctx.workspace))
    assert {:ok, %{"peers" => [%{"id" => _}]}, _} = Stations.presence_state(station.id)

    assert :ok = Stations.remove(ctx.user, ctx.session, ctx.workspace.id, station.id)
    assert {:error, :station_removed} = Stations.active_station(station.id)
    assert {:error, :station_removed} = Stations.presence_state(station.id)

    assert {:error, :not_found} =
             Stations.remove(ctx.user, ctx.session, ctx.workspace.id, station.id)

    # A new token takes a removed station back.
    assert {:ok, _} = enroll(station, token!(ctx, ctx.workspace))
    assert {:ok, _} = Stations.active_station(station.id)
  end

  describe "a Workspace that is not active" do
    for status <- ~w(suspended deleted) do
      test "#{status}: its stations are refused as removed ones are", ctx do
        station = keypair()
        cloud = keypair()
        tenant = ctx.workspace.salix_tenant_id
        group = ctx.workspace.salix_group_id
        {:ok, _} = enroll(station, token!(ctx, ctx.workspace))
        {:ok, _} = Stations.admit_cloud_station(tenant, group, cloud.id, nil, nil)
        assert {:ok, _} = Stations.active_station(station.id)

        Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
          set: [status: unquote(status)]
        )

        for id <- [station.id, cloud.id] do
          assert {:error, :station_removed} = Stations.active_station(id)
          assert {:error, :station_removed} = Stations.presence_state(id)
        end

        assert Stations.workspace_members_by_email(tenant, group, [ctx.user["email"]]) == nil

        # The control plane places no Cloud VM station there either.
        assert {:error, :not_found} =
                 Stations.admit_cloud_station(tenant, group, keypair().id, nil, nil)

        assert {:error, :not_found} =
                 Stations.admit_cloud_station(tenant, group, cloud.id, cloud.id, nil)

        # The rows stay: an active Workspace has its stations again.
        Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
          set: [status: "active"]
        )

        assert {:ok, %Station{}} = Stations.active_station(station.id)
        assert {:ok, _state, _row} = Stations.presence_state(cloud.id)
      end
    end
  end

  describe "Cloud VM stations" do
    test "the control plane places its Cloud VM's station in the Group's Workspace", ctx do
      station = keypair()
      tenant = ctx.workspace.salix_tenant_id
      group = ctx.workspace.salix_group_id

      assert {:ok, place} = Stations.admit_cloud_station(tenant, group, station.id, nil, "0.2.0")

      assert %{
               "origin" => @origin,
               "provider" => "comma",
               "workspace_name" => "Team",
               "name" => "Cloud VM",
               "relay_urls" => ["https://relay.comma.test"],
               "grant_keys" => %{"keys" => [_ | _]},
               "gateway_keys" => [_]
             } = place

      assert place["workspace"] == group
      assert place["station"] == station.id

      assert {:ok, [%Station{kind: "cloud_vm", enrolled_by: nil, version: "0.2.0"} = row]} =
               Stations.list(ctx.user, ctx.session, ctx.workspace.id)

      # The same key again keeps the station as it is.
      assert {:ok, ^place} =
               Stations.admit_cloud_station(tenant, group, station.id, station.id, "0.2.1")

      assert SalixRepo.get!(Station, station.id).enrolled_at == row.enrolled_at
      assert {:ok, %{"peers" => [%{"id" => _}]}, _} = Stations.presence_state(station.id)

      assert {:error, :invalid_request} =
               Stations.admit_cloud_station(tenant, group, "nothex", nil, nil)
    end

    test "a new key replaces the previous Cloud VM station, never a member's", ctx do
      first = keypair()
      tenant = ctx.workspace.salix_tenant_id
      group = ctx.workspace.salix_group_id
      {:ok, _} = Stations.admit_cloud_station(tenant, group, first.id, nil, nil)
      Events.subscribe(Events.station_topic(first.id))

      second = keypair()
      assert {:ok, _} = Stations.admit_cloud_station(tenant, group, second.id, first.id, nil)
      assert_received {:comma_station, :removed}
      assert {:error, :station_removed} = Stations.active_station(first.id)

      assert {:ok, [%Station{id: id}]} = Stations.list(ctx.user, ctx.session, ctx.workspace.id)
      assert id == second.id

      # A station a member enrolled is not the Cloud VM's, so it stays.
      enrolled = keypair()
      {:ok, _} = enroll(enrolled, token!(ctx, ctx.workspace))

      assert {:ok, _} =
               Stations.admit_cloud_station(tenant, group, keypair().id, enrolled.id, nil)

      assert {:ok, _} = Stations.active_station(enrolled.id)
    end

    test "a key placed in another Workspace is refused and not moved", ctx do
      station = keypair()
      other = workspace!(ctx.user, "Other")
      {:ok, _} = enroll(station, token!(ctx, other))

      assert {:error, :station_elsewhere} =
               Stations.admit_cloud_station(
                 ctx.workspace.salix_tenant_id,
                 ctx.workspace.salix_group_id,
                 station.id,
                 nil,
                 nil
               )

      assert SalixRepo.get!(Station, station.id).group_id == other.salix_group_id
      assert {:ok, []} = Stations.list(ctx.user, ctx.session, ctx.workspace.id)
    end
  end

  describe "notices" do
    setup ctx do
      prior = SystemsRuntime.get_env(:comma_core, :apns)
      {_, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:ec, "P-256"}))

      SystemsRuntime.put_env(:comma_core, :apns,
        profiles: %{
          "sandbox" => [
            team_id: "TESTTEAM",
            key_id: "TESTKEY",
            private_key: pem,
            allowed_bundle_ids: ["surf.comma.ios"]
          ]
        },
        plug: {Req.Test, __MODULE__}
      )

      unless SystemsRuntime.Proc.whereis(APNs.ProviderToken),
        do: start_supervised!(APNs.ProviderToken)

      on_exit(fn -> SystemsRuntime.put_env(:comma_core, :apns, prior) end)

      test = SystemsRuntime.Proc.self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        SystemsRuntime.Proc.send(test, {:apns, List.last(conn.path_info), Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      station = keypair()
      {:ok, _} = enroll(station, token!(ctx, ctx.workspace))
      %{station: station}
    end

    test "go to members' device addresses by email, once per address", ctx do
      target!(ctx.session, ctx.workspace, "owner-token")
      {outsider, outsider_session} = user!("outsider")
      outsider_ws = workspace!(outsider, "Elsewhere")
      target!(outsider_session, outsider_ws, "outsider-token")

      body = %{
        "notices" => [
          %{
            "to" => [
              String.upcase(ctx.user["email"]),
              ctx.user["email"],
              outsider["email"],
              "nobody@example.test"
            ],
            "kind" => "block",
            "session" => "s1",
            "thread" => 7,
            "title" => "Deploy",
            "by" => "",
            "text" => "Pick a region",
            "at" => 1
          },
          %{"to" => ["x"], "kind" => "BAD", "session" => "s", "text" => "skipped"}
        ]
      }

      assert {:ok, %{}} = Notices.deliver(ctx.station.id, body)
      settle_receive({:apns, "owner-token", payload})

      assert payload["aps"]["alert"] == %{
               "title" => "Deploy",
               "body" => "Needs you · Pick a region"
             }

      assert payload["type"] == "station_notice"
      assert payload["station_id"] == ctx.station.id
      assert payload["workspace_id"] == ctx.workspace.id
      assert payload["station_session"] == "s1"
      settle_refute_receive({:apns, _, _})
    end

    test "a removed station cannot push", ctx do
      target!(ctx.session, ctx.workspace, "owner-token")
      :ok = Stations.remove(ctx.user, ctx.session, ctx.workspace.id, ctx.station.id)

      notice = %{"to" => [ctx.user["email"]], "kind" => "done", "session" => "s", "text" => "hi"}

      assert {:error, :station_removed} =
               Notices.deliver(ctx.station.id, %{"notices" => [notice]})

      settle_refute_receive({:apns, _, _})
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp user!(label) do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "#{label}-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    {user, session}
  end

  defp workspace!(user, name) do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_station_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "station-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "station-test",
        name: name,
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

  defp target!(session, workspace, token) do
    Repo.insert!(%Target{
      auth_session_id: session["id"],
      kind: "device",
      token: token,
      environment: "sandbox",
      bundle_id: "surf.comma.ios",
      workspace_id: workspace.id,
      group_id: workspace.salix_group_id,
      expires_at: DateTime.add(SystemsClock.utc_now(), 3600)
    })
  end

  defp roster(workspace), do: Roster.roster(workspace.salix_tenant_id, workspace.salix_group_id)

  defp token!(ctx, workspace) do
    {:ok, %{"token" => token}} =
      Stations.create_enrollment(ctx.user, ctx.session, workspace.id, %{})

    token
  end

  defp keypair do
    {public, seed} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    %{id: Base.encode16(public, case: :lower), seed: seed}
  end

  defp sign(station, message),
    do:
      SystemsRuntime.Proc.sign(:eddsa, :none, message, [station.seed, :ed25519])
      |> Base.encode16(case: :lower)

  defp enroll(station, token) do
    Stations.enroll(%{
      "token" => token,
      "station" => station.id,
      "signature" => sign(station, "comma-station-enroll-v1:#{@origin}:#{token}:#{station.id}"),
      "version" => "0.1.7"
    })
  end
end
