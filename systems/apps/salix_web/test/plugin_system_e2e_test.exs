defmodule SalixWeb.PluginSystemE2ETest do
  @moduledoc """
  Product-path coverage for Salix plugins as group-level feature-package switches.

  The assertions go through Dashboard LiveView, tenant-scoped runtime HTTP APIs,
  and runtime materialization. They intentionally avoid child-domain store
  mutation checks except as observable facts around a plugin toggle.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Salix.Control.{
    ComposioSettings,
    Groups,
    PluginCatalogCache,
    Plugins,
    Store,
    Tenants
  }

  alias SalixIM.ProviderConnects
  alias SalixStore.{Ids, Keys}

  @endpoint SalixWeb.DashboardEndpoint

  defmodule MeetingPreparationStub do
    def start_research(group_id, _plan_id, _revision, _worker_id, agent_id),
      do: result("start_research", group_id, agent_id, nil)

    def open_trigger(group_id, _plan_id, _kind, _revision, agent_id, session_id),
      do: result("open_trigger", group_id, agent_id, session_id)

    def record_decision(
          group_id,
          _plan_id,
          _revision,
          _decision,
          _baseline,
          agent_id,
          session_id
        ),
        do: result("record_decision", group_id, agent_id, session_id)

    def publish_report(group_id, _plan_id, _revision, _report, agent_id, session_id),
      do: result("publish_report", group_id, agent_id, session_id)

    defp result(command, group_id, agent_id, session_id),
      do:
        {:ok,
         %{
           "command" => command,
           "group_id" => group_id,
           "agent_id" => agent_id,
           "session_id" => session_id
         }}
  end

  defmodule MeetingStub do
    def join(group_id, _params, tool_context),
      do: result("join", group_id, tool_context["agent_id"])

    def get(group_id, _params) do
      {:ok, record} = result("get", group_id, nil)
      {:ok, record, %{"label" => ["scope|meeting-connect|C_MEETING"]}}
    end

    defp result(command, group_id, agent_id),
      do: {:ok, %{"command" => command, "group_id" => group_id, "agent_id" => agent_id}}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_plugin_store = Application.get_env(:salix_agent, :plugin_store_mod)
    prev_composio_store = Application.get_env(:salix_agent, :composio_store_mod)
    prev_meeting_preparation = Application.get_env(:salix_agent, :meeting_preparation_mod)
    prev_meeting = Application.get_env(:salix_agent, :meeting_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :plugin_store_mod, Salix.Bindings.AgentPluginStore)
    Application.put_env(:salix_agent, :composio_store_mod, Salix.Bindings.AgentComposioStore)
    Application.put_env(:salix_agent, :meeting_preparation_mod, MeetingPreparationStub)
    Application.put_env(:salix_agent, :meeting_mod, MeetingStub)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      put_or_delete_env(:salix_store, :s3_backend, prev_store)
      put_or_delete_env(:salix_agent, :plugin_store_mod, prev_plugin_store)
      put_or_delete_env(:salix_agent, :composio_store_mod, prev_composio_store)

      put_or_delete_env(
        :salix_agent,
        :meeting_preparation_mod,
        prev_meeting_preparation
      )

      put_or_delete_env(:salix_agent, :meeting_mod, prev_meeting)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, tenant} = Tenants.create(%{"name" => "Plugin E2E"})
    tenant_id = tenant["tenant_id"]
    {:ok, api_key} = Tenants.create_api_key(tenant_id, %{"name" => "plugin e2e"})

    {:ok, group_a} =
      Salix.Control.Groups.create(
        %{"name" => "Plugin A"},
        tenant_id
      )

    {:ok, router} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_a["group_id"],
          "name" => "Plugin Router",
          "role" => "router"
        },
        tenant_id
      )

    {:ok, group_a} =
      Salix.Control.Groups.update(
        group_a["group_id"],
        %{"router_agent_id" => router["agent_id"]},
        tenant_id
      )

    Process.put(:plugin_tenant_key, api_key["key"])

    {:ok, tenant_id: tenant_id, group_a: group_a, router: router, suffix: suffix}
  end

  @tag :hidden_runtime_catalog
  test "hidden groups retain runtime plugins without exposing their catalog to the dashboard", %{
    tenant_id: tenant_id,
    group_a: group,
    router: router
  } do
    group_id = group["group_id"]
    assert {:ok, _} = Plugins.list_raw_definitions(tenant_id, group_id)
    assert {:ok, _} = Groups.update(group_id, %{"hidden" => true})

    assert {:ok, config} =
             SalixAgent.RoundConfig.build_runtime_session_config(
               router["agent_id"],
               "router",
               %{}
             )

    assert "core-runtime" in config.plugin_projection["enabled_plugin_ids"]
    assert {:error, :not_found} = Plugins.list_raw_definitions(tenant_id, group_id)
    assert {:error, :not_found} = Plugins.get_definition(tenant_id, group_id, "core-runtime")
    assert {:error, :not_found} = Plugins.list_group_enablements(tenant_id, group_id)
    assert {:error, :not_found} = Groups.get(group_id, tenant_id)

    assert {:ok, other_tenant} = Tenants.create(%{"name" => "Unrelated tenant"})

    assert {:error, :not_found} =
             Plugins.runtime_projection(%{
               "tenant_id" => other_tenant["tenant_id"],
               "group_id" => group_id
             })

    assert {:ok, _} = Groups.update(group_id, %{"hidden" => false})
    assert {:ok, definitions} = Plugins.list_raw_definitions(tenant_id, group_id)
    assert Enum.any?(definitions, &(&1["plugin_id"] == "core-runtime"))
  end

  test "a catalog load that overlaps an invalidation is not served after it", %{
    tenant_id: tenant_id,
    group_a: group
  } do
    group_id = group["group_id"]
    group_key = Keys.ctl_group(group_id)
    assert :ok = PluginCatalogCache.invalidate_group(group_id)

    # The load reads the group record before the write and returns after it.
    :ok = SalixStore.S3.Fake.set_fault({:pause, :get, group_key})
    load = Task.async(fn -> PluginCatalogCache.snapshot(tenant_id, group_id) end)
    assert eventually(&SalixStore.S3.Fake.paused?/0)
    assert :ok = PluginCatalogCache.invalidate_group(group_id)
    :ok = SalixStore.S3.Fake.release_pause()
    assert {:ok, _late_snapshot} = Task.await(load, 5_000)

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _fresh} = PluginCatalogCache.snapshot(tenant_id, group_id)
    assert {:get, group_key} in SalixStore.S3.Fake.read_log()

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _cached} = PluginCatalogCache.snapshot(tenant_id, group_id)
    assert SalixStore.S3.Fake.read_log() == []
  end

  test "group catalog cache serves one snapshot and reloads after writes", %{
    tenant_id: tenant_id,
    group_a: group
  } do
    group_id = group["group_id"]
    system_prefix = Keys.ctl_system_plugin_definitions_prefix()

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, definitions} = Plugins.list_definitions(tenant_id, group_id)
    assert Enum.any?(definitions, &(&1["plugin_id"] == "core-runtime"))

    assert %{"type" => "integration"} =
             definitions
             |> Enum.find(&(&1["plugin_id"] == "linear"))
             |> Map.fetch!("setup_status")

    cold_reads = SalixStore.S3.Fake.read_log()
    assert cold_reads != []

    refute Enum.any?(cold_reads, fn
             {:list, ^system_prefix, _opts} -> true
             {:get, key} -> String.starts_with?(key, system_prefix)
             _ -> false
           end)

    assert :ok = PluginCatalogCache.invalidate_group(group_id)
    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, raw_definitions} = Plugins.list_raw_definitions(tenant_id, group_id)

    raw_linear = Enum.find(raw_definitions, &(&1["plugin_id"] == "linear"))
    assert get_in(raw_linear, ["setup", "type"]) == "integration"
    refute Map.has_key?(raw_linear, "setup_status")

    raw_reads = SalixStore.S3.Fake.read_log()
    group_definition_prefix = Keys.ctl_group_plugin_definitions_prefix(tenant_id, group_id)

    assert Enum.any?(raw_reads, fn
             {:list, ^group_definition_prefix, _opts} -> true
             _other -> false
           end)

    forbidden_child_prefixes = [
      Keys.ctl_oauth_group_bindings_prefix(group_id),
      "ctl/oauth/connections/",
      Keys.ctl_mcp_group_bindings_prefix(tenant_id, group_id),
      Keys.ctl_im_connects_prefix(group_id)
    ]

    refute Enum.any?(raw_reads, fn
             {:list, prefix, _opts} ->
               Enum.any?(forbidden_child_prefixes, fn forbidden ->
                 String.starts_with?(prefix, forbidden) or
                   String.starts_with?(forbidden, prefix)
               end)

             {operation, key} when operation in [:get, :head] ->
               Enum.any?(forbidden_child_prefixes, &String.starts_with?(key, &1))

             _other ->
               false
           end)

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _enablements} = Plugins.list_group_enablements(tenant_id, group_id)

    assert {:ok, _projection} =
             Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})

    assert SalixStore.S3.Fake.read_log() == []

    assert {:ok, tenant_plugin} =
             Plugins.create_tenant_definition(tenant_id, %{
               "name" => "Cached tenant plugin",
               "refs" => %{"tool_refs" => ["cached.tenant.tool"]}
             })

    assert {:ok, refreshed_definitions} = Plugins.list_definitions(tenant_id, group_id)

    assert Enum.any?(
             refreshed_definitions,
             &(&1["plugin_id"] == tenant_plugin["plugin_id"])
           )

    assert {:ok, _disabled} = Plugins.disable_group(tenant_id, group_id, "composio")
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _enablements} = Plugins.list_group_enablements(tenant_id, group_id)
    assert SalixStore.S3.Fake.read_log() != []
  end

  test "cold group catalog fans out independent definition and enablement reads", %{
    tenant_id: tenant_id,
    group_a: group
  } do
    group_id = group["group_id"]

    assert {:ok, tenant_plugin} =
             Plugins.create_tenant_definition(tenant_id, %{
               "name" => "Parallel catalog read",
               "refs" => %{"tool_refs" => ["parallel.catalog.read"]}
             })

    tenant_definition_key =
      Keys.ctl_tenant_plugin_definition(tenant_id, tenant_plugin["plugin_id"])

    group_prefix = Keys.ctl_group_plugin_definitions_prefix(tenant_id, group_id)
    enablement_prefix = Keys.ctl_group_plugin_enablements_prefix(tenant_id, group_id)

    SalixStore.S3.Fake.reset_read_log()
    :ok = SalixStore.S3.Fake.set_fault({:pause, :get, tenant_definition_key})

    on_exit(fn ->
      if Process.whereis(SalixStore.S3.Fake) && SalixStore.S3.Fake.paused?(),
        do: SalixStore.S3.Fake.release_pause()
    end)

    projection =
      Task.async(fn ->
        Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})
      end)

    assert eventually(&SalixStore.S3.Fake.paused?/0)

    assert eventually(fn ->
             reads = SalixStore.S3.Fake.read_log()

             Enum.any?(reads, &match?({:list, ^group_prefix, _opts}, &1)) and
               Enum.any?(reads, &match?({:list, ^enablement_prefix, _opts}, &1))
           end)

    assert Task.yield(projection, 0) == nil
    assert :ok = SalixStore.S3.Fake.release_pause()
    assert {:ok, _projection} = Task.await(projection)
  end

  test "idempotent preallocated group retry does not recreate a cleared default override", %{
    tenant_id: tenant_id
  } do
    group_id = Ids.new_group_id(tenant_id)
    attrs = %{"name" => "Preallocated plugin defaults"}
    plugin_id = "meeting-preparation"
    key = Keys.ctl_group_plugin_enablement(tenant_id, group_id, plugin_id)

    assert {:ok, %{"group_id" => ^group_id}} =
             Groups.create_preallocated(attrs, tenant_id, group_id)

    assert :ok = Plugins.clear_group_enablement(tenant_id, group_id, plugin_id)
    assert {:error, :not_found} = Store.get_record(key)

    assert {:ok, %{"group_id" => ^group_id}} =
             Groups.create_preallocated(attrs, tenant_id, group_id)

    assert {:error, :not_found} = Store.get_record(key)
  end

  test "new groups persist only overrides while runtime resolves defaults and preserves history",
       %{
         tenant_id: tenant_id
       } do
    group_id = Ids.new_group_id(tenant_id)
    attrs = %{"name" => "Plugin override semantics"}
    meeting_id = "meeting-preparation"
    meeting_key = Keys.ctl_group_plugin_enablement(tenant_id, group_id, meeting_id)

    assert {:ok, %{"group_id" => ^group_id}} =
             Groups.create_preallocated(attrs, tenant_id, group_id)

    assert [] =
             Store.list_records(Keys.ctl_group_plugin_enablements_prefix(tenant_id, group_id))

    assert [] = Store.list_records(Keys.ctl_system_plugin_definitions_prefix())

    assert {:ok, defaults} =
             Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})

    assert meeting_id in defaults["enabled_plugin_ids"]
    assert "linear" in defaults["disabled_plugin_ids"]

    assert {:ok, historical_false} =
             Plugins.disable_group(tenant_id, group_id, meeting_id)

    assert {:ok, disabled} =
             Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})

    assert meeting_id in disabled["disabled_plugin_ids"]

    assert {:ok, %{"group_id" => ^group_id}} =
             Groups.create_preallocated(attrs, tenant_id, group_id)

    assert {:ok, ^historical_false} = Store.get_record(meeting_key)

    assert :ok = Plugins.clear_group_enablement(tenant_id, group_id, meeting_id)

    assert {:ok, restored} =
             Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})

    assert meeting_id in restored["enabled_plugin_ids"]

    now = Store.now()

    assert {:ok, _invalid} =
             Store.put_new(meeting_key, %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "plugin_id" => meeting_id,
               "enabled" => "invalid",
               "enabled_version" => 1,
               "revision" => 2,
               "created_at" => now,
               "updated_at" => now
             })

    assert {:ok, _locked_override} =
             Store.put_new(
               Keys.ctl_group_plugin_enablement(tenant_id, group_id, "core-runtime"),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "plugin_id" => "core-runtime",
                 "enabled" => false,
                 "enabled_version" => 1,
                 "revision" => 1,
                 "created_at" => now,
                 "updated_at" => now
               }
             )

    :ok = Salix.Control.PluginCatalogCache.invalidate_group(group_id)

    assert {:ok, fail_closed} =
             Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})

    assert meeting_id in fail_closed["disabled_plugin_ids"]
    assert "core-runtime" in fail_closed["enabled_plugin_ids"]
  end

  test "historical durable system definitions are ignored by catalog and mutation paths", %{
    tenant_id: tenant_id,
    group_a: group
  } do
    plugin_id = Ids.new_plugin_id()
    key = Keys.ctl_system_plugin_definition(plugin_id)
    now = Store.now()

    historical = %{
      "owner_scope" => "system",
      "tenant_id" => "",
      "group_id" => "",
      "plugin_id" => plugin_id,
      "version" => 1,
      "name" => "Historical durable system definition",
      "description" => "must remain inert",
      "refs" => %{},
      "source" => "retired_seed",
      "read_only" => true,
      "locked" => false,
      "default_enabled" => true,
      "created_at" => now,
      "updated_at" => now
    }

    assert {:ok, ^historical} = Store.put_new(key, historical)
    assert {:error, :not_found} = Plugins.get_definition(tenant_id, group["group_id"], plugin_id)

    assert {:error, :not_found} =
             Plugins.update_definition(tenant_id, group["group_id"], plugin_id, %{"name" => "x"})

    assert {:error, :not_found} =
             Plugins.update_tenant_definition(tenant_id, plugin_id, %{"name" => "x"})

    assert {:error, :not_found} =
             Plugins.update_group_definition(
               tenant_id,
               group["group_id"],
               plugin_id,
               %{"name" => "x"}
             )

    assert {:ok, ^historical} = Store.get_record(key)
  end

  test "Dashboard and runtime API manage a group plugin without mutating child domains", %{
    tenant_id: tenant_id,
    group_a: group_a,
    suffix: suffix
  } do
    group_id = group_a["group_id"]
    plugin_name = "Handtest Plugin #{suffix}"
    missing_skill_id = "missing-skill-#{suffix}"

    {:ok, _settings} = ComposioSettings.put(tenant_id, %{"api_key" => "ck_plugin_e2e"})

    # The system composio plugin is on by default; park it so the custom
    # plugin below is the only source of `composio.execute` in the projection.
    assert req(:post, "/v1/runtime/agent-groups/#{group_id}/plugins/composio/disable").status ==
             200

    {:ok, slack_connect} =
      ProviderConnects.create_slack_im_connect(tenant_id, group_id, %{
        "app_name" => "Plugin E2E Slack",
        "app_id" => "A-PLUGIN-#{suffix}",
        "client_id" => "client-plugin-#{suffix}",
        "client_secret" => "secret-plugin-#{suffix}",
        "signing_secret" => "signing-plugin-#{suffix}"
      })

    {:ok, before_toggle_connects} = ProviderConnects.list_group_im_connects(group_id, "slack")

    {:ok, view, html} = live(authed_conn(tenant_id), "/dash/plugins")
    assert html =~ "Plugins"
    assert html =~ "core-runtime"
    refute has_element?(view, "#plugin-create-form input[name=plugin_id]")

    locked_enable =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/plugins/core-runtime/enable")

    locked_disable =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/plugins/core-runtime/disable")

    assert locked_enable.status == 400
    assert locked_disable.status == 400

    locked_page = req(:get, "/v1/runtime/agent-groups/#{group_id}/plugins").body
    assert "core-runtime" in locked_page["projection"]["enabled_plugin_ids"]
    refute Enum.any?(locked_page["enablements"], &(&1["plugin_id"] == "core-runtime"))

    refs = %{
      "tool_refs" => ["composio.execute"],
      "skill_refs" => [missing_skill_id],
      "mcp_refs" => ["missing-mcp-#{suffix}"],
      "oauth_requirements" => [%{"provider" => "github", "alias" => "work"}],
      "im_connect_requirements" => [%{"provider" => "slack"}]
    }

    view
    |> form("form[phx-submit=create-definition]", %{
      "name" => plugin_name,
      "description" => "Plugin E2E",
      "owner_scope" => "group",
      "refs_json" => Jason.encode!(refs)
    })
    |> render_submit()

    page_after_create = req(:get, "/v1/runtime/agent-groups/#{group_id}/plugins").body
    plugin_id = definition_id_by_name(page_after_create, plugin_name)
    assert Ids.valid_plugin_id?(plugin_id)

    render_click(element(view, "button[phx-click=enable][phx-value-id='#{plugin_id}']"))

    page = req(:get, "/v1/runtime/agent-groups/#{group_id}/plugins").body
    assert Enum.any?(page["definitions"], &(&1["plugin_id"] == plugin_id))

    assert Enum.any?(
             page["enablements"],
             &(&1["plugin_id"] == plugin_id and &1["enabled"] == true)
           )

    projection = page["projection"]
    assert plugin_id in projection["enabled_plugin_ids"]
    assert "composio.execute" in projection["allowed_tools"]
    assert missing_skill_id in projection["visible_skill_ids"]
    assert projection_ref(projection, plugin_id, "tool_refs") == ["composio.execute"]
    assert projection_ref(projection, plugin_id, "skill_refs") == [missing_skill_id]
    assert projection_ref(projection, plugin_id, "mcp_refs") == ["missing-mcp-#{suffix}"]

    assert projection_ref(projection, plugin_id, "oauth_requirements") == [
             %{"alias" => "work", "provider" => "github"}
           ]

    assert projection_ref(projection, plugin_id, "im_connect_requirements") == [
             %{"provider" => "slack"}
           ]

    disclosure =
      SalixAgent.ToolDisclosure.materialize("worker", :internal, %{
        tenant_id: tenant_id,
        group_id: group_id,
        plugin_projection: projection
      })

    assert disclosed?(disclosure, "composio.execute")

    disabled =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/plugins/#{plugin_id}/disable").body

    assert disabled["enabled"] == false

    after_disable = req(:get, "/v1/runtime/agent-groups/#{group_id}/plugins/projection").body
    refute plugin_id in after_disable["enabled_plugin_ids"]
    refute "composio.execute" in after_disable["allowed_tools"]

    disclosure_after_disable =
      SalixAgent.ToolDisclosure.materialize("worker", :internal, %{
        tenant_id: tenant_id,
        group_id: group_id,
        plugin_projection: after_disable
      })

    refute disclosed?(disclosure_after_disable, "composio.execute")

    {:ok, after_toggle_connects} = ProviderConnects.list_group_im_connects(group_id, "slack")

    assert Enum.map(after_toggle_connects, & &1["connect_id"]) ==
             Enum.map(before_toggle_connects, & &1["connect_id"])

    assert Enum.find(after_toggle_connects, &(&1["connect_id"] == slack_connect["connect_id"]))
  end

  test "composio plugin defaults on and discloses tools from the deployment-default settings", %{
    tenant_id: tenant_id,
    group_a: group_a
  } do
    group_id = group_a["group_id"]

    projection = req(:get, "/v1/runtime/agent-groups/#{group_id}/plugins/projection").body
    assert "composio" in projection["enabled_plugin_ids"]
    assert "composio.execute" in projection["allowed_tools"]

    # No tenant settings record: the deployment default alone must keep the
    # composio.* family disclosed.
    {:ok, _} = ComposioSettings.put_default(%{"api_key" => "ck_deployment_default"})

    disclosure =
      SalixAgent.ToolDisclosure.materialize("worker", :internal, %{
        tenant_id: tenant_id,
        group_id: group_id,
        plugin_projection: projection
      })

    assert disclosed?(disclosure, "composio.execute")

    # Definitively unconfigured (no tenant record, no deployment default): the
    # capability gate drops the family even though the plugin stays enabled.
    assert :ok = ComposioSettings.delete_default()

    disclosure =
      SalixAgent.ToolDisclosure.materialize("worker", :internal, %{
        tenant_id: tenant_id,
        group_id: group_id,
        plugin_projection: projection
      })

    refute disclosed?(disclosure, "composio.execute")

    # The plugin gate remains a real per-group off switch on top.
    assert req(:post, "/v1/runtime/agent-groups/#{group_id}/plugins/composio/disable").status ==
             200

    after_disable = req(:get, "/v1/runtime/agent-groups/#{group_id}/plugins/projection").body
    refute "composio" in after_disable["enabled_plugin_ids"]
    refute "composio.execute" in after_disable["allowed_tools"]
    assert "composio.execute" in after_disable["disabled_tools"]

    disclosure =
      SalixAgent.ToolDisclosure.materialize("worker", :internal, %{
        tenant_id: tenant_id,
        group_id: group_id,
        plugin_projection: after_disable
      })

    refute disclosed?(disclosure, "composio.execute")
    assert disclosed?(disclosure, "fs.read_file")
  end

  test "tenant definitions are visible across groups while enablement stays group-local", %{
    tenant_id: tenant_id,
    group_a: group_a,
    suffix: suffix
  } do
    {:ok, group_b} =
      Salix.Control.Groups.create(
        %{"name" => "Plugin B"},
        tenant_id
      )

    tenant_plugin_name = "Tenant Plugin #{suffix}"

    created =
      req(:post, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins",
        json: %{
          "owner_scope" => "tenant",
          "name" => tenant_plugin_name,
          "refs" => %{"tool_refs" => ["memory.search"]}
        }
      ).body

    plugin_id = created["plugin_id"]
    assert created["owner_scope"] == "tenant"
    assert Ids.valid_plugin_id?(plugin_id)

    page_a = req(:get, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins").body
    page_b = req(:get, "/v1/runtime/agent-groups/#{group_b["group_id"]}/plugins").body

    assert Enum.any?(page_a["definitions"], &(&1["plugin_id"] == plugin_id))
    assert Enum.any?(page_b["definitions"], &(&1["plugin_id"] == plugin_id))
    refute Enum.any?(page_b["enablements"], &(&1["plugin_id"] == plugin_id))

    assert req(
             :post,
             "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins/#{plugin_id}/enable"
           ).status ==
             200

    enabled_a =
      req(:get, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins/projection").body

    enabled_b =
      req(:get, "/v1/runtime/agent-groups/#{group_b["group_id"]}/plugins/projection").body

    assert plugin_id in enabled_a["enabled_plugin_ids"]
    refute plugin_id in enabled_b["enabled_plugin_ids"]

    group_plugin_name = "Group Only Plugin #{suffix}"

    group_created =
      req(:post, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins",
        json: %{
          "owner_scope" => "group",
          "name" => group_plugin_name,
          "refs" => %{"tool_refs" => ["memory.write"]}
        }
      )

    assert group_created.status == 201
    group_plugin_id = group_created.body["plugin_id"]
    assert Ids.valid_plugin_id?(group_plugin_id)

    page_b_after_group_create =
      req(:get, "/v1/runtime/agent-groups/#{group_b["group_id"]}/plugins").body

    refute Enum.any?(
             page_b_after_group_create["definitions"],
             &(&1["plugin_id"] == group_plugin_id)
           )
  end

  test "runtime API rejects invalid refs before they enter projection", %{
    group_a: group_a,
    suffix: suffix
  } do
    duplicate_tool = "plugin.duplicate_tool_#{suffix}"

    response =
      req(:post, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins",
        json: %{
          "name" => "Bad Plugin #{suffix}",
          "refs" => %{"tool_refs" => [duplicate_tool, duplicate_tool]}
        }
      )

    assert response.status == 400
    assert response.body["error"] =~ "duplicates"

    projection =
      req(:get, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins/projection").body

    page = req(:get, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins").body
    refute definition_id_by_name(page, "Bad Plugin #{suffix}")
    refute duplicate_tool in projection["allowed_tools"]
  end

  test "format-valid missing tool targets can be saved without becoming callable", %{
    tenant_id: tenant_id,
    group_a: group_a,
    suffix: suffix
  } do
    plugin_name = "Missing Tool Plugin #{suffix}"
    missing_tool = "env.unknown_tool_#{suffix}"

    created =
      req(:post, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins",
        json: %{
          "name" => plugin_name,
          "refs" => %{"tool_refs" => [missing_tool]}
        }
      )

    assert created.status == 201
    plugin_id = created.body["plugin_id"]
    assert Ids.valid_plugin_id?(plugin_id)

    assert req(
             :post,
             "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins/#{plugin_id}/enable"
           ).status == 200

    projection =
      req(:get, "/v1/runtime/agent-groups/#{group_a["group_id"]}/plugins/projection").body

    assert plugin_id in projection["enabled_plugin_ids"]
    assert missing_tool in projection["allowed_tools"]
    assert projection_ref(projection, plugin_id, "tool_refs") == [missing_tool]

    disclosure =
      SalixAgent.ToolDisclosure.materialize("worker", :internal, %{
        tenant_id: tenant_id,
        group_id: group_a["group_id"],
        plugin_projection: projection
      })

    refute disclosed?(disclosure, missing_tool)
  end

  test "catalog reads do not restore the retired custom-id migration", %{
    tenant_id: tenant_id,
    group_a: group_a,
    suffix: suffix
  } do
    group_id = group_a["group_id"]
    old_plugin_id = "legacy-custom-plugin-#{suffix}"
    plugin_name = "Legacy Custom Plugin #{suffix}"
    legacy_tool = "legacy.custom_tool_#{suffix}"
    now = Store.now()
    definition_key = Keys.ctl_group_plugin_definition(tenant_id, group_id, old_plugin_id)
    enablement_key = Keys.ctl_group_plugin_enablement(tenant_id, group_id, old_plugin_id)

    {:ok, _definition} =
      Store.put_new(definition_key, %{
        "owner_scope" => "group",
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "plugin_id" => old_plugin_id,
        "version" => 1,
        "name" => plugin_name,
        "description" => "legacy semantic custom id",
        "refs" => %{"tool_refs" => [legacy_tool]},
        "source" => "group",
        "read_only" => false,
        "locked" => false,
        "default_enabled" => false,
        "created_at" => now,
        "updated_at" => now
      })

    {:ok, _enablement} =
      Store.put_new(enablement_key, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "plugin_id" => old_plugin_id,
        "enabled" => true,
        "enabled_version" => 1,
        "revision" => 3,
        "created_at" => now,
        "updated_at" => now
      })

    assert {:ok, _projection} =
             Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})

    refute Ids.valid_plugin_id?(old_plugin_id)
    assert {:ok, %{"plugin_id" => ^old_plugin_id}} = Store.get_record(definition_key)

    assert {:ok, %{"plugin_id" => ^old_plugin_id, "enabled" => true}} =
             Store.get_record(enablement_key)

    refute Enum.any?(
             Store.list_records(Keys.ctl_group_plugin_definitions_prefix(tenant_id, group_id)),
             &(&1["name"] == plugin_name and &1["plugin_id"] != old_plugin_id)
           )
  end

  defp authed_conn(tenant_id) do
    build_conn()
    |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id})
  end

  defp req(method, path, opts \\ []),
    do: req_as(Process.get(:plugin_tenant_key), method, path, opts)

  defp req_as(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token}]

    Req.request!(
      [method: method, url: SalixWeb.Application.base_url() <> path, headers: headers] ++ opts
    )
  end

  defp projection_ref(projection, plugin_id, ref_key) do
    projection["plugins"]
    |> Enum.find(%{}, &(&1["plugin_id"] == plugin_id))
    |> get_in(["refs", ref_key])
  end

  defp definition_id_by_name(page, name) do
    case Enum.find(page["definitions"], &(&1["name"] == name)) do
      nil -> nil
      definition -> definition["plugin_id"]
    end
  end

  defp disclosed?(disclosure, name) do
    Enum.any?(disclosure["tools"], &(&1["name"] == name and &1["callable"] == true))
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
