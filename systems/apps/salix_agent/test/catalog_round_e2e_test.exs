defmodule SalixAgent.CatalogRoundE2ETest do
  @moduledoc """
  A real Round on a catalog route, through the real provider encoding.

  A catalog route binds its Profile only at dispatch, so every step before
  dispatch must stay provider-neutral: each candidate encodes the request with
  its own protocol and its own request id. These tests run `Round.run/2` with
  `SalixLlm.Provider`, real API-key Profiles and their real endpoints. A Req
  adapter answers in place of the network and records what each provider got.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, InternalSessionStore, Round}

  @session "ses1_0000000000000000903"

  # Refuses a deducting call while the test asks it to, and hands each
  # finished call's meter fact to the test.
  defmodule Metering do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering
    @impl true
    def before_llm_call(fact) do
      if fact[:settlement] == "deduct" and
           SystemsRuntime.PersistentTerm.get({__MODULE__, :refuse_deduct}, false),
         do: {:error, {:billing_unavailable, %{reason: "insufficient_credits"}}},
         else: :ok
    end

    @impl true
    def after_llm_call(fact) do
      case SystemsRuntime.PersistentTerm.get({__MODULE__, :test}, nil) do
        nil ->
          :ok

        pid ->
          SystemsRuntime.Proc.send(
            pid,
            {:metered, Map.take(fact, [:credential_scope, :settlement])}
          )
      end

      :ok
    end
  end

  defmodule Resolver do
    @moduledoc false
    def resolve(_agent_id), do: {:ok, SystemsRuntime.PersistentTerm.get({__MODULE__, :route})}
  end

  defmodule NoKnowledge do
    @moduledoc false
    def retrieve(_agent_id, _question, _context), do: {:ok, []}
  end

  setup do
    settings = [
      {:salix_store, :s3_backend},
      {:salix_agent, :llm},
      {:salix_agent, :llm_metering_mod},
      {:salix_agent, :llm_resolver},
      {:salix_agent, :project_knowledge_provider_mod},
      {:req, :default_options}
    ]

    previous = for {app, key} <- settings, do: {app, key, SystemsRuntime.fetch_env(app, key)}

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase({Resolver, :route})
      SystemsRuntime.PersistentTerm.erase({Metering, :refuse_deduct})
      SystemsRuntime.PersistentTerm.erase({Metering, :test})

      for {app, key, value} <- previous do
        case value do
          {:ok, value} -> SystemsRuntime.put_env(app, key, value)
          :error -> SystemsRuntime.delete_env(app, key)
        end
      end
    end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixLlm.Provider)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, Metering)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, Resolver)
    SystemsRuntime.put_env(:salix_agent, :project_knowledge_provider_mod, NoKnowledge)

    agent = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent)
    tenant = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker"
    })

    {:ok, _} =
      SalixAgent.TestSupport.SessionFixture.commit(agent, @session, [
        %{"type" => "session_created", "session_id" => @session, "platform" => "raft"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session,
          "message_id" => 1,
          "content" => "say hello"
        },
        %{"type" => "ack", "session_id" => @session, "last_ack_message_id" => 1}
      ])

    {:ok, agent: agent, tenant: tenant}
  end

  test "each candidate encodes for its own protocol and request id", %{
    agent: agent,
    tenant: tenant
  } do
    # The first Profile tried refuses with 429, so the request moves to the
    # other, in whichever order dispatch tries them: OpenAI gets Responses
    # with `gpt-5.5`, OpenRouter gets Chat Completions with `openai/gpt-5.5`.
    {:ok, _} = key(tenant, "openai", "sk-proj-e2e-0123456789abcdef")
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-e2e-0123456789abcdef")
    providers = capture(:first_host_busy)

    run_round(agent, tenant, "gpt-5.5")

    # The provider retries the 429 itself before dispatch moves on.
    sent = sent(providers)
    assert %{} = openai = Enum.find(sent, &(&1.url =~ "api.openai.com"))
    assert %{} = openrouter = Enum.find(sent, &(&1.url =~ "openrouter.ai"))

    assert openai.url == "https://api.openai.com/v1/responses"
    assert openai.body["model"] == "gpt-5.5"
    assert is_list(openai.body["input"])
    assert openai.headers["authorization"] == ["Bearer sk-proj-e2e-0123456789abcdef"]

    assert openrouter.url == "https://openrouter.ai/api/v1/chat/completions"
    assert openrouter.body["model"] == "openai/gpt-5.5"
    assert is_list(openrouter.body["messages"])
    assert openrouter.headers["authorization"] == ["Bearer sk-or-v1-e2e-0123456789abcdef"]
  end

  # A Session's own model choice (SalixAgent.ModelChoice) replaces its
  # Agent's model for that Session only.
  test "a Session with its own model sends that model, not its Agent's", %{
    agent: agent,
    tenant: tenant
  } do
    {:ok, _} = key(tenant, "anthropic", "sk-ant-e2e-0123456789abcdef")
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-e2e-0123456789abcdef")
    providers = capture(:refuse)

    {:ok, _} =
      SalixAgent.TestSupport.SessionFixture.commit(agent, @session, [
        %{
          "type" => "session_update",
          "session_id" => @session,
          "model" => %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => true}
        }
      ])

    run_round(agent, tenant, "claude-haiku-4-5")

    assert [_ | _] = sent = sent(providers)
    assert Enum.all?(sent, &(&1.url == "https://openrouter.ai/api/v1/chat/completions"))
    assert Enum.all?(sent, &(&1.body["model"] == "openai/gpt-5.5"))
  end

  # The site LLM proxy (runtime proxy, meeting summary and copilot, site APIs)
  # sends a resolved route itself. A catalog route has no endpoint of its own:
  # it must go through dispatch to a Profile's endpoint and request id.
  test "the site proxy sends a catalog route to a Profile, not to catalog://", %{tenant: tenant} do
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-e2e-0123456789abcdef")
    providers = capture(:refuse)

    {:ok, route} =
      AccountPool.resolve_config(
        %{"catalog_model" => "gpt-5.5", "allow_paid" => true, "credential_scope" => "tenant"},
        tenant
      )

    assert {:error, {:http, 400, _}} =
             SalixLlm.SiteProxy.complete(route, %{
               messages: [%{"role" => "user", "content" => "hi"}]
             })

    assert [openrouter] = sent(providers)
    assert openrouter.url == "https://openrouter.ai/api/v1/chat/completions"
    assert openrouter.body["model"] == "openai/gpt-5.5"
  end

  describe "a platform Router" do
    setup %{tenant: tenant} do
      platform = AccountPool.platform_tenant()

      on_exit(fn ->
        SalixAgent.SubscriptionStore.query(
          "DELETE FROM subscription_accounts WHERE tenant_id=$1",
          [platform]
        )

        SalixAgent.PlatformRouter.delete(tenant)
      end)

      {:ok, _} = key(platform, "openrouter", "sk-or-v1-platform-e2e-0123456789")
      {:ok, _} = key(tenant, "openai", "sk-proj-e2e-0123456789abcdef")
      SystemsRuntime.PersistentTerm.put({Metering, :test}, self())
      :ok
    end

    test "a round served by a platform key is metered as platform-funded, by its billing", %{
      agent: agent,
      tenant: tenant
    } do
      {:ok, _} =
        SalixAgent.PlatformRouter.put(tenant, %{"model" => "gpt-5.5", "billing" => "record"})

      providers = capture({:answer, "openrouter.ai"})
      run_round(agent, tenant, "gpt-5.5", %{"platform" => true, "allow_paid" => false})

      assert [%{host: "openrouter.ai"} = first | _] = sent(providers)
      assert first.headers["authorization"] == ["Bearer sk-or-v1-platform-e2e-0123456789"]
      assert_received {:metered, %{credential_scope: "platform", settlement: "record"}}
    end

    test "in deduct billing a refused fee check stops the round; the tenant's key is not tried",
         %{
           agent: agent,
           tenant: tenant
         } do
      {:ok, _} =
        SalixAgent.PlatformRouter.put(tenant, %{"model" => "gpt-5.5", "billing" => "deduct"})

      SystemsRuntime.PersistentTerm.put({Metering, :refuse_deduct}, true)
      providers = capture(:refuse)
      run_round(agent, tenant, "gpt-5.5", %{"platform" => true, "allow_paid" => false})

      assert sent(providers) == []
      refute_received {:metered, %{credential_scope: "platform"}}
    end

    test "in deduct billing a refused fee check sends the round to the tenant's key when the record allows pay-per-use",
         %{agent: agent, tenant: tenant} do
      {:ok, _} =
        SalixAgent.PlatformRouter.put(tenant, %{
          "model" => "gpt-5.5",
          "billing" => "deduct",
          "allow_paid" => true
        })

      SystemsRuntime.PersistentTerm.put({Metering, :refuse_deduct}, true)
      providers = capture(:refuse)
      # The choice the Router holds: the record's option carried into it.
      run_round(agent, tenant, "gpt-5.5", %{"platform" => true, "allow_paid" => true})

      assert [_ | _] = sent = sent(providers)
      assert Enum.all?(sent, &(&1.host == "api.openai.com"))
      refute_received {:metered, %{credential_scope: "platform"}}
    end
  end

  defp run_round(agent, tenant, model, extra \\ %{}) do
    {:ok, route} =
      AccountPool.resolve_config(
        Map.merge(
          %{"catalog_model" => model, "allow_paid" => true, "credential_scope" => "tenant"},
          extra
        ),
        tenant
      )

    SystemsRuntime.PersistentTerm.put({Resolver, :route}, route)
    # The providers refuse, so the Round ends without a reply. What matters is
    # what reached each provider.
    _ = Round.run(%{agent_id: agent, session_id: @session}, @session)
  end

  defp key(tenant, source, api_key) do
    AccountPool.create(tenant, %{
      "credential_kind" => "provider_api_key",
      "source" => source,
      "api_key" => api_key
    })
  end

  # Answer every provider request in place of the network with a 400 that no
  # other Profile can fix. `:first_host_busy` answers 429 at the first host
  # until a request reaches another one.
  defp capture(mode) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    adapter = fn request ->
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()

      if mode == {:answer, request.url.host},
        do: answer(log, request, body),
        else: refuse(log, mode, request, body)
    end

    Req.default_options(adapter: adapter, retry: false)
    log
  end

  # A streamed Chat Completions reply with its usage.
  defp answer(log, request, body) do
    Agent.update(log, fn sent ->
      [
        %{
          host: request.url.host,
          url: URI.to_string(request.url),
          headers: request.headers,
          body: body
        }
        | sent
      ]
    end)

    chunks = [
      "data: " <>
        Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "hello"}}]}) <>
        "\n\n",
      "data: " <>
        Jason.encode!(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 2, "total_tokens" => 14}
        }) <> "\n\n",
      "data: [DONE]\n\n"
    ]

    response =
      Req.Response.new(status: 200, body: "", headers: %{"content-type" => ["text/event-stream"]})

    Enum.reduce(chunks, {request, response}, fn chunk, acc ->
      {_, acc} = request.into.({:data, chunk}, acc)
      acc
    end)
  end

  defp refuse(log, mode, request, body) do
    status =
      Agent.get_and_update(log, fn sent ->
        hosts = sent |> Enum.map(& &1.host) |> Enum.uniq()

        status =
          if mode == :first_host_busy and hosts in [[], [request.url.host]], do: 429, else: 400

        entry = %{
          host: request.url.host,
          url: URI.to_string(%{request.url | query: nil}),
          headers: request.headers,
          body: body
        }

        {status, [entry | sent]}
      end)

    error = Jason.encode!(%{"error" => %{"type" => "e2e", "message" => "refused"}})

    response =
      Req.Response.new(
        status: status,
        body: "",
        headers: %{"content-type" => ["application/json"]}
      )

    if is_function(request.into, 2) do
      {_, result} = request.into.({:data, error}, {request, response})
      result
    else
      {request, %{response | body: error}}
    end
  end

  defp sent(log), do: log |> Agent.get(& &1) |> Enum.reverse()
end
