defmodule SalixAgent.ToolDisclosureGatingTest do
  @moduledoc """
  Tenant-configuration capability gating in `SalixAgent.ToolDisclosure`:
  the `oauth.*` family is dropped from a session's disclosure when no OAuth
  provider app resolves for the tenant (no tenant credentials, no platform
  default), and the `composio.*` family when the tenant has no Composio
  settings — so a single-path tenant's context is not polluted by the other
  path's dead tools. Fail-open cases: no wired store seam, blank tenant, or
  a transient store error keeps the family visible.

  The `email.*` family is gated on the session group's platform-managed
  `owner_emails` list with the same fail-open semantics (no wired group
  context, blank tenant/group, transient error → visible).
  """
  use ExUnit.Case, async: false

  alias SalixAgent.ToolDisclosure

  defmodule OAuthStubStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    defp cfg, do: Application.get_env(:salix_agent, :gating_oauth_stub, %{})

    @impl true
    def agent_oauth_context(_agent_id), do: {:error, :agent_not_found}

    @impl true
    def provider_app(_tenant, provider) do
      case cfg() do
        %{configured: providers} = c ->
          if provider in providers,
            do: {:ok, %{"client_id" => "x", "client_secret" => "y"}},
            else: default_result(c)

        c ->
          default_result(c)
      end
    end

    defp default_result(%{result: result}), do: result
    defp default_result(_), do: {:error, :not_configured}

    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}
    @impl true
    def public_base_url, do: nil
    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule ComposioStubStore do
    @moduledoc false
    @behaviour SalixAgent.ComposioStore

    @impl true
    def settings(_tenant) do
      Application.get_env(:salix_agent, :gating_composio_stub, {:error, :not_configured})
    end
  end

  defmodule GroupStubContext do
    @moduledoc false
    @behaviour SalixAgent.GroupContext

    defp result, do: Application.get_env(:salix_agent, :gating_group_stub, {:error, :not_found})

    @impl true
    def list(_tenant_id), do: []

    @impl true
    def get(_group_id, _tenant_id), do: result()
  end

  defmodule MediaStubResolver do
    @behaviour SalixAgent.MediaResolver
    @impl true
    def resolve(_agent), do: Application.get_env(:salix_agent, :gating_media_stub)
  end

  @seam_keys [
    :media_resolver,
    :gating_media_stub,
    :oauth_store_mod,
    :composio_store_mod,
    :group_context_mod,
    :gating_oauth_stub,
    :gating_composio_stub,
    :gating_group_stub
  ]

  setup do
    prev = Map.new(@seam_keys, &{&1, Application.get_env(:salix_agent, &1)})

    on_exit(fn ->
      Enum.each(prev, fn
        {key, nil} -> Application.delete_env(:salix_agent, key)
        {key, value} -> Application.put_env(:salix_agent, key, value)
      end)
    end)

    :ok
  end

  test "unconfigured video is absent from disclosure, help, and callable tools" do
    Application.put_env(:salix_agent, :media_resolver, MediaStubResolver)

    for media <- [
          nil,
          %{},
          %{"video_config" => %{}},
          %{"video_config" => %{"provider" => "test", "model" => "test"}}
        ] do
      Application.put_env(:salix_agent, :gating_media_stub, {:ok, media})

      ctx =
        SalixAgent.TestSupport.with_plugin_projection(%{
          agent_id: "agent-1",
          tenant_id: "tenant-1"
        })

      disclosure = ToolDisclosure.materialize("worker", :internal, ctx)
      ctx = Map.put(ctx, :tool_disclosure, disclosure)
      refute Enum.any?(disclosure["tools"], &(&1["name"] == "video.generate"))
      refute ToolDisclosure.callable?(ctx, "video.generate")
      refute ToolDisclosure.helpable?(ctx, "video.generate")
    end
  end

  test "configured video returns on the next disclosure and changes its revision" do
    Application.put_env(:salix_agent, :media_resolver, MediaStubResolver)
    Application.put_env(:salix_agent, :gating_media_stub, {:ok, %{}})

    ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "agent-1", tenant_id: "tenant-1"})

    before = ToolDisclosure.materialize("worker", :internal, ctx)

    config = %{
      "provider" => "test",
      "model" => "test",
      "provider_config" => %{"base_url" => "https://example.test"}
    }

    Application.put_env(:salix_agent, :gating_media_stub, {:ok, %{"video_config" => config}})
    after_config = ToolDisclosure.materialize("worker", :internal, ctx)
    assert before["revision"] != after_config["revision"]

    assert ToolDisclosure.callable?(
             Map.put(ctx, :tool_disclosure, after_config),
             "video.generate"
           )

    assert SalixAgent.MediaResolver.generation_configured?(config)
  end

  test "video disclosure fails open without resolution scope or on a transient error" do
    Application.put_env(:salix_agent, :media_resolver, MediaStubResolver)
    Application.put_env(:salix_agent, :gating_media_stub, {:error, :unavailable})
    assert "video.generate" in disclosed_names(%{agent_id: "agent-1"})
    Application.put_env(:salix_agent, :gating_media_stub, {:ok, nil})
    assert "video.generate" in disclosed_names()
    Application.delete_env(:salix_agent, :media_resolver)
    assert "video.generate" in disclosed_names(%{agent_id: "agent-1"})
  end

  defp wire(oauth_stub_cfg, composio_result) do
    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStubStore)
    Application.put_env(:salix_agent, :composio_store_mod, ComposioStubStore)
    Application.put_env(:salix_agent, :gating_oauth_stub, oauth_stub_cfg)
    Application.put_env(:salix_agent, :gating_composio_stub, composio_result)
  end

  defp disclosed_names(ctx \\ %{tenant_id: "tenant-1"}) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(ctx)
    disclosure = ToolDisclosure.materialize("worker", :internal, ctx)
    Enum.map(disclosure["tools"], & &1["name"])
  end

  defp family(names, prefix), do: Enum.filter(names, &String.starts_with?(&1, prefix))

  test "both families are dropped for a tenant with neither path configured" do
    wire(%{result: {:error, :not_configured}}, {:error, :not_configured})

    names = disclosed_names()
    assert family(names, "oauth.") == []
    assert family(names, "composio.") == []
    # Everything else is untouched.
    assert "fs.read_file" in names
  end

  test "one configured provider keeps the whole oauth family" do
    wire(%{configured: ["notion"], result: {:error, :not_configured}}, {:error, :not_configured})

    names = disclosed_names()

    assert Enum.sort(family(names, "oauth.")) == [
             "oauth.complete_authorization",
             "oauth.delete_credential",
             "oauth.list_credentials",
             "oauth.request_authorization"
           ]

    assert family(names, "composio.") == []
  end

  test "composio settings keep the composio family for a composio-only tenant" do
    wire(%{result: {:error, :not_configured}}, {:ok, %{"api_key" => "ck", "base_url" => ""}})

    names = disclosed_names()
    assert family(names, "oauth.") == []

    assert Enum.sort(family(names, "composio.")) == [
             "composio.bind_trigger",
             "composio.check_connection",
             "composio.create_trigger",
             "composio.delete_connection",
             "composio.execute",
             "composio.get_tool",
             "composio.get_trigger_type",
             "composio.list_connections",
             "composio.list_toolkits",
             "composio.list_tools",
             "composio.list_trigger_types",
             "composio.list_triggers",
             "composio.manage_trigger",
             "composio.request_connection"
           ]
  end

  test "transient store errors fail open" do
    wire(%{result: {:error, :unavailable}}, {:error, :timeout})

    names = disclosed_names()
    assert family(names, "oauth.") != []
    assert family(names, "composio.") != []
  end

  test "a blank or missing tenant fails open" do
    wire(%{result: {:error, :not_configured}}, {:error, :not_configured})

    for ctx <- [%{tenant_id: "  "}, %{agent_id: "a1"}] do
      names = disclosed_names(ctx)
      assert family(names, "oauth.") != [], "oauth family hidden for #{inspect(ctx)}"
      assert family(names, "composio.") != [], "composio family hidden for #{inspect(ctx)}"
    end
  end

  test "unwired store seams fail open" do
    Application.put_env(:salix_agent, :oauth_store_mod, nil)
    Application.put_env(:salix_agent, :composio_store_mod, nil)

    names = disclosed_names()
    assert family(names, "oauth.") != []
    assert family(names, "composio.") != []
  end

  describe "email.* owner-email gating" do
    defp wire_group(result) do
      Application.put_env(:salix_agent, :group_context_mod, GroupStubContext)
      Application.put_env(:salix_agent, :gating_group_stub, result)
    end

    @group_ctx %{tenant_id: "tenant-1", group_id: "group-1"}

    test "a group with owner emails keeps the family" do
      wire_group({:ok, %{"owner_emails" => ["owner@example.com"]}})

      assert family(disclosed_names(@group_ctx), "email.") == ["email.send_to_owners"]
    end

    test "a group with no owner emails drops the family" do
      wire_group({:ok, %{"name" => "Workspace"}})
      assert family(disclosed_names(@group_ctx), "email.") == []

      wire_group({:ok, %{"owner_emails" => []}})
      assert family(disclosed_names(@group_ctx), "email.") == []

      wire_group({:error, :not_found})
      assert family(disclosed_names(@group_ctx), "email.") == []
    end

    test "gated email tools disappear from callable and helpable surfaces too" do
      wire_group({:ok, %{"owner_emails" => []}})

      ctx = SalixAgent.TestSupport.with_plugin_projection(@group_ctx)
      disclosure = ToolDisclosure.materialize("worker", :internal, ctx)
      ctx = Map.put(ctx, :tool_disclosure, disclosure)

      refute ToolDisclosure.callable?(ctx, "email.send_to_owners")
      refute ToolDisclosure.helpable?(ctx, "email.send_to_owners")
    end

    test "an unwired group context, blank tenant/group, or transient error fails open" do
      Application.delete_env(:salix_agent, :group_context_mod)
      assert family(disclosed_names(@group_ctx), "email.") == ["email.send_to_owners"]

      wire_group({:error, :unavailable})
      assert family(disclosed_names(@group_ctx), "email.") == ["email.send_to_owners"]

      wire_group({:error, :not_found})

      assert family(disclosed_names(%{tenant_id: "tenant-1"}), "email.") == [
               "email.send_to_owners"
             ]

      assert family(disclosed_names(%{group_id: "group-1"}), "email.") == ["email.send_to_owners"]
    end
  end

  describe "memory.ask_worker Group gating" do
    test "an explicit disabled flag removes the tool from every disclosure surface" do
      ctx =
        %{memory_ask_worker_enabled: false}
        |> SalixAgent.TestSupport.with_plugin_projection()

      disclosure = ToolDisclosure.materialize("router", :internal, ctx)
      ctx = Map.put(ctx, :tool_disclosure, disclosure)

      refute "memory.ask_worker" in Enum.map(disclosure["tools"], & &1["name"])
      refute ToolDisclosure.callable?(ctx, "memory.ask_worker")
      refute ToolDisclosure.helpable?(ctx, "memory.ask_worker")
    end

    test "an explicit enabled flag retains the Router-only tool" do
      disclosure =
        %{memory_ask_worker_enabled: true}
        |> SalixAgent.TestSupport.with_plugin_projection()
        |> then(&ToolDisclosure.materialize("router", :internal, &1))

      assert "memory.ask_worker" in Enum.map(disclosure["tools"], & &1["name"])
    end
  end

  test "gated families disappear from callable and helpable surfaces too" do
    wire(%{result: {:error, :not_configured}}, {:error, :not_configured})

    ctx = SalixAgent.TestSupport.with_plugin_projection(%{tenant_id: "tenant-1"})
    disclosure = ToolDisclosure.materialize("worker", :internal, ctx)
    ctx = Map.put(ctx, :tool_disclosure, disclosure)

    refute ToolDisclosure.callable?(ctx, "oauth.list_credentials")
    refute ToolDisclosure.helpable?(ctx, "composio.execute")
    assert ToolDisclosure.callable?(ctx, "fs.read_file")
  end

  test "recommendation publication stays callable with its full schema available on demand" do
    for runtime_kind <- [:internal, :external] do
      disclosure = ToolDisclosure.materialize_static("router", runtime_kind, %{})
      ctx = %{tool_disclosure: disclosure, runtime_kind: runtime_kind}
      entry = ToolDisclosure.find_disclosure_entry(ctx, "recommendation.publish")
      prompt = ToolDisclosure.prompt_section(disclosure, runtime_kind)
      assert prompt =~ "recommendation.publish"
      refute prompt =~ Jason.encode!(entry["input_schema"])
      assert ToolDisclosure.callable?(ctx, "recommendation.publish")

      help = SalixAgent.Tools.help(%{"tool" => "recommendation.publish"}, ctx) |> Jason.decode!()
      assert help["input_schema"] == entry["input_schema"]
      assert help["input_schema"]["required"] == ["run_id", "snapshot"]
      assert get_in(help, ["input_schema", "properties", "snapshot", "required"]) != []

      native =
        Enum.find(
          ToolDisclosure.external_specs(disclosure),
          &(&1["name"] == "recommendation.publish")
        )

      assert native["input_schema"] == help["input_schema"]
    end
  end

  test "MCP discovery and help do not change provider prompt prefixes" do
    manual = String.duplicate("Long provider-owned instructions. ", 4_000)
    schema = %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}

    entries =
      for name <- ["mcp.notion.search", "mcp.another_server.lookup"] do
        %{"name" => name, "summary" => manual, "manual" => manual, "input_schema" => schema}
      end

    for runtime <- [:internal, :external] do
      ctx = SalixAgent.TestSupport.with_plugin_projection(%{runtime_kind: runtime})
      empty = ToolDisclosure.materialize_prepared("worker", runtime, ctx, [], [])
      populated = ToolDisclosure.materialize_prepared("worker", runtime, ctx, [], entries)

      changed =
        ToolDisclosure.materialize_prepared("worker", runtime, ctx, [], Enum.take(entries, 1))

      prompt = fn disclosure ->
        SalixAgent.ToolPolicy.session_prompt("worker", %{}, nil, runtime, disclosure)
      end

      assert prompt.(empty) == prompt.(populated)
      assert prompt.(changed) == prompt.(populated)

      assert ToolDisclosure.internal_llm_specs("worker", empty) ==
               ToolDisclosure.internal_llm_specs("worker", populated)

      assert ToolDisclosure.external_specs(empty) == ToolDisclosure.external_specs(populated)

      ctx = Map.put(ctx, :tool_disclosure, populated)

      for entry <- entries do
        name = entry["name"]
        assert ToolDisclosure.callable?(ctx, name)
        help = SalixAgent.Tools.help(%{"tool" => name}, ctx) |> Jason.decode!()
        assert help["manual"] == manual
        assert help["input_schema"] == schema
      end

      assert prompt.(populated) == prompt.(empty)
      refute ToolDisclosure.callable?(Map.put(ctx, :tool_disclosure, empty), hd(entries)["name"])
    end
  end

  test "management and label tools are discovered on demand without changing the prefix" do
    label = %{
      "name" => "im_api.internal.label.list",
      "summary" => "List labels",
      "input_schema" => %{"type" => "object"}
    }

    for runtime <- [:internal, :external] do
      ctx = SalixAgent.TestSupport.with_plugin_projection(%{runtime_kind: runtime})
      disclosure = ToolDisclosure.materialize_prepared("router", runtime, ctx, [label], [])
      ctx = Map.put(ctx, :tool_disclosure, disclosure)
      prompt = ToolDisclosure.prompt_section(disclosure, runtime)
      specs = ToolDisclosure.external_specs(disclosure)

      for namespace <- ToolDisclosure.discovery_namespaces() do
        result = SalixAgent.Tools.help(%{"tool" => namespace}, ctx) |> Jason.decode!()
        assert result["tools"] != [], "#{runtime}: #{namespace}"

        for entry <- result["tools"] do
          name = entry["name"]
          refute prompt =~ "- " <> name <> ":"
          refute Enum.any?(specs, &(&1["name"] == name))
          assert ToolDisclosure.callable?(ctx, name)

          assert %{"input_schema" => schema} =
                   SalixAgent.Tools.help(%{"tool" => name}, ctx) |> Jason.decode!()

          assert is_map(schema)
        end
      end

      assert ToolDisclosure.prompt_section(disclosure, runtime) == prompt
      denied = Map.put(ctx, :tool_disclosure, %{"tools" => []})

      assert %{"tools" => []} =
               SalixAgent.Tools.help(%{"tool" => "calendar"}, denied) |> Jason.decode!()
    end
  end
end
