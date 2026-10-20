defmodule SalixIM.TestSupport.ProviderFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias SalixIM.{ConversationServer, Provider}
  import ExUnit.Callbacks
  alias SalixStore.Keys
  alias SalixIM.TestSupport.BanditServer

  alias SalixIM.ProviderTest.{
    MockSlack,
    FakeTenantAppStore,
    EmptyPluginStore
  }

  def native_setup do
    SalixAgent.TestSupport.stop_all_agents()

    # Schedules live in the node-global control Postgres now, which no
    # S3.Fake.reset can clear — the schedule tests here assert exact fired
    # sets, so this file truncates for a clean slate.
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_api = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
    prev_files = SystemsRuntime.get_env(:salix_im, :slack_files_base_url)
    prev_notifier = SystemsRuntime.get_env(:salix_im, :conversation_notifier)
    prev_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    prev_conversation_source = SystemsRuntime.get_env(:salix_agent, :conversation_source_mod)
    prev_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    prev_llm_resolver = SystemsRuntime.get_env(:salix_agent, :llm_resolver)
    prev_oauth_store = SystemsRuntime.get_env(:salix_agent, :oauth_store_mod)
    prev_session_activity = SystemsRuntime.get_env(:salix_im, :session_activity_mod)

    prev_slack_tool_rate_limit_retry_budget_ms =
      SystemsRuntime.get_env(:salix_im, :slack_tool_rate_limit_retry_budget_ms)

    prev_slack_tool_rate_limit_max_retries =
      SystemsRuntime.get_env(:salix_im, :slack_tool_rate_limit_max_retries)

    prev_agent_workspace = SystemsRuntime.get_env(:salix_im, :agent_workspace_mod)
    prev_provider_app_store = SystemsRuntime.get_env(:salix_im, :provider_app_store_mod)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_plugin_store = SystemsRuntime.get_env(:salix_agent, :plugin_store_mod)
    prev_diagnostic_sink = SystemsRuntime.get_env(:salix_im, :diagnostic_sink)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_agent, :plugin_store_mod, EmptyPluginStore)
    SalixAgent.TestSupport.configure_control_fixtures!()
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    SystemsRuntime.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, Salix.Bindings.AgentLlmResolver)
    SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore)

    SystemsRuntime.put_env(
      :salix_im,
      :session_activity_mod,
      SalixIM.TestSupport.SessionActivity
    )

    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, SalixIM.TestSupport.AgentWorkspace)
    SystemsRuntime.put_env(:salix_im, :provider_app_store_mod, FakeTenantAppStore)
    SystemsRuntime.put_env(:salix_im, :diagnostic_sink, nil)

    start_supervised!(MockSlack)
    start_supervised!(FakeTenantAppStore)

    base_url = BanditServer.serve!(MockSlack)
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "#{base_url}/api")
    SystemsRuntime.put_env(:salix_im, :slack_files_base_url, "#{base_url}")

    # The Conversation owners a test starts stop with it, before the mocks
    # they use: an owner left running would keep retrying its deliveries on
    # the module's clock through every later test.
    start_supervised!(SalixIM.TestSupport.Fleet.Cleanup)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :group_context_mod, prev_group_context)
      restore(:salix_agent, :plugin_store_mod, prev_plugin_store)
      restore(:salix_im, :slack_api_base_url, prev_api)
      restore(:salix_im, :slack_files_base_url, prev_files)
      restore(:salix_im, :conversation_notifier, prev_notifier)
      restore(:salix_im, :agent_delivery_mod, prev_agent_delivery)
      restore(:salix_agent, :conversation_source_mod, prev_conversation_source)
      restore(:salix_agent, :im_provider_mod, prev_im_provider)
      restore(:salix_agent, :llm_resolver, prev_llm_resolver)
      restore(:salix_agent, :oauth_store_mod, prev_oauth_store)
      restore(:salix_im, :session_activity_mod, prev_session_activity)

      restore(
        :salix_im,
        :slack_tool_rate_limit_retry_budget_ms,
        prev_slack_tool_rate_limit_retry_budget_ms
      )

      restore(
        :salix_im,
        :slack_tool_rate_limit_max_retries,
        prev_slack_tool_rate_limit_max_retries
      )

      restore(:salix_im, :agent_workspace_mod, prev_agent_workspace)
      restore(:salix_im, :provider_app_store_mod, prev_provider_app_store)
      restore(:salix_im, :diagnostic_sink, prev_diagnostic_sink)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    FakeTenantAppStore.put(tenant, %{
      "app_secret" => "fs-secret",
      "verification_token" => "verify-token",
      "encrypt_key" => "encrypt-secret"
    })

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn rec ->
        Map.put(rec, "router_agent_id", agent["agent_id"])
      end)

    {:ok, tenant: tenant, group_id: group_id, agent_id: agent["agent_id"]}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  def seed_connect(group_id, connect_id, provider, extra) do
    extra = seed_connect_defaults(group_id, provider, extra)
    seed_raw_connect(group_id, connect_id, provider, extra)
  end

  def seed_raw_connect(group_id, connect_id, provider, extra) do
    now = SystemsClock.system_time(:millisecond)

    rec =
      Map.merge(
        %{
          "tenant_id" => extra["tenant_id"] || "default",
          "group_id" => group_id,
          "connect_id" => connect_id,
          "provider" => provider,
          "created_at" => now,
          "updated_at" => now
        },
        extra
      )

    {:ok, _} = SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), rec)
    rec
  end

  def seed_legacy_slack_connect_without_inbound(group_id, connect_id, extra) do
    seed_raw_connect(group_id, connect_id, "slack", extra)
  end

  defp seed_connect_defaults(group_id, "slack", extra) do
    if Map.has_key?(extra, "inbound_agent_id") do
      extra
    else
      {:ok, group} = SalixIM.GroupDirectory.get_group(group_id)
      Map.put(extra, "inbound_agent_id", group["router_agent_id"])
    end
  end

  defp seed_connect_defaults(_group_id, _provider, extra), do: extra

  def create_control_agent(attrs, tenant_id) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    group_id = attrs["group_id"]

    agent =
      case attrs["agent_id"] do
        agent_id when is_binary(agent_id) ->
          if SalixStore.Ids.valid_agent_id_for_group?(agent_id, group_id) do
            SalixAgent.TestSupport.create_control_agent!(agent_id, attrs)
          else
            SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, attrs)
          end

        _missing ->
          SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, attrs)
      end

    {:ok, agent}
  end

  def create_slack_task!(
        tenant_id,
        group_id,
        router_id,
        title \\ "Ship the artifact",
        opts \\ []
      ) do
    worker_attrs = %{
      "name" => "Slack card worker #{SystemsRuntime.Proc.unique_integer([:positive])}",
      "group_id" => group_id,
      "role" => "worker"
    }

    worker_attrs =
      case Keyword.get(opts, :model) do
        model when is_binary(model) and model != "" ->
          Map.put(worker_attrs, "model", %{"kind" => "catalog", "model" => model})

        _ ->
          worker_attrs
      end

    {:ok, worker} = create_control_agent(worker_attrs, tenant_id)

    request_id = "slack-card-task-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    command = Keyword.get(opts, :command, title)
    attrs = %{"title" => title, "content" => command, "client_request_id" => request_id}

    assert {:ok, conversation_id} =
             ConversationServer.reserve_task_conversation_id(
               group_id,
               router_id,
               worker["agent_id"],
               attrs
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             SalixIM.TaskConversationInput.create_with_id(
               group_id,
               conversation_id,
               router_id,
               worker["agent_id"],
               attrs
               |> Map.put(
                 "schedule",
                 Keyword.get(opts, :schedule, %{"schedule_id" => nil, "command" => command})
               )
               |> then(fn attrs ->
                 case Keyword.get(opts, :session_model) do
                   nil -> attrs
                   model -> Map.put(attrs, "session_model", model)
                 end
               end)
               |> Map.put("initial_message_attrs", %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router_id,
                 "content" => command,
                 "metadata" => %{"message_type" => "task_command"},
                 "client_request_id" => "delegate-" <> request_id
               })
             )

    {conversation_id, worker["agent_id"]}
  end

  def call(agent_id, provider, api, connect_id, params, metadata \\ %{}) do
    Provider.call_api(
      agent_id,
      provider,
      api,
      Map.merge(
        %{
          "connect_id" => connect_id,
          "params" => params
        },
        metadata
      )
    )
  end
