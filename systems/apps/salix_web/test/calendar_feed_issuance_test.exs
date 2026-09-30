defmodule Salix.Bindings.CalendarFeedIssuanceTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.{AgentCalendar, CalendarFeed}
  alias SalixCalendar.AgentAPI
  alias SalixStore.{Ids, Keys, Repo, S3}

  defmodule TestOAuthStore do
    @behaviour SalixAgent.OAuthStore

    @impl true
    def agent_oauth_context(_agent_id), do: {:ok, Process.get({__MODULE__, :context})}

    @impl true
    def provider_app(_tenant, _provider), do: {:error, :not_configured}

    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}

    @impl true
    def public_base_url, do: nil

    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: {:error, :not_found}
  end

  setup do
    S3.Fake.reset()
    Repo.query!("TRUNCATE calendar_feed_subscriptions")

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)
    router_session_id = Ids.new_session_id()

    group = %{
      "group_id" => group_id,
      "tenant_id" => tenant_id,
      "router_agent_id" => agent_id,
      "router_conversation_id" => "conv_" <> group_id
    }

    assert {:ok, _} = S3.put(Keys.ctl_group(group_id), Jason.encode!(group), if_none_match: "*")

    principal = %{
      "namespace" => "slack_user",
      "tenant_id" => tenant_id,
      "subject_id" => "U_alice"
    }

    assert {:ok, _item} =
             AgentAPI.create_event(
               group_id,
               %{
                 "title" => "与 XX 开会",
                 "start" => "2026-09-15T19:00:00",
                 "time_zone" => "Asia/Tokyo"
               },
               principal,
               "msg1_1"
             )

    {:ok,
     group_id: group_id,
     tenant_id: tenant_id,
     agent_id: agent_id,
     group: group,
     principal: principal,
     router: %{
       "agent_id" => agent_id,
       "role" => "router",
       "router_session_id" => router_session_id
     }}
  end

  test "returns a usable link for the model to send, on any source provider", ctx do
    # No provider connect is seeded: issuance owns no destination, so the
    # requester's source transport cannot gate getting the link.
    for namespace <- ["slack_user", "feishu_user", "telegram_user", "comma_user"] do
      principal = Map.put(ctx.principal, "namespace", namespace)

      assert {:ok, _item} =
               AgentAPI.create_event(
                 ctx.group_id,
                 %{
                   "title" => namespace <> " 的会议",
                   "start" => "2026-09-15T19:00:00",
                   "time_zone" => "Asia/Tokyo"
                 },
                 principal,
                 "msg_" <> namespace
               )

      assert {:ok, %{"feed_url" => url}} =
               AgentCalendar.issue_feed_link(ctx.group_id, principal)

      {feed_id, secret} = parse(url)
      assert {:ok, %{body: body}} = CalendarFeed.serve(feed_id, secret, "")
      assert String.contains?(body, "SUMMARY:" <> namespace <> " 的会议")
    end
  end

  test "re-issuing rotates: same feed, new secret, old URL stops working", ctx do
    assert {:ok, %{"feed_url" => url}} =
             AgentCalendar.issue_feed_link(ctx.group_id, ctx.principal)

    {feed_id, secret} = parse(url)

    assert {:ok, %{"feed_url" => replacement}} =
             AgentCalendar.issue_feed_link(ctx.group_id, ctx.principal)

    {feed_id2, secret2} = parse(replacement)
    assert feed_id2 == feed_id
    assert secret2 != secret
    assert {:error, :unauthorized} = CalendarFeed.serve(feed_id, secret, "")
    assert {:ok, _} = CalendarFeed.serve(feed_id2, secret2, "")
  end

  test "the sealed provider principal carries through the tool to a usable link", ctx do
    previous_calendar = Application.get_env(:salix_agent, :calendar_mod)
    previous_oauth = Application.get_env(:salix_agent, :oauth_store_mod)
    Application.put_env(:salix_agent, :calendar_mod, AgentCalendar)
    Application.put_env(:salix_agent, :oauth_store_mod, TestOAuthStore)
    Process.put({TestOAuthStore, :context}, %{tenant: ctx.tenant_id, group_id: ctx.group_id})

    on_exit(fn ->
      restore(:salix_agent, :calendar_mod, previous_calendar)
      restore(:salix_agent, :oauth_store_mod, previous_oauth)
    end)

    assert {:ok, delivery} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(
               ctx.group,
               ctx.router,
               "send my private calendar link",
               %{
                 "provider" => "slack",
                 "connect_id" => "connA",
                 "workspace_id" => "T1",
                 "channel_id" => "D1",
                 "thread_ts" => "1.0",
                 "message_ts" => "1.1",
                 "user_id" => "U_alice"
               },
               source_message_id: "im_provider:slack:event-1",
               trusted_source_text: "send my private calendar link"
             )

    assert get_in(delivery, ["trusted_origin", "principal_ref", "subject_id"]) == "U_alice"

    assert %{"feed_url" => url} =
             SalixAgent.Tools.Calendar.issue_feed_link(%{}, %{
               agent_id: ctx.agent_id,
               trusted_origin: delivery["trusted_origin"]
             })
             |> Jason.decode!()

    {feed_id, secret} = parse(url)
    assert {:ok, _} = CalendarFeed.serve(feed_id, secret, "")
  end

  test "fails closed without a human principal", ctx do
    assert {:error, :missing_principal} = AgentCalendar.issue_feed_link(ctx.group_id, nil)
  end

  test "rejects a principal from another tenant", ctx do
    principal = Map.put(ctx.principal, "tenant_id", Ids.new_tenant_id())

    assert {:error, :principal_tenant_mismatch} =
             AgentCalendar.issue_feed_link(ctx.group_id, principal)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp parse(url) do
    [_, tail] = String.split(url, "/v1/calendar/feeds/")
    [feed_id, secret_ics] = String.split(tail, "/")
    {feed_id, String.trim_trailing(secret_ics, ".ics")}
  end
end
