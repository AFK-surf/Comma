defmodule MailAcceptance do
  @fixture Path.join(__DIR__, "acceptance.local.json")
  def state, do: Agent.get(__MODULE__, & &1)
  def update(fun), do: Agent.update(__MODULE__, fun)

  def record(path),
    do: update(&Map.update!(&1, :requests, fn xs -> Enum.take([path | xs], 100) end))

  def model_event(event, _measurements, metadata, _config) do
    if event != [:salix, :operation, :stop] or metadata[:operation] == "decide" do
      row = Map.take(metadata, [:operation, :model_key, :provider, :outcome])
      update(&Map.update!(&1, :model_calls, fn xs -> Enum.take([row | xs], 200) end))
    end
  end

  def evidence do
    s = state()
    {:ok, monitors} = SalixStore.Loops.proactive_monitors(s.workspace["router_agent_id"])

    acked =
      s[:last_event] != nil and
        Enum.any?(monitors, &SalixStore.Loops.acked?(&1["id"], s.last_event))

    Map.take(s, [:requests, :reply, :failure, :now, :group, :scenario, :model_calls, :decisions])
    |> Map.put(:acked, acked)
  end

  def trace_decisions do
    receive do
      {:trace, _, :call, {SalixAgent.Decide, :call, [args, _ctx, _opts]}} ->
        update(&Map.update!(&1, :decisions, fn xs -> Enum.take([%{input: args} | xs], 20) end))

      {:trace, _, :return_from, {SalixAgent.Decide, :call, 3}, result} ->
        update(&Map.update!(&1, :decisions, fn xs -> Enum.take([%{output: result} | xs], 20) end))

      _ ->
        :ok
    end

    trace_decisions()
  end

  def boot do
    unless Mix.env() == :test, do: raise("MIX_ENV=test required")
    Logger.configure(level: :warning)
    config = System.fetch_env!("MAIL_ACCEPTANCE_MODEL_CONFIG") |> File.read!() |> Jason.decode!()

    saved =
      if File.exists?(@fixture) and "--reset" not in System.argv(),
        do: Jason.decode!(File.read!(@fixture)),
        else: nil

    for {app, repo, database} <- [
          {:salix_store, SalixStore.Repo, "comma_mail_acceptance"},
          {:comma_core, Comma.Repo, "comma_mail_acceptance_comma"},
          {:billing_core, BillingCore.Repo, "comma_mail_acceptance_billing"}
        ] do
      settings =
        Application.fetch_env!(app, repo)
        |> Keyword.merge(
          hostname: "127.0.0.1",
          port: String.to_integer(System.get_env("SALIX_TEST_DB_PORT", "32787")),
          database: database,
          pool: DBConnection.ConnectionPool,
          pool_size: 15
        )

      Application.put_env(app, repo, settings)

      case repo.__adapter__().storage_up(settings) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        other -> raise(inspect(other))
      end

      if app != :salix_store do
        {:ok, _, _} =
          Ecto.Migrator.with_repo(repo, fn repo ->
            Ecto.Migrator.run(repo, Application.app_dir(app, "priv/repo/migrations"), :up,
              all: true,
              log: false
            )
          end)
      end
    end

    Application.put_env(:systems_observability, :port, 0)

    for {key, value} <- [
          s3_backend: SalixStore.S3.AWS,
          s3_endpoint: "http://127.0.0.1:32790",
          s3_bucket: "comma-proactive-acceptance",
          s3_access_key_id: "minioadmin",
          s3_secret_access_key: "minioadmin"
        ],
        do: Application.put_env(:salix_store, key, value)

    Application.put_env(:comma_core, :selfhost, true)

    Application.put_env(
      :comma_core,
      Oban,
      Application.fetch_env!(:comma_core, Oban) |> Keyword.put(:testing, :disabled)
    )

    Application.put_env(
      :comma_core,
      :default_agent_template,
      Map.put(config["llm"], "template_id", "mail-acceptance-real")
    )

    Application.put_env(:billing_core, :start_repo, true)

    Application.put_env(
      :salix_agent,
      :decide,
      Enum.map(config["decide"], fn {k, v} -> {String.to_existing_atom(k), v} end)
    )

    Application.put_env(:salix_agent, :llm, SalixLlm.Provider)
    Application.put_env(:salix_agent, :composio_store_mod, Salix.Bindings.AgentComposioStore)
    Application.put_env(:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore)
    Application.put_env(:salix_agent, :schedules_mod, SalixCluster.Schedules)

    for {key, value} <- [
          port: 50368,
          allowed_origins: ["http://127.0.0.1:4177", "http://127.0.0.1:4178"],
          web_cookie_origin: "http://127.0.0.1:4177",
          admin_cookie_origin: "http://127.0.0.1:4178",
          session_cookie: [secure: false]
        ],
        do: Application.put_env(:comma_web, key, value)

    Application.put_env(:salix_web, :port, 50367)
    Application.put_env(:salix_web, :site_rate_limit_redis_url, "redis://127.0.0.1:32786/1")

    unless Application.fetch_env!(:salix_store, SalixStore.Repo)[:database] ==
             "comma_mail_acceptance",
           do: raise("unsafe database")

    if is_nil(saved), do: SalixStore.RepoTestSetup.ensure!()
    {:ok, _} = Application.ensure_all_started(:comma_web)
    {:ok, _} = Application.ensure_all_started(:salix_web)

    {:ok, _} =
      Agent.start_link(
        fn ->
          %{
            group: nil,
            requests: [],
            model_calls: [],
            decisions: [],
            reply: false,
            failure: false,
            scenario: "contract",
            now: System.system_time(:millisecond)
          }
        end,
        name: __MODULE__
      )

    :telemetry.attach_many(
      "mail-acceptance",
      [[:salix, :operation, :stop], [:salix, :llm, :attempt, :stop]],
      &__MODULE__.model_event/4,
      nil
    )

    Code.ensure_loaded!(SalixAgent.Decide)
    tracer = spawn(fn -> trace_decisions() end)
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern({SalixAgent.Decide, :call, 3}, [{:_, [], [{:return_trace}]}], [:local])

    {:ok, server} =
      Bandit.start_link(
        plug: MailAcceptance.Provider,
        ip: {127, 0, 0, 1},
        port: 50369,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}")

    {user, workspace} =
      if saved do
        {:ok, workspace} = Comma.Workspaces.get(saved["workspace"])
        {:ok, user} = Comma.Accounts.get_user(workspace["owner_user_id"])
        {user, workspace}
      else
        {:ok, user} =
          Comma.Accounts.create_user(%{
            "email" => "acceptance-#{System.system_time(:microsecond)}@example.test",
            "name" => "Mail Acceptance"
          })

        {user,
         Comma.WorkspaceTestSupport.create_ready_workspace!(user, %{
           "name" => "Mail acceptance",
           "vm" => %{"enabled" => false}
         })}
      end

    {:ok, workspace} = CommaWeb.SalixClient.resolve_workspace_scope(workspace)
    {:ok, _} = CommaWeb.SalixClient.ensure_group_router_conversation(workspace)
    group = workspace["default_group_id"]
    secret = String.duplicate("m", 43)

    {:ok, _} =
      SalixStore.ComposioSettings.put(workspace["salix_tenant_id"], %{
        "api_key" => "local-fixture",
        "enabled" => true,
        "webhook_secret" => secret
      })

    if is_nil(saved),
      do: Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "gmail", "ca_acceptance")

    {:ok, session} = Comma.Accounts.create_session(user["id"])
    update(&Map.merge(&1, %{group: group, user: user, workspace: workspace, secret: secret}))

    result = %{
      api: CommaWeb.Application.base_url(),
      control: "http://127.0.0.1:#{port}",
      session: session["token"],
      group: group,
      workspace: workspace["id"],
      model: config["llm"]["model"]
    }

    File.write!(@fixture, Jason.encode!(result))
    File.chmod!(@fixture, 0o600)
    :ok = Oban.start_queue(Comma.Oban, queue: :comma_external, limit: 1)
    IO.puts("MAIL_ACCEPTANCE_READY " <> Jason.encode!(Map.drop(result, [:session])))
  end

  def message(id, reply \\ false) do
    scenario = id |> String.replace_prefix("mail_", "") |> String.replace_suffix("_reply", "")

    {subject, body} =
      case scenario do
        "quiet" ->
          {"Your sign-in verification code",
           "Your one-time verification code is 123456. It expires in ten minutes. This automated email needs no reply or follow-up."}

        "waiting" ->
          {"Please confirm the appointment",
           "Hi Alex, I sent this three days ago and am waiting for your confirmation of our Tuesday appointment. Please reply with confirmation. Thanks."}

        "bill" ->
          {"Invoice due tomorrow",
           "Your fictional studio invoice of $85 is due tomorrow at 17:00. It is not paid yet. Please arrange payment before the due date. No attachment."}

        _ ->
          {"Contract approval due tomorrow",
           "Please review the contract terms and approve by tomorrow at 17:00. We need your response before we can start. The fee is $120 and the term is one month. No attachments."}
      end

    %{
      "id" => id,
      "threadId" => "thread_" <> scenario,
      "internalDate" => Integer.to_string(state().now),
      "labelIds" =>
        if(scenario == "waiting" and not reply, do: ["SENT"], else: ["INBOX", "UNREAD"]),
      "payload" => %{
        "mimeType" => "text/plain",
        "headers" => [
          %{"name" => "Subject", "value" => subject},
          %{
            "name" => "From",
            "value" =>
              if(scenario == "waiting" and not reply,
                do: "owner@example.test",
                else: "alex@example.test"
              )
          },
          %{
            "name" => "To",
            "value" =>
              if(scenario == "waiting" and not reply,
                do: "alex@example.test",
                else: "owner@example.test"
              )
          }
        ],
        "body" => %{
          "data" =>
            Base.url_encode64(
              if(reply,
                do:
                  "Confirmed: our Tuesday appointment is booked. You have my confirmation; no further reply or follow-up is needed.",
                else: body
              ),
              padding: false
            )
        }
      }
    }
  end

  def inject do
    s = state()
    event_id = "event_#{s.scenario}_#{s.now}"
    update(&Map.put(&1, :last_event, event_id))

    Req.post!(SalixWeb.Application.base_url() <> "/v1/composio-webhooks/" <> s.secret,
      json: %{
        "id" => event_id,
        "type" => "composio.trigger.message",
        "data" => %{
          "id" => "mail_" <> s.scenario,
          "message_id" => "mail_" <> s.scenario,
          "threadId" => "thread_" <> s.scenario
        },
        "metadata" => %{
          "trigger_id" => "ti_acceptance",
          "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
          "connected_account_id" => "ca_acceptance",
          "user_id" => s.group
        }
      },
      retry: false
    ).body
  end
