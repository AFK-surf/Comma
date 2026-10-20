defmodule CommaWeb.StationsTest do
  @moduledoc """
  `CommaWeb.Stations` resolves the Group, requester and station from the tool
  ctx and calls the station gateway over HTTP (stubbed with `Req.Test`).
  """
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias CommaWeb.Stations
  alias SalixStore.Ids

  @station String.duplicate("cd", 32)
  @token "gateway-token-0123456789abcdef0123"

  defmodule Directory do
    @behaviour CommaWeb.Stations.Directory

    @impl true
    def list_group_stations(tenant_id, group_id) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:directory, tenant_id, group_id})
      {:ok, [%{"id" => String.upcase(String.duplicate("cd", 32)), "name" => "Build box"}]}
    end
  end

  setup do
    previous =
      for key <- [:station_gateway, :station_directory],
          do: {key, SystemsRuntime.get_env(:comma_web, key)}

    # These tests exercise the gateway transport over a Req.Test stub.
    SystemsRuntime.put_env(:comma_web, :station_tools_transport, :gateway)
    on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :station_tools_transport) end)

    SystemsRuntime.put_env(:comma_web, :station_gateway,
      url: "http://gateway.test",
      token: @token,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    SystemsRuntime.put_env(:comma_web, :station_directory, Directory)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:comma_web, key)
        {key, value} -> SystemsRuntime.put_env(:comma_web, key, value)
      end)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    owner = user!("owner")
    viewer = user!("viewer")

    workspace =
      Repo.insert!(
        Workspace.changeset(%Workspace{}, %{
          id: "wsp_station_#{SystemsRuntime.Proc.unique_integer([:positive])}",
          owner_user_id: owner["id"],
          salix_tenant_id: tenant,
          salix_group_id: group,
          group_generation: "test",
          salix_router_agent_id: Ids.new_agent_id(group),
          salix_worker_agent_id: Ids.new_agent_id(group),
          billing_owner_id: "station-test-#{tenant}",
          name: "Stations",
          status: "active"
        })
      )

    for {user, role} <- [{owner, "owner"}, {viewer, "viewer"}] do
      Repo.insert!(
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user["id"],
          role: role,
          status: "active"
        })
      )
    end

    agent = Ids.new_agent_id(group)

    {:ok,
     workspace: workspace,
     owner: owner,
     viewer: viewer,
     tenant: tenant,
     group: group,
     agent: agent}
  end

  defp user!(label) do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "#{label}-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    user
  end

  defp ctx(f, user) do
    %{
      agent_id: f.agent,
      session_id: "ses_station",
      tool_call_id: "call_station_1",
      tenant_id: f.tenant,
      group_id: f.group,
      trusted_origin: %{
        "provider" => "internal",
        "conversation_id" => "conv_station",
        "principal_ref" => %{"namespace" => "comma_user", "subject_id" => user["id"]}
      }
    }
  end

  defp stub_gateway(reply) do
    test = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      SystemsRuntime.Proc.send(
        test,
        {:gateway, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
         Jason.decode!(body)}
      )

      reply.(conn)
    end)
  end

  test "forwards an op with the requester context and the requester's email", f do
    stub_gateway(
      &Req.Test.json(&1, %{"ok" => true, "result" => %{"session" => "s1", "thread" => "t1"}})
    )

    args = %{"prompt" => "Ship it", "requester_email" => "spoofed@example.com"}

    assert Stations.call(ctx(f, f.owner), String.upcase(@station), "session.start", args) ==
             {:ok, %{"session" => "s1", "thread" => "t1"}}

    assert_received {:gateway, path, ["Bearer " <> @token], body}
    assert path == "/v1/stations/#{@station}/tools"
    assert body["op"] == "session.start"
    assert body["id"] == "call_station_1"
    assert body["args"] == %{"prompt" => "Ship it", "requester_email" => f.owner["email"]}

    assert body["context"] == %{
             # The Group id is the workspace the station holds.
             "workspace" => f.group,
             "user_id" => f.owner["id"],
             "user_email" => f.owner["email"],
             "agent" => f.agent,
             "conversation" => "conv_station"
           }
  end

  test "the Group's roster in Salix decides the offer, whichever product owns the Group", f do
    prior = SystemsRuntime.get_env(:salix_store, :stations)
    SystemsRuntime.put_env(:salix_store, :stations, kek: String.duplicate("k", 32))
    SalixStore.Repo.delete_all(SalixStore.Stations.SigningKeys.Key)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :stations, prior || []) end)
    SystemsRuntime.put_env(:comma_web, :station_directory, CommaWeb.Stations.GroupDirectory)

    # A Group that is no Comma Workspace.
    tenant = SalixAgent.TestSupport.new_tenant_id()
    ctx = %{tenant_id: tenant, group_id: Ids.new_group_id(tenant)}
    refute Stations.offered?(ctx)
    refute Stations.offered?(%{tenant_id: f.tenant, group_id: f.group})

    {public, _seed} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    station = Base.encode16(public, case: :lower)

    assert {:ok, %{"workspace" => workspace}} =
             Comma.Stations.admit_cloud_station(
               ctx.tenant_id,
               ctx.group_id,
               station,
               nil,
               nil,
               "https://salix.test"
             )

    assert workspace == ctx.group_id
    assert Stations.offered?(ctx)
    # The station is in that Group only.
    refute Stations.offered?(%{ctx | tenant_id: f.tenant})
    refute Stations.offered?(%{tenant_id: f.tenant, group_id: f.group})
  end

  test "refuses stations outside the Group and turns without a member", f do
    other = String.duplicate("ef", 32)

    assert Stations.call(ctx(f, f.owner), other, "exec", %{"command" => "id"}) ==
             {:error, :station_not_found}

    agent_turn = put_in(ctx(f, f.owner), [:trusted_origin, "principal_ref"], nil)

    assert Stations.call(agent_turn, @station, "exec", %{"command" => "id"}) ==
             {:error, :requester_required}

    stranger = user!("stranger")

    assert Stations.call(ctx(f, stranger), @station, "exec", %{"command" => "id"}) ==
             {:error, :requester_required}

    refute_received {:gateway, _, _, _}
  end

  test "a viewer may only read", f do
    stub_gateway(&Req.Test.json(&1, %{"ok" => true, "result" => %{"entries" => []}}))

    assert Stations.call(ctx(f, f.viewer), @station, "exec", %{"command" => "id"}) ==
             {:error, :forbidden}

    assert {:ok, %{"entries" => []}} =
             Stations.call(ctx(f, f.viewer), @station, "fs.list", %{"path" => "/"})
  end
end
