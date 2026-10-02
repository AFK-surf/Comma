defmodule SalixAgent.CatalogRoundE2ETest do
  @moduledoc """
  A real Round on a catalog route, through the real provider encoding.

  A catalog route binds its Profile only at dispatch, so every step before
  dispatch must stay provider-neutral: each candidate encodes the request with
  its own protocol and its own request id. These tests run `Round.run/2` with
  `SalixLlm.Provider`, real API-key Profiles and their real endpoints. A Req
  adapter answers in place of the network and records what each provider got.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{AccountPool, InternalSessionStore, Round}

  @session "ses1_0000000000000000903"

  defmodule Metering do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering
    @impl true
    def before_llm_call(_fact), do: :ok
    @impl true
    def after_llm_call(_fact), do: :ok
  end

  defmodule Resolver do
    @moduledoc false
    def resolve(_agent_id), do: {:ok, :persistent_term.get({__MODULE__, :route})}
  end

  defmodule NoKnowledge do
    @moduledoc false
    def retrieve(_agent_id, _question, _context), do: {:ok, []}
  end

  setup_all do
    poller = Process.whereis(SalixAgent.SubscriptionQuotaWorker)
    if poller, do: :sys.suspend(poller)
    on_exit(fn -> if poller && Process.alive?(poller), do: :sys.resume(poller) end)
    :ok
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

    previous = for {app, key} <- settings, do: {app, key, Application.fetch_env(app, key)}

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      :persistent_term.erase({Resolver, :route})

      for {app, key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, SalixLlm.Provider)
    Application.put_env(:salix_agent, :llm_metering_mod, Metering)
    Application.put_env(:salix_agent, :llm_resolver, Resolver)
    Application.put_env(:salix_agent, :project_knowledge_provider_mod, NoKnowledge)

    agent = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent)
    tenant = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker"
    })

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent, @session, [
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

  test "an Anthropic candidate gets an Anthropic Messages request", %{
    agent: agent,
    tenant: tenant
  } do
    {:ok, _} = key(tenant, "anthropic", "sk-ant-e2e-0123456789abcdef")
    providers = capture(:refuse)

    run_round(agent, tenant, "claude-haiku-4-5")

    assert [anthropic | _] = sent(providers)
    assert anthropic.url == "https://api.anthropic.com/v1/messages"
    assert anthropic.body["model"] == "claude-haiku-4-5"
    assert is_list(anthropic.body["messages"])
    assert anthropic.headers["x-api-key"] == ["sk-ant-e2e-0123456789abcdef"]
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

  defp run_round(agent, tenant, model) do
    {:ok, route} =
      AccountPool.resolve_config(
        %{"catalog_model" => model, "allow_paid" => true, "credential_scope" => "tenant"},
        tenant
      )

    :persistent_term.put({Resolver, :route}, route)
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

    Req.default_options(adapter: adapter, retry: false)
    log
  end

  defp sent(log), do: log |> Agent.get(& &1) |> Enum.reverse()
end
