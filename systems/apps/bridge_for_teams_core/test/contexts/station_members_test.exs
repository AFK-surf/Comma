defmodule BridgeForTeams.StationMembersTest do
  # Salix keeps the station roster and its keys in its own database, outside
  # this test's transaction, and the KEK is application configuration.
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Orgs, Projects, StationMembers}
  alias SalixStore.Stations
  alias SalixStore.Stations.Revocations

  setup do
    SalixStore.RepoTestSetup.ensure!()
    SalixStore.Repo.delete_all(SalixStore.Stations.SigningKeys.Key)
    prior = SystemsRuntime.get_env(:salix_store, :stations)
    members = SystemsRuntime.get_env(:salix_store, :station_members)
    SystemsRuntime.put_env(:salix_store, :stations, kek: String.duplicate("k", 32))
    # Only this product answers here: another product's store is not this test's.
    SystemsRuntime.put_env(:salix_store, :station_members, [StationMembers])

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :stations, prior || [])
      SystemsRuntime.put_env(:salix_store, :station_members, members || [])
    end)

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, project} = Projects.create_project(org.id, %{name: "Proj", slug: "proj"})

    users =
      for name <- ~w(owner admin member grant_admin grant_user stranger), into: %{} do
        {:ok, user} = Accounts.create_user(%{email: "#{name}@x.com"})
        {String.to_atom(name), user}
      end

    {:ok, _} = Memberships.put_org_member(org.id, users.owner.id, "owner")
    {:ok, _} = Memberships.put_org_member(org.id, users.admin.id, "admin")
    {:ok, _} = Memberships.put_org_member(org.id, users.member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, users.grant_admin.id, "admin")
    {:ok, _} = Memberships.put_project_member(project.id, users.grant_user.id, "user")

    %{org: org, project: project, users: users}
  end

  defp role(org, project, user),
    do: StationMembers.role(org.salix_tenant_id, project.salix_group_id, user.id)

  test "Organization owners and admins and Project admins manage; a Project user is a member",
       %{org: org, project: project, users: users} do
    assert role(org, project, users.owner) == {:ok, "owner"}
    assert role(org, project, users.admin) == {:ok, "admin"}
    assert role(org, project, users.grant_admin) == {:ok, "admin"}
    assert role(org, project, users.grant_user) == {:ok, "user"}

    # An Organization member without a Project grant has no Agent Swarm access.
    assert role(org, project, users.member) == :none
    assert role(org, project, users.stranger) == :none

    assert StationMembers.manager_role?("owner")
    assert StationMembers.manager_role?("admin")
    refute StationMembers.manager_role?("user")
  end

  test "answers :none for a Group of another tenant, an archived Project or a non-BFT user id",
       %{org: org, project: project, users: users} do
    assert StationMembers.role("tnt_other", project.salix_group_id, users.owner.id) == :none
    assert StationMembers.role(org.salix_tenant_id, project.salix_group_id, "usr_comma") == :none

    {:ok, _} = Projects.archive_project(project)
    assert role(org, project, users.owner) == :none
  end

  test "a provider requester needs the same SSO app audience and current Project authority", %{
    org: org,
    project: project,
    users: users
  } do
    alias BridgeForTeams.Schema.{OrgSsoConnection, OrgSsoIdentity}
    alias BridgeForTeams.Repo

    {:ok, _} =
      Repo.insert(
        OrgSsoConnection.changeset(%OrgSsoConnection{}, %{
          org_id: org.id,
          provider: "feishu",
          client_id: "cli-sso",
          client_secret: "secret"
        })
      )

    {:ok, _} =
      Repo.insert(
        OrgSsoIdentity.changeset(%OrgSsoIdentity{}, %{
          org_id: org.id,
          user_id: users.grant_user.id,
          provider: "feishu",
          provider_subject_type: "open_id",
          provider_subject: "ou-member"
        })
      )

    connect = %{"provider" => "feishu", "app_id" => "cli-sso"}
    user = users.grant_user.id

    assert {:ok, ^user} =
             SalixStore.StationMembers.requester(
               org.salix_tenant_id,
               project.salix_group_id,
               connect,
               "ou-member"
             )

    assert {:error, :requester_required} =
             SalixStore.StationMembers.requester(
               org.salix_tenant_id,
               project.salix_group_id,
               Map.put(connect, "app_id", "cli-other"),
               "ou-member"
             )

    assert {:error, :requester_required} =
             SalixStore.StationMembers.requester(
               org.salix_tenant_id,
               project.salix_group_id,
               connect,
               user
             )

    :ok = Memberships.remove_project_member(project.id, user)

    assert {:error, :requester_required} =
             SalixStore.StationMembers.requester(
               org.salix_tenant_id,
               project.salix_group_id,
               connect,
               "ou-member"
             )
  end

  describe "a Project's Group is the workspace of its stations" do
    defp station_id do
      {public, _seed} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
      Base.encode16(public, case: :lower)
    end

    defp claims(credential) do
      [_head, body, _signature] = String.split(credential, ".")
      body |> Base.url_decode64!(padding: false) |> Jason.decode!()
    end

    defp credential(org, project, user) do
      Stations.issue_credential(
        org.salix_tenant_id,
        project.salix_group_id,
        %{"id" => user.id, "email" => user.email, "name" => ""},
        station_id(),
        %{"id" => "bft-session", "expires_at" => SystemsClock.system_time(:second) + 3600}
      )
    end

    test "its Cloud VM's station is placed there and a Project admin gets a member credential",
         %{org: org, project: project, users: users} do
      {tenant, group} = {org.salix_tenant_id, project.salix_group_id}
      station = station_id()

      assert {:ok, %{kind: "cloud_vm"} = row, nil} =
               Stations.place_cloud_station(tenant, group, station, nil, "0.3.0")

      # The station is told the Group id as its workspace, named as the Project.
      assert {:ok, %{"workspace" => ^group, "workspace_name" => "Proj", "station" => ^station}} =
               Stations.placement(row)

      assert {:ok, %{"workspace" => ^group, "workspace_name" => "Proj"} = state, _row} =
               Stations.presence_state(station)

      assert state["peers"] == [%{"id" => station, "name" => "Cloud VM", "version" => "0.3.0"}]

      assert {:ok, %{"credential" => credential}} = credential(org, project, users.grant_admin)
      admin_id = users.grant_admin.id
      assert %{"ws" => ^group, "sub" => ^admin_id, "role" => "admin"} = claims(credential)

      # The key the credential is signed with is the one the station is told.
      [head | _] = String.split(credential, ".")
      %{"kid" => kid} = head |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert Enum.any?(state["grant_keys"]["keys"], &(&1["kid"] == kid))

      assert {:ok, %{"credential" => member}} = credential(org, project, users.grant_user)
      assert %{"ws" => ^group, "role" => "user"} = claims(member)

      # An Organization member without a Project grant is no member of the Group.
      assert {:error, :not_found} = credential(org, project, users.member)
    end

    test "an archived Project's stations are refused as removed ones are",
         %{org: org, project: project} do
      {tenant, group} = {org.salix_tenant_id, project.salix_group_id}
      station = station_id()
      {:ok, _row, nil} = Stations.place_cloud_station(tenant, group, station, nil, nil)

      assert StationMembers.workspace_active?(tenant, group) == true
      assert SalixStore.StationMembers.workspace_active?(tenant, group)
      assert {:ok, %{id: ^station}} = Stations.active_station(station)
      assert {:ok, _state, _row} = Stations.presence_state(station)

      {:ok, _} = Projects.archive_project(project)

      assert StationMembers.workspace_active?(tenant, group) == false
      refute SalixStore.StationMembers.workspace_active?(tenant, group)
      assert {:error, :station_removed} = Stations.active_station(station)
      assert {:error, :station_removed} = Stations.presence_state(station)

      # A Group of no Project is not this product's to answer for.
      assert StationMembers.workspace_active?(tenant, "grp_not_a_project") == :none
      assert StationMembers.workspace_active?("tnt_other", group) == :none
    end

    test "a member removed from the Project or the Organization has their credentials revoked",
         %{org: org, project: project, users: users} do
      {tenant, group} = {org.salix_tenant_id, project.salix_group_id}
      station = station_id()
      {:ok, _row, nil} = Stations.place_cloud_station(tenant, group, station, nil, nil)
      {:ok, other} = Projects.create_project(org.id, %{name: "Other", slug: "other"})
      assert Revocations.list(tenant, group) == []

      assert :ok = Memberships.remove_project_member(project.id, users.grant_user.id)
      removed = users.grant_user.id
      assert [%{"kind" => "sub", "id" => ^removed, "at" => at}] = Revocations.list(tenant, group)
      assert at >= SystemsClock.system_time(:second) - 5
      # Only that Project's Group.
      assert Revocations.list(tenant, other.salix_group_id) == []

      # The station is told with its next state.
      assert {:ok, %{"revocations" => [%{"id" => ^removed}]}, _row} =
               Stations.presence_state(station)

      assert {:error, :not_found} = credential(org, project, users.grant_user)

      # A removal that does not happen revokes nothing.
      assert {:error, :not_found} =
               Memberships.remove_project_member(project.id, users.stranger.id)

      assert [_one] = Revocations.list(tenant, group)

      # An Organization admin has the role in every Project: all their Groups.
      assert :ok = Memberships.remove_org_member(org.id, users.admin.id)
      admin = users.admin.id

      for group_id <- [group, other.salix_group_id] do
        assert Enum.any?(
                 Revocations.list(tenant, group_id),
                 &match?(%{"kind" => "sub", "id" => ^admin}, &1)
               )
      end
    end
  end
end
