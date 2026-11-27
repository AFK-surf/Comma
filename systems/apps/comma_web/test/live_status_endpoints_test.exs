defmodule CommaWeb.LiveStatusEndpointsTest.Salix do
  def resolve_workspace_scope(workspace), do: {:ok, workspace}
end

defmodule CommaWeb.LiveStatusEndpointsTest do
  use SystemsClock.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Comma.{Accounts, LiveStatuses, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.LiveStatuses.Target
  alias Comma.Notifications.APNs
  alias SalixStore.Ids

  @opts CommaWeb.Router.init([])

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    Comma.PodLifecycle.reset_for_test()

    prior_apns = SystemsRuntime.get_env(:comma_core, :apns)
    prior_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    {_, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:ec, "P-256"}))

    SystemsRuntime.put_env(:comma_core, :apns,
      profiles: %{
        "production" => [
          team_id: "TESTTEAM",
          key_id: "TESTKEY",
          private_key: pem,
          allowed_bundle_ids: ["surf.comma.ios"]
        ]
      }
    )

    SystemsRuntime.put_env(:comma_core, :salix_client, __MODULE__.Salix)

    unless SystemsRuntime.Proc.whereis(APNs.ProviderToken),
      do: start_supervised!(APNs.ProviderToken)

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :apns, prior_apns)
      SystemsRuntime.put_env(:comma_core, :salix_client, prior_client)
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      Comma.PodLifecycle.reset_for_test()
    end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "live-http-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    {:ok, outsider} =
      Accounts.create_user(%{
        "email" => "live-out-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, outsider_session} =
      Accounts.create_session(outsider["id"], client_kind: "ios", client_platform: "ios")

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_live_http_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "live-http-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "live-http-test",
        name: "Live HTTP Workspace",
        status: "active"
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    %{
      user: user,
      session: session,
      outsider_session: outsider_session,
      workspace: workspace,
      group_id: group
    }
  end

  test "GET /v1/comma/groups/:group_id/live-activities enforces auth and returns snake_case items",
       ctx do
    assert {:ok, _} =
             LiveStatuses.upsert(
               ctx.workspace.id,
               ctx.group_id,
               %{
                 "key" => "flight:CA1501",
                 "category" => "flight",
                 "title" => "CA1501 登机中",
                 "subtitle" => "T3 · 登机口 C18",
                 "compact_label" => "C18",
                 "detail_left" => "PEK → SHA",
                 "detail_right" => "C18"
               },
               conversation_id: "cnv_flight_1"
             )

    path = "/v1/comma/groups/#{ctx.group_id}/live-activities"

    assert %{status: 401} = call_router(:get, path, nil)
    assert %{status: 404} = call_router(:get, path, ctx.outsider_session["token"])

    {:ok, restricted_ops} =
      Accounts.create_session(ctx.user["id"], restricted: true, session_source: "ops_api")

    assert %{status: 403} = call_router(:get, path, restricted_ops["token"])

    {:ok, restricted_panel} =
      Accounts.create_session(ctx.user["id"],
        restricted: true,
        session_source: "channel_task_panel",
        auth_method: "telegram_miniapp",
        workspace_id: ctx.workspace.id,
        group_id: ctx.group_id,
        channel_subject: "123456789",
        channel_connect_id: "conn-panel-1"
      )

    panel_conn =
      conn(:get, path)
      |> put_req_header("cookie", "comma_panel_session=" <> restricted_panel["token"])
      |> CommaWeb.Router.call(@opts)

    assert panel_conn.status == 401

    assert {:error, :forbidden} =
             LiveStatuses.list_active_authorized(ctx.user, restricted_panel, ctx.group_id)

    conn = call_router(:get, path, ctx.session["token"])
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    %{"data" => [item]} = Jason.decode!(conn.resp_body)
    assert item["key"] == "flight:CA1501"
    assert item["workspace_id"] == ctx.workspace.id
    assert item["group_id"] == ctx.group_id
    assert item["conversation_id"] == "cnv_flight_1"
    assert item["category"] == "flight"
    assert item["status"] == "active"
    assert item["compact_label"] == "C18"
    assert is_integer(item["started_at_epoch_seconds"])
    assert is_nil(item["dismiss_at_epoch_seconds"])
    assert is_integer(item["stale_epoch_seconds"])
    assert is_integer(item["expires_epoch_seconds"])
    assert is_integer(item["updated_at_epoch_seconds"])

    # Ended item within dismiss_after_seconds stays visible on GET with dismiss_at_epoch_seconds,
    # while list_active/1 (used by live_activity.list tool) excludes it.
    assert {:ok, _} =
             LiveStatuses.end_status(ctx.group_id, %{
               "key" => "flight:CA1501",
               "outcome" => "done",
               "title" => "已起飞",
               "dismiss_after_seconds" => 30
             })

    assert LiveStatuses.list_active(ctx.group_id) == []

    ended_conn = call_router(:get, path, ctx.session["token"])
    assert ended_conn.status == 200
    %{"data" => [ended_item]} = Jason.decode!(ended_conn.resp_body)
    assert ended_item["key"] == "flight:CA1501"
    assert ended_item["status"] == "done"
    assert is_integer(ended_item["started_at_epoch_seconds"])
    assert is_integer(ended_item["dismiss_at_epoch_seconds"])

    # Past dismiss window, GET no longer returns the terminal item.
    import Ecto.Query

    past = DateTime.add(SystemsClock.utc_now(), -60, :second)

    Repo.update_all(
      from(s in Comma.LiveStatuses.Status,
        where: s.group_id == ^ctx.group_id and s.live_key == "flight:CA1501"
      ),
      set: [ended_at: past]
    )

    after_window_conn = call_router(:get, path, ctx.session["token"])
    assert after_window_conn.status == 200
    assert %{"data" => []} = Jason.decode!(after_window_conn.resp_body)
  end

  test "POST push-to-start, POST tokens, and DELETE registrations enforce schema, scope, and reasons",
       ctx do
    pts_body = %{
      "token" => String.duplicate("a", 64),
      "environment" => "production",
      "bundle_id" => "surf.comma.ios",
      "locale" => "zh-Hans",
      "workspace_id" => ctx.workspace.id,
      "group_id" => ctx.group_id,
      "activity_schema" => "live_status_v1"
    }

    # Invalid schema -> 422
    assert %{status: 422} =
             call_router(
               :post,
               "/v1/comma/notifications/live-statuses/push-to-start",
               ctx.session["token"],
               Map.put(pts_body, "activity_schema", "tasks_v1")
             )

    # Outsider -> 404 (hides group existence)
    assert %{status: 404} =
             call_router(
               :post,
               "/v1/comma/notifications/live-statuses/push-to-start",
               ctx.outsider_session["token"],
               pts_body
             )

    # Restricted session -> 403
    {:ok, restricted} =
      Accounts.create_session(ctx.user["id"], restricted: true, session_source: "ops_api")

    assert %{status: 403} =
             call_router(
               :post,
               "/v1/comma/notifications/live-statuses/push-to-start",
               restricted["token"],
               pts_body
             )

    # Valid push-to-start -> 200
    pts_conn =
      call_router(
        :post,
        "/v1/comma/notifications/live-statuses/push-to-start",
        ctx.session["token"],
        pts_body
      )

    assert pts_conn.status == 200
    %{"id" => pts_id, "status" => "active"} = Jason.decode!(pts_conn.resp_body)

    # Missing live_key on tokens -> 422
    assert %{status: 422} =
             call_router(
               :post,
               "/v1/comma/notifications/live-statuses/tokens",
               ctx.session["token"],
               Map.put(pts_body, "activity_id", "act-1")
             )

    # Valid live_activity token -> 200
    token_conn =
      call_router(
        :post,
        "/v1/comma/notifications/live-statuses/tokens",
        ctx.session["token"],
        Map.merge(pts_body, %{
          "token" => String.duplicate("b", 64),
          "activity_id" => "act-1",
          "live_key" => "flight:CA1501"
        })
      )

    assert token_conn.status == 200
    %{"id" => la_id, "status" => "active"} = Jason.decode!(token_conn.resp_body)

    # Invalid reason -> 422
    assert %{status: 422} =
             call_router(
               :delete,
               "/v1/comma/notifications/live-statuses/registrations/#{la_id}?reason=bogus",
               ctx.session["token"]
             )

    # Outsider DELETE cannot remove owner's registration
    assert %{status: 204} =
             call_router(
               :delete,
               "/v1/comma/notifications/live-statuses/registrations/#{la_id}?reason=dismissed",
               ctx.outsider_session["token"]
             )

    assert Repo.get(Target, la_id) != nil

    # Owner DELETE with dismissed records suppression on push_to_start
    assert %{status: 204} =
             call_router(
               :delete,
               "/v1/comma/notifications/live-statuses/registrations/#{la_id}?reason=dismissed",
               ctx.session["token"]
             )

    assert Repo.get(Target, la_id) == nil
    assert Map.has_key?(Repo.get!(Target, pts_id).suppressed_keys, "flight:CA1501")
  end

  defp call_router(method, path, token, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    CommaWeb.Router.call(conn, @opts)
  end
end
