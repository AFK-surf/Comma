defmodule CommaWeb.StationDeviceCutoverTest do
  @moduledoc """
  The experimental station cutover of user devices
  (`COMMA_STATIONS_DEVICE_CUTOVER`): the device install surfaces answer the
  station enrollment command.
  """
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixStore.Ids

  @origin "https://api.comma.test"
  @station String.duplicate("cd", 32)
  @other_station String.duplicate("ef", 32)
  @token "gateway-token-0123456789abcdef0123"
  @owner_key {__MODULE__, :owner}
  @stations_key {__MODULE__, :stations}

  defmodule Directory do
    @behaviour CommaWeb.Stations.Directory

    @impl true
    def list_group_stations(_tenant_id, _group_id),
      do: {:ok, SystemsRuntime.PersistentTerm.get({CommaWeb.StationDeviceCutoverTest, :stations})}
  end

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
    put_stations(device_cutover: true)

    # These tests exercise the gateway transport over a Req.Test stub.
    SystemsRuntime.put_env(:comma_web, :station_tools_transport, :gateway)
    on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :station_tools_transport) end)

    SystemsRuntime.put_env(:comma_web, :station_gateway,
      url: "http://gateway.test",
      token: @token,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    SystemsRuntime.put_env(:comma_web, :station_directory, Directory)

    SystemsRuntime.PersistentTerm.put(@owner_key, SystemsRuntime.Proc.self())
    SystemsRuntime.PersistentTerm.put(@stations_key, [])

    on_exit(fn ->
      Enum.each([@owner_key, @stations_key], &:persistent_term.erase/1)

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
          id: "wsp_cutover_#{SystemsRuntime.Proc.unique_integer([:positive])}",
          owner_user_id: owner["id"],
          salix_tenant_id: tenant,
          salix_group_id: group,
          group_generation: "test",
          salix_router_agent_id: Ids.new_agent_id(group),
          salix_worker_agent_id: Ids.new_agent_id(group),
          billing_owner_id: "cutover-test-#{tenant}",
          name: "Cutover",
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

  defp put_stations(extra) do
    SystemsRuntime.put_env(:comma_core, :stations, Keyword.merge([origin: @origin], extra))
  end

  defp user!(label) do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "#{label}-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    user
  end

  describe "device install command" do
    test "Settings > Devices gives a member who uses stations the one-line station enrollment",
         f do
      SystemsRuntime.PersistentTerm.put(@stations_key, [station(@station, "Build box", f.owner)])

      assert {:ok, install} =
               SalixEnv.DeviceInstall.create_token_command(f.tenant, f.group, %{
                 "name" => "Cutover Connector",
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
      SystemsRuntime.PersistentTerm.put(@stations_key, [
        station(@station, "Build box", f.admin),
        station(@other_station, "Laptop", f.member),
        station(String.duplicate("ab", 32), "Tablet", f.viewer)
      ])

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

      # A read-only member who uses stations is refused, with no owner fallback.
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

  describe "Connector command" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "cutover-artifacts-#{SystemsRuntime.Proc.unique_integer([:positive])}"
        )

      for platform <- SalixStore.ConnectorInstall.platforms() do
        File.mkdir_p!(Path.join(root, platform))
        File.write!(Path.join([root, platform, "salix-connect"]), "fixture")
      end

      old = SystemsRuntime.get_env(:salix_env, :device_install_local_artifact_root)
      SystemsRuntime.put_env(:salix_env, :device_install_local_artifact_root, root)

      on_exit(fn ->
        if old,
          do: SystemsRuntime.put_env(:salix_env, :device_install_local_artifact_root, old),
          else: SystemsRuntime.delete_env(:salix_env, :device_install_local_artifact_root)

        File.rm_rf!(root)
      end)
    end

    test "the Router's install tool gives the member who asked the device it installs", f do
      {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Connector owner test"})
      tenant = tenant["tenant_id"]
      {:ok, %{"group_id" => group}} = Salix.Control.Groups.create(%{"name" => "Owner"}, tenant)

      # The member has no station, so the tool keeps the Connector installer.
      assert {:ok, %{"device_id" => device_id, "command" => command}} =
               SalixEnv.DeviceInstall.create_command(tenant, group, "MacBook Air",
                 requester: tool_requester(%{tenant: tenant, group: group}, f.member)
               )

      assert command =~ "/v1/device-connection/install.sh"

      # Owned by the member, so Settings > Devices lists it and its access is theirs to set.
      assert {:ok, _} =
               SalixEnv.Control.get_owned_environment(device_id, group, tenant, f.member["id"])

      assert {:error, :forbidden} =
               SalixEnv.Control.get_owned_environment(device_id, group, tenant, f.owner["id"])
    end
  end

  defp station(id, name, enroller, online \\ true),
    do: %{"id" => id, "name" => name, "enrolled_by" => enroller["id"], "online" => online}

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
