defmodule SalixStore.StationsTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{Repo, Stations}
  alias SalixStore.Stations.{Revocations, SigningKeys, Workspaces}

  @tenant "tnt_roster"
  @group "grp_roster_a"
  @other_group "grp_roster_b"

  setup do
    Repo.query!(
      "TRUNCATE salix_stations, salix_station_signing_keys, salix_station_revocations, salix_station_workspaces"
    )

    :ok
  end

  defp id(n), do: Base.encode16(<<n::256>>, case: :lower)

  defp roster_ids(group \\ @group), do: Enum.map(Stations.roster(@tenant, group), & &1.id)

  describe "admitting device stations" do
    test "admitting a station to another Group moves it there" do
      assert {:ok, station, nil} =
               Stations.admit(@tenant, @group, id(1), %{
                 name: "  Ada's   Mac ",
                 version: "0.1.7",
                 enrolled_by: "u1"
               })

      assert station.name == "Ada's Mac"
      assert station.kind == "device"

      assert {:ok, moved, {@tenant, @group}} =
               Stations.admit(@tenant, @other_group, id(1), %{enrolled_by: "u2"})

      assert moved.name == "Station"
      assert moved.enrolled_by == "u2"
      assert roster_ids() == []
      assert roster_ids(@other_group) == [id(1)]
    end

    test "a removed station comes back afresh" do
      {:ok, _station, nil} = Stations.admit(@tenant, @group, id(1), %{name: "Old"})
      assert :ok = Stations.remove(@tenant, @group, id(1))
      assert {:error, :station_removed} = Stations.active_station(id(1))
      assert {:error, :not_found} = Stations.remove(@tenant, @group, id(1))

      assert {:ok, station, nil} = Stations.admit(@tenant, @group, id(1), %{name: "New"})
      assert station.name == "New"
      assert is_nil(station.removed_at)
    end
  end

  describe "the Cloud VM station" do
    test "a new VM key replaces the Group's previous Cloud VM station, never a device" do
      {:ok, _device, nil} = Stations.admit(@tenant, @group, id(1), %{enrolled_by: "u1"})

      assert {:ok, vm, nil} = Stations.place_cloud_station(@tenant, @group, id(2), nil, "1.0")
      assert vm.kind == "cloud_vm"
      assert vm.name == "Cloud VM"
      assert is_nil(vm.enrolled_by)

      assert {:ok, _vm, replaced} =
               Stations.place_cloud_station(@tenant, @group, id(3), id(2), nil)

      assert replaced == id(2)
      assert roster_ids() == [id(1), id(3)]

      # A device is never taken for the previous Cloud VM station.
      assert {:ok, _vm, nil} = Stations.place_cloud_station(@tenant, @group, id(4), id(1), nil)
      assert id(1) in roster_ids()
    end

    test "a key placed in another Group is refused and stays" do
      {:ok, _station, nil} = Stations.admit(@tenant, @other_group, id(1))

      assert {:error, :station_elsewhere} =
               Stations.place_cloud_station(@tenant, @group, id(1), nil, nil)

      assert roster_ids(@other_group) == [id(1)]
    end
  end

  test "rename, presence and the state frame" do
    {:ok, _station, nil} = Stations.admit(@tenant, @group, id(1), %{name: "A"})
    {:ok, _station, nil} = Stations.admit(@tenant, @group, id(2), %{name: "B"})

    assert {:ok, renamed} = Stations.rename(@tenant, @group, id(2), "Build box")
    assert renamed.name == "Build box"
    assert {:error, :not_found} = Stations.rename(@tenant, @other_group, id(2), "X")

    assert :ok = Stations.connected(id(1), "0.3.0")
    assert {:ok, %{version: "0.3.0", last_seen_at: %DateTime{}}} = Stations.active_station(id(1))

    [revocation] = Revocations.revoke([{@tenant, @group}], "sid", "session-1")

    assert {:ok, frame, station} =
             Stations.presence_state(id(1), %{"origin" => "https://salix.test"})

    assert station.id == id(1)
    assert frame["type"] == "state"
    assert frame["origin"] == "https://salix.test"
    # The Group is the workspace a station is in; no product names this one.
    assert {frame["workspace"], frame["workspace_name"]} == {@group, ""}

    assert frame["peers"] == [
             %{"id" => id(1), "name" => "A", "version" => "0.3.0"},
             %{"id" => id(2), "name" => "Build box", "version" => nil}
           ]

    assert [%{"kid" => _}] = frame["grant_keys"]["keys"]
    assert frame["revocations"] == [elem(revocation, 1)]
  end

  describe "members, as the product that owns the Group answers" do
    defmodule Product do
      @behaviour SalixStore.StationMembers

      @impl true
      def role("tnt_roster", "grp_roster_a", "u_admin"), do: {:ok, "admin"}
      def role("tnt_roster", "grp_roster_a", "u_member"), do: {:ok, "user"}
      def role(_tenant_id, _group_id, _user_id), do: :none

      @impl true
      def manager_role?(role), do: role == "admin"

      @impl true
      def workspace_name("tnt_roster", "grp_roster_a"), do: {:ok, "Roster project"}
      def workspace_name(_tenant_id, _group_id), do: :none

      # Its workspace is in use unless the test says it is not.
      @impl true
      def workspace_active?("tnt_roster", "grp_roster_a"),
        do: not SystemsRuntime.get_env(:salix_store, :test_roster_project_archived, false)

      def workspace_active?(_tenant_id, _group_id), do: :none
    end

    setup do
      prior = SystemsRuntime.get_env(:salix_store, :station_members)
      SystemsRuntime.put_env(:salix_store, :station_members, [Product])

      on_exit(fn ->
        if prior,
          do: SystemsRuntime.put_env(:salix_store, :station_members, prior),
          else: SystemsRuntime.delete_env(:salix_store, :station_members)
      end)
    end

    defp claims(credential) do
      [_head, body, _signature] = String.split(credential, ".")
      body |> Base.url_decode64!(padding: false) |> Jason.decode!()
    end

    test "a station is told its Group id as workspace, with the product's name for it" do
      {:ok, station, nil} = Stations.admit(@tenant, @group, id(1), %{name: "A"})

      assert {:ok, %{"workspace" => @group, "workspace_name" => "Roster project"} = place} =
               Stations.placement(station)

      assert %{"station" => station_id, "name" => "A", "grant_keys" => %{"keys" => [_]}} = place
      assert station_id == id(1)

      assert {:ok, %{"workspace" => @group, "workspace_name" => "Roster project"}, _station} =
               Stations.presence_state(id(1))
    end

    test "a station is served only while the product has the Group's workspace in use" do
      {:ok, _station, nil} = Stations.admit(@tenant, @group, id(1))
      {:ok, _station, nil} = Stations.admit(@tenant, @other_group, id(2))
      on_exit(fn -> SystemsRuntime.delete_env(:salix_store, :test_roster_project_archived) end)

      assert SalixStore.StationMembers.workspace_active?(@tenant, @group)
      assert {:ok, _station} = Stations.active_station(id(1))

      SystemsRuntime.put_env(:salix_store, :test_roster_project_archived, true)
      refute SalixStore.StationMembers.workspace_active?(@tenant, @group)
      assert {:error, :station_removed} = Stations.active_station(id(1))
      assert {:error, :station_removed} = Stations.presence_state(id(1))
      # The row stays in the roster, for when the workspace is in use again.
      assert roster_ids() == [id(1)]

      # A Group no product owns is refused by no one.
      assert SalixStore.StationMembers.workspace_active?(@tenant, @other_group)
      assert {:ok, _station} = Stations.active_station(id(2))

      SystemsRuntime.delete_env(:salix_store, :test_roster_project_archived)
      assert {:ok, _station} = Stations.active_station(id(1))
    end

    test "the workspace id is the one Salix keeps for the Group; a rename tells the id before too" do
      {:ok, station, nil} = Stations.admit(@tenant, @group, id(1), %{name: "A"})
      session = %{"id" => "ses_1", "expires_at" => SystemsClock.system_time(:second) + 3600}
      user = %{"id" => "u_member", "email" => "m@x.test", "name" => "M"}
      ws = fn -> Stations.issue_credential(@tenant, @group, user, id(9), session) end

      # No row: the Group id, and no id before it.
      assert Workspaces.told(@tenant, @group) == %{id: @group, was: []}
      assert {:ok, %{"workspace" => @group, "workspace_was" => []}} = Stations.placement(station)

      # A Group told another id (a Comma Workspace's, as its stations were enrolled).
      assert {:ok, %{id: "wsp_roster", was: [@group]}} =
               Workspaces.rename(@tenant, @group, "wsp_roster")

      assert Stations.workspace_id(@tenant, @group) == "wsp_roster"

      assert {:ok, %{"workspace" => "wsp_roster", "workspace_was" => [@group]}, _station} =
               Stations.presence_state(id(1))

      assert {:ok, %{"workspace" => "wsp_roster", "workspace_was" => [@group]}} =
               Stations.placement(station)

      assert {:ok, %{"credential" => credential}} = ws.()
      assert %{"ws" => "wsp_roster"} = claims(credential)

      # The same id again changes nothing.
      assert {:ok, %{id: "wsp_roster", was: [@group]}} =
               Workspaces.rename(@tenant, @group, "wsp_roster")

      # Another rename: the ids before are only added to, the first one stays first.
      assert {:ok, %{id: "wsp_later", was: [@group, "wsp_roster"]}} =
               Workspaces.rename(@tenant, @group, "wsp_later")

      assert {:ok, %{"workspace" => "wsp_later", "workspace_was" => [@group, "wsp_roster"]},
              _station} = Stations.presence_state(id(1))

      assert {:ok, %{"credential" => credential}} = ws.()
      assert %{"ws" => "wsp_later"} = claims(credential)

      # An id names one Group's workspace; another Group is told its own id still.
      assert {:error, :workspace_id_taken} =
               Workspaces.rename(@tenant, @other_group, "wsp_later")

      assert Workspaces.told(@tenant, @other_group) == %{id: @other_group, was: []}
    end

    test "a member's credential carries the Group id and the product's role" do
      session = %{"id" => "ses_1", "expires_at" => SystemsClock.system_time(:second) + 3600}
      user = %{"id" => "u_member", "email" => "m@x.test", "name" => "M"}

      assert {:ok, %{"credential" => credential, "expires_at" => expires_at}} =
               Stations.issue_credential(@tenant, @group, user, id(9), session)

      assert expires_at == session["expires_at"]

      assert %{
               "iss" => "comma",
               "ws" => @group,
               "sub" => "u_member",
               "role" => "user",
               "sid" => "ses_1",
               "device" => device
             } = claims(credential)

      assert device == id(9)

      assert {:error, :invalid_device} =
               Stations.issue_credential(@tenant, @group, user, "x", session)

      # No role in the Group, or a Group the product does not own: no credential.
      stranger = %{"id" => "u_stranger", "email" => "s@x.test", "name" => "S"}

      assert {:error, :not_found} =
               Stations.issue_credential(@tenant, @group, stranger, id(9), session)

      assert {:error, :not_found} =
               Stations.issue_credential(@tenant, @other_group, user, id(9), session)
    end
  end

  describe "signing keys" do
    test "the first signer is provisioned; rotation publishes before it signs" do
      assert {:ok, {seed, kid}} = SigningKeys.signer()
      assert byte_size(seed) == 32
      assert SigningKeys.signer() == {:ok, {seed, kid}}

      pending = SigningKeys.prepublish!(kid: "next")
      assert Enum.map(SigningKeys.grant_keys()["keys"], & &1["kid"]) == [kid, pending]

      assert ^pending = SigningKeys.activate!(prepublish_seconds: 0)
      assert {:ok, {_seed, ^pending}} = SigningKeys.signer()

      assert [%{kid: ^kid, status: "verify_only"}, %{kid: ^pending, status: "signing"}] =
               SigningKeys.list()

      fresh = SigningKeys.rotate_compromised!(kid: "fresh")
      assert Enum.map(SigningKeys.list(), & &1.kid) == [kid, fresh]
    end
  end

  test "a revocation is published on the PubSub this application runs" do
    alias SalixStore.Stations.Events

    # No product's web application is needed: a node that only writes the
    # roster (BridgeForTeams removing a member) publishes too.
    assert is_pid(SystemsRuntime.Proc.whereis(Events.pubsub()))
    :ok = Events.subscribe(Events.group_topic(@group))

    revocations =
      Revocations.revoke([{@tenant, @group}, {@tenant, @other_group}], "sub", "user-1")

    Events.publish(revocations)
    # Told once, for the Group subscribed to; the publisher sends before it returns.
    assert_received {:comma_station_ws, :revoke, %{"kind" => "sub", "id" => "user-1", "at" => _}}
    refute_received {:comma_station_ws, :revoke, _}
  end

  test "revocations are told per Group, and only the Groups named" do
    [{{@tenant, @group}, sub}] = Revocations.revoke([{@tenant, @group}], "sub", "user-1")
    assert Revocations.list(@tenant, @group) == [sub]
    assert Revocations.list(@tenant, @other_group) == []

    # Told for 31 days; an older row is pruned by the next revocation there.
    old = SystemsClock.system_time(:second) - 31 * 24 * 60 * 60 - 1

    Repo.insert_all(Revocations, [
      %{tenant_id: @tenant, group_id: @group, kind: "sid", subject_id: "old", at: old}
    ])

    assert Revocations.list(@tenant, @group) == [sub]
    Revocations.revoke([{@tenant, @group}], "sid", "session-2")
    assert Repo.aggregate(Revocations, :count) == 2
  end
end
