defmodule SalixAgent.AgentModelChoiceTest do
  @moduledoc "An Agent's model choice stored as its own `model` value."
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, AgentModel, Control, LlmResolver}
  alias SalixAgent.Migrations.AgentModelChoices
  alias SalixStore.{Ids, Keys, S3}

  @catalog %{"kind" => "catalog", "model" => "gpt-5.5", "reasoning_effort" => "high"}

  setup do
    previous = SystemsRuntime.fetch_env(:salix_agent, :llm_resolver)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, Salix.Bindings.AgentLlmResolver)
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        {:ok, value} -> SystemsRuntime.put_env(:salix_agent, :llm_resolver, value)
        :error -> SystemsRuntime.delete_env(:salix_agent, :llm_resolver)
      end
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    agent = SalixAgent.TestSupport.create_control_agent!(agent_id, %{role: "worker"})
    {:ok, agent: agent, tenant: agent["tenant_id"]}
  end

  test "a model choice replaces the platform default until it is cleared", %{
    agent: agent,
    tenant: tenant
  } do
    assert {:ok, _, :platform_default} = AgentModel.choice(agent)

    assert {:ok, chosen} = Control.configure(agent["agent_id"], %{"model" => @catalog}, tenant)
    assert chosen["model"] == Map.put(@catalog, "allow_paid", false)

    # Rounds resolve the choice: a catalog route this tenant pays for.
    assert {:ok, llm} = LlmResolver.resolve_runtime(agent["agent_id"])
    assert AccountPool.catalog_route?(llm)
    assert {llm["model"], llm["reasoning_effort"]} == {"gpt-5.5", "high"}

    assert {:ok, %{"model_display_name" => "GPT-5.5"}, :pinned} =
             AgentModel.resolve_public(chosen)

    assert {:error, {:bad_request, "template_id is not supported; give model"}} =
             Control.configure(agent["agent_id"], %{"template_id" => "any"}, tenant)

    assert {:error, {:bad_request, _}} =
             Control.configure(
               agent["agent_id"],
               %{"model" => %{@catalog | "reasoning_effort" => "ultra"}},
               tenant
             )

    assert {:ok, following} = Control.configure(agent["agent_id"], %{"model" => nil}, tenant)
    assert following["model"] == nil

    assert {:ok, %{"kind" => "platform", "tier" => "worker"}, :platform_default} =
             AgentModel.choice(following)
  end

  test "the migration stores private catalog and runtime choices as model values", %{
    agent: agent,
    tenant: tenant
  } do
    catalog =
      private_template!(tenant, %{
        "catalog_model" => "gpt-5.5",
        "allow_paid" => true,
        "reasoning_effort" => "high"
      })

    runtime =
      private_template!(tenant, %{
        "runtime_provider" => "codex",
        "runtime_model" => "gpt-5.5",
        "reasoning_effort" => "low"
      })

    global_agent = agent

    catalog_agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, agent["group_id"], %{
        "role" => "worker"
      })

    runtime_agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, agent["group_id"], %{
        "role" => "worker"
      })

    # Records of an earlier release name their private template.
    pin_template!(catalog_agent, catalog)
    pin_template!(runtime_agent, runtime)

    assert {:ok, %{migrated: 2}} = AgentModelChoices.run()

    assert stored(catalog_agent)["model"] == %{
             "kind" => "catalog",
             "model" => "gpt-5.5",
             "reasoning_effort" => "high",
             "allow_paid" => true
           }

    assert stored(runtime_agent)["model"] == %{
             "kind" => "runtime",
             "provider" => "codex",
             "model" => "gpt-5.5",
             "reasoning_effort" => "low"
           }

    refute Map.has_key?(stored(global_agent), "model")

    # A second pass changes nothing.
    assert {:ok, %{migrated: 0}} = AgentModelChoices.run()
  end

  test "the migration preserves a custom model after its Profile is deleted", %{
    agent: agent,
    tenant: tenant
  } do
    {:ok, profile} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "base_url" => "https://ollama.example.test",
        "protocol" => "chat_completions",
        "models" => ["nemotron-3-ultra"]
      })

    template =
      private_template!(tenant, %{
        "catalog_model" => "nemotron-3-ultra",
        "allow_paid" => true,
        "profile_id" => profile["id"]
      })

    pin_template!(agent, template)

    assert {:ok, nil} = AccountPool.delete(tenant, profile["id"], profile["version"])
    before = stored(agent)

    assert {:ok, %{migrated: 1}} = AgentModelChoices.run()

    choice = %{
      "kind" => "catalog",
      "model" => "nemotron-3-ultra",
      "allow_paid" => true,
      "profile_id" => profile["id"]
    }

    assert stored(agent) == Map.put(before, "model", choice)
    # The choice still resolves; no Profile serves it, so dispatch stops the
    # input as `model_unavailable`.
    assert {:ok, llm} = LlmResolver.resolve_runtime(agent["agent_id"])

    assert {:error, %{"reason" => "model_unavailable"}} =
             AccountPool.dispatch(llm, fn _ -> flunk("no Profile serves the model") end)

    assert {:ok, %{migrated: 0}} = AgentModelChoices.run()
  end

  test "the migration preserves an id removed from the built-in catalog", %{
    agent: agent,
    tenant: tenant
  } do
    template =
      private_template!(tenant, %{"catalog_model" => "gpt-5.5", "allow_paid" => false})

    pin_template!(agent, template)

    key = Keys.ctl_private_template(tenant, template)
    {:ok, %{body: body}} = S3.get(key)
    historical = put_in(Jason.decode!(body), ["provider_config", "catalog_model"], "glm-5.2")
    {:ok, _} = S3.put(key, Jason.encode!(historical))
    before = stored(agent)

    assert {:ok, %{migrated: 1}} = AgentModelChoices.run()

    assert stored(agent) ==
             Map.put(before, "model", %{
               "kind" => "catalog",
               "model" => "glm-5.2",
               "allow_paid" => false
             })
  end

  test "the migration does not copy a template owned by another tenant", %{
    agent: agent,
    tenant: tenant
  } do
    template =
      private_template!(tenant, %{"catalog_model" => "gpt-5.5", "allow_paid" => false})

    pin_template!(agent, template)

    key = Keys.ctl_private_template(tenant, template)
    {:ok, %{body: body}} = S3.get(key)

    {:ok, _} =
      S3.put(
        key,
        Jason.encode!(
          Map.put(Jason.decode!(body), "tenant_id", SalixAgent.TestSupport.new_tenant_id())
        )
      )

    before = stored(agent)
    assert {:ok, %{migrated: 0}} = AgentModelChoices.run()
    assert stored(agent) == before
  end

  defp private_template!(tenant, provider_config) do
    id = Ids.new_private_template_id()

    template = %{
      "template_id" => id,
      "tenant_id" => tenant,
      "name" => "Choice",
      "model" => "gpt-5.5",
      "provider_config" => provider_config
    }

    {:ok, _} = S3.put(Keys.ctl_private_template(tenant, id), Jason.encode!(template))
    id
  end

  defp pin_template!(agent, template_id) do
    key = Keys.ctl_agent(agent["agent_id"])
    {:ok, %{body: body}} = S3.get(key)
    record = body |> Jason.decode!() |> Map.put("template_id", template_id)
    {:ok, _} = S3.put(key, Jason.encode!(record))
  end

  defp stored(agent) do
    {:ok, %{body: body}} = S3.get(Keys.ctl_agent(agent["agent_id"]))
    Jason.decode!(body)
  end
end
