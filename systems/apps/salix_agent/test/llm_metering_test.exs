defmodule SalixAgent.LLMMeteringTest do
  use ExUnit.Case, async: false

  defmodule Impl do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools, %{return_error: true}) do
      SalixAgent.LLM.Error.transport("mock", :timeout)
    end

    def complete(_messages, _tools, %{missing_usage: true}), do: {:final, "ok"}

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
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:meter_before, fact})
      :ok
    end

    @impl true
    def after_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:meter_after, fact})
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
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_metering = Application.get_env(:salix_agent, :llm_metering_mod)
    prev_pid = Application.get_env(:salix_agent, :metering_test_pid)

    Application.put_env(:salix_agent, :llm, Impl)
    Application.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
    Application.put_env(:salix_agent, :metering_test_pid, self())

    on_exit(fn ->
      restore(:llm, prev_llm)
      restore(:llm_metering_mod, prev_metering)
      restore(:metering_test_pid, prev_pid)
    end)
  end

  test "successful Responses without usage remains successful and meters missing usage" do
    assert {:final, "ok"} =
             SalixAgent.LLM.complete([], [], %{protocol: "responses", missing_usage: true})

    assert_receive {:meter_after, %{status: "ok", usage: %{"usage_reported" => false}}}
  end

  @tag :byok
  test "dispatch carries resolved credential scope into admission and usage" do
    assert {:final, "ok", _} =
             SalixAgent.LLM.complete([], [], %{
               "model" => "gpt-x",
               "credential_scope" => "tenant"
             })

    assert_receive {:meter_before, %{credential_scope: "tenant"}}
    assert_receive {:meter_after, %{credential_scope: "tenant", usage: %{"prompt_tokens" => 3}}}
  end

  test "generic LLM dispatch meters non-Round call sites" do
    assert {:final, "ok", _meta} =
             SalixAgent.LLM.complete([], [], %{
               model: "gpt-5.5",
               entrypoint: "js_analyze",
               actor_type: "system"
             })

    assert_receive {:meter_before,
                    %{
                      entrypoint: "js_analyze",
                      actor_type: "system",
                      model: "gpt-5.5",
                      provider: "openai",
                      app_revision: app_revision
                    }}

    assert is_binary(app_revision)
    assert app_revision != ""

    assert_receive {:meter_after,
                    %{
                      status: "ok",
                      usage: %{"prompt_tokens" => 3},
                      provider_model: "m",
                      provider: "openai",
                      app_revision: ^app_revision
                    }}
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
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "disabled" => false,
        "status" => "active",
        "prepared" => true,
        "credentials" => encrypted
      })

    assert {:final, "ok", _} = SalixAgent.LLM.complete([], [], config)
    assert_receive {:meter_before, %{tenant_account_pool: true}}
    assert_receive {:meter_after, %{tenant_account_pool: true, usage: %{"prompt_tokens" => 3}}}

    assert {:final, "ok", _} =
             SalixAgent.LLM.complete([], [], Map.put(config, "base_url", "https://other.invalid"))

    assert_receive {:meter_before, %{tenant_account_pool: false}}
  end

  test "app revision prefers runtime git SHA environment over mix version" do
    previous_app_env = Application.get_env(:salix_agent, :app_revision)
    previous_system_env = System.get_env("SALIX_APP_REVISION")

    Application.delete_env(:salix_agent, :app_revision)
    System.put_env("SALIX_APP_REVISION", "git-sha-test")

    try do
      assert SalixAgent.AppRevision.value() == "git-sha-test"
    after
      if previous_app_env,
        do: Application.put_env(:salix_agent, :app_revision, previous_app_env),
        else: Application.delete_env(:salix_agent, :app_revision)

      if previous_system_env,
        do: System.put_env("SALIX_APP_REVISION", previous_system_env),
        else: System.delete_env("SALIX_APP_REVISION")
    end
  end

  test "generic LLM dispatch meters structured provider errors as errors" do
    assert {:error, meta} =
             SalixAgent.LLM.complete([], [], %{
               return_error: true,
               model: "gpt-5.5",
               entrypoint: "js_analyze"
             })

    assert meta["category"] == "transport_error"

    assert_receive {:meter_before, %{entrypoint: "js_analyze", model: "gpt-5.5"}}

    assert_receive {:meter_after,
                    %{
                      status: "error",
                      response_kind: :error,
                      usage: %{},
                      llm_error: %{"category" => "transport_error", "provider" => "mock"}
                    }}
  end

  test "generic LLM dispatch emits a distinct request id for each metered call" do
    assert {:final, "ok", _meta} = SalixAgent.LLM.complete([], [], %{model: "gpt-5.5"})
    assert {:final, "ok", _meta} = SalixAgent.LLM.complete([], [], %{model: "gpt-5.5"})

    assert_receive {:meter_before, %{request_id: first_request_id}}
    assert_receive {:meter_after, %{request_id: ^first_request_id}}
    assert_receive {:meter_before, %{request_id: second_request_id}}
    assert_receive {:meter_after, %{request_id: ^second_request_id}}

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
    Application.put_env(:salix_agent, :llm_metering_mod, RaisingMetering)

    assert {:error, {:billing_unavailable, decision}} =
             SalixAgent.LLM.complete([], [], %{model: "m"})

    refute decision.allowed?
    assert decision.reason == "fee_control_error"
  end

  defp restore(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore(key, value), do: Application.put_env(:salix_agent, key, value)
end
