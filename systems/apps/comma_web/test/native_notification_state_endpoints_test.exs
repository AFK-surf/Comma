defmodule CommaWeb.NativeNotificationStateEndpointsTest.Salix do
  def resolve_workspace_scope(workspace),
    do: {:ok, Map.put(workspace, "router_conversation_id", Process.get(:notification_router_id))}

  def list_group_activity_tasks(_workspace),
    do: Process.get(:activity_result, {:ok, %{"data" => []}})

  def get_group_conversation(_workspace, id),
    do: {:ok, %{"conversation_id" => id, "kind" => "user_chat"}}

  def get_group_conversation_with_messages(_workspace, _id, opts),
    do:
      {:ok,
       %{
         "messages" =>
           Enum.filter(
             Process.get(:notification_messages, []),
             &(&1["message_id"] == opts[:through_id])
           )
       }}

  def list_group_conversation_message_page(_workspace, _id, opts) do
    messages = Process.get(:notification_messages, [])
    selected = if opts[:limit] == 1, do: Enum.take(messages, -1), else: messages

    {:ok,
     %{
       "messages" => selected,
       "bounds" =>
         if(messages != [],
           do: %{"head_seq" => hd(messages)["seq"], "tail_seq" => List.last(messages)["seq"]}
         ),
       "covered" => if(selected != [], do: %{"last_seq" => List.last(selected)["seq"]})
     }}
  end
end

defmodule CommaWeb.NativeNotificationStateEndpointsTest do
  use SystemsClock.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Comma.{Accounts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixStore.Ids
  @opts CommaWeb.Router.init([])

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    prior = SystemsRuntime.get_env(:comma_core, :salix_client)

    SystemsRuntime.put_env(
      :comma_core,
      :salix_client,
      CommaWeb.NativeNotificationStateEndpointsTest.Salix
    )

    Comma.PodLifecycle.reset_for_test()

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      SystemsRuntime.put_env(:comma_core, :salix_client, prior)
      Comma.PodLifecycle.reset_for_test()
    end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "state-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} = Accounts.create_session(user["id"])
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    row =
      Repo.insert!(%Workspace{
        id: "wsp_state_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "state-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "state-test",
        name: "Native state",
        status: "active"
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: row.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    Process.put(:notification_router_id, Ids.new_conversation_id())
    %{user: user, session: session, group: group, row: row}
  end

  test "Router state and exact-message read ACK synchronize the count through real HTTP routes",
       ctx do
    path = "/v1/comma/groups/#{ctx.group}/router-notifications"
    assert %{status: 200} = request(:get, path, ctx.session)

    Process.put(:notification_messages, [
      %{
        "message_id" => "msg_router",
        "seq" => 1,
        "actor_type" => "agent",
        "agent_id" => ctx.row.salix_router_agent_id,
        "content" => "Reply"
      }
    ])

    assert %{status: 200, resp_body: body} = request(:get, path, ctx.session)
    assert Jason.decode!(body)["unread_count"] == 1
    assert %{status: 400} = request(:post, path <> "/read", ctx.session, %{})

    assert %{status: 404} =
             request(:post, path <> "/read", ctx.session, %{"message_id" => "forged"})

    assert %{status: 200, resp_body: body} =
             request(:post, path <> "/read", ctx.session, %{"message_id" => "msg_router"})

    assert Jason.decode!(body)["unread_count"] == 0
  end

  test "restricted, revoked and another account cannot access notification state", ctx do
    path = "/v1/comma/groups/#{ctx.group}/router-notifications"

    {:ok, restricted} =
      Accounts.create_session(ctx.user["id"], restricted: true, session_source: "ops_api")

    assert %{status: 403} = request(:get, path, restricted)

    {:ok, other} =
      Accounts.create_user(%{
        "email" => "state-other-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, other_session} = Accounts.create_session(other["id"])
    assert %{status: 404} = request(:get, path, other_session)
    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert %{status: 401} = request(:get, path, ctx.session)
  end

  defp request(method, path, session, body \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn =
      if session,
        do: put_req_header(conn, "authorization", "Bearer " <> session["token"]),
        else: conn

    CommaWeb.Router.call(conn, @opts)
  end
end
