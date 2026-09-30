# Local preview of the production LiveView with explicit, isolated test data.
# Run with MIX_ENV=test, --no-start, and MEETING_PREVIEW_DB_PORT on local Postgres.
unless Mix.env() == :test, do: raise("meeting preview requires MIX_ENV=test")

port = System.fetch_env!("MEETING_PREVIEW_DB_PORT") |> String.to_integer()

for {app, repo} <- [
      {:bridge_for_teams_core, BridgeForTeams.Repo},
      {:billing_core, BillingCore.Repo},
      {:salix_store, SalixStore.Repo},
      {:comma_core, Comma.Repo},
      {:alert_router, AlertRouter.Repo}
    ] do
  config = Application.fetch_env!(app, repo)

  Application.put_env(
    app,
    repo,
    Keyword.merge(config,
      hostname: "127.0.0.1",
      port: port,
      database: "#{app}_meeting_preview",
      username: "postgres",
      password: "postgres"
    )
  )
end

Application.put_env(:salix_env, :transfer_port, 0)
Application.put_env(:systems_observability, :port, 0)
Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
Application.delete_env(:salix_meet, :calendar_autojoin)
Application.put_env(:salix_meet, :calendar_autojoin_channels, [])
Application.put_env(:bridge_for_teams_web, :dev_login, true)
endpoint = BridgeForTeamsWeb.DashboardEndpoint
config = Application.fetch_env!(:bridge_for_teams_web, endpoint)

Application.put_env(
  :bridge_for_teams_web,
  endpoint,
  Keyword.merge(config, server: true, http: [ip: {127, 0, 0, 1}, port: 4411])
)

Logger.configure(level: :warning)
Mix.Task.run("ecto.create", ["--quiet", "--no-compile"])
Mix.Task.run("ecto.migrate", ["--quiet", "--no-compile"])
Mix.Task.run("app.start")

for repo <- [BridgeForTeams.Repo, BillingCore.Repo] do
  unless Process.whereis(repo), do: repo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
end

unless Process.whereis(SalixStore.S3.Fake), do: SalixStore.S3.Fake.start_link()

if snapshot_path = System.get_env("MEETING_PREVIEW_SNAPSHOT") do
  Code.require_file("meeting_preparation_snapshot.exs", __DIR__)
  BridgeForTeamsWeb.MeetingPreparationSnapshot.start(snapshot_path)
