# PROTOTYPE. Real Salix APIs, compiled Loop, tool dispatch, and Conversation owner.
# Synthetic Composio and decision HTTP services. Scripted conversational model.
# No Gmail credentials, external sends, or production application changes.

defmodule ProactivePrototype do
  alias SalixAgent.{AgentWorkspace, Fleet, Loops, SpinfoamFixture}
  alias SalixAgent.Loops.Host
  @root __DIR__
  @token "local-proactive-prototype"
  @names ~w(important quiet missing_body model_error uncertain duplicate foreign_account restart model_redelivery model_retry)

  def names, do: @names

  def boot do
    unless Mix.env() == :test, do: raise("Run with MIX_ENV=test")
    repo = Application.fetch_env!(:salix_store, SalixStore.Repo)

    unless repo[:hostname] == "127.0.0.1" and repo[:database] == "proactive_chat_prototype",
      do: raise("This prototype requires its own loopback database: proactive_chat_prototype")

    Logger.configure(level: :warning)
    Application.put_env(:systems_observability, :port, 0)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, @token)
    Application.put_env(:salix_web, :port, 0)

    Application.put_env(
      :salix_web,
      :site_rate_limit_redis_url,
      System.fetch_env!("REDIS_TEST_URL")
    )

    Application.put_env(:salix_agent, :llm, ProactivePrototype.ChatModel)
    IO.puts("PROTOTYPE_BOOT: isolated database")
    SalixStore.RepoTestSetup.ensure!()
    IO.puts("PROTOTYPE_BOOT: runtime")
    {:ok, _} = Application.ensure_all_started(:salix_web)

    case Salix.App.RouterInbox.RateLimit.hit("prototype-preflight", 60_000, 100) do
      {:allow, _} -> :ok
      other -> raise("prototype Redis preflight failed: #{inspect(other)}")
    end

    {:ok, _} = SalixAgent.LLM.Mock.start_link()

    {:ok, _} =
      Agent.start_link(fn -> %{requests: [], reports: [], busy: false} end, name: __MODULE__)

    {:ok, provider} =
      Bandit.start_link(
        plug: ProactivePrototype.Provider,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(provider)
    base = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_store, :composio_base_url_override, base)
    Application.put_env(:salix_web, :composio_client_mod, SalixStore.Composio)
    Application.put_env(:salix_agent, :composio_client_mod, SalixStore.Composio)
    Application.put_env(:salix_agent, :composio_store_mod, Salix.Bindings.AgentComposioStore)
    Application.put_env(:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore)

    Application.put_env(:salix_agent, :decide,
      endpoint: base <> "/v1/systemone",
      api_key: "prototype",
      model: "synthetic-policy"
    )

    await(fn -> Host.status().available end)
    elf = SpinfoamFixture.compile!(File.read!(Path.join(@root, "mail.c")))
    Agent.update(__MODULE__, &Map.put(&1, :elf, elf))
    IO.puts("PROTOTYPE_READY: compiled Loop + local provider + real Conversation owner")
  end

  def run(name) when name in @names do
    started = System.monotonic_time(:millisecond)

    Agent.update(
      __MODULE__,
      &Map.merge(&1, %{
        requests: [],
        busy: true,
        ctx: nil,
        scenario: name,
        provider_recovered: false
      })
    )

    try do
      ctx = setup(name)
      Agent.update(__MODULE__, &Map.put(&1, :ctx, ctx))
      report = exercise(ctx, name)

      finish(
        Map.merge(report, %{
          scenario: name,
          elapsed_ms: System.monotonic_time(:millisecond) - started
        })
      )
    rescue
      error ->
        finish(%{
          scenario: name,
          outcome: "error",
          error: Exception.format(:error, error, __STACKTRACE__)
        })
    after
      ctx = Agent.get(__MODULE__, &Map.get(&1, :ctx))

      if ctx do
        Loops.delete(ctx.agent_id, ctx.loop_id)
        Fleet.stop_existing(ctx.agent_id)
      end

      Agent.update(__MODULE__, &%{&1 | busy: false, ctx: nil})
    end
  end

  defp setup(name) do
    id = System.unique_integer([:positive])
    tenant = req(@token, :post, "/v1/admin/tenants", %{name: "PROTOTYPE #{id}"}, 201)

    key =
      req(
        @token,
        :post,
        "/v1/admin/tenants/#{tenant["tenant_id"]}/api-keys",
        %{name: "prototype"},
        201
      )["key"]

    template =
      req(
        @token,
        :post,
        "/v1/admin/templates",
        %{template_id: "prototype-#{id}", name: "Prototype", model: "mock-model"},
        201
      )

    group =
      req(key, :post, "/v1/runtime/agent-groups", %{name: "PROTOTYPE #{id}"}, 201)["group_id"]

    router =
      req(
        key,
        :post,
        "/v1/runtime/agents",
        %{
          group_id: group,
          template_id: template["template_id"],
          role: "router",
          name: "Prototype assistant"
        },
        201
      )

    agent = router["agent_id"]
    req(key, :patch, "/v1/runtime/agent-groups/#{group}", %{router_agent_id: agent}, 200)

    conversation =
      req(key, :get, "/v1/runtime/agent-groups/#{group}/router/conversation", nil, 200)[
        "conversation_id"
      ]

    {:ok, record} = SalixAgent.Control.get_record(agent)
    session = record["router_session_id"]
    {:ok, _} = SalixAgent.InternalSessionStore.prepare_commit(agent, session, [])
    {:ok, _} = Fleet.ensure_started(agent, create: false)
    :ok = Fleet.await_ownership_installed(agent)

    {:ok, write} =
      AgentWorkspace.prepare_write(agent, "/loops/prototype.elf", Agent.get(__MODULE__, & &1.elf))

    {:ok, _} = AgentWorkspace.seed_operation(agent, "prototype-#{id}", %{}, [write])

    {:ok, loop} =
      Loops.create(%{agent_id: agent, session_id: session, role: "router"}, %{
        "path" => "/loops/prototype.elf",
        "name" => "Mail prototype",
        "config" => %{
          "account_id" => "ca_prototype",
          "decision_attempts" => if(name == "model_redelivery", do: 1, else: 2),
          "startup_delay_ms" => if(name == "restart", do: 5000, else: 0)
        }
      })

    loop_id = loop["loop_id"]
    await(fn -> is_binary(Host.object_for_loop(loop_id)) end)

    ctx = %{
      key: key,
      group_id: group,
      agent_id: agent,
      session_id: session,
      conversation_id: conversation,
      loop_id: loop_id,
      mail: mail(name),
      event_id: "event-#{id}"
    }

    Agent.update(__MODULE__, &Map.put(&1, :ctx, ctx))
    req(key, :put, "/v1/runtime/composio/settings", %{api_key: "synthetic-provider"}, 200)
    webhook = req(key, :post, "/v1/runtime/composio/webhook", %{}, 200)["webhook_url"]

    SalixAgent.Tools.ComposioTriggers.create(
      %{
        "loop_id" => loop_id,
        "connected_account_id" => "ca_prototype",
        "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
        "trigger_config" => %{}
      },
      %{agent_id: agent, session_id: session, role: "router"}
    )

    Map.put(ctx, :webhook, webhook)
  end

  def mail(name) do
    body =
      case name do
        "quiet" ->
          "The deadline is cancelled. No action is needed."

        "missing_body" ->
          ""

        "uncertain" ->
          "There may be a change to the plan. Details will follow."

        _ ->
          "Please confirm the release before 17:00 today. Deployment is blocked until you approve."
      end

    %{
      "messageId" => "mail-1",
      "subject" => "Release update",
      "sender" => "colleague@example.test",
      "body" => body,
      "webUrl" => "https://example.test/mail/mail-1"
    }
  end

  defp exercise(ctx, name) do
    text = "邮件提醒：#{ctx.mail["subject"]}\n#{ctx.mail["body"]}\n来源：#{ctx.mail["webUrl"]}"

    SalixAgent.LLM.Mock.script([
      {:assistant, "",
       [
         %{
           id: "notify-#{ctx.event_id}",
           name: "call",
           args: %{
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => ctx.conversation_id,
               "content" => [%{"type" => "text", "text" => text}]
             }
           }
         }
       ]},
      {:final, "prototype turn complete"}
    ])

    event = %{
      "id" => ctx.event_id,
      "type" => "composio.trigger.message",
      "metadata" => %{
        "trigger_id" => "ti_prototype",
        "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
        "user_id" => ctx.group_id,
        "connected_account_id" =>
          if(name == "foreign_account", do: "ca_foreign", else: "ca_prototype")
      },
      "data" => %{"message_id" => "mail-1"}
    }

    response = post_event(ctx, event)

    if response.status != 202 do
      %{
        outcome: "rejected",
        ingress_status: response.status,
        ingress: response.body,
        messages: messages(ctx),
        trace: trace()
      }
    else
      recovery =
        if name == "restart" do
          old_object = Host.object_for_loop(ctx.loop_id)
          :ok = Fleet.stop_existing(ctx.agent_id)
          await(fn -> is_nil(Host.object_for_loop(ctx.loop_id)) end)
          {:ok, _} = Fleet.ensure_started(ctx.agent_id, create: false)
          :ok = Fleet.await_ownership_installed(ctx.agent_id)

          await(fn ->
            id = Host.object_for_loop(ctx.loop_id)
            is_binary(id) and id != old_object
          end)

          await(fn ->
            SalixStore.Loops.acked?(ctx.loop_id, ctx.event_id) and length(messages(ctx)) == 1
          end)

          {:ok, checkpoint} = Loops.get_checkpoint(ctx.loop_id)

          snapshot = %{
            after_restart_checkpoint: checkpoint,
            after_restart_messages: messages(ctx),
            after_restart_acked: SalixStore.Loops.acked?(ctx.loop_id, ctx.event_id)
          }

          retry = post_event(ctx, event)
          Map.put(snapshot, :upstream_redelivery_status, retry.status)
        end

      recovery =
        if name == "model_retry" do
          await(fn ->
            {:ok, state} = Loops.get_checkpoint(ctx.loop_id)
            state["stage"] == "retry_wait"
          end)

          acked = SalixStore.Loops.acked?(ctx.loop_id, ctx.event_id)
          Agent.update(__MODULE__, &Map.put(&1, :provider_recovered, true))

          %{
            first_attempt: "decision_error",
            first_attempt_acked: acked,
            retry_owner: "compiled Loop, retained event, one retry"
          }
        else
          recovery
        end

      row =
        await(fn ->
          {:ok, row} = SalixStore.Loops.get(ctx.loop_id)
          stage = get_in(row, ["checkpoint", "stage"])

          if stage in ~w(quiet defer source_error decision_error wake_result) and
               not (name == "model_retry" and stage == "decision_error"),
             do: row
        end)

      stage = row["checkpoint"]["stage"]

      recovery =
        if name == "model_redelivery" do
          Agent.update(__MODULE__, &Map.put(&1, :provider_recovered, true))
          retry = post_event(ctx, event)

          {:ok, runtime} =
            Host.deliver_loop_event(ctx.loop_id, %{
              "event_id" => ctx.event_id,
              "topic" => "GMAIL_NEW_GMAIL_MESSAGE",
              "payload" => event["data"]
            })

          Process.sleep(300)

          %{
            redelivery_status: retry.status,
            runtime: runtime,
            acked_before_retry: SalixStore.Loops.acked?(ctx.loop_id, ctx.event_id)
          }
        else
          recovery
        end

      visible =
        if stage == "wake_result" do
          await(fn ->
            case messages(ctx) do
              [] -> nil
              rows -> rows
            end
          end)
        else
          messages(ctx)
        end

      duplicate =
        if name == "duplicate" do
          retry = post_event(ctx, event)
          Process.sleep(300)
          %{ingress_status: retry.status, messages_after_retry: length(messages(ctx))}
        end

      {:ok, session} = SalixAgent.InternalSessionStore.read(ctx.agent_id, ctx.session_id)

      wakes =
        SalixAgent.InternalSession.get(session, :messages)
        |> Enum.filter(
          &String.starts_with?(
            to_string(&1[:source_message_id] || &1["source_message_id"] || ""),
            "loop:"
          )
        )
        |> Enum.map(&Map.take(&1, [:source_message_id, :content, "source_message_id", "content"]))

      %{
        outcome:
          cond do
            name == "model_redelivery" -> "retry_suppressed"
            visible == [] -> stage
            true -> "visible_reply"
          end,
        ingress_status: response.status,
        checkpoint: row["checkpoint"],
        messages: visible,
        session_wakes: wakes,
        acknowledged: SalixStore.Loops.acked?(ctx.loop_id, ctx.event_id),
        duplicate: duplicate,
        recovery: recovery,
        trace: trace(),
        evidence: %{
          runtime: "real compiled Loop / tool dispatch / Session / Conversation owner",
          source: "synthetic Composio HTTP",
          decision: "synthetic typed-decision HTTP, real Decide facade",
          reply: "scripted LLM, real authorized message write",
          product_target:
            "isolated Salix Router conversation; Comma account binding is not exercised"
        }
      }
    end
  end

  defp post_event(ctx, event),
    do:
      Req.post!(SalixWeb.Application.base_url() <> URI.parse(ctx.webhook).path,
        json: event,
        retry: false
      )

  defp messages(ctx),
    do:
      req(
        ctx.key,
        :get,
        "/v1/runtime/agent-groups/#{ctx.group_id}/conversations/#{ctx.conversation_id}/messages?limit=100",
        nil,
        200
      )

  defp trace, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  defp finish(report) do
    report = Map.put(report, :verified, verify(report))
    Agent.update(__MODULE__, &%{&1 | reports: Enum.take(&1.reports ++ [report], -20)})
    IO.puts("PROTOTYPE_RESULT " <> Jason.encode!(report))
    report
  end

  defp verify(%{scenario: name} = report) do
    reads =
      Enum.filter(report[:trace] || [], &(&1.path == "/api/v3/tools/execute/GMAIL_FETCH_EMAILS"))

    decisions = Enum.filter(report[:trace] || [], &(&1.path == "/v1/systemone"))
    messages = report[:messages] || []

    case name do
      n when n in ~w(important duplicate) ->
        report[:outcome] == "visible_reply" and length(messages) == 1 and length(reads) == 1 and
          length(decisions) == 1 and length(report[:session_wakes] || []) == 1 and
          report[:acknowledged] == true and
          Enum.find(report[:trace] || [], &(&1.path == "chat-model"))[:body][:body_present] ==
            true and
          (n != "duplicate" or report[:duplicate][:messages_after_retry] == 1)

      "quiet" ->
        report[:outcome] == "quiet" and messages == [] and length(decisions) == 1 and
          report[:acknowledged] == true

      "missing_body" ->
        report[:outcome] == "source_error" and messages == [] and length(reads) == 1 and
          decisions == [] and report[:acknowledged] == false

      "model_error" ->
        report[:outcome] == "decision_error" and messages == [] and length(decisions) == 2 and
          report[:acknowledged] == false

      "uncertain" ->
        report[:outcome] == "defer" and messages == [] and length(decisions) == 1 and
          report[:acknowledged] == false

      "foreign_account" ->
        report[:ingress_status] == 422 and messages == [] and reads == [] and decisions == []

      "restart" ->
        report[:outcome] == "visible_reply" and length(messages) == 1 and length(decisions) == 1 and
          report[:recovery][:after_restart_checkpoint]["stage"] == "wake_result" and
          length(report[:recovery][:after_restart_messages]) == 1 and
          report[:recovery][:after_restart_acked] == true and
          report[:recovery][:upstream_redelivery_status] == 202

      "model_retry" ->
        report[:outcome] == "visible_reply" and length(messages) == 1 and length(decisions) == 2 and
          report[:recovery][:first_attempt_acked] == false and
          report[:acknowledged] == true

      "model_redelivery" ->
        report[:outcome] == "retry_suppressed" and messages == [] and length(decisions) == 1 and
          report[:recovery][:runtime]["duplicate"] == true and report[:acknowledged] == false
    end
  end

  def state, do: Agent.get(__MODULE__, &Map.take(&1, [:reports, :busy, :scenario]))

  def serve do
    {:ok, server} =
      Bandit.start_link(
        plug: ProactivePrototype.UI,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    IO.puts("PROTOTYPE_URL=http://127.0.0.1:#{port}")
    Process.sleep(:infinity)
  end

  def record(request),
    do:
      Agent.update(
        __MODULE__,
        &Map.update!(&1, :requests, fn rows -> Enum.take([request | rows], 80) end)
      )

  def req(token, method, path, body, expected) do
    opts = [
      method: method,
      url: SalixWeb.Application.base_url() <> path,
      headers: [{"authorization", "Bearer " <> token}],
      retry: false
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts
    res = Req.request!(opts)
    if res.status != expected, do: raise("#{method} #{path}: #{res.status} #{inspect(res.body)}")
    res.body
  end

  def await(fun, deadline \\ System.monotonic_time(:millisecond) + 20_000) do
    case fun.() do
      value when value in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("prototype stage timed out")
        Process.sleep(50)
        await(fun, deadline)

      value ->
        value
    end
  end
end

defmodule ProactivePrototype.ChatModel do
  # The response is scripted, but verify what the real Session projects to the model.
  def complete(messages, tools) do
    capture(messages)
    SalixAgent.LLM.Mock.complete(messages, tools)
  end

  def complete_stream(messages, tools, on_delta),
    do: complete_stream(messages, tools, on_delta, [])

  def complete_stream(messages, tools, on_delta, opts) do
    capture(messages)
    SalixAgent.LLM.Mock.complete_stream(messages, tools, on_delta, opts)
  end

  defp capture(messages) do
    ctx = Agent.get(ProactivePrototype, &Map.get(&1, :ctx))
    encoded = Jason.encode!(messages)

    ProactivePrototype.record(%{
      path: "chat-model",
      method: "complete",
      body: %{body_present: ctx != nil and String.contains?(encoded, ctx.mail["body"])}
    })
  end
end

defmodule ProactivePrototype.Provider do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    {:ok, raw, conn} = read_body(conn)
    args = if raw == "", do: %{}, else: Jason.decode!(raw)
    ctx = Agent.get(ProactivePrototype, &Map.get(&1, :ctx, %{}))
    name = Agent.get(ProactivePrototype, &Map.get(&1, :scenario))
    ProactivePrototype.record(%{path: conn.request_path, method: conn.method, body: args})

    {status, body} =
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3.1/webhook_subscriptions"} ->
          {200, %{items: []}}

        {"POST", "/api/v3.1/webhook_subscriptions"} ->
          {200, Map.put(args, "id", "wh_prototype")}

        {"GET", "/api/v3/connected_accounts/ca_prototype"} ->
          {200, %{id: "ca_prototype", user_id: ctx.group_id, status: "ACTIVE"}}

        {"GET", "/api/v3/connected_accounts/ca_foreign"} ->
          {200, %{id: "ca_foreign", user_id: "foreign-group", status: "ACTIVE"}}

        {"POST", "/api/v3.1/trigger_instances/GMAIL_NEW_GMAIL_MESSAGE/upsert"} ->
          {200, %{trigger_id: "ti_prototype"}}

        {"GET", "/api/v3.1/trigger_instances/active"} ->
          {200,
           %{
             items: [
               %{
                 id: "ti_prototype",
                 connected_account_id: "ca_prototype",
                 user_id: ctx.group_id,
                 trigger_name: "GMAIL_NEW_GMAIL_MESSAGE"
               }
             ]
           }}

        {"POST", "/api/v3/tools/execute/GMAIL_FETCH_EMAILS"} ->
          if get_in(args, ["arguments", "query"]) == "mail-1" and
               get_in(args, ["arguments", "include_payload"]) == true,
             do: {200, %{successful: true, data: %{messages: [ctx.mail]}}},
             else: {422, %{error: "exact synthetic mail ID and body required"}}

        {"POST", "/v1/systemone"} ->
          recovered = Agent.get(ProactivePrototype, &Map.get(&1, :provider_recovered, false))

          if name == "model_error" or
               (name in ["model_retry", "model_redelivery"] and not recovered) do
            {503, %{error: "synthetic model unavailable"}}
          else
            body = get_in(args, ["state", "body"]) || ""

            choice =
              cond do
                String.contains?(body, "No action") -> "quiet"
                String.contains?(body, "before 17:00") -> "notify"
                true -> "defer"
              end

            probabilities =
              Map.new(~w(notify quiet defer), &{&1, if(&1 == choice, do: 1.0, else: 0.0)})

            {200,
             %{
               model: "synthetic-policy",
               answers: %{
                 attention: %{
                   type: "choice",
                   choice: choice,
                   confidence: 1.0,
                   probabilities: probabilities
                 }
               },
               usage: %{input_tokens: 10, output_tokens: 1}
             }}
          end

        _ ->
          {404, %{error: "unimplemented synthetic provider route"}}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end

defmodule ProactivePrototype.UI do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    case {conn.method, conn.request_path} do
      {"GET", "/"} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, File.read!(Path.join(__DIR__, "index.html")))

      {"GET", "/state"} ->
        json(conn, 200, ProactivePrototype.state())

      {"POST", "/run"} ->
        with ["1"] <- get_req_header(conn, "x-prototype"),
             {:ok, raw, conn} <- read_body(conn, length: 1024),
             {:ok, %{"scenario" => name}} <- Jason.decode(raw),
             true <- name in ProactivePrototype.names() do
          admitted =
            Agent.get_and_update(ProactivePrototype, fn state ->
              if state.busy, do: {false, state}, else: {true, %{state | busy: true}}
            end)

          if admitted do
            Task.start(fn -> ProactivePrototype.run(name) end)
            json(conn, 202, %{accepted: true})
          else
            json(conn, 409, %{error: "scenario already running"})
          end
        else
          _ -> json(conn, 400, %{error: "invalid scenario"})
        end

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  defp json(conn, status, data),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, Jason.encode!(data))
end

ProactivePrototype.boot()
args = System.argv()

cond do
  "--serve" in args ->
    ProactivePrototype.serve()

  "--all" in args ->
    reports = Enum.map(ProactivePrototype.names(), &ProactivePrototype.run/1)
    File.write!(Path.join(__DIR__, "results.local.json"), Jason.encode!(reports, pretty: true))
    unless Enum.all?(reports, & &1.verified), do: System.halt(1)

  "--case" in args ->
    name = Enum.at(args, Enum.find_index(args, &(&1 == "--case")) + 1)
    ProactivePrototype.run(name)

  true ->
    Stream.repeatedly(fn ->
      IO.puts("\n" <> Enum.join(ProactivePrototype.names(), " | "))
      IO.gets("scenario (q to quit)> ")
    end)
    |> Enum.reduce_while(nil, fn
      input, _ when input in [:eof, "q\n"] ->
        {:halt, nil}

      input, _ ->
        name = String.trim(input)
        if name in ProactivePrototype.names(), do: ProactivePrototype.run(name)
        {:cont, nil}
    end)
end
