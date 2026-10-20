defmodule SalixAgent.LLMMeteringTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  defmodule Impl do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools, %{return_error: true}) do
      SalixAgent.LLM.Error.transport("mock", :timeout)
    end

    def complete(_messages, _tools, %{missing_usage: true}), do: {:final, "ok"}

    def complete(_messages, _tools, %{"provider_quota" => true}) do
      SalixAgent.LLM.Error.http("openai_chat", 429, %{
        "error" => %{
          "code" => "insufficient_quota",
          "message" => "You exceeded your current quota"
        }
      })
    end

    def complete(_messages, _tools, %{"gateway_credits" => true}) do
      SalixAgent.LLM.Error.http("anthropic", 402, %{
        "name" => "AiGatewayError",
        "internalCode" => 2021,
        "message" => "Insufficient wholesale credits."
      })
    end

    def complete(_messages, _tools, _opts) do
      {:final, "ok", %{"usage" => %{"prompt_tokens" => 3}, "model" => "m"}}
    end

    @impl true
    def complete(_messages, _tools), do: {:final, "ok"}
  end

  defmodule MeteringFake do
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:meter_before, fact}
      )

      :ok
    end

    @impl true
    def after_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:meter_after, fact}
      )

      :ok
    end
  end

  defmodule RaisingMetering do
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(_fact), do: raise("metering down")

    @impl true
    def after_llm_call(_fact), do: exit(:metering_down)
  end

  setup do
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_metering = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    prev_pid = SystemsRuntime.get_env(:salix_agent, :metering_test_pid)

    SystemsRuntime.put_env(:salix_agent, :llm, Impl)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
    SystemsRuntime.put_env(:salix_agent, :metering_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore(:llm, prev_llm)
      restore(:llm_metering_mod, prev_metering)
      restore(:metering_test_pid, prev_pid)
    end)
  end

  test "successful Responses without usage remains successful and meters missing usage" do
    assert {:final, "ok"} =
             SalixAgent.LLM.complete([], [], %{protocol: "responses", missing_usage: true})

    settle_receive({:meter_after, %{status: "ok", usage: %{"usage_reported" => false}}})
  end

  @tag :byok
  test "dispatch carries resolved credential scope into admission and usage" do
    assert {:final, "ok", _} =
             SalixAgent.LLM.complete([], [], %{
               "model" => "gpt-x",
               "credential_scope" => "tenant"
             })

    settle_receive({:meter_before, %{credential_scope: "tenant"}})
    settle_receive({:meter_after, %{credential_scope: "tenant", usage: %{"prompt_tokens" => 3}}})
  end

  @tag :byok
  test "an exhausted provider account the member funds stops as a billing failure" do
    # Round dispatches with metering disabled and without a billing context:
    # the tenant-scoped route alone identifies the member's own key.
    opts = %{"model" => "gpt-x", "provider_quota" => true, "credential_scope" => "tenant"}

    for opts <- [opts, Map.put(opts, "metering_disabled", true)] do
      assert {:error,
              %{
                "error_class" => "billing_unavailable",
                "reason" => "provider_quota_exhausted",
                "retryable" => false,
                "status" => 429
              }} = SalixAgent.LLM.complete([], [], opts)
    end
  end

  # Staging 2026-10-02: once the AI Gateway's prepaid credits ran out, every
  # platform-funded Anthropic call got this 402. The Worker showed a connection
  # failure that asked for another send, which could not succeed. OpenAI's
  # `429 insufficient_quota` reports the same exhausted account.
  test "an exhausted platform provider account stops as an unavailable model" do
    for scope <- [nil, "platform"],
        {failure, status} <- [{"gateway_credits", 402}, {"provider_quota", 429}] do
      assert {:error,
              %{
                "error_class" => "billing_unavailable",
                "reason" => "model_unavailable",
                "retryable" => false,
                "status" => ^status
              }} =
               SalixAgent.LLM.complete([], [], %{
                 "model" => "claude-x",
                 failure => true,
                 "credential_scope" => scope,
                 "metering_disabled" => true
               })
    end
  end

  test "generic LLM dispatch meters non-Round call sites" do
    assert {:final, "ok", _meta} =
             SalixAgent.LLM.complete([], [], %{
               model: "gpt-5.5",
               entrypoint: "js_analyze",
               actor_type: "system"
             })

    settle_receive(
      {:meter_before,
       %{
         entrypoint: "js_analyze",
         actor_type: "system",
         model: "gpt-5.5",
         provider: "openai",
         app_revision: app_revision
       }}
    )

    assert is_binary(app_revision)
    assert app_revision != ""

    settle_receive(
      {:meter_after,
       %{
         status: "ok",
         usage: %{"prompt_tokens" => 3},
         provider_model: "m",
         provider: "openai",
         app_revision: ^app_revision
       }}
    )
  end

  test "only the configured tenant route marks subscription usage exempt" do
    tenant = SalixStore.Ids.new_tenant_id()

    {:ok, config} =
      SalixAgent.AccountPool.resolve_config(
        %{"account_pool" => "codex", "model" => "gpt-5"},
        tenant
      )

    id = SalixAgent.SubscriptionStore.id()

    {:ok, encrypted} =
      SalixAgent.SubscriptionStore.seal(tenant, id, %{"access_token" => "synthetic"})

    {:ok, _} =
      SalixAgent.SubscriptionStore.create(tenant, %{
        "id" => id,
        "credential" => "subscription",
        "source" => "codex",
        "disabled" => false,
        "status" => "ok",
        "prepared" => true,
        "credentials" => encrypted
      })

    assert {:final, "ok", _} = SalixAgent.LLM.complete([], [], config)
    settle_receive({:meter_before, %{tenant_account_pool: true}})
    settle_receive({:meter_after, %{tenant_account_pool: true, usage: %{"prompt_tokens" => 3}}})

    assert {:final, "ok", _} =
             SalixAgent.LLM.complete([], [], Map.put(config, "base_url", "https://other.invalid"))

    settle_receive({:meter_before, %{tenant_account_pool: false}})
  end

  test "generic LLM dispatch meters structured provider errors as errors" do
    assert {:error, meta} =
             SalixAgent.LLM.complete([], [], %{
               return_error: true,
               model: "gpt-5.5",
               entrypoint: "js_analyze"
             })

    assert meta["category"] == "transport_error"

    settle_receive({:meter_before, %{entrypoint: "js_analyze", model: "gpt-5.5"}})

    settle_receive(
      {:meter_after,
       %{
         status: "error",
         response_kind: :error,
         usage: %{},
         llm_error: %{"category" => "transport_error", "provider" => "mock"}
       }}
    )
  end

  test "generic LLM dispatch emits a distinct request id for each metered call" do
    assert {:final, "ok", _meta} = SalixAgent.LLM.complete([], [], %{model: "gpt-5.5"})
    assert {:final, "ok", _meta} = SalixAgent.LLM.complete([], [], %{model: "gpt-5.5"})

    settle_receive({:meter_before, %{request_id: first_request_id}})
    settle_receive({:meter_after, %{request_id: ^first_request_id}})
    settle_receive({:meter_before, %{request_id: second_request_id}})
    settle_receive({:meter_after, %{request_id: ^second_request_id}})
    assert is_binary(first_request_id)
    assert is_binary(second_request_id)
    assert first_request_id != second_request_id
  end

  test "Round can disable generic dispatch metering to avoid duplicate facts" do
    assert {:final, "ok", _meta} = SalixAgent.LLM.complete([], [], %{metering_disabled: true})
    refute_received {:meter_before, _}
    refute_received {:meter_after, _}
  end

  test "before-call metering failures block provider dispatch" do
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, RaisingMetering)

    assert {:error, {:billing_unavailable, decision}} =
             SalixAgent.LLM.complete([], [], %{model: "m"})

    refute decision.allowed?
    assert decision.reason == "fee_control_error"
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)
end
