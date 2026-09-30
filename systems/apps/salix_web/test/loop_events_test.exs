defmodule SalixWeb.LoopEventsTest do
  @moduledoc """
  Loop ingress over HTTP: group keys, Loop secret URLs, and Composio project
  secret URLs. Real compiled guests process events and call provider tools.
  Tests cover ownership, retry identity, lifecycle, and bounded admission.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LLM.Mock

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_api_token = Application.get_env(:salix_web, :api_token)
    # Comma registers its member source item pool as a Composio signal reader at
    # boot. These tests cover Salix Loop delivery only.
    prev_signal = Application.get_env(:salix_web, :composio_signal_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, "test-token")
    Application.delete_env(:salix_web, :composio_signal_mod)

    Comma.PodLifecycle.reset_for_test()
    SalixCluster.NodeLifecycle.reset()

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    case start_supervised(Mock) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Mock.script([])
    Application.put_env(:salix_agent, :llm, Mock)
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")
    SalixStore.Repo.query!("TRUNCATE agent_loops, agent_loop_acks")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_web, :api_token, prev_api_token)
      restore_env(:salix_web, :composio_signal_mod, prev_signal)
      Comma.PodLifecycle.reset_for_test()
      SalixCluster.NodeLifecycle.reset()
    end)

    tenant_id = req(:post, "/v1/admin/tenants", json: %{name: "Loop Tenant"}).body["tenant_id"]

    tenant_key =
      req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"}).body["key"]

    group = req_as(tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Loops"}).body
    group_id = group["group_id"]

    worker =
      req_as(tenant_key, :post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Worker", role: "worker"}
      ).body

    minted =
      req_as(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/router/api-keys",
        json: %{name: "CI"}
      )

    assert minted.status == 201

    # A Loop row without a running object: the ingress path is exercised up
    # to the owner-node delivery, which answers "not running" here.
    now = System.system_time(:millisecond)

    {:ok, loop} =
      SalixStore.Loops.create(%{
        "id" => SalixStore.Ids.new_loop_id(),
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "agent_id" => worker["agent_id"],
        "session_id" => SalixStore.Ids.new_session_id(),
        "elf_sha256" => "abc",
        "elf_path" => "/loops/main.elf",
        "created_at" => now
      })

    {:ok,
     tenant_id: tenant_id,
     group_id: group_id,
     key: minted.body["key"],
     tenant_key: tenant_key,
     loop_id: loop["id"],
     agent_id: worker["agent_id"],
     session_id: loop["session_id"]}
  end

  defp path(group_id, loop_id), do: "/v1/agent-groups/#{group_id}/loops/#{loop_id}/events"

  test "a group key posts an event to its group's loop", ctx do
    response =
      req_as(ctx.key, :post, path(ctx.group_id, ctx.loop_id),
        json: %{topic: "deploy", payload: %{kind: "deploy"}, event_id: "d1"}
      )

    assert response.status == 202
    assert {:ok, row} = SalixStore.Loops.get(ctx.loop_id)
    assert row["pending_events"]["d1"]["payload"] == %{"kind" => "deploy"}
  end

  test "a malformed event is refused before routing", ctx do
    response = req_as(ctx.key, :post, path(ctx.group_id, ctx.loop_id), json: %{payload: %{}})
    assert response.status == 422
    assert response.body["field"] == "topic"
  end

  test "another group's loop, a foreign group path and a tenant key are refused", ctx do
    assert req_as(ctx.key, :post, path(ctx.group_id, "lop1_0000000000000000009"),
             json: %{topic: "t"}
           ).status == 404

    assert req_as(
             ctx.key,
             :post,
             path("grp1_0000000000000000001_0000000000000000002", ctx.loop_id),
             json: %{topic: "t"}
           ).status == 404

    assert req_as(ctx.tenant_key, :post, path(ctx.group_id, ctx.loop_id), json: %{topic: "t"}).status ==
             401

    assert req_as("salix_gk_nope", :post, path(ctx.group_id, ctx.loop_id), json: %{topic: "t"}).status ==
             401
  end

  test "a paused loop answers 409", ctx do
    {:ok, _} =
      SalixStore.Loops.update(ctx.loop_id, fn r ->
        {:ok, Map.merge(r, %{"status" => "paused", "paused_by" => "user"})}
      end)

    response = req_as(ctx.key, :post, path(ctx.group_id, ctx.loop_id), json: %{topic: "t"})
    assert response.status == 409
    assert response.body["status"] == "paused"
  end

  test "secret URLs are recoverable, owner-scoped, rotatable and revocable", ctx do
    alias SalixAgent.Tools.Loops, as: Tools
    owner = %{agent_id: ctx.agent_id}
    args = %{"loop_id" => ctx.loop_id, "action" => "enable"}
    url = Jason.decode!(Tools.webhook(args, owner))["webhook_url"]
    assert is_binary(url)
    assert Jason.decode!(Tools.get(args, owner))["webhook_url"] == url
    assert Enum.any?(Jason.decode!(Tools.list(%{}, owner)), &(&1["webhook_url"] == url))
    assert Jason.decode!(Tools.webhook(args, owner))["webhook_url"] == url

    assert_raise RuntimeError, "loop not found", fn ->
      Tools.webhook(args, %{agent_id: "foreign"})
    end

    assert Jason.decode!(Tools.list(%{}, %{agent_id: "foreign"})) == []
    assert webhook(url, %{"action" => "done"}).status == 202
    rotated = Jason.decode!(Tools.webhook(%{args | "action" => "rotate"}, owner))["webhook_url"]
    refute rotated == url
    assert webhook(url, %{}).status == 404
    assert webhook(rotated, %{}).status == 202
    Tools.webhook(%{args | "action" => "revoke"}, owner)
    refute Map.has_key?(Jason.decode!(Tools.get(args, owner)), "webhook_url")
    assert webhook(rotated, %{}).status == 404
    replacement = Jason.decode!(Tools.webhook(args, owner))["webhook_url"]
    Tools.delete(args, owner)
    assert webhook(replacement, %{}).status == 404
  end

  test "webhooks enforce input bounds, backpressure and the Loop lifecycle", ctx do
    {:ok, loop} = SalixAgent.Loops.configure_webhook(ctx.agent_id, ctx.loop_id, "enable")
    url = loop["webhook_url"]
    assert webhook(url, %{"large" => String.duplicate("x", 16_384)}).status == 413
    assert webhook(url, [1, 2]).status == 400
    assert webhook(url, %{}, [{"idempotency-key", String.duplicate("x", 129)}]).status == 422

    assert Req.post!(request_url(url),
             body: "a=b",
             headers: [{"content-type", "application/x-www-form-urlencoded"}]
           ).status == 415

    {:ok, _} =
      SalixStore.Loops.update(ctx.loop_id, fn r -> {:ok, Map.put(r, "status", "paused")} end)

    assert webhook(url, %{}).status == 409
    for _ <- 1..60, do: webhook(url, %{})
    limited = webhook(url, %{})
    assert limited.status == 429
    assert limited.headers["retry-after"] != nil
    assert limited.headers["cache-control"] == ["no-store"]
  end

  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "header-free HTTP delivery reaches the guest and preserves explicit retry identity", ctx do
    alias SalixAgent.{AgentWorkspace, Fleet, InternalSessionStore, Loops, SpinfoamFixture}
    alias SalixAgent.Loops.Host
    {:ok, _} = InternalSessionStore.prepare_commit(ctx.agent_id, ctx.session_id, [])
    {:ok, _} = Fleet.ensure_started(ctx.agent_id, create: false)
    :ok = Fleet.await_ownership_installed(ctx.agent_id)
    elf = SpinfoamFixture.compile!(webhook_program())
    path = "/loops/webhook.elf"
    {:ok, write} = AgentWorkspace.prepare_write(ctx.agent_id, path, elf)
    {:ok, _} = AgentWorkspace.seed_operation(ctx.agent_id, "webhook-fixture", %{}, [write])

    {:ok, loop} =
      Loops.create(%{agent_id: ctx.agent_id, session_id: ctx.session_id, role: "worker"}, %{
        "path" => path
      })

    id = loop["loop_id"]
    await(fn -> is_binary(Host.object_for_loop(id)) end)
    {:ok, loop} = Loops.configure_webhook(ctx.agent_id, id, "enable")
    url = loop["webhook_url"]
    first = webhook(url, %{"action" => "completed"}, [{"idempotency-key", "delivery-1"}])
    assert first.status == 202
    assert first.body["event_id"] == "delivery-1"
    await(fn -> SalixStore.Loops.acked?(id, "delivery-1") end)
    {:ok, record} = SalixStore.Loops.get(id)

    assert record["checkpoint"] == %{
             "event_id" => "delivery-1",
             "topic" => "webhook",
             "payload" => %{"action" => "completed"}
           }

    retry = webhook(url, %{"action" => "completed"}, [{"idempotency-key", "delivery-1"}])
    assert retry.status == 202
    assert retry.body["duplicate"] == true
    a = webhook(url, %{"action" => "completed"})
    b = webhook(url, %{"action" => "completed"})
    assert a.status == 202 and b.status == 202
    refute a.body["event_id"] == b.body["event_id"]
    await(fn -> SalixStore.Loops.acked?(id, b.body["event_id"]) end)
  end

  defmodule ComposioAPI do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, state) do
      {:ok, body, conn} = read_body(conn)
      conn = fetch_query_params(conn)
      args = if body == "", do: %{}, else: Jason.decode!(body)
      request = {conn.method, conn.request_path, conn.query_params, args}

      {status, response} =
        Agent.get_and_update(state, fn st ->
          st = Map.update!(st, :requests, &[request | &1])

          case {conn.method, conn.request_path} do
            {"GET", "/api/v3.1/webhook_subscriptions"} ->
              {{200, %{items: st.subscriptions}}, st}

            {method, "/api/v3.1/webhook_subscriptions" <> _} when method in ["POST", "PATCH"] ->
              sub = Map.put(args, "id", "wh_test")
              {{200, sub}, %{st | subscriptions: [sub]}}

            {"GET", "/api/v3/connected_accounts/" <> id} ->
              case Map.fetch(st.accounts, id) do
                {:ok, a} -> {{200, a}, st}
                :error -> {{404, %{}}, st}
              end

            {"POST", "/api/v3.1/trigger_instances/GMAIL_NEW_GMAIL_MESSAGE/upsert"} ->
              {{200, %{trigger_id: "ti_gmail"}}, st}

            {"GET", "/api/v3.1/trigger_instances/active"} ->
              {{200, %{items: st.triggers}}, st}

            {method, "/api/v3.1/trigger_instances/manage/" <> _}
            when method in ["PATCH", "DELETE"] ->
              {{200, %{status: "success"}}, st}

            {"POST", "/api/v3/tools/execute/GMAIL_FETCH_EMAILS"} ->
              {{200, %{successful: true, data: %{messages: [%{id: "mail-1"}]}}}, st}

            _ ->
              {{404, %{}}, st}
          end
        end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  defp composio_setup(ctx) do
    {:ok, state} =
      start_supervised(
        {Agent,
         fn ->
           %{
             subscriptions: [],
             requests: [],
             accounts: %{
               "ca_gmail" => %{
                 "id" => "ca_gmail",
                 "user_id" => ctx.group_id,
                 "status" => "ACTIVE"
               }
             },
             triggers: [
               %{
                 "id" => "ti_gmail",
                 "connected_account_id" => "ca_gmail",
                 "user_id" => ctx.group_id,
                 "trigger_name" => "GMAIL_NEW_GMAIL_MESSAGE"
               }
             ]
           }
         end}
      )

    {:ok, server} =
      start_supervised({Bandit, plug: {ComposioAPI, state}, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    overrides = [
      {:salix_agent, :composio_store_mod, Salix.Bindings.AgentComposioStore},
      {:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore},
      {:salix_agent, :composio_client_mod, SalixStore.Composio},
      {:salix_web, :composio_client_mod, SalixStore.Composio},
      {:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}"}
    ]

    for {app, key, value} <- overrides do
      old = Application.get_env(app, key)
      Application.put_env(app, key, value)
      on_exit(fn -> restore_env(app, key, old) end)
    end

    SalixStore.Repo.query!("TRUNCATE composio_settings")
    # Settings are not sandboxed. A default record left behind would send later
    # suites to the real provider with this fake key.
    on_exit(fn -> SalixStore.Repo.query!("TRUNCATE composio_settings") end)

    response =
      req_as(ctx.tenant_key, :put, "/v1/runtime/composio/settings", json: %{api_key: "ck_test"})

    assert response.status == 200
    response = req_as(ctx.tenant_key, :post, "/v1/runtime/composio/webhook", json: %{})
    assert response.status == 200, inspect(response.body)
    {state, response.body["webhook_url"]}
  end

  test "Composio account trigger reaches a compiled Loop and the Loop executes Gmail without a model",
       ctx do
    alias SalixAgent.{AgentWorkspace, Fleet, InternalSessionStore, Loops, SpinfoamFixture}
    alias SalixAgent.Loops.Host
    alias SalixAgent.Tools.ComposioTriggers
    {state, url} = composio_setup(ctx)
    {:ok, _} = InternalSessionStore.prepare_commit(ctx.agent_id, ctx.session_id, [])
    {:ok, _} = Fleet.ensure_started(ctx.agent_id, create: false)
    :ok = Fleet.await_ownership_installed(ctx.agent_id)

    program =
      String.replace(
        webhook_program(),
        "sf_handle args = sf_json_object();",
        ~S"""
        sf_handle request = sf_json_parse("{\"tool_slug\":\"GMAIL_FETCH_EMAILS\",\"connected_account_id\":\"ca_gmail\",\"arguments\":{\"max_results\":1}}", 112);
        if (request < 0) return 9;
        sf_handle result = sf_host_call("composio.execute", request, 10000);
        if (result < 0) return 10;
        sf_drop(result);
        sf_drop(request);
        sf_handle args = sf_json_object();
        """
      )

    # Use the exact JSON length in the C fixture.
    request_json =
      ~s({"tool_slug":"GMAIL_FETCH_EMAILS","connected_account_id":"ca_gmail","arguments":{"max_results":1}})

    program = String.replace(program, ", 112);", ", #{byte_size(request_json)});")
    elf = SpinfoamFixture.compile!(program)
    {:ok, write} = AgentWorkspace.prepare_write(ctx.agent_id, "/loops/gmail.elf", elf)
    {:ok, _} = AgentWorkspace.seed_operation(ctx.agent_id, "gmail-fixture", %{}, [write])
    tool_ctx = %{agent_id: ctx.agent_id, session_id: ctx.session_id, role: "worker"}
    {:ok, loop} = Loops.create(tool_ctx, %{"path" => "/loops/gmail.elf"})
    id = loop["loop_id"]
    await(fn -> is_binary(Host.object_for_loop(id)) end)

    ComposioTriggers.create(
      %{
        "loop_id" => id,
        "connected_account_id" => "ca_gmail",
        "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
        "trigger_config" => %{}
      },
      tool_ctx
    )

    payload = %{
      "id" => "evt_gmail_1",
      "type" => "composio.trigger.message",
      "metadata" => %{
        "trigger_id" => "ti_gmail",
        "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
        "user_id" => ctx.group_id,
        "connected_account_id" => "ca_gmail"
      },
      "data" => %{"message_id" => "mail-1", "subject" => "Incoming Gmail"}
    }

    assert webhook(url, payload).status == 202
    await(fn -> SalixStore.Loops.acked?(id, "evt_gmail_1") end)
    {:ok, row} = SalixStore.Loops.get(id)

    assert row["checkpoint"] == %{
             "event_id" => "evt_gmail_1",
             "topic" => "GMAIL_NEW_GMAIL_MESSAGE",
             "payload" => payload["data"]
           }

    assert webhook(url, payload).status == 202
    Process.sleep(100)
    calls = Agent.get(state, & &1.requests)

    assert Enum.count(
             calls,
             &match?({"POST", "/api/v3/tools/execute/GMAIL_FETCH_EMAILS", _, _}, &1)
           ) == 1

    assert Enum.any?(calls, fn
             {"POST", "/api/v3.1/trigger_instances/GMAIL_NEW_GMAIL_MESSAGE/upsert", _, body} ->
               body["user_id"] == ctx.group_id and body["connected_account_id"] == "ca_gmail"

             _ ->
               false
           end)

    ComposioTriggers.bind(%{"loop_id" => ctx.loop_id, "trigger_id" => "ti_gmail"}, tool_ctx)
    assert webhook(url, payload).status == 202
    ComposioTriggers.bind(%{"loop_id" => ctx.loop_id}, tool_ctx)
    {:ok, _} = Loops.pause(ctx.agent_id, id)
    assert webhook(url, Map.put(payload, "id", "paused")).body["subscribers"] == 0
    {:ok, _} = Loops.resume(ctx.agent_id, id)
    await(fn -> is_binary(Host.object_for_loop(id)) end)
    assert webhook(url, Map.put(payload, "id", "resumed")).status == 202
    await(fn -> SalixStore.Loops.acked?(id, "resumed") end)
    ComposioTriggers.bind(%{"loop_id" => id}, tool_ctx)
    assert webhook(url, Map.put(payload, "id", "unbound")).body["subscribers"] == 0
    {:ok, _} = Loops.pause(ctx.agent_id, id)
  end

  test "Composio registration preserves URLs, protects an existing destination and scopes administration",
       ctx do
    {state, url} = composio_setup(ctx)

    assert req_as(ctx.tenant_key, :post, "/v1/admin/composio/default-webhook", json: %{}).status ==
             401

    again = req_as(ctx.tenant_key, :post, "/v1/runtime/composio/webhook", json: %{})
    assert again.body["webhook_url"] == url
    view = req_as(ctx.tenant_key, :get, "/v1/runtime/composio/settings").body
    assert view["webhook_configured"]
    refute Map.has_key?(view, "webhook_secret")
    refute Map.has_key?(view, "webhook_url")

    Agent.update(
      state,
      &%{
        &1
        | subscriptions: [%{"id" => "wh_other", "webhook_url" => "https://other.example/events"}]
      }
    )

    denied = req_as(ctx.tenant_key, :post, "/v1/runtime/composio/webhook", json: %{})
    assert denied.status == 409

    assert Agent.get(state, &hd(&1.subscriptions)["webhook_url"]) ==
             "https://other.example/events"

    replaced =
      req_as(ctx.tenant_key, :post, "/v1/runtime/composio/webhook",
        json: %{replace_existing: true}
      )

    assert replaced.status == 200
    assert replaced.body["webhook_url"] == url
  end

  test "a default webhook cannot deliver into a tenant with its own Composio settings", ctx do
    composio_setup(ctx)

    assert req(:put, "/v1/admin/composio/default-settings", json: %{api_key: "ck_default"}).status ==
             200

    configured = req(:post, "/v1/admin/composio/default-webhook", json: %{replace_existing: true})
    assert configured.status == 200
    url = configured.body["webhook_url"]

    event = %{
      "id" => "default-event",
      "type" => "composio.trigger.message",
      "metadata" => %{
        "user_id" => ctx.group_id,
        "trigger_id" => "ti_gmail",
        "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
        "connected_account_id" => "ca_gmail"
      },
      "data" => %{}
    }

    assert webhook(url, event).status == 422
    assert req_as(ctx.tenant_key, :delete, "/v1/runtime/composio/settings").status == 200
    assert webhook(url, event).status == 202
  end

  test "Composio ingress rejects foreign accounts and revoked URLs, and bounds input", ctx do
    {state, url} = composio_setup(ctx)
    tool_ctx = %{agent_id: ctx.agent_id, session_id: ctx.session_id}
    alias SalixAgent.Tools.ComposioTriggers

    args = %{
      "loop_id" => ctx.loop_id,
      "connected_account_id" => "ca_gmail",
      "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE"
    }

    other =
      req_as(ctx.tenant_key, :post, "/v1/runtime/agents",
        json: %{group_id: ctx.group_id, name: "Other", role: "worker"}
      ).body

    assert_raise RuntimeError, ~r/not_found/, fn ->
      ComposioTriggers.create(args, %{tool_ctx | agent_id: other["agent_id"]})
    end

    Agent.update(state, &put_in(&1, [:accounts, "ca_gmail", "user_id"], "foreign"))
    assert_raise RuntimeError, ~r/not_found/, fn -> ComposioTriggers.create(args, tool_ctx) end

    assert_raise RuntimeError, ~r/not_found/, fn ->
      ComposioTriggers.manage(%{"trigger_id" => "ti_gmail", "action" => "delete"}, tool_ctx)
    end

    payload = %{
      "id" => "event",
      "type" => "composio.trigger.message",
      "metadata" => %{
        "user_id" => ctx.group_id,
        "trigger_id" => "ti_gmail",
        "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
        "connected_account_id" => "ca_gmail"
      },
      "data" => %{}
    }

    assert webhook(url, payload).status == 422
    Agent.update(state, &%{&1 | accounts: %{}})

    assert %{"status" => "delete"} =
             ComposioTriggers.manage(
               %{"trigger_id" => "ti_gmail", "action" => "delete"},
               tool_ctx
             )
             |> Jason.decode!()

    assert webhook(url, %{"data" => String.duplicate("x", 17_000)}).status == 413

    response =
      req_as(ctx.tenant_key, :post, "/v1/runtime/composio/webhook", json: %{rotate: true})

    assert response.status == 200
    assert webhook(url, payload).status == 404
    new_url = response.body["webhook_url"]
    req_as(ctx.tenant_key, :put, "/v1/runtime/composio/settings", json: %{api_key: "ck_replaced"})
    assert webhook(new_url, payload).status == 404
  end

  defp webhook_program do
    """
    #include "spinfoam.h"
    SF_MAIN sf_i64 main(void) {
      for (;;) {
        sf_handle event = sf_event_next(60000);
        if (event == SF_TIMEOUT) continue;
        if (event < 0) return 1;
        sf_handle args = sf_json_object();
        sf_json_set(args, "state", event);
        sf_handle saved = sf_host_call("loop.state.put", args, 10000);
        if (saved < 0) return 2;
        sf_drop(saved);
        sf_drop(args);
        sf_handle ack = sf_host_call("loop.ack", event, 10000);
        if (ack < 0) return 3;
        sf_drop(ack);
        sf_drop(event);
      }
    }
    """
  end

  defp request_url(url), do: base() <> URI.parse(url).path

  defp webhook(url, body, headers \\ []),
    do: Req.post!(request_url(url), json: body, headers: headers, retry: false)

  defp await(check, attempts \\ 100)
  defp await(_check, 0), do: flunk("Loop did not converge within five seconds")

  defp await(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(50)
          await(check, attempts - 1)
        )
  end

  defp req(method, path, opts), do: req_as("test-token", method, path, opts)

  defp req_as(token, method, path, opts \\ []) do
    headers = [{"authorization", "Bearer " <> token}]
    Req.request!([method: method, url: base() <> path, headers: headers] ++ opts)
  end

  defp base, do: SalixWeb.Application.base_url()

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
