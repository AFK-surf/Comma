defmodule Comma.RouterNotificationsTest.Salix do
  def resolve_workspace_scope(workspace) do
    {:ok, Map.put(workspace, "router_conversation_id", Process.get(:router_id))}
  end

  def list_group_conversation_message_page(_workspace, _id, opts) do
    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:page, opts})
    messages = Process.get(:router_messages, [])

    selected =
      cond do
        opts[:after] ->
          Enum.filter(messages, &(&1["seq"] > opts[:after])) |> Enum.take(opts[:limit])

        opts[:around] ->
          Enum.filter(messages, &(&1["seq"] >= opts[:around])) |> Enum.take(opts[:limit])

        true ->
          Enum.take(messages, -opts[:limit])
      end

    result =
      {:ok,
       %{
         "messages" => selected,
         "bounds" =>
           if(messages != [],
             do: %{"head_seq" => hd(messages)["seq"], "tail_seq" => List.last(messages)["seq"]}
           ),
         "covered" =>
           if(selected != [],
             do: %{"first_seq" => hd(selected)["seq"], "last_seq" => List.last(selected)["seq"]}
           )
       }}

    if opts[:limit] == 1,
      do: if(callback = Process.delete(:router_tail_callback), do: callback.())

    result
  end

  def get_group_conversation(_workspace, id),
    do: {:ok, %{"kind" => "user_chat", "conversation_id" => id}}

  def get_group_conversation_with_messages(_workspace, _id, opts) do
    if callback = Process.get(:router_read_callback), do: callback.()

    {:ok,
     %{
       "messages" =>
         Enum.filter(
           Process.get(:router_messages, []),
           &(&1["message_id"] == opts[:through_id])
         )
     }}
  end
end

defmodule Comma.RouterNotificationsTest do
  use Comma.DataCase, async: false
  alias Comma.{Accounts, RouterNotifications}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.RouterNotifications.MessagePosition
  alias SalixStore.Ids

  setup do
    prior = SystemsRuntime.get_env(:comma_core, :salix_client)
    SystemsRuntime.put_env(:comma_core, :salix_client, Comma.RouterNotificationsTest.Salix)
    on_exit(fn -> SystemsRuntime.put_env(:comma_core, :salix_client, prior) end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "router-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} = Accounts.create_session(user["id"])
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    row =
      Repo.insert!(%Workspace{
        id: "wsp_router_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "router-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "router-test",
        name: "Router notifications",
        status: "active"
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: row.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    Process.put(:router_id, Ids.new_conversation_id())
    %{user: user, session: session, group: group, row: row}
  end

  test "enrollment skips historical banners; only committed visible Router replies count and reading is idempotent",
       ctx do
    handler_id = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler_id,
        [:comma_product, :operation, :stop],
        fn _event, measurements, metadata, owner ->
          if metadata.operation == :router_notification_projection,
            do:
              SystemsRuntime.Proc.send(
                owner,
                {:router_projection_duration, measurements.duration}
              )
        end,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)
    Process.put(:router_messages, [reply(ctx, 1)])
    started = System.monotonic_time()
    assert {:ok, %{"unread_count" => 0, "latest_seq" => 0}} = snapshot(ctx)
    assert_receive {:router_projection_duration, duration}
    assert duration >= 0 and duration <= System.monotonic_time() - started
    user_message = reply(ctx, 2) |> Map.put("actor_type", "user")
    hidden = reply(ctx, 3) |> Map.put("visibility", "hidden")
    draft = reply(ctx, 4) |> Map.put("content", [])
    worker = reply(ctx, 5) |> Map.put("agent_id", ctx.row.salix_worker_agent_id)

    Process.put(:router_messages, [
      reply(ctx, 1),
      user_message,
      hidden,
      draft,
      worker,
      reply(ctx, 6),
      reply(ctx, 7)
    ])

    assert {:ok, %{"unread_count" => 2, "latest_seq" => 7}} = snapshot(ctx)
    assert {:ok, %{"unread_count" => 2}} = snapshot(ctx)
    assert Repo.aggregate(MessagePosition, :count) == 2
    assert {:ok, %{"unread_count" => 1}} = read(ctx, "msg_6")
    assert {:ok, %{"unread_count" => 1}} = read(ctx, "msg_6")
    assert {:ok, %{"unread_count" => 0}} = read(ctx, "msg_7")
    assert Repo.aggregate(MessagePosition, :count) == 0
    assert {:error, :not_found} = read(ctx, "made-up")
  end

  test "Router created after enrollment and WeChat outbound receipt appear as unread exactly once",
       ctx do
    id = Process.get(:router_id)
    Process.delete(:router_id)
    assert {:ok, %{"unread_count" => 0}} = snapshot(ctx)
    Process.put(:router_id, id)
    inbound = reply(ctx, 1) |> Map.put("actor_type", "system") |> Map.put("agent_input", %{})

    sent = %{
      "message_id" => "provider_receipt",
      "seq" => 2,
      "actor_type" => "system",
      "kind" => "app_event",
      "metadata" => %{"event_type" => "provider.message"},
      "platform_message" => %{
        "provider" => "wechat",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "reply"}]
      }
    }

    Process.put(:router_messages, [inbound, sent])

    assert {:ok, %{"unread_count" => 1, "latest_message_id" => "provider_receipt"}} =
             snapshot(ctx)

    assert {:ok, %{"unread_count" => 1}} = snapshot(ctx)
  end

  test "restricted credentials and another account cannot read or acknowledge Router messages",
       ctx do
    assert {:error, :forbidden} =
             RouterNotifications.snapshot(
               ctx.user,
               Map.put(ctx.session, "restricted", true),
               ctx.group
             )

    {:ok, other} =
      Accounts.create_user(%{
        "email" => "outsider-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, other_session} = Accounts.create_session(other["id"])
    assert {:error, :not_found} = RouterNotifications.snapshot(other, other_session, ctx.group)

    assert {:error, :not_found} =
             RouterNotifications.read(other, other_session, ctx.group, "msg_1")
  end

  test "session revocation during a canonical Message read cannot advance the read position",
       ctx do
    assert {:ok, _} = snapshot(ctx)
    Process.put(:router_messages, [reply(ctx, 1)])
    assert {:ok, %{"unread_count" => 1}} = snapshot(ctx)
    before = Repo.get!(Workspace, ctx.row.id).router_notification_state

    Process.put(:router_read_callback, fn ->
      Accounts.revoke_session_token(ctx.session["token"])
    end)

    assert {:error, _} = read(ctx, "msg_1")
    assert Repo.get!(Workspace, ctx.row.id).router_notification_state == before
    assert Repo.aggregate(MessagePosition, :count) == 1
  end

  defp reply(ctx, seq),
    do: %{
      "message_id" => "msg_#{seq}",
      "seq" => seq,
      "actor_type" => "agent",
      "agent_id" => ctx.row.salix_router_agent_id,
      "content" => "Reply #{seq}"
    }

  defp snapshot(ctx), do: RouterNotifications.snapshot(ctx.user, ctx.session, ctx.group)
  defp read(ctx, id), do: RouterNotifications.read(ctx.user, ctx.session, ctx.group, id)
end