else
  {:ok, _} = SalixWeb.Test.MeetingPreparationProvider.start_link()

  {:ok, server} =
    Bandit.start_link(plug: SalixWeb.Test.MeetingPreparationProvider, port: 0, ip: {127, 0, 0, 1})

  {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
  Application.put_env(:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}")
  Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

  alias BridgeForTeams.{Accounts, Memberships, Orgs, UserOnboardings}
  alias SalixStore.{Ids, Keys, S3}

  {:ok, user} =
    Accounts.create_user(%{
      "name" => "本地预览",
      "email" => "meeting-preview-#{System.system_time(:second)}@example.test"
    })

  {:ok, user} = Accounts.update_locale(user, System.get_env("MEETING_PREVIEW_LOCALE", "zh_Hans"))
  {:ok, onboarding} = UserOnboardings.ensure_onboarding(user.id)
  {:ok, _} = UserOnboardings.complete(onboarding)

  {:ok, org} =
    Orgs.create_org(%{
      "name" => "本地测试 · 会前准备",
      "slug" => "meeting-preview-#{System.system_time(:second)}"
    })

  {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")

  project =
    BridgeForTeams.Repo.insert!(%BridgeForTeams.Schema.Project{
      org_id: org.id,
      name: "产品与研发（测试数据）",
      slug: "meeting-preview",
      salix_group_id: Ids.new_group_id(org.salix_tenant_id)
    })

  fixture = BridgeForTeamsWeb.MeetingPreparationFixture.seed(org, project)

  {:ok, settings} =
    Salix.Bindings.MeetingPreparationDashboard.run(
      org.salix_tenant_id,
      project.salix_group_id,
      "save",
      %{
        "enabled" => true,
        "connect_id" => fixture.connect_id,
        "channel_id" => "C-TEAM",
        "calendar_selections" => [
          %{"account_id" => "ca-product", "calendar_id" => "product@example.test"},
          %{"account_id" => "ca-engineering", "calendar_id" => "engineering@example.test"}
        ],
        "preparation_lead_minutes" => 30,
        "research_enabled" => true,
        "autojoin" => false,
        "calendar_writeback" => false,
        "series" => []
      }
    )

  # Persist sample status records only. No schedules, model runs, or provider sends.
  now = System.system_time(:millisecond)
  calendar_id = Ids.new_calendar_id()
  group = Map.put(fixture.group, "calendar_id", calendar_id)

  events =
    for {title, minutes, state} <- [
          {"Technical Design · 测试会议", 90, :ready},
          {"产品迭代讨论 · 测试会议", 150, :preparing},
          {"每周进展回顾 · 测试会议", 240, :scheduled}
        ] do
      plan_id = Ids.new_meeting_plan_id()
      item_id = Ids.new_calendar_item_id()

      ref = %{
        "calendar_id" => calendar_id,
        "calendar_item_id" => item_id,
        "recurrence_key" => %{"value" => title}
      }

      start_ms = now + :timer.minutes(minutes)

      prep = %{
        "policy_revision" => settings["settings_revision"],
        "card_status" => "pending",
        "research_decision" => "pending",
        "decision_at" => start_ms - :timer.minutes(50),
        "publish_deadline_at" => start_ms - :timer.minutes(30)
      }

      prep =
        case state do
          :ready ->
            Map.put(
              prep,
              "report",
              "本地测试内容，用于检查 Dashboard 展示效果。\n\n本次讨论\n• 确认日历选择范围及会议系列。\n• 检查发送频道、提前时间与团队准备内容。\n\n待确认\n• 个人设置需完成 Dashboard 与 Slack 的身份绑定后开放。"
            )

          :preparing ->
            Map.put(prep, "research_task", %{"task_id" => "local-preview"})

          :scheduled ->
            prep
        end

      {:ok, _} =
        S3.put(
          Keys.ctl_meeting_plan(group["group_id"], plan_id),
          Jason.encode!(%{
            "group_id" => group["group_id"],
            "meeting_plan_id" => plan_id,
            "occurrence_ref" => ref,
            "status" => "planned",
            "managed_calendar" => true,
            "preparation" => prep,
            "updated_at" => now
          })
        )

      %{
        "event_id" => plan_id,
        "title" => title,
        "start_ms" => start_ms,
        "end_ms" => start_ms + :timer.hours(1),
        "calendar_id" => calendar_id,
        "calendar_item_id" => item_id,
        "meeting_plan_id" => plan_id,
        "occurrence_ref" => ref,
        "meet_url" => "https://meet.google.com/abc-defg-hij"
      }
    end

  {:ok, projection} = SalixMeet.CalendarProjection.load(group)

  {:ok, projection, _} =
    SalixMeet.CalendarProjection.reconcile(projection, events, %{}, max_events: 20)

  {:ok, _} = SalixMeet.CalendarProjection.checkpoint(projection)

  # Existing material permalinks are fixtures, not uploaded files.
  :ok = SalixStore.MeetingGroupProjections.mark_ready(%{"source" => "meeting-preview"})
  :ok = SalixStore.MeetingGroupProjectionReadiness.refresh()

  for {id, attrs} <- [
        {"record-a-", %{}},
        {"record-b-",
         %{
           "title" => "Planning · sample meeting",
           "start_at" => 1_789_600_000,
           "delivery" => %{},
           "artifacts" => %{}
         }},
        {"record-c-",
         %{
           "title" => "Design sync · sample meeting",
           "status" => "processing",
           "start_at" => 1_789_590_000,
           "delivery" => %{},
           "artifacts" => %{}
         }},
        {"record-private-",
         %{
           "title" => "Private source must not appear",
           "slack_ref" => %{"channel_id" => "CPRIVATE"}
         }}
      ] do
    BridgeForTeamsWeb.MeetingPreparationFixture.seed_record(
      fixture.group,
      fixture.connect_id,
      id <> project.id,
      attrs
    )
  end

  url =
    "http://127.0.0.1:4411/dev/login?" <>
      URI.encode_query(%{"email" => user.email, "to" => "/orgs/#{org.slug}/meetings"})

  IO.puts("MEETING_PREVIEW_URL=" <> url)
  Process.sleep(:infinity)
end
