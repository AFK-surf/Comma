defmodule CommaWeb.StationDeviceInstallTest do
  @moduledoc """
  The device install surfaces answer the station enrollment command
  (`CommaWeb.Stations.DeviceInstall`).
  """
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixStore.Ids

  @origin "https://api.comma.test"

  setup do
    Comma.AuthChallengeStore.Memory.reset!()

    previous =
      for {app, key} <- [
            {:comma_core, :stations},
            {:salix_store, :stations},
            {:comma_web, :station_gateway},
            {:comma_web, :station_directory}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :stations, kek: SystemsRuntime.Proc.random_bytes(32))
    SystemsRuntime.put_env(:comma_core, :stations, origin: @origin)

    on_exit(fn ->
      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    owner = user!("owner")
    member = user!("member")
    admin = user!("admin")
    viewer = user!("viewer")

    workspace =
      Repo.insert!(
        Workspace.changeset(%Workspace{}, %{
          id: "wsp_install_#{SystemsRuntime.Proc.unique_integer([:positive])}",
          owner_user_id: owner["id"],
          salix_tenant_id: tenant,
          salix_group_id: group,
          group_generation: "test",
          salix_router_agent_id: Ids.new_agent_id(group),
          salix_worker_agent_id: Ids.new_agent_id(group),
          billing_owner_id: "install-test-#{tenant}",
          name: "Install",
          status: "active"
        })
      )

    for {user, role} <- [
          {owner, "owner"},
          {member, "member"},
          {admin, "admin"},
          {viewer, "viewer"}
        ] do
      Repo.insert!(
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user["id"],
          role: role,
          status: "active"
        })
      )
    end

    {:ok,
     workspace: workspace,
     owner: owner,
     member: member,
     admin: admin,
     viewer: viewer,
     tenant: tenant,
     group: group,
     agent: Ids.new_agent_id(group)}
  end

  defp user!(label) do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "#{label}-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    user
  end

  describe "device install command" do
    test "Settings > Devices gives a member the one-line station enrollment", f do
      assert {:ok, install} =
               SalixEnv.DeviceInstall.create_token_command(f.tenant, f.group, %{
                 "name" => "Laptop",
                 "meta" => %{"owner_user_id" => f.owner["id"]}
               })

      assert install["kind"] == "station"
      assert install["name"] == "Station"
      refute Map.has_key?(install, "token")

      assert [_, token] =
               Regex.run(
                 ~r{\Acurl -fsSL https://api\.comma\.test/stations/install\.sh \| sh -s -- (\S+)\z},
                 install["install_command"]
               )

      assert is_integer(install["expires_at"])
      # The token names the Group and the signed-in enroller.
      assert [tenant, group, enroller, _id, _secret] = String.split(token, ".")
      assert {tenant, group, enroller} == {f.tenant, f.group, f.owner["id"]}
    end

    test "the Router's install tool issues as the member who asked, never as the owner", f do
      assert {:ok, %{"kind" => "station", "name" => "Mac mini", "command" => command}} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "Mac mini",
                 requester: tool_requester(f, f.admin)
               )

      assert command =~ ".#{f.admin["id"]}."

      # A member enrolls a station of their own.
      assert {:ok, %{"kind" => "station", "command" => command}} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "Mac mini",
                 requester: tool_requester(f, f.member)
               )

      assert command =~ ".#{f.member["id"]}."

      # A read-only member is refused, with no owner fallback.
      assert {:error, :requester_required} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "Mac mini",
                 requester: tool_requester(f, f.viewer)
               )

      assert {:error, :forbidden} =
               SalixEnv.DeviceInstall.create_token_command(f.tenant, f.group, %{
                 "meta" => %{"owner_user_id" => f.viewer["id"]}
               })
    end
  end

  describe "a Group of another product" do
    # What `BridgeForTeams.StationMembers` answers for a Project: its members,
    # and whether the Project is in use.
    defmodule ProjectMembers do
      @behaviour SalixStore.StationMembers

      @impl true
      def role(_tenant, group, user),
        do: if({group, user} == member(), do: {:ok, "user"}, else: :none)

      @impl true
      def open_enrollment?(_tenant, group), do: group == elem(member(), 0)

      @impl true
      def manager_role?(_role), do: false
      @impl true
      def read_only_role?(_role), do: false

      @impl true
      def workspace_name(_tenant, group),
        do: if(group == elem(member(), 0), do: {:ok, "My Swarm"}, else: :none)

      @impl true
      def workspace_active?(_tenant, group) do
        if group == elem(member(), 0),
          do: SystemsRuntime.get_env(:comma_web, :test_project_active, true),
          else: :none
      end

      defp member, do: SystemsRuntime.get_env(:comma_web, :test_project_member)
    end

    setup f do
      # Salix keeps the keys outside this test's transaction: each test seals its own.
      SalixStore.RepoTestSetup.ensure!()
      SalixStore.Repo.delete_all(SalixStore.Stations.SigningKeys.Key)

      {:ok, %{"tenant_id" => tenant}} = Salix.Control.Tenants.create(%{"name" => "Project"})
      {:ok, %{"group_id" => group}} = Salix.Control.Groups.create(%{"name" => "Swarm"}, tenant)
      user = "019a0000-0000-7000-8000-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      prior = SystemsRuntime.get_env(:salix_store, :station_members)

      SystemsRuntime.put_env(:comma_web, :test_project_member, {group, user})
      SystemsRuntime.put_env(:salix_store, :station_members, [ProjectMembers])

      on_exit(fn ->
        SystemsRuntime.delete_env(:comma_web, :test_project_member)
        SystemsRuntime.delete_env(:comma_web, :test_project_active)
        SystemsRuntime.put_env(:salix_store, :station_members, prior || [])
      end)

      {:ok, Map.merge(f, %{tenant: tenant, group: group, user: user})}
    end

    test "its member's computer enrolls and connects as a device of that Group", f do
      assert {:ok, %{"kind" => "station", "command" => command}} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "Jump",
                 requester: %{user_id: f.user}
               )

      assert [_, token] = Regex.run(~r{ sh -s -- (\S+)\z}, command)
      assert %{"workspace" => group, "connector" => connector} = enroll!(token)

      assert group == f.group
      assert connector["workspace_id"] == f.group
      assert connector["name"] == "Jump"

      assert {:ok, tenant, %{"device_id" => device_id}} =
               SalixEnv.ConnectorTokens.validate_connector_token(connector["token"])

      assert tenant == f.tenant

      assert {:ok, %{"meta" => %{"owner_user_id" => owner, "surface" => "bft"}}} =
               SalixEnv.Registry.get_device(f.tenant, f.group, device_id)

      assert owner == f.user
    end

    test "someone who is not its member is refused", f do
      assert {:error, :forbidden} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "Jump",
                 requester: %{user_id: f.member["id"]}
               )
    end

    test "its Router issues for someone it cannot map, and the device has no owner", f do
      assert {:ok, %{"command" => command}} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "Jump",
                 requester: %{
                   tenant_id: f.tenant,
                   group_id: f.group,
                   trusted_origin: %{"provider" => "slack"}
                 }
               )

      assert [_, token] = Regex.run(~r{ sh -s -- (\S+)\z}, command)
      assert %{"connector" => connector} = enroll!(token)

      assert {:ok, _tenant, %{"device_id" => device_id}} =
               SalixEnv.ConnectorTokens.validate_connector_token(connector["token"])

      assert {:ok, %{"meta" => meta}} = SalixEnv.Registry.get_device(f.tenant, f.group, device_id)
      assert meta["surface"] == "bft"
      refute Map.has_key?(meta, "owner_user_id")
    end

    test "a Group not in use has no install command", f do
      SystemsRuntime.put_env(:comma_web, :test_project_active, false)

      assert {:error, :station_install_unavailable} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "Jump",
                 requester: %{user_id: f.user}
               )
    end
  end

  describe "without a station enrollment" do
    test "a Group no product owns has no install command", f do
      {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "No workspace"})
      tenant = tenant["tenant_id"]
      {:ok, %{"group_id" => group}} = Salix.Control.Groups.create(%{"name" => "Other"}, tenant)

      assert {:error, :station_install_unavailable} =
               SalixEnv.DeviceInstall.create_command(tenant, group, "MacBook Air",
                 requester: %{user_id: f.member["id"], origin: @origin}
               )
    end

    test "a request that names no origin enrolls at the server's public origin", f do
      previous = SystemsRuntime.get_env(:salix_web, :public_base_url)

      on_exit(fn ->
        if is_nil(previous),
          do: SystemsRuntime.delete_env(:salix_web, :public_base_url),
          else: SystemsRuntime.put_env(:salix_web, :public_base_url, previous)
      end)

      SystemsRuntime.put_env(:comma_core, :stations, [])
      SystemsRuntime.delete_env(:salix_web, :public_base_url)

      assert {:error, :station_install_unavailable} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "MacBook Air",
                 requester: %{user_id: f.member["id"]}
               )

      SystemsRuntime.put_env(:salix_web, :public_base_url, @origin <> "/")

      assert {:ok, %{"command" => command}} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "MacBook Air",
                 requester: %{user_id: f.member["id"]}
               )

      assert command =~ "curl -fsSL #{@origin}/stations/install.sh"
    end

    test "a request that names no member has no install command", f do
      assert {:error, :station_install_unavailable} =
               SalixEnv.DeviceInstall.create_command(f.tenant, f.group, "MacBook Air")
    end
  end

  defp enroll!(token) do
    {public, seed} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    station = Base.encode16(public, case: :lower)
    message = "comma-station-enroll-v1:#{@origin}:#{token}:#{station}"

    {:ok, answer} =
      Comma.Stations.enroll(%{
        "token" => token,
        "station" => station,
        "signature" =>
          SystemsRuntime.Proc.sign(:eddsa, :none, message, [seed, :ed25519])
          |> Base.encode16(case: :lower)
      })

    answer
  end

  defp tool_requester(f, user) do
    %{
      tenant_id: f.tenant,
      group_id: f.group,
      trusted_origin: %{
        "provider" => "internal",
        "principal_ref" => %{"namespace" => "comma_user", "subject_id" => user["id"]}
      }
    }
  end
end
