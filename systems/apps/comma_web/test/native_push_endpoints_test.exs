defmodule CommaWeb.NativePushEndpointsTest.Salix do
  def resolve_workspace_scope(workspace), do: {:ok, workspace}
end

defmodule CommaWeb.NativePushEndpointsTest do
  use SystemsClock.Case, async: false
  import Plug.Conn
  import Plug.Test
  import Ecto.Query
  alias Comma.{Accounts, Repo}
  alias Comma.Accounts.User
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Notifications.{APNs, Target}
  alias SalixStore.Ids

  @path "/v1/comma/notifications/devices"
  @opts CommaWeb.Router.init([])

  setup ctx do
    owner =
      if ctx[:registration],
        do: {:owner, Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, sandbox: false)},
        else: CommaWeb.TestRepoSandbox.start_owner!(:transaction)

    Comma.PodLifecycle.reset_for_test()

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      Comma.PodLifecycle.reset_for_test()
    end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "unsubscribe-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    %{user: user, session: session}
  end

  setup :registration_setup

  defp registration_setup(%{registration: true} = ctx) do
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

    unless Oban.whereis(Comma.Oban),
      do:
        start_supervised!(
          {Oban, name: Comma.Oban, repo: Repo, testing: :manual, queues: false, plugins: false}
        )

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :apns, prior_apns)
      SystemsRuntime.put_env(:comma_core, :salix_client, prior_client)
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_registration_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: ctx.user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "registration-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "registration-test",
        name: "Native registration",
        status: "active"
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: ctx.user["id"],
      role: "owner",
      status: "active"
    })

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        ids = Repo.all(from(t in Target, where: t.group_id == ^group, select: t.id))

        Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'target_id'", j.args) in ^ids))

        Repo.delete_all(from(w in Workspace, where: w.id == ^workspace.id))
        Repo.delete_all(from(u in User, where: u.id == ^ctx.user["id"]))
      end)
    end)

    server =
      start_supervised!(
        {Bandit, plug: CommaWeb.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{workspace: workspace, base: "http://127.0.0.1:#{port}"}
  end

  defp registration_setup(_ctx), do: :ok

  for {kind, endpoint} <- [
        {"device", "devices"},
        {"push_to_start", "push-to-start"},
        {"live_activity", "live-activities"}
      ] do
    @tag registration: true
    test "#{kind} registration persists an address without an enclosing SQL transaction", ctx do
      kind = unquote(kind)
      attrs = registration_attrs(ctx.workspace, kind)

      assert %{status: 200, body: body} =
               register(ctx.base, ctx.session, unquote(endpoint), attrs)

      assert %{"id" => id, "status" => "active"} = body
      target = Repo.get!(Target, id)
      assert target.auth_session_id == ctx.session["id"]
      assert target.kind == kind
      assert target.token == attrs["token"]
    end
  end

  @tag registration: true
  test "a registration ID collision rejects the other Session and preserves its address", ctx do
    attrs = registration_attrs(ctx.workspace, "live_activity")
    assert %{status: 200} = register(ctx.base, ctx.session, "live-activities", attrs)
    {:ok, other} = Accounts.create_session(ctx.user["id"], client_kind: "ios")

    assert %{status: 422} = register(ctx.base, other, "live-activities", attrs)
    assert Repo.get!(Target, attrs["registration_id"]).auth_session_id == ctx.session["id"]

    fresh = Map.put(attrs, "registration_id", SystemsRuntime.Proc.uuid())
    assert %{status: 200} = register(ctx.base, other, "live-activities", fresh)
    assert Repo.get!(Target, fresh["registration_id"]).auth_session_id == other["id"]
  end

  test "authenticated ID-free DELETE reconciles only this session's ordinary legacy slot", ctx do
    {:ok, watch} =
      Accounts.create_session(ctx.user["id"],
        auth_method: "watch_pairing",
        parent_session_id: ctx.session["id"],
        client_kind: "watch",
        client_platform: "watchos"
      )

    {:ok, second_phone} = Accounts.create_session(ctx.user["id"], client_kind: "ios")

    {:ok, outsider} =
      Accounts.create_user(%{
        "email" =>
          "unsubscribe-other-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, outsider_session} = Accounts.create_session(outsider["id"])

    legacy_device = target(ctx.session, "device")

    survivors = [
      target(ctx.session, "live_activity"),
      target(ctx.session, "push_to_start"),
      target(watch, "device"),
      target(second_phone, "device"),
      target(outsider_session, "device")
    ]

    assert Enum.all?([legacy_device | survivors], &is_nil(&1.bundle_id))
    assert %{status: 401} = request(nil)
    assert Repo.get(Target, legacy_device.id)
    assert %{status: 204, resp_body: ""} = request(ctx.session["token"])
    assert Repo.get(Target, legacy_device.id) == nil
    assert Enum.all?(survivors, &Repo.get(Target, &1.id))
    assert %{status: 204, resp_body: ""} = request(ctx.session["token"])
    assert Enum.all?(survivors, &Repo.get(Target, &1.id))
  end

  test "restricted or revoked credentials cannot erase an ordinary registration", ctx do
    {:ok, restricted} =
      Accounts.create_session(ctx.user["id"], restricted: true, session_source: "ops_api")

    restricted_target = target(restricted, "device")
    ordinary_target = target(ctx.session, "device")
    assert %{status: 403} = request(restricted["token"])
    assert Repo.get(Target, restricted_target.id)
    assert Repo.get(Target, ordinary_target.id)
    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert %{status: 401} = request(ctx.session["token"])
    assert Repo.get(Target, ordinary_target.id)
  end

  test "Activity dismissal preserves the cohort only for the owning Session", ctx do
    start = target(ctx.session, "push_to_start")
    Repo.update!(Ecto.Changeset.change(start, activity_schema: "tasks_v1"))
    activity = target(ctx.session, "live_activity")

    Repo.update!(
      Ecto.Changeset.change(activity,
        activity_schema: "tasks_v1",
        conversation_id: nil,
        activity_content: %{"tasks" => [%{"id" => "task_visible"}]}
      )
    )

    path = "/v1/comma/notifications/registrations/#{activity.id}"
    assert %{status: 422} = request(ctx.session["token"], path <> "?reason=anything")
    assert Repo.get(Target, activity.id)
    {:ok, other} = Accounts.create_session(ctx.user["id"])
    assert %{status: 204} = request(other["token"], path <> "?reason=dismissed")
    assert Repo.get(Target, activity.id)
    assert Repo.get!(Target, start.id).suppressed_task_ids == []
    assert %{status: 204} = request(ctx.session["token"], path <> "?reason=dismissed")
    assert Repo.get(Target, activity.id) == nil
    assert Repo.get!(Target, start.id).suppressed_task_ids == ["task_visible"]
  end

  defp request(token, path \\ @path) do
    conn = conn(:delete, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    CommaWeb.Router.call(conn, @opts)
  end

  defp register(base, session, endpoint, attrs) do
    Req.post!(
      url: base <> "/v1/comma/notifications/" <> endpoint,
      headers: [{"authorization", "Bearer " <> session["token"]}],
      json: attrs,
      retry: false
    )
  end

  defp registration_attrs(workspace, kind) do
    attrs = %{
      "token" => String.duplicate("a", 64),
      "environment" => "production",
      "bundle_id" => "surf.comma.ios",
      "locale" => "zh-Hans",
      "workspace_id" => workspace.id,
      "group_id" => workspace.salix_group_id
    }

    attrs =
      if kind == "device",
        do: attrs,
        else:
          Map.merge(attrs, %{
            "activity_schema" => "tasks_v1",
            "registration_id" => SystemsRuntime.Proc.uuid()
          })

    if kind == "live_activity", do: Map.put(attrs, "activity_id", "local-activity"), else: attrs
  end

  defp target(session, kind) do
    Repo.insert!(%Target{
      auth_session_id: session["id"],
      kind: kind,
      token: String.duplicate("a", 64),
      environment: "sandbox",
      workspace_id: "wsp_unsubscribe",
      group_id: "group_unsubscribe",
      conversation_id: if(kind == "live_activity", do: "task_unsubscribe"),
      activity_id: if(kind == "live_activity", do: "activity_unsubscribe"),
      expires_at: DateTime.add(SystemsClock.utc_now(), 3_600)
    })
  end
end
