defmodule Comma.Stations.SalixCopyTest do
  use Comma.DataCase, async: false

  alias Comma.Data.{User, Workspace, WorkspaceMembership}
  alias Comma.Stations.{Members, Revocations, SalixCopy, SigningKeys, Station}
  alias SalixStore.Repo, as: SalixRepo
  alias SalixStore.StationMembers
  alias SalixStore.Stations, as: SalixStations

  @kek String.duplicate("k", 32)

  setup do
    SalixStore.RepoTestSetup.ensure!()

    SalixRepo.query!(
      "TRUNCATE salix_stations, salix_station_signing_keys, salix_station_revocations, salix_station_workspaces"
    )

    phase!(nil)
    Comma.Stations.Window.forget()

    on_exit(fn ->
      phase!("complete")
      Comma.Stations.Window.forget()
    end)

    salix = SystemsRuntime.get_env(:salix_store, :stations)
    SystemsRuntime.put_env(:salix_store, :stations, kek: @kek)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :stations, salix || []) end)

    user!("usr_copy_owner")
    user!("usr_copy_member")
    a = workspace!("a", "usr_copy_owner")
    b = workspace!("b", "usr_copy_owner")
    member!(a, "usr_copy_member", "member")
    %{a: a, b: b}
  end

  defp id(n), do: Base.encode16(<<n::256>>, case: :lower)

  # Salix's tables are outside this test's transaction, the marker too: the
  # baseline says the move is complete, and each test here starts before it.
  defp phase!(nil),
    do: SalixRepo.query!("DELETE FROM salix_cutover_markers WHERE name = 'station_roster_v1'")

  defp phase!(phase) do
    SalixRepo.query!(
      """
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('station_roster_v1', TIMESTAMPTZ '2026-01-01 00:00:00Z', $1)
      ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence
      """,
      [%{"phase" => phase}]
    )
  end

  defp user!(id), do: Repo.insert!(%User{id: id, normalized_email: "#{id}@example.test"})

  defp workspace!(name, owner) do
    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_copy_" <> name,
        owner_user_id: owner,
        salix_tenant_id: "tnt_copy_" <> name,
        salix_group_id: "grp_copy_" <> name,
        group_generation: "copy-test",
        salix_router_agent_id: "agt_copy_router_" <> name,
        salix_worker_agent_id: "agt_copy_worker_" <> name,
        billing_owner_id: "copy-test",
        name: name,
        status: "active"
      })

    member!(workspace, owner, "owner")
    workspace
  end

  defp member!(workspace, user_id, role) do
    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user_id,
      role: role,
      status: "active"
    })
  end

  defp station!(n, workspace, attrs) do
    now = SystemsClock.utc_now()

    Repo.insert!(
      struct(
        Station,
        Map.merge(
          %{
            id: id(n),
            workspace_id: workspace.id,
            name: "Station #{n}",
            version: "0.1.#{n}",
            enrolled_by: "usr_copy_owner",
            enrolled_at: now,
            last_seen_at: now
          },
          attrs
        )
      )
    )
  end

  defp salix_rows do
    SalixRepo.all(from(s in SalixStore.Stations.Station, order_by: s.id))
  end

  test "copies the roster to each Workspace's Group, and a second pass changes nothing",
       %{a: a, b: b} do
    station!(1, a, %{})
    station!(2, a, %{enrolled_by: nil, name: "Cloud VM"})
    station!(3, a, %{removed_at: SystemsClock.utc_now()})
    station!(4, b, %{})
    comma_before = Repo.all(from(s in Station, order_by: s.id))

    assert {:ok, %{stations: 4}} = SalixCopy.run(Repo)
    copied = salix_rows()

    assert Enum.map(SalixStations.roster("tnt_copy_a", "grp_copy_a"), &{&1.id, &1.kind}) ==
             [{id(1), "device"}, {id(2), "cloud_vm"}]

    assert Enum.map(SalixStations.roster("tnt_copy_b", "grp_copy_b"), & &1.id) == [id(4)]

    for {comma, salix} <- Enum.zip(comma_before, copied) do
      assert Map.take(
               salix,
               [:id, :name, :version, :enrolled_by, :enrolled_at] ++
                 [:removed_at, :last_seen_at, :inserted_at, :updated_at]
             ) ==
               Map.take(
                 comma,
                 [:id, :name, :version, :enrolled_by, :enrolled_at] ++
                   [:removed_at, :last_seen_at, :inserted_at, :updated_at]
               )
    end

    assert {:ok, %{stations: 4}} = SalixCopy.run(Repo)
    assert salix_rows() == copied

    # A later pass (the one of the release that moves the readers) catches up with Comma.
    Repo.update_all(from(s in Station, where: s.id == ^id(1)), set: [name: "Renamed"])
    assert {:ok, _} = SalixCopy.run(Repo)
    assert {:ok, %{name: "Renamed"}} = SalixStations.active_station(id(1))
    assert Repo.aggregate(Station, :count) == 4
  end

  # Comma's own tables are written by no code now: the rows a deployment
  # still holds are made here as its servers made them.
  defp comma_keys! do
    {:ok, {seed, kid}} = SalixStore.Stations.SigningKeys.signer()
    pending = SalixStore.Stations.SigningKeys.prepublish!(kid: "comma-station-next")
    keys = SalixStore.Stations.SigningKeys.grant_keys()
    list = SalixStore.Stations.SigningKeys.list()

    rows =
      SalixRepo.all(SalixStore.Stations.SigningKeys.Key)
      |> Enum.map(&(&1 |> Map.from_struct() |> Map.drop([:__meta__])))

    Repo.insert_all(SigningKeys.Key, rows)
    SalixRepo.delete_all(SalixStore.Stations.SigningKeys.Key)
    %{seed: seed, kid: kid, pending: pending, keys: keys, list: list}
  end

  defp comma_revocation!(workspace, kind, id, at) do
    Repo.insert_all(Revocations, [
      %{workspace_id: workspace.id, kind: kind, subject_id: id, at: at}
    ])

    %{"kind" => kind, "id" => id, "at" => at}
  end

  test "the signing key set is the same before and after, kid and key material" do
    comma = comma_keys!()

    # A key only Salix had is not Comma's; the copy leaves Comma's set.
    SalixStore.Stations.SigningKeys.prepublish!(kid: "salix-only")

    assert {:ok, %{signing_keys: 2}} = SalixCopy.run(Repo)
    assert SalixStore.Stations.SigningKeys.grant_keys() == comma.keys
    assert SalixStore.Stations.SigningKeys.list() == comma.list
    assert SalixStore.Stations.SigningKeys.signer() == {:ok, {comma.seed, comma.kid}}

    assert {:ok, _} = SalixCopy.run(Repo)
    assert SalixStore.Stations.SigningKeys.grant_keys() == comma.keys
    assert Enum.map(comma.list, & &1.kid) |> Enum.sort() == Enum.sort([comma.kid, comma.pending])
  end

  test "revocations move from each Workspace to its Group", %{a: a, b: b} do
    now = SystemsClock.system_time(:second)
    member = comma_revocation!(a, "sub", "usr_copy_member", now)
    comma_revocation!(b, "sub", "usr_copy_member", now)
    gone = comma_revocation!(a, "sid", "ses_gone", now - 5)

    assert {:ok, %{revocations: 3}} = SalixCopy.run(Repo)

    assert SalixStore.Stations.Revocations.list("tnt_copy_a", "grp_copy_a") == [member, gone]
    assert length(SalixStore.Stations.Revocations.list("tnt_copy_b", "grp_copy_b")) == 1

    assert {:ok, %{revocations: 3}} = SalixCopy.run(Repo)
    assert SalixRepo.aggregate(SalixStore.Stations.Revocations, :count) == 3
  end

  describe "the window, while servers of the release before still write Comma's tables" do
    alias Comma.Stations
    alias Comma.Stations.Window
    alias SalixStore.Stations.Workspaces

    setup do
      prior = SystemsRuntime.get_env(:salix_store, :station_members)
      SystemsRuntime.put_env(:salix_store, :station_members, [Members])
      on_exit(fn -> SystemsRuntime.put_env(:salix_store, :station_members, prior || []) end)
      :ok
    end

    # Times a row says, in order: `at(1)` is before `at(2)`.
    defp at(n), do: DateTime.add(~U[2026-10-01 00:00:00.000000Z], n, :second)

    defp open!(a) do
      station!(1, a, %{enrolled_at: at(1)})
      comma = comma_keys!()
      assert {:ok, %{stations: 1, workspaces: 1}} = SalixCopy.open_window(Repo)
      assert SalixCopy.phase() == {:ok, :window}
      comma
    end

    test "opening it makes Salix's rows Comma's and tells each Group with stations its Workspace id",
         %{a: a, b: b} do
      station!(1, a, %{enrolled_at: at(1)})
      station!(2, b, %{enrolled_at: at(1), removed_at: at(2)})
      comma = comma_keys!()
      # A copy from the release before, since renamed there.
      assert {:ok, %{stations: 2}} = SalixCopy.run(Repo)
      assert SalixCopy.phase() == {:ok, :before}
      Repo.update_all(from(s in Station, where: s.id == ^id(1)), set: [name: "Renamed since"])

      assert {:ok, %{stations: 2, signing_keys: 2, workspaces: 1}} = SalixCopy.open_window(Repo)
      assert {:ok, %{name: "Renamed since"}} = SalixStations.active_station(id(1))
      assert SalixStore.Stations.SigningKeys.grant_keys() == comma.keys

      # The station enrolled with the Workspace id is told it still, and so is a credential's `ws`.
      workspace_id = a.id
      assert Workspaces.told("tnt_copy_a", "grp_copy_a") == %{id: workspace_id, was: []}

      assert {:ok, %{"workspace" => ^workspace_id, "workspace_was" => []}, _station} =
               SalixStations.presence_state(id(1))

      session = %{"id" => "ses_copy", "expires_at" => SystemsClock.system_time(:second) + 600}
      user = %{"id" => "usr_copy_owner", "email" => "o@example.test", "name" => ""}

      assert {:ok, %{"credential" => credential}} =
               SalixStations.issue_credential("tnt_copy_a", "grp_copy_a", user, id(9), session)

      [_head, body, _signature] = String.split(credential, ".")

      assert %{"ws" => ^workspace_id} =
               body |> Base.url_decode64!(padding: false) |> Jason.decode!()

      # A Workspace with no station left is told its Group id, as a new Group is.
      assert Workspaces.told("tnt_copy_b", "grp_copy_b") == %{id: "grp_copy_b", was: []}
    end

    test "a station enrolled through a server of the release before is admitted here, and is in Salix",
         %{a: a, b: b} do
      open!(a)
      # Only in Comma's table: enrolled after the window opened, in a Workspace that had none.
      station!(2, b, %{enrolled_at: at(5), name: "Enrolled there"})
      assert {:error, :station_removed} = SalixStations.active_station(id(2))

      assert {:ok, %{name: "Enrolled there", group_id: "grp_copy_b"}} =
               Stations.active_station(id(2))

      assert {:ok, %{id: _}} = SalixStations.active_station(id(2))
      # It was told the Workspace id there, and is told it here.
      workspace_id = b.id

      assert {:ok, %{"workspace" => ^workspace_id}, _station} = Stations.presence_state(id(2))
      # A client's list reads it too, before the station ever connects here.
      station!(3, b, %{enrolled_at: at(6)})
      :ok = Window.workspace(b)
      assert Enum.map(SalixStations.roster("tnt_copy_b", "grp_copy_b"), & &1.id) == [id(2), id(3)]
    end

    test "a station removed through a server of the release before is refused here and removed in Salix",
         %{a: a} do
      open!(a)
      assert {:ok, _station} = Stations.active_station(id(1))

      Repo.update_all(from(s in Station, where: s.id == ^id(1)),
        set: [removed_at: at(9), updated_at: at(9)]
      )

      assert {:error, :station_removed} = Stations.active_station(id(1))
      assert {:error, :station_removed} = Stations.presence_state(id(1))
      assert %{removed_at: removed_at} = SalixRepo.get!(SalixStore.Stations.Station, id(1))
      assert removed_at == at(9)
    end

    test "what a server of this release did is not undone by what Comma's row still says",
         %{a: a} do
      open!(a)
      station!(2, a, %{enrolled_at: at(1)})
      :ok = Window.workspace(a)
      assert {:ok, _station} = SalixStations.rename("tnt_copy_a", "grp_copy_a", id(1), "Here")
      assert :ok = SalixStations.remove("tnt_copy_a", "grp_copy_a", id(2))

      # The removed station connects to a server of the release before, which
      # still has it: Comma's row is touched after Salix's removal.
      later = DateTime.add(SystemsClock.utc_now(), 60, :second)

      Repo.update_all(from(s in Station, where: s.id == ^id(2)),
        set: [last_seen_at: later, updated_at: later]
      )

      assert {:error, :station_removed} = Stations.active_station(id(2))
      assert {:ok, %{name: "Here"}} = Stations.active_station(id(1))
      assert {:ok, _merged} = SalixCopy.open_window(Repo)
      assert {:error, :station_removed} = SalixStations.active_station(id(2))
      assert {:ok, %{name: "Here"}} = SalixStations.active_station(id(1))

      # Taken back there with a new token: a later enrollment than Salix's row.
      taken_back = DateTime.add(SystemsClock.utc_now(), 120, :second)

      Repo.update_all(from(s in Station, where: s.id == ^id(2)),
        set: [enrolled_at: taken_back, removed_at: nil, name: "Back"]
      )

      assert {:ok, %{name: "Back"}} = Stations.active_station(id(2))
    end

    test "a revocation written through a server of the release before is in the next state frame here",
         %{a: a} do
      open!(a)
      now = SystemsClock.system_time(:second)

      [{_group, here}] =
        SalixStore.Stations.Revocations.revoke([{"tnt_copy_a", "grp_copy_a"}], "sid", "ses_here")

      there = comma_revocation!(a, "sid", "ses_there", now + 1)
      # One both have keeps the later time.
      comma_revocation!(a, "sid", "ses_here", here["at"] - 100)

      assert {:ok, %{"revocations" => told}, _station} = Stations.presence_state(id(1))
      assert there in told
      assert here in told
      assert SalixStore.Stations.Revocations.list("tnt_copy_a", "grp_copy_a") == told
    end

    test "a signing key made through a server of the release before verifies here; Salix keeps one signer",
         %{a: a} do
      comma = open!(a)
      # A key Salix has no row of: it is taken, to verify with.
      Repo.insert_all(SigningKeys.Key, [
        %{
          kid: "made-there",
          public_key: <<1::256>>,
          private_key_ciphertext: <<2::256>>,
          private_key_iv: <<3::96>>,
          private_key_tag: <<4::128>>,
          status: "verify_only",
          retire_after: DateTime.add(SystemsClock.utc_now(), 3600, :second),
          created_at: at(7),
          updated_at: at(7)
        }
      ])

      assert {:ok, %{"grant_keys" => %{"keys" => keys}}, _station} =
               Stations.presence_state(id(1))

      assert "made-there" in Enum.map(keys, & &1["kid"])
      assert {:ok, {_seed, kid}} = SalixStore.Stations.SigningKeys.signer()
      assert kid == comma.kid
    end

    test "with no key yet, the first signer made there is Salix's signer too", %{a: a} do
      station!(1, a, %{enrolled_at: at(1)})
      assert {:ok, _copied} = SalixCopy.open_window(Repo)
      assert SalixRepo.aggregate(SalixStore.Stations.SigningKeys.Key, :count) == 0
      comma = comma_keys!()

      assert {:ok, %{"grant_keys" => keys}, _station} = Stations.presence_state(id(1))
      assert keys == comma.keys
      assert SalixStore.Stations.SigningKeys.signer() == {:ok, {comma.seed, comma.kid}}
    end

    test "after the rollout the last merge closes it: Comma's tables are read no more",
         %{a: a, b: b} do
      open!(a)
      station!(2, b, %{enrolled_at: at(5)})
      late = comma_revocation!(a, "sid", "ses_late", SystemsClock.system_time(:second))

      assert {:ok, %{stations: 2, revocations: 1}} = SalixCopy.finish(Repo)
      assert SalixCopy.phase() == {:ok, :complete}
      assert {:ok, _station} = SalixStations.active_station(id(2))
      assert SalixStore.Stations.Revocations.list("tnt_copy_a", "grp_copy_a") == [late]
      refute Window.open?()

      # Rows Comma's tables get now (there is no server left to write them) change nothing here.
      station!(3, a, %{enrolled_at: at(8)})
      Repo.update_all(from(s in Station, where: s.id == ^id(1)), set: [removed_at: at(9)])
      comma_revocation!(a, "sid", "ses_ignored", SystemsClock.system_time(:second))

      read =
        comma_reads(fn ->
          assert {:error, :station_removed} = Stations.active_station(id(3))
          assert {:ok, %{"revocations" => [^late]}, _station} = Stations.presence_state(id(1))
          assert :ok = Window.workspace(a)
          assert :ok = Window.group("tnt_copy_a", "grp_copy_a")
          assert Window.workspace_id("grp_copy_a") == nil
        end)

      assert read == []
      assert SalixCopy.finish(Repo) == {:ok, :complete}
      assert SalixCopy.open_window(Repo) == {:ok, :complete}
      assert SalixCopy.run(Repo) == {:ok, :complete}
      assert {:error, :station_removed} = SalixStations.active_station(id(3))
    end

    test "with no row in Comma's tables nothing is copied; the last step still closes the window" do
      SalixStore.Stations.SigningKeys.prepublish!(kid: "salix-only")

      assert SalixCopy.open_window(Repo) == {:ok, %{stations: 0, signing_keys: 0, revocations: 0}}
      assert SalixCopy.phase() == {:ok, :before}
      assert Window.open?()
      assert {:ok, _} = SalixCopy.finish(Repo)
      assert SalixCopy.phase() == {:ok, :complete}
      assert [%{kid: "salix-only"}] = SalixRepo.all(SalixStore.Stations.SigningKeys.Key)
    end

    test "a release rolled back opens the window again", %{a: a} do
      open!(a)
      assert {:ok, _} = SalixCopy.finish(Repo)
      assert :ok = SalixCopy.reopen()
      Window.forget()
      station!(2, a, %{enrolled_at: at(5)})
      assert {:ok, _station} = Stations.active_station(id(2))
    end

    # The tables of Comma's that `run` reads, by its repo's own account (a
    # query's event is told in the process that made it).
    defp comma_reads(run) do
      name = {__MODULE__, SystemsRuntime.Proc.make_ref()}

      :telemetry.attach(
        name,
        [:comma, :repo, :query],
        fn _event, _measures, meta, _config ->
          if is_binary(meta[:source]) and String.starts_with?(meta.source, "comma_station"),
            do: Process.put(name, [meta.source | Process.get(name, [])])
        end,
        nil
      )

      try do
        run.()
      after
        :telemetry.detach(name)
      end

      Enum.reverse(Process.get(name, []))
    end
  end

  describe "station members (Comma)" do
    test "the active Membership role in the Workspace's Group; owners and admins manage" do
      assert Members.role("tnt_copy_a", "grp_copy_a", "usr_copy_owner") == {:ok, "owner"}
      assert Members.role("tnt_copy_a", "grp_copy_a", "usr_copy_member") == {:ok, "member"}
      assert Members.role("tnt_copy_b", "grp_copy_b", "usr_copy_member") == :none
      # The Group of another tenant is not this Workspace.
      assert Members.role("tnt_copy_b", "grp_copy_a", "usr_copy_owner") == :none
      assert Members.manager_role?("owner")
      assert Members.manager_role?("admin")
      refute Members.manager_role?("member")
    end

    test "a suspended Workspace or Membership has no role", %{a: a} do
      Repo.update_all(
        from(m in WorkspaceMembership,
          where: m.workspace_id == ^a.id and m.user_id == "usr_copy_member"
        ),
        set: [status: "removed"]
      )

      assert Members.role("tnt_copy_a", "grp_copy_a", "usr_copy_member") == :none
      Repo.update_all(from(w in Workspace, where: w.id == ^a.id), set: [status: "deleted"])
      assert Members.role("tnt_copy_a", "grp_copy_a", "usr_copy_owner") == :none
    end

    test "the port answers from the registered product" do
      prior = SystemsRuntime.get_env(:salix_store, :station_members)
      SystemsRuntime.delete_env(:salix_store, :station_members)

      on_exit(fn ->
        if prior,
          do: SystemsRuntime.put_env(:salix_store, :station_members, prior),
          else: SystemsRuntime.delete_env(:salix_store, :station_members)
      end)

      assert StationMembers.role("tnt_copy_a", "grp_copy_a", "usr_copy_owner") == :none
      StationMembers.register(Members)
      StationMembers.register(Members)
      assert SystemsRuntime.get_env(:salix_store, :station_members) == [Members]
      assert StationMembers.role("tnt_copy_a", "grp_copy_a", "usr_copy_owner") == {:ok, "owner"}
      assert StationMembers.manager?("tnt_copy_a", "grp_copy_a", "usr_copy_owner")
      refute StationMembers.manager?("tnt_copy_a", "grp_copy_a", "usr_copy_member")
      refute StationMembers.manager?("tnt_copy_a", "grp_copy_a", "usr_nobody")
    end
  end
end
