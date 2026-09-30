defmodule SalixAgent.AgentDefaultsTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentDefaults, Control, Templates, TestSupport}

  setup do
    previous_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      TestSupport.stop_all_agents()

      if previous_store,
        do: Application.put_env(:salix_store, :s3_backend, previous_store),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    :ok
  end

  defp global_template!(name) do
    {:ok, template} =
      Templates.create(%{
        "template_id" => "tmpl-#{name}-#{System.unique_integer([:positive])}",
        "name" => name,
        "model" => "mock",
        "provider" => "mock"
      })

    template
  end

  defp private_template!(tenant_id, name) do
    {:ok, template} =
      Templates.create_private(
        %{"name" => name, "model" => "mock", "provider" => "mock"},
        tenant_id
      )

    template
  end

  describe "resolution" do
    test "existing Agents use platform or explicit templates, never tenant defaults" do
      tenant_id = TestSupport.new_tenant_id()
      rec = %{"role" => "worker", "tenant_id" => tenant_id}

      assert {:ok, %{"model" => "gpt-test"}, :platform_default} =
               AgentDefaults.resolve_template(rec)

      platform = global_template!("platform")
      {:ok, _} = AgentDefaults.update_platform(%{"worker_template_id" => platform["template_id"]})

      assert {:ok, %{"template_id" => platform_id}, :platform_default} =
               AgentDefaults.resolve_template(rec)

      assert platform_id == platform["template_id"]

      tenant = private_template!(tenant_id, "tenant")

      TestSupport.put_tenant_agent_defaults!(tenant_id, %{
        worker_template_id: tenant["template_id"]
      })

      assert {:ok, %{"template_id" => ^platform_id}, :platform_default} =
               AgentDefaults.resolve_template(rec)

      # The tenant layer names a worker template only; router still defers upward.
      assert {:ok, %{"model" => "gpt-test"}, :platform_default} =
               AgentDefaults.resolve_template(%{rec | "role" => "router"})

      pinned = global_template!("pinned")

      assert {:ok, %{"template_id" => pinned_id}, :pinned} =
               AgentDefaults.resolve_template(Map.put(rec, "template_id", pinned["template_id"]))

      assert pinned_id == pinned["template_id"]
    end

    test "a default change applies to a following Agent without rewriting its record" do
      first = global_template!("first")
      second = global_template!("second")
      {:ok, _} = AgentDefaults.update_platform(%{"worker_template_id" => first["template_id"]})

      tenant_id = TestSupport.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)
      TestSupport.create_control_group!(group_id)

      {:ok, agent} = Control.create(%{"group_id" => group_id, "role" => "worker"}, tenant_id)
      assert is_nil(agent["template_id"])

      assert {:ok, %{"template_id" => first_id}, :platform_default} =
               Templates.resolve_template_for_record(agent)

      assert first_id == first["template_id"]

      {:ok, _} = AgentDefaults.update_platform(%{"worker_template_id" => second["template_id"]})
      {:ok, unchanged} = Control.get_record(agent["agent_id"])
      assert is_nil(unchanged["template_id"])

      assert {:ok, %{"template_id" => second_id}, :platform_default} =
               Templates.resolve_template_for_record(unchanged)

      assert second_id == second["template_id"]

      # Pinning and then clearing the pin returns the Agent to the default.
      {:ok, pinned} =
        Control.configure(agent["agent_id"], %{"template_id" => first["template_id"]}, tenant_id)

      assert pinned["template_id"] == first["template_id"]
      assert {:ok, _, :pinned} = Templates.resolve_template_for_record(pinned)

      {:ok, cleared} = Control.configure(agent["agent_id"], %{"template_id" => ""}, tenant_id)
      assert is_nil(cleared["template_id"])
      assert {:ok, _, :platform_default} = Templates.resolve_template_for_record(cleared)
    end
  end

  test "creation snapshots tenant choices and later edits never rewrite existing Agents" do
    tenant_id = TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    TestSupport.create_control_group!(group_id)
    first = global_template!("creation-first")["template_id"]
    second = global_template!("creation-second")["template_id"]
    attrs = %{"group_id" => group_id, "role" => "worker"}
    TestSupport.put_tenant_agent_defaults!(tenant_id, %{worker_template_id: first})
    assert {:ok, one} = Control.create(attrs, tenant_id)
    assert one["template_id"] == first
    TestSupport.put_tenant_agent_defaults!(tenant_id, %{worker_template_id: second})
    assert {:ok, two} = Control.create(attrs, tenant_id)
    assert two["template_id"] == second
    assert {:ok, unchanged} = Control.get_record(one["agent_id"])
    assert unchanged["template_id"] == first
    assert {:ok, explicit} = Control.create(Map.put(attrs, "template_id", first), tenant_id)
    assert explicit["template_id"] == first
    assert {:ok, cleared} = Control.configure(one["agent_id"], %{"template_id" => nil}, tenant_id)

    assert {:ok, %{"model" => "gpt-test"}, :platform_default} =
             AgentDefaults.resolve_template(cleared)

    TestSupport.put_tenant_agent_defaults!(tenant_id, %{worker_template_id: nil})
    assert {:ok, following} = Control.create(attrs, tenant_id)
    assert following["template_id"] == nil
  end

  test "rolling migration preserves tenant models and can overwrite a concurrent Default choice" do
    tenant_id = TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    TestSupport.create_control_group!(group_id)

    assert {:ok, legacy} =
             Control.create(%{"group_id" => group_id, "role" => "worker"}, tenant_id)

    template_id = global_template!("legacy-choice")["template_id"]
    TestSupport.put_tenant_agent_defaults!(tenant_id, %{worker_template_id: template_id})

    assert {:ok, %{migrated: 1}} =
             SalixAgent.Migrations.AgentCreationDefaults.run()

    assert {:ok, agent} = Control.get_record(legacy["agent_id"])
    assert agent["template_id"] == template_id

    assert {:ok, %{migrated: 0}} =
             SalixAgent.Migrations.AgentCreationDefaults.run()

    assert {:ok, _} = Control.configure(legacy["agent_id"], %{"template_id" => nil}, tenant_id)
    assert {:ok, %{migrated: 1}} = SalixAgent.Migrations.AgentCreationDefaults.run()
    assert {:ok, rewritten} = Control.get_record(legacy["agent_id"])
    assert rewritten["template_id"] == template_id
  end

  test "rolling migration preserves concurrent Agent edits" do
    tenant_id = TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    TestSupport.create_control_group!(group_id)
    assert {:ok, agent} = Control.create(%{"group_id" => group_id, "role" => "worker"}, tenant_id)
    template_id = global_template!("concurrent-choice")["template_id"]
    TestSupport.put_tenant_agent_defaults!(tenant_id, %{worker_template_id: template_id})
    key = SalixStore.Keys.ctl_agent(agent["agent_id"])
    SalixStore.S3.Fake.set_fault({:pause, :put, key})
    migration = Task.async(fn -> SalixAgent.Migrations.AgentCreationDefaults.run() end)

    try do
      await_migration_pause(200)
      assert {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(key)
      edited = Jason.decode!(body) |> Map.put("name", "Concurrent name")
      assert {:ok, _} = SalixStore.S3.put(key, Jason.encode!(edited), if_match: etag)
      assert :ok = SalixStore.S3.Fake.release_pause()
      assert {:ok, %{migrated: 0}} = Task.await(migration)
      assert {:ok, saved} = Control.get_record(agent["agent_id"])
      assert saved["name"] == "Concurrent name"
      assert saved["template_id"] == nil
    after
      if SalixStore.S3.Fake.paused?(), do: SalixStore.S3.Fake.release_pause()
      Task.shutdown(migration)
    end
  end

  defp await_migration_pause(0), do: flunk("migration did not reach conditional write")

  defp await_migration_pause(attempts) do
    unless SalixStore.S3.Fake.paused?() do
      Process.sleep(10)
      await_migration_pause(attempts - 1)
    end
  end

  describe "pointer validation" do
    test "platform pointers accept only visible global templates and can be cleared" do
      tenant_id = TestSupport.new_tenant_id()
      private = private_template!(tenant_id, "private")

      assert {:error, {:bad_request, _}} =
               AgentDefaults.update_platform(%{"router_template_id" => private["template_id"]})

      assert {:error, {:bad_request, _}} =
               AgentDefaults.update_platform(%{"router_template_id" => "tmpl-missing"})

      global = global_template!("global")

      {:ok, saved} =
        AgentDefaults.update_platform(%{"router_template_id" => global["template_id"]})

      assert saved == %{"router_template_id" => global["template_id"]}

      {:ok, cleared} = AgentDefaults.update_platform(%{"router_template_id" => nil})
      assert cleared == %{}
      assert {:ok, %{}} = AgentDefaults.platform()
    end

    test "tenant pointers must name a template the tenant can see" do
      tenant_id = TestSupport.new_tenant_id()
      other_tenant = TestSupport.new_tenant_id()
      foreign = private_template!(other_tenant, "foreign")
      own = private_template!(tenant_id, "own")

      assert {:error, {:bad_request, _}} =
               AgentDefaults.validate_attrs(
                 %{"worker_template_id" => foreign["template_id"]},
                 tenant_id
               )

      assert {:ok, %{"worker_template_id" => id, "other" => 1}} =
               AgentDefaults.validate_attrs(
                 %{"worker_template_id" => own["template_id"], "other" => 1},
                 tenant_id
               )

      assert id == own["template_id"]
    end
  end

  describe "delete protection" do
    test "global deletion preserves tenant defaults across inventory pages" do
      template = global_template!("tenant-default")

      tenant_ids =
        for _ <- 1..101 do
          tenant_id = TestSupport.new_tenant_id()
          TestSupport.put_tenant_agent_defaults!(tenant_id, %{})
          tenant_id
        end

      last_tenant = Enum.max(tenant_ids)

      TestSupport.put_tenant_agent_defaults!(last_tenant, %{
        worker_template_id: template["template_id"]
      })

      assert {:ok, [^last_tenant]} = AgentDefaults.tenants_referencing(template["template_id"])
      assert {:error, {:conflict, _}} = Templates.delete(template["template_id"])
      assert {:ok, _} = Templates.get(template["template_id"])

      TestSupport.put_tenant_agent_defaults!(last_tenant, %{worker_template_id: nil})
      assert :ok = Templates.delete(template["template_id"])
    end

    test "a template named by a default pointer cannot be deleted" do
      tenant_id = TestSupport.new_tenant_id()
      platform = global_template!("platform")
      {:ok, _} = AgentDefaults.update_platform(%{"worker_template_id" => platform["template_id"]})

      assert {:error, {:conflict, _}} = Templates.delete(platform["template_id"])

      tenant = private_template!(tenant_id, "tenant")

      TestSupport.put_tenant_agent_defaults!(tenant_id, %{
        router_template_id: tenant["template_id"]
      })

      assert {:error, {:conflict, _}} =
               Templates.delete_private(tenant["template_id"], tenant_id, 100)

      TestSupport.put_tenant_agent_defaults!(tenant_id, %{router_template_id: nil})
      assert :ok = Templates.delete_private(tenant["template_id"], tenant_id, 100)
    end

    test "a default-pointer read failure refuses deletion" do
      unused = global_template!("unused")
      {:ok, _} = SalixStore.S3.put(SalixStore.Keys.ctl_system_agent_defaults(), "not-json")

      assert {:error, :platform_agent_defaults_invalid} = AgentDefaults.platform()

      assert {:error, :platform_agent_defaults_invalid} =
               AgentDefaults.referenced?(unused["template_id"], nil)

      assert {:error, :template_reference_unavailable} = Templates.delete(unused["template_id"])

      :ok = SalixStore.S3.delete(SalixStore.Keys.ctl_system_agent_defaults())

      tenant_id = TestSupport.new_tenant_id()
      private = private_template!(tenant_id, "private")

      {:ok, _} =
        SalixStore.S3.put(
          SalixStore.Keys.ctl_tenant(tenant_id),
          Jason.encode!(%{
            "tenant_id" => tenant_id,
            "name" => tenant_id,
            "config" => "not-json"
          })
        )

      assert {:error, :tenant_agent_defaults_invalid} = AgentDefaults.tenant(tenant_id)

      assert {:error, :tenant_agent_defaults_invalid} =
               AgentDefaults.referenced?(private["template_id"], tenant_id)

      assert {:error, :template_reference_unavailable} =
               Templates.delete_private(private["template_id"], tenant_id, 100)

      other = global_template!("other")

      assert {:error, :tenant_agent_defaults_invalid} =
               AgentDefaults.tenants_referencing(other["template_id"])

      assert {:error, :template_reference_unavailable} = Templates.delete(other["template_id"])
    end
  end

  test "effective role defaults report the resolved layer per role" do
    tenant_id = TestSupport.new_tenant_id()
    platform = global_template!("platform")
    tenant = private_template!(tenant_id, "tenant")

    {:ok, _} =
      AgentDefaults.update_platform(%{
        "router_template_id" => platform["template_id"],
        "worker_template_id" => platform["template_id"]
      })

    TestSupport.put_tenant_agent_defaults!(tenant_id, %{worker_template_id: tenant["template_id"]})

    effective = AgentDefaults.effective_role_defaults(tenant_id)
    assert effective["router"]["source"] == "platform_default"
    assert effective["router"]["name"] == "platform"
    assert effective["worker"]["source"] == "tenant_default"
    assert effective["worker"]["name"] == "tenant"
    refute Map.has_key?(effective["worker"], "provider_config")
  end
end