end

defmodule SalixIM.ProviderTest.MockSlack do
  @moduledoc "Recording mock of the Slack Web API: `GET` or form-encoded `POST /api/{method}`."
  use Elixir.Agent
  alias SystemsRuntime.Agent
  import Plug.Conn

  def start_link(_ \\ []),
    do: Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)

  def respond(method, body),
    do: Agent.update(__MODULE__, fn s -> put_in(s.responses[method], body) end)

  def respond(method, status, body),
    do: Agent.update(__MODULE__, fn s -> put_in(s.responses[method], {status, body}) end)

  def respond(method, status, headers, body),
    do: Agent.update(__MODULE__, fn s -> put_in(s.responses[method], {status, headers, body}) end)

  def respond_with(method, fun) when is_function(fun, 1),
    do: Agent.update(__MODULE__, fn s -> put_in(s.responses[method], fun) end)

  def requests(method) do
    Agent.get(__MODULE__, & &1.requests)
    |> Enum.reverse()
    |> Enum.filter(&(&1.method == method))
  end

  def last_request(method), do: method |> requests() |> List.last()

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn)
    conn = fetch_query_params(conn)

    case conn.path_info do
      ["api", method] ->
        req = %{
          method: method,
          params: Map.merge(conn.query_params, decode_request_body(raw)),
          auth: conn |> get_req_header("authorization") |> List.first(),
          content_type: conn |> get_req_header("content-type") |> List.first(),
          raw: raw
        }

        Agent.update(__MODULE__, fn s -> %{s | requests: [req | s.requests]} end)
        response = Agent.get(__MODULE__, & &1.responses[method]) || %{"ok" => true}
        response = if is_function(response, 1), do: response.(req), else: response
        {status, headers, body} = response_status_headers_body(response)

        conn =
          Enum.reduce(headers, conn, fn {key, value}, conn ->
            put_resp_header(conn, to_string(key), to_string(value))
          end)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      ["upload", file_id] ->
        req = %{
          method: "external_upload",
          file_id: file_id,
          params: %{},
          auth: conn |> get_req_header("authorization") |> List.first(),
          content_type: conn |> get_req_header("content-type") |> List.first(),
          raw: raw
        }

        Agent.update(__MODULE__, fn s -> %{s | requests: [req | s.requests]} end)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"ok" => true}))

      ["files", file_id] ->
        req = %{
          method: "canvas_download",
          file_id: file_id,
          params: %{},
          auth: conn |> get_req_header("authorization") |> List.first(),
          content_type: nil,
          raw: raw
        }

        Agent.update(__MODULE__, fn s -> %{s | requests: [req | s.requests]} end)

        response =
          Agent.get(__MODULE__, & &1.responses["canvas_download"]) || "# Canvas\nbody"

        response = if is_function(response, 1), do: response.(req), else: response
        {status, headers, body} = response_status_headers_body(response)

        conn =
          Enum.reduce(headers, conn, fn {key, value}, conn ->
            put_resp_header(conn, to_string(key), to_string(value))
          end)

        send_resp(conn, status, body)
    end
  end

  defp decode_request_body(raw) do
    case Jason.decode(raw) do
      {:ok, params} when is_map(params) -> params
      _ -> URI.decode_query(raw)
    end
  end

  defp response_status_headers_body({status, headers, body}), do: {status, headers, body}
  defp response_status_headers_body({status, body}), do: {status, [], body}
  defp response_status_headers_body(body), do: {200, [], body}
end

defmodule SalixIM.ProviderTest.FakeTenantAppStore do
  use Elixir.Agent
  alias SystemsRuntime.Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(tenant_id, app), do: Agent.update(__MODULE__, &Map.put(&1, tenant_id, app))

  def get_feishu_tenant_app(tenant_id) do
    case Agent.get(__MODULE__, &Map.get(&1, tenant_id)) do
      nil -> :none
      app -> {:ok, app}
    end
  end
end

defmodule SalixIM.ProviderTest.EmptyPluginStore do
  @moduledoc false
  def runtime_projection(_attrs), do: {:ok, %{"revision" => "provider-test"}}
end
