defmodule SalixAgent.LlmConfigTest do
  @moduledoc """
  Per-agent LLM config is resolved through the control-plane template. The
  runtime session receives the resolved per-call opts, but `SalixAgent.State`
  does not own a journaled provider snapshot.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Agent, Keys, S3}
  alias SalixAgent.{State, Templates}

  @session_id "ses1_0000000000000000603"

  defmodule ControlTemplateResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: Templates.resolve_llm_for_agent(agent_id)
  end

  # An impl capturing the opts it was called with (registered via :persistent_term).
  defmodule CapturingLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools) do
      record([])
      {:final, "no-opts"}
    end

    @impl true
    def complete(_messages, _tools, llm_opts) do
      record(llm_opts)
      {:final, "with-opts"}
    end

    defp record(opts) do
      pid = :persistent_term.get({__MODULE__, :test_pid})
      send(pid, {:llm_called, opts})
      :ok
    end
  end

  defmodule ScopeMetering do
    def before_llm_call(fact) do
      send(:persistent_term.get({CapturingLLM, :test_pid}), {:scope_before, fact})
      :ok
    end

    def after_llm_call(fact) do
      send(:persistent_term.get({CapturingLLM, :test_pid}), {:scope_after, fact})
      :ok
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_llm_resolver = Application.get_env(:salix_agent, :llm_resolver)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, CapturingLLM)
    Application.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
    :persistent_term.put({CapturingLLM, :test_pid}, self())
    start_supervised!(SalixStore.S3.Fake)

    agent = SalixAgent.TestSupport.new_agent_id()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      Application.put_env(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :llm_resolver, prev_llm_resolver)
      restore(:salix_agent, :group_context_mod, prev_group_context)
    end)

    {:ok, agent: agent}
  end

  @tag :private_template
  @tag :session_optimization
  test "warm catalog reuse resolves changed credentials and fails on deleted configuration", %{
    agent: agent
  } do
    record = SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, snapshot} = SalixAgent.RoundConfig.build_round_snapshot(agent)
    assert {:ok, warm} = SalixAgent.RoundConfig.refresh_round_snapshot(agent, snapshot, %{})
    assert warm.session_config == snapshot.session_config

    assert {:ok, _} =
             Templates.update(record["template_id"], %{
               "provider_config" => %{"api_key" => "replacement-test-key"}
             })

    assert {:ok, refreshed} = SalixAgent.RoundConfig.refresh_round_snapshot(agent, warm, %{})
    assert opt(refreshed.llm_opts, "api_key") == "replacement-test-key"
    assert refreshed.session_config == snapshot.session_config

    # A failed live lookup must not release the cached credentials.
    assert {:ok, _} =
             SalixStore.CasRecord.update(
               Keys.ctl_agent(agent),
               &Map.put(&1, "template_id", "missing-template")
             )

    assert {:error, _} = SalixAgent.RoundConfig.refresh_round_snapshot(agent, refreshed, %{})
  end

  @tag :private_template
  test "a selected tenant template reaches the actual round's LLM dispatch", %{agent: agent_id} do
    previous_metering = Application.get_env(:salix_agent, :llm_metering_mod)
    Application.put_env(:salix_agent, :llm_metering_mod, ScopeMetering)
    on_exit(fn -> restore(:salix_agent, :llm_metering_mod, previous_metering) end)
    record = SalixAgent.TestSupport.create_control_agent!(agent_id)
    tenant = record["tenant_id"]

    assert {:ok, template} =
             Templates.create_private(
               %{
                 "name" => "Tenant round",
                 "model" => "gpt-tenant-round",
                 "provider_config" => %{"api_key" => "tenant-round-secret"}
               },
               tenant
             )

    assert {:ok, _} =
             SalixAgent.Control.configure(
               agent_id,
               %{"template_id" => template["template_id"]},
               tenant
             )

    assert {:ok, _} =
             SalixAgent.deliver(agent_id, %{content: "hi", session_id: @session_id},
               source_message_id: "private-template-round:#{agent_id}"
             )

    assert_receive {:llm_called, opts}, 3_000
    assert opt(opts, "model") == "gpt-tenant-round"
    assert opt(opts, "api_key") == "tenant-round-secret"
    assert opt(opts, "credential_scope") == "tenant"
    assert_receive {:scope_before, %{credential_scope: "tenant"}}
    assert_receive {:scope_after, %{credential_scope: "tenant"}}, 3_000
    SalixAgent.TestSupport.await_session_quiet(agent_id, @session_id)
  end

  @tag :byok
  test "private deletion stops at the reference bound and preserves unread templates", %{
    agent: agent_id
  } do
    record = SalixAgent.TestSupport.create_control_agent!(agent_id)
    tenant = record["tenant_id"]
    other = SalixStore.Ids.new_agent_id(record["group_id"])
    assert {:ok, _} = S3.put(Keys.ctl_agent(other), Jason.encode!(%{"agent_id" => other}))

    assert {:ok, template} =
             Templates.create_private(%{"name" => "Unused", "model" => "gpt-x"}, tenant)

    id = template["template_id"]
    assert {:error, :template_reference_limit} = Templates.delete_private(id, tenant, 1)
    assert {:ok, _} = Templates.get(id, tenant)
    assert :ok = Templates.delete_private(id, tenant, 2)
    assert {:error, :not_found} = Templates.get(id, tenant)
  end

  @tag :byok
  test "template ownership overrides supplied credential scope for main and analyze configs" do
    attrs = %{
      "name" => "Scope",
      "model" => "gpt-x",
      "provider_config" => %{"credential_scope" => "tenant"},
      "analyze_config" => %{
        "endpoint" => "https://example.com/v1",
        "model" => "gpt-analyze",
        "credential_scope" => "tenant"
      }
    }

    assert {:ok, global} = Templates.create(attrs)
    assert {:ok, llm} = Templates.resolve_llm_for_template(global["template_id"])
    assert llm["credential_scope"] == "platform"
    assert {:ok, media} = Templates.resolve_media_for_template(global["template_id"])
    assert media["analyze_config"]["credential_scope"] == "platform"
    tenant = SalixStore.Ids.new_tenant_id()
    assert {:ok, private} = Templates.create_private(attrs, tenant)
    assert {:ok, media} = Templates.resolve_media_for_template(private["template_id"], tenant)
    assert media["analyze_config"]["credential_scope"] == "tenant"
  end

  @tag :private_template
  test "the combined catalog keeps its total bound and never includes another tenant" do
    tenant = SalixStore.Ids.new_tenant_id()
    other = SalixStore.Ids.new_tenant_id()
    assert {:ok, global} = Templates.create(%{"name" => "Global", "model" => "gpt-global"})

    assert {:ok, private} =
             Templates.create_private(%{"name" => "Private", "model" => "gpt-private"}, tenant)

    for n <- 1..4 do
      assert {:ok, _} =
               Templates.create_private(%{"name" => "Other #{n}", "model" => "gpt-other"}, other)
    end

    assert {:ok, catalog} = Templates.list_available(tenant, 2)

    assert Enum.map(catalog, & &1["template_id"]) == [
             global["template_id"],
             private["template_id"]
           ]

    assert {:error, :model_catalog_too_large} = Templates.list_available(tenant, 1)
    assert {:error, :model_catalog_too_large} = Templates.list_private(other, 3)
    assert {:error, :invalid_model_catalog_limit} = Templates.list_available(tenant, 101)
    assert {:error, :invalid_model_catalog_limit} = Templates.list_private(tenant, 0)
  end

  test "the control template config reaches the impl as per-call opts", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a, %{
      "model" => "claude-haiku-4-5",
      "provider" => "anthropic",
      "provider_config" => %{
        "protocol" => "anthropic",
        "api_key_env" => "TENANT_A_KEY"
      }
    })

    # Now a user delivery → round → the impl sees the snapshot as opts.
    {:ok, _} =
      SalixAgent.deliver(a, %{content: "hi", session_id: @session_id},
        source_message_id: "llm-config-snapshot:#{a}"
      )

    assert_receive {:llm_called, opts}, 3_000
    assert opt(opts, "model") == "claude-haiku-4-5"
    assert opt(opts, "api_key_env") == "TENANT_A_KEY"

    # The runtime state does not own provider config; a fresh replay remains
    # free of a stale llm snapshot.
    {:ok, state} = Agent.read_state(a, State)
    refute Map.has_key?(state, :llm)
  end

  test "without a session snapshot the default control template still resolves opts", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _} =
      SalixAgent.deliver(a, %{content: "hi", session_id: @session_id},
        source_message_id: "llm-config-default:#{a}"
      )

    assert_receive {:llm_called, opts}, 3_000
    assert opt(opts, "model") == "mock"
  end

  test "template resolution carries inferred provider into LLM opts" do
    id = "tmpl-provider-#{System.unique_integer([:positive])}"

    assert {:ok, template} =
             Templates.create(%{
               "template_id" => id,
               "name" => "Gemini",
               "model" => "gemini-2.5-pro",
               "provider_config" => %{
                 "base_url" => "https://generativelanguage.googleapis.com/v1beta"
               }
             })

    assert template["provider"] == "gemini"

    assert {:ok, llm} = Templates.resolve_llm_for_template(id)
    assert llm["model"] == "gemini-2.5-pro"
    assert llm["provider"] == "gemini"
  end

  test "public template reads fetch one record without returning provider credentials" do
    id = "tmpl-public-#{System.unique_integer([:positive])}"

    assert {:ok, _template} =
             Templates.create(%{
               "template_id" => id,
               "name" => "Public model",
               "model" => "gpt-public",
               "provider_config" => %{
                 "api_key" => "not-returned",
                 "base_url" => "https://example.test/v1"
               }
             })

    assert {:ok, template} = Templates.get_public(id)
    assert template["template_id"] == id
    assert template["model"] == "gpt-public"
    refute Map.has_key?(template, "provider_config")
  end

  test "bounded public template catalog redacts private config and excludes hidden entries" do
    assert {:ok, _template} =
             Templates.create(%{
               "template_id" => "catalog-visible",
               "name" => "Visible model",
               "model" => "gpt-visible",
               "provider" => "openai",
               "provider_config" => %{"api_key" => "must-not-cross"},
               "request_headers" => %{"x-private" => "must-not-cross"}
             })

    assert {:ok, _template} =
             Templates.create(%{
               "template_id" => "catalog-hidden",
               "name" => "Hidden model",
               "model" => "gpt-hidden",
               "provider" => "openai",
               "hidden" => true
             })

    assert {:ok, templates} = Templates.list_public_bounded(10)
    assert Enum.map(templates, & &1["template_id"]) == ["catalog-visible"]

    assert [visible] = templates
    assert visible["model"] == "gpt-visible"
    refute Map.has_key?(visible, "provider_config")
    refute Map.has_key?(visible, "request_headers")
  end

  test "bounded public template catalog rejects overflow before reading an unbounded set" do
    for number <- 1..4 do
      assert {:ok, _template} =
               Templates.create(%{
                 "template_id" => "catalog-overflow-#{number}",
                 "name" => "Catalog overflow #{number}",
                 "model" => "gpt-overflow-#{number}"
               })
    end

    assert {:error, :model_catalog_too_large} = Templates.list_public_bounded(3)
  end

  test "template resolution canonicalizes the 5.6-sol alias" do
    id = "tmpl-sol-#{System.unique_integer([:positive])}"

    assert {:ok, template} =
             Templates.create(%{
               "template_id" => id,
               "name" => "5.6 SOL",
               "model" => "5.6-sol",
               "provider_config" => %{
                 "base_url" => "https://api.openai.com/v1"
               }
             })

    assert template["provider"] == "openai"
    assert template["model"] == "gpt-5.6-sol"

    assert {:ok, updated} = Templates.update(id, %{"model" => " 5.6-SOL "})
    assert updated["model"] == "gpt-5.6-sol"

    assert {:ok, llm} = Templates.resolve_llm_for_template(id)
    assert llm["model"] == "gpt-5.6-sol"
    assert llm["provider"] == "openai"
    assert llm["protocol"] == "responses"
  end

  test "GPT-5.6 official alias and canonical tiers resolve to stable Responses configs" do
    cases = [
      {"gpt-5.6", "gpt-5.6-sol"},
      {"gpt-5.6-sol", "gpt-5.6-sol"},
      {" GPT-5.6-TERRA ", "gpt-5.6-terra"},
      {"gpt-5.6-luna", "gpt-5.6-luna"}
    ]

    for {input_model, expected_model} <- cases do
      id = "tmpl-gpt56-#{System.unique_integer([:positive])}"

      assert {:ok, template} =
               Templates.create(%{
                 "template_id" => id,
                 "name" => input_model,
                 "model" => input_model,
                 "provider_config" => %{"base_url" => "https://api.openai.com/v1"}
               })

      assert template["model"] == expected_model
      assert template["provider"] == "openai"

      assert {:ok, llm} = Templates.resolve_llm_for_template(id)
      assert llm["model"] == expected_model
      assert llm["provider"] == "openai"
      assert llm["protocol"] == "responses"
    end
  end

  test "GPT-5.6 template preserves an explicit Chat Completions protocol" do
    id = "tmpl-sol-chat-#{System.unique_integer([:positive])}"

    assert {:ok, _template} =
             Templates.create(%{
               "template_id" => id,
               "name" => "5.6 Sol chat",
               "model" => "gpt-5.6-sol",
               "provider_config" => %{
                 "protocol" => "chat_completions",
                 "base_url" => "https://api.openai.com/v1"
               }
             })

    assert {:ok, llm} = Templates.resolve_llm_for_template(id)
    assert llm["model"] == "gpt-5.6-sol"
    assert llm["protocol"] == "chat_completions"
  end

  test "GPT-5.6 template does not force Responses for an explicit non-OpenAI provider" do
    id = "tmpl-sol-proxy-#{System.unique_integer([:positive])}"

    assert {:ok, _template} =
             Templates.create(%{
               "template_id" => id,
               "name" => "5.6 Sol proxy",
               "model" => "gpt-5.6-sol",
               "provider" => "custom-proxy",
               "provider_config" => %{"base_url" => "https://models.example.test/v1"}
             })

    assert {:ok, llm} = Templates.resolve_llm_for_template(id)
    assert llm["model"] == "gpt-5.6-sol"
    assert llm["provider"] == "custom-proxy"
    refute Map.has_key?(llm, "protocol")
  end

  test "template resolution canonicalizes a stored legacy 5.6-sol alias" do
    id = "tmpl-legacy-sol-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             S3.put(
               Keys.ctl_template(id),
               Jason.encode!(%{
                 "template_id" => id,
                 "name" => "Legacy 5.6 SOL",
                 "model" => "5.6-sol",
                 "provider" => "openai",
                 "provider_config" => %{
                   "protocol" => "responses",
                   "base_url" => "https://api.openai.com/v1"
                 },
                 "max_tokens" => 65_536,
                 "created_at" => System.system_time(:second)
               }),
               if_none_match: "*"
             )

    assert {:ok, llm} = Templates.resolve_llm_for_template(id)
    assert llm["model"] == "gpt-5.6-sol"
    assert llm["provider"] == "openai"
    assert llm["protocol"] == "responses"
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp opt(opts, key) when is_map(opts), do: opts[key] || opts[String.to_atom(key)]

  defp opt(opts, key) when is_list(opts) do
    Keyword.get(opts, String.to_atom(key)) ||
      case List.keyfind(opts, key, 0) do
        {^key, value} -> value
        _ -> nil
      end
  end

  defp opt(_opts, _key), do: nil
end