end

defmodule MailAcceptance.Provider do
  use Plug.Router
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  match _ do
    path = conn.request_path
    MailAcceptance.record(path)
    s = MailAcceptance.state()

    {status, body} =
      cond do
        path == "/acceptance/evidence" ->
          {200, MailAcceptance.evidence()}

        path == "/acceptance/scenario" ->
          scenario = conn.body_params["scenario"]
          if scenario not in ~w(contract quiet waiting bill), do: raise("unknown scenario")
          MailAcceptance.update(&%{&1 | scenario: scenario, reply: false, failure: false})
          {200, %{ok: true}}

        path == "/acceptance/inject" ->
          {200, MailAcceptance.inject()}

        path == "/acceptance/reply" ->
          MailAcceptance.update(&%{&1 | reply: true})
          {200, %{ok: true}}

        path == "/acceptance/fail" ->
          MailAcceptance.update(&%{&1 | failure: true})
          {200, %{ok: true}}

        path == "/acceptance/advance" ->
          now = s.now + (conn.body_params["milliseconds"] || 3_600_000)
          MailAcceptance.update(&%{&1 | now: now})
          result = SalixCluster.Schedules.run_once(now: now)
          {200, %{now: now, result: inspect(result)}}

        path == "/api/v3/connected_accounts" ->
          {200,
           %{
             "items" => [
               %{
                 "id" => "ca_acceptance",
                 "user_id" => s.group,
                 "status" => "ACTIVE",
                 "toolkit" => %{"slug" => "gmail"}
               }
             ]
           }}

        String.starts_with?(path, "/api/v3/connected_accounts/") ->
          {200,
           %{
             "id" => "ca_acceptance",
             "user_id" => s.group,
             "status" => "ACTIVE",
             "toolkit" => %{"slug" => "gmail"}
           }}

        String.starts_with?(path, "/api/v3/tools/execute/") ->
          slug = List.last(conn.path_info)
          args = conn.body_params["arguments"] || %{}
          MailAcceptance.record(slug)

          data =
            case slug do
              "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID" ->
                MailAcceptance.message(args["message_id"])

              "GMAIL_FETCH_MESSAGE_BY_THREAD_ID" ->
                scenario = String.replace_prefix(args["thread_id"], "thread_", "")
                messages = [MailAcceptance.message("mail_" <> scenario)]

                messages =
                  if s.reply and scenario == s.scenario,
                    do:
                      messages ++ [MailAcceptance.message("mail_" <> scenario <> "_reply", true)],
                    else: messages

                %{"id" => args["thread_id"], "messages" => messages}

              _ ->
                raise "Only fixture source reads are permitted"
            end

          {200, %{"successful" => not s.failure, "data" => data}}

        path == "/api/v3.1/tool_router/session" ->
          {200, %{"session_id" => "local_proxy"}}

        String.ends_with?(path, "/proxy_execute") ->
          p = conn.body_params
          if p["method"] != "GET", do: raise("outbound provider mutation forbidden")
          url = p["endpoint"] || ""
          MailAcceptance.record(url)

          data =
            cond do
              String.ends_with?(url, "/profile") ->
                %{"emailAddress" => "owner@example.test"}

              String.contains?(url, "/messages/") ->
                MailAcceptance.message(URI.parse(url).path |> String.split("/") |> List.last())

              String.contains?(url, "/threads/") ->
                thread = URI.parse(url).path |> String.split("/") |> List.last()
                scenario = String.replace_prefix(thread, "thread_", "")

                %{
                  "id" => thread,
                  "messages" =>
                    [MailAcceptance.message("mail_" <> scenario)]
                    |> then(fn xs ->
                      if s.reply and scenario == s.scenario,
                        do: xs ++ [MailAcceptance.message("mail_" <> scenario <> "_reply", true)],
                        else: xs
                    end)
                }

              true ->
                %{"messages" => [%{"id" => "mail_contract", "threadId" => "thread_contract"}]}
            end

          {200, %{"status" => if(s.failure, do: 503, else: 200), "data" => data}}

        String.contains?(path, "trigger_instances") ->
          {200, %{"trigger_id" => "ti_acceptance", "id" => "ti_acceptance"}}

        conn.method == "DELETE" ->
          {200, %{}}

        true ->
          {404, %{error: "unsupported_fixture_route", path: path}}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end

MailAcceptance.boot()
Process.sleep(:infinity)
