defmodule CommaWeb.LiveLlmRouterWorkersE2eTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Real-LLM check of the zero-Worker Comma Router flow: a request that needs a
  Task makes the Router read the servable models, create a named Worker with
  one of them, and create the Task for that Worker.

  Run with `SALIX_E2E_LLM_API_KEY=... LLM_MODEL=deepseek-flash mix test
  apps/comma_web/test/live_llm_router_workers_e2e_test.exs --include live_llm
  --only live_llm`. The Router follows the platform Router model, which a
  platform Profile with the environment's key serves for this test only. The Tenant's Profile that
  `agent.models` reads is an OpenCode Go key Profile with a placeholder key,
  so the new Worker's own requests are rejected; this test ends at the Task.
  """
  use Comma.DataCase, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live

  @moduletag :live_llm
  @moduletag timeout: 360_000

  defmodule ToolCallArchive do
    @moduledoc false
    # Receives every tool call at the `SalixAgent.Tools` seam.
    def active?, do: true
    def reserve(_fact), do: nil

    def record(%{boundary: :tool_call} = fact) do
      if owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}, nil),
        do: SystemsRuntime.Proc.send(owner, {:tool_calls, fact.agent_id, fact.payload})

      :ok
    end

    def record(%{boundary: :tool_result, payload: %{"results" => results}} = fact) do
      if owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}, nil) do
        for result <- List.wrap(results),
            inspect(result) =~ "agent.create_worker",
            do: SystemsRuntime.Proc.send(owner, {:create_worker_result, fact.agent_id, result})
      end

      :ok
    end

    def record(_fact), do: :ok
  end

  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  setup do
    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :agent_management_ports},
            {:salix_agent, :event_archive_mod},
            {:comma_core, :salix_client}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, CommaWeb.AgentManagement)
    SystemsRuntime.put_env(:salix_agent, :event_archive_mod, ToolCallArchive)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    SystemsRuntime.PersistentTerm.put({ToolCallArchive, :owner}, SystemsRuntime.Proc.self())
    cleanup = Live.install_runtime!()

    on_exit(fn ->
      cleanup.()
      SystemsRuntime.PersistentTerm.erase({ToolCallArchive, :owner})
      SalixAgent.TestSupport.stop_all_agents()
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing)

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    :ok
  end

  test "live LLM: a zero-Worker Router creates a named Worker by model, then the Task",
       %{llm: llm} do
    {:ok, user} =
      Comma.Accounts.create_user(%{"email" => "live-workers-#{Live.unique_suffix()}@example.com"})

    workspace = create_ready_workspace!(user, %{"name" => "调研空间"})
    tenant = workspace["salix_tenant_id"]
    group = workspace["default_group_id"]
    router = workspace["router_agent_id"]
    assert workspace["default_worker_agent_id"] == nil

    grant_credits!(workspace)

    Repo.update_all(from(u in Comma.Accounts.User, where: u.id == ^user["id"]),
      set: [locale: "zh-CN"]
    )

    Repo.insert!(%Comma.Data.RecommendationProfile{
      workspace_id: workspace["id"],
      user_id: user["id"],
      timezone: "Asia/Shanghai"
    })

    {:ok, _profile} =
      SalixAgent.AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "opencode-go",
        "api_key" => "sk-placeholder-0000000000000000"
      })

    {:ok, servable} = SalixAgent.AccountPool.servable_models(tenant, limit: 100)
    servable = Map.new(servable["models"], &{&1["id"], &1})
    assert map_size(servable) > 0

    use_live_router!(router, llm)
    {:ok, chat} = SalixIM.RouterConversationInput.ensure(group)

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group, %{
               "content" => "帮我调研一下 2026 年 Q3 国内 AI 编程助手的市场格局，写一份 500 字的总结",
               "client_request_id" => "live-workers-#{Live.unique_suffix()}"
             })

    # Wait until the Router has replied and its activation has settled.
    session = Live.router_session_id!(router)

    Live.eventually(
      fn ->
        if router_replies(group, chat["conversation_id"], router) != [] and
             settled?(router, session),
           do: {:ok, :settled},
           else: :retry
      end,
      300_000
    )

    calls = router_tool_calls(router)
    names = Enum.map(calls, & &1.tool)

    reply =
      router_replies(group, chat["conversation_id"], router)
      |> Enum.map_join("\n", &Live.text_content(&1["content"]))

    IO.puts(
      "\n=== live zero-Worker Router run ===\ntool sequence: #{Enum.join(names, " -> ")}\nrouter reply:\n#{reply}"
    )

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group, limit: 50)

    assert task = Enum.find(conversations, &(&1["kind"] == "agent_task")),
           "the Router created no Task"

    {:ok, worker} = SalixAgent.Control.get_record(task["task_worker_agent_id"])

    assert create = Enum.find(calls, &(&1.tool == "agent.create_worker")),
           "the Router created no Worker"

    chosen = create.params["model"] || %{}
    model = servable[chosen["model"]]
    effort = chosen["reasoning_effort"]

    for {:create_worker_result, ^router, result} <- drain_results(),
        do: IO.puts("agent.create_worker result: " <> String.slice(inspect(result), 0, 600))

    for call <- calls,
        call.tool == "agent.create_worker",
        do:
          IO.puts(
            "agent.create_worker: #{inspect(Map.take(call.params, ~w(name runtime model)))}"
          )

    IO.puts("""
    chosen model: #{chosen["model"]}  effort: #{inspect(effort)}
    worker: #{worker["name"]} (#{worker["agent_id"]})
    task: #{task["conversation_id"]}
    """)

    # Read the models before creating the Worker, then create the Task.
    models_at = Enum.find_index(names, &(&1 in ["agent.models", "agent.list"]))
    create_at = Enum.find_index(names, &(&1 == "agent.create_worker"))
    task_at = Enum.find_index(names, &(&1 == "im_api.internal.task.create"))
    assert "agent.models" in names
    assert models_at < create_at and create_at < task_at

    assert chosen["kind"] == "catalog"
    assert model, "chosen model #{inspect(chosen["model"])} is not one agent.models offers"
    assert is_nil(effort) or effort in model["efforts"]
    assert task["task_worker_agent_id"] == worker["agent_id"]

    replies_before = router_replies(group, chat["conversation_id"], router)

    # A person's name, not a role title.
    refute worker["name"] =~ ~r/worker|assistant|agent|助理|助手|研究员|调研/iu

    assert String.contains?(reply, worker["name"])

    assert Enum.any?(
             [model["id"], model["name"]],
             &String.contains?(String.downcase(reply), String.downcase(&1))
           ),
           "the reply does not name the model"

    # A second Worker in the same Router session, after the first Task ran.
    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group, %{
               "content" => "再新建一个 Worker，用 DeepSeek V4 Pro，把同一个调研任务交给它重新做一遍。",
               "client_request_id" => "live-workers-second-#{Live.unique_suffix()}"
             })

    Live.eventually(
      fn ->
        if length(router_replies(group, chat["conversation_id"], router)) > length(replies_before) and
             settled?(router, session),
           do: {:ok, :settled},
           else: :retry
      end,
      300_000
    )

    second_calls = router_tool_calls(router)
    second_results = drain_results()
    IO.puts("second tool sequence: #{Enum.map_join(second_calls, " -> ", & &1.tool)}")

    for call <- second_calls,
        call.tool == "agent.create_worker",
        do:
          IO.puts("second agent.create_worker: #{inspect(Map.take(call.params, ~w(name model)))}")

    for {:create_worker_result, ^router, result} <- second_results,
        do:
          IO.puts("second agent.create_worker result: " <> String.slice(inspect(result), 0, 800))

    refute Enum.any?(second_results, fn {_, _, result} ->
             inspect(result) =~ "mutation_outcome_unknown"
           end)

    assert length(workers_in(workspace)) >= 2
  end

  defp workers_in(workspace) do
    {:ok, page} =
      SalixAgent.Control.page_workers(workspace["salix_tenant_id"], workspace["default_group_id"],
        limit: 50
      )

    page.items
  end

  defp grant_credits!(%{"billing_account_id" => account, "id" => workspace_id}) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace_id
      })

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account,
        credits: 100,
        valid_from: DateTime.add(SystemsClock.utc_now(), -3600),
        expires_at: DateTime.add(SystemsClock.utc_now(), 86_400),
        source_type: "manual_contract",
        source_id: "live-workers:#{workspace_id}",
        source_event_id: "live-workers:#{workspace_id}",
        idempotency_key: "live-workers:#{workspace_id}"
      })
  end

  # The Router follows the platform Router model, served here by the live LLM.
  defp use_live_router!(router, llm) do
    platform = SalixAgent.AccountPool.platform_tenant()

    {:ok, profile} =
      SalixAgent.AccountPool.create(platform, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => System.fetch_env!(llm.api_key_env),
        "base_url" => llm.base_url,
        "protocol" => llm.protocol,
        "models" => [llm.model]
      })

    {:ok, settings} = SalixAgent.PlatformModels.get()

    on_exit(fn ->
      {:ok, _} = SalixAgent.PlatformModels.put(settings)

      SalixAgent.SubscriptionStore.query("DELETE FROM subscription_accounts WHERE id=$1", [
        profile["id"]
      ])
    end)

    entry = %{
      "profile_id" => profile["id"],
      "model" => llm.model,
      "protocol" => llm.protocol,
      "max_tokens" => llm.max_tokens
    }

    tiers = Map.put(settings["tiers"] || %{}, "router", entry)
    {:ok, _} = SalixAgent.PlatformModels.put(Map.put(settings, "tiers", tiers))
    SalixAgent.Server.info(router)
  end

  defp drain_results(acc \\ []) do
    SystemsRuntime.Proc.receive do
      {:create_worker_result, _, _} = message -> drain_results([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp settled?(router, session_id) do
    case SalixAgent.InternalSessionStore.read(router, session_id) do
      {:ok, session} ->
        SalixAgent.InternalSession.status(session) == :idle and
          SalixAgent.InternalSession.work_reasons(session) == []

      _other ->
        false
    end
  end

  defp router_replies(group, chat_id, router) do
    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(group, chat_id, limit: 50)

    Enum.filter(messages, &(&1["actor_type"] == "agent" and &1["agent_id"] == router))
  end

  # Every tool call the Router dispatched, in order, with the call envelope opened.
  defp router_tool_calls(router, acc \\ []) do
    SystemsRuntime.Proc.receive do
      {:tool_calls, ^router, %{"calls" => calls}} ->
        router_tool_calls(router, acc ++ Enum.flat_map(List.wrap(calls), &open_call/1))

      {:tool_calls, _other, _payload} ->
        router_tool_calls(router, acc)
    after
      0 -> acc
    end
  end

  defp open_call(call) when is_map(call) do
    name = call["name"] || call[:name]
    args = call["args"] || call[:args] || call["arguments"] || %{}
    args = if is_binary(args), do: Jason.decode!(args), else: args

    case {name, args} do
      {"call", %{"tool" => tool} = envelope} -> [%{tool: tool, params: envelope["params"] || %{}}]
      {name, args} when is_binary(name) -> [%{tool: name, params: args}]
      _ -> []
    end
  end

  defp open_call(_call), do: []
end
