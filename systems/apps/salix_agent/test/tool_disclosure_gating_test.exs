defmodule SalixAgent.ToolDisclosureGatingTest do
  @moduledoc """
  Tool disclosure behavior that the prompt and help depend on: the revision
  that refreshes a stored prompt, the size of what sessions copy, help for
  tools without prompt schemas, and prompt prefixes that discovery does not
  change.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.ToolDisclosure

  defmodule MediaStubResolver do
    @behaviour SalixAgent.MediaResolver
    @impl true
    def resolve(_agent), do: SystemsRuntime.get_env(:salix_agent, :gating_media_stub)
  end

  setup do
    prev =
      Map.new(
        [:media_resolver, :gating_media_stub],
        &{&1, SystemsRuntime.get_env(:salix_agent, &1)}
      )

    on_exit(fn ->
      Enum.each(prev, fn
        {key, nil} -> SystemsRuntime.delete_env(:salix_agent, key)
        {key, value} -> SystemsRuntime.put_env(:salix_agent, key, value)
      end)
    end)

    :ok
  end

  test "a capability the tenant has not configured is refused at dispatch" do
    SystemsRuntime.put_env(:salix_agent, :media_resolver, MediaStubResolver)
    SystemsRuntime.put_env(:salix_agent, :gating_media_stub, {:ok, %{}})

    ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{
        agent_id: "agent-1",
        tenant_id: "tenant-1",
        session_id: "s1",
        role: "worker",
        runtime_kind: :internal,
        visible_reply_guard: :clean,
        visible_reply_phase: :clean
      })

    ctx = Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))

    [result] =
      SalixAgent.SessionToolDispatch.execute(
        [%{"id" => "v1", "name" => "video.generate", "args" => %{"prompt" => "a cat"}}],
        ctx
      )

    assert %{"status" => "guidance", "error" => "tool is not callable in this session"} =
             Jason.decode!(result.content)
  end

  test "IFC help guidance is conditional even when the model uses the outer envelope" do
    entry = %{
      "name" => "im_api.internal.label.list",
      "summary" => "List labels",
      "manual" => "Return labels available to this agent.",
      "input_schema" => %{"type" => "object"}
    }

    ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{
        runtime_kind: :internal,
        llm_tool_envelope: true
      })

    disclosure = ToolDisclosure.materialize_prepared("router", :internal, ctx, [entry], [])
    ctx = Map.put(ctx, :tool_disclosure, disclosure)

    help = fn mode ->
      SalixAgent.Tools.help(%{"tool" => entry["name"]}, Map.put(ctx, :ifc_mode, mode))
      |> Jason.decode!()
    end

    off = help.(:off)
    enabled = help.(:enforce)
    assert off["manual"] == entry["manual"]
    assert String.ends_with?(enabled["manual"], entry["manual"])
    refute enabled["manual"] == off["manual"]
    assert enabled["input_schema"] == off["input_schema"]
  end

  test "management and label tools are discovered on demand without changing the prefix" do
    label = %{
      "name" => "im_api.internal.label.list",
      "summary" => "List labels",
      "input_schema" => %{"type" => "object"}
    }

    runtime = :internal
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{runtime_kind: runtime})
    disclosure = ToolDisclosure.materialize_prepared("router", runtime, ctx, [label], [])
    ctx = Map.put(ctx, :tool_disclosure, disclosure)
    prompt = ToolDisclosure.prompt_section(disclosure, runtime)

    for namespace <- ToolDisclosure.discovery_namespaces() do
      result = SalixAgent.Tools.help(%{"tool" => namespace}, ctx) |> Jason.decode!()
      assert result["tools"] != [], "#{runtime}: #{namespace}"

      for entry <- result["tools"] do
        assert %{"input_schema" => schema} =
                 SalixAgent.Tools.help(%{"tool" => entry["name"]}, ctx) |> Jason.decode!()

        assert is_map(schema)
      end
    end

    assert ToolDisclosure.prompt_section(disclosure, runtime) == prompt
    denied = Map.put(ctx, :tool_disclosure, %{"tools" => []})

    assert %{"tools" => []} =
             SalixAgent.Tools.help(%{"tool" => "calendar"}, denied) |> Jason.decode!()
  end

  test "a Router installs a Comma plugin without a help round; plugin management stays on demand" do
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{runtime_kind: :internal})
    disclosure = ToolDisclosure.materialize_static("router", :internal, ctx)
    visibility = Map.new(disclosure["tools"], &{&1["name"], &1["prompt_visibility"]})

    assert visibility["plugin.request_install"] == "manual"

    management =
      ~w(plugin.definitions_list plugin.definition_create plugin.definition_update plugin.definition_get plugin.refs_put plugin.enable plugin.disable plugin.projection_get)

    for name <- management, do: assert(visibility[name] == "hidden", name)

    help =
      SalixAgent.Tools.help(%{"tool" => "plugin"}, Map.put(ctx, :tool_disclosure, disclosure))
      |> Jason.decode!()

    listed = Enum.map(help["tools"], & &1["name"])
    for name <- management, do: assert(name in listed, name)

    worker = ToolDisclosure.materialize_static("worker", :internal, ctx)
    refute Enum.any?(worker["tools"], &(&1["name"] == "plugin.request_install"))
  end

  test "triage_investigation workers pre-disclose triage tools and share a byte-identical system prompt across tasks" do
    triage_manual = ~w(
      im_api.internal.triage.read_source
      im_api.internal.triage.read_context
      im_api.internal.triage.read_memory
      im_api.internal.triage.complete
    )

    triage_summary = ~w(
      im_api.slack.get_channel_history
      im_api.slack.get_thread_replies
      im_api.slack.get_user_info
      im_api.slack.search
      im_api.slack.message_search
      im_api.internal.station_task.list
    )

    im_entries =
      Enum.map(triage_manual ++ triage_summary ++ ["im_api.slack.post_message"], fn name ->
        %{
          "name" => name,
          "summary" => "Summary for #{name}.",
          "manual" => "Manual for #{name}.",
          "input_schema" => %{"type" => "object"}
        }
      end)

    base_ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{
        runtime_kind: :internal,
        llm_tool_envelope: true
      })

    triage_ctx_1 =
      Map.put(base_ctx, :trusted_origins, [
        %{"triage_investigation" => %{"conversation_id" => "conv_triage_1"}}
      ])

    triage_ctx_2 =
      Map.put(base_ctx, :trusted_origins, [
        %{"triage_investigation" => %{"conversation_id" => "conv_triage_2"}}
      ])

    disclosure_1 =
      ToolDisclosure.materialize_prepared("worker", :internal, triage_ctx_1, im_entries, [])

    disclosure_2 =
      ToolDisclosure.materialize_prepared("worker", :internal, triage_ctx_2, im_entries, [])

    assert disclosure_1["triage_investigation"] == true
    assert disclosure_2["triage_investigation"] == true

    visibility_by_name = Map.new(disclosure_1["tools"], &{&1["name"], &1["prompt_visibility"]})

    for name <- triage_manual do
      assert visibility_by_name[name] == "manual", name
    end

    for name <- triage_summary do
      assert visibility_by_name[name] == "summary", name
    end

    for name <-
          ~w(composio.list_connections composio.list_tools composio.get_tool composio.execute) do
      assert visibility_by_name[name] == "summary", name
    end

    assert visibility_by_name["im_api.slack.post_message"] == "hidden"

    # Non-triage worker tools stay callable and helpable, but stay hidden from
    # the initial uncached prompt listing.
    env_exec = Enum.find(disclosure_1["tools"], &(&1["name"] == "env.exec"))
    assert env_exec["prompt_visibility"] == "hidden"
    assert env_exec["callable"] == true
    assert env_exec["helpable"] == true

    prompt_1 =
      SalixAgent.ToolPolicy.session_prompt("worker", %{}, nil, :internal, disclosure_1, %{})

    prompt_2 =
      SalixAgent.ToolPolicy.session_prompt("worker", %{}, nil, :internal, disclosure_2, %{})

    assert prompt_1 =~ "## Triage investigation protocol"
    assert prompt_1 == prompt_2

    # Ordinary worker without triage_investigation grant
    ordinary_worker =
      ToolDisclosure.materialize_prepared("worker", :internal, base_ctx, im_entries, [])

    refute Map.has_key?(ordinary_worker, "triage_investigation")

    ordinary_vis = Map.new(ordinary_worker["tools"], &{&1["name"], &1["prompt_visibility"]})

    for name <- triage_manual ++ triage_summary ++ ["im_api.slack.post_message"] do
      assert ordinary_vis[name] == "hidden", name
    end

    ordinary_prompt =
      SalixAgent.ToolPolicy.session_prompt("worker", %{}, nil, :internal, ordinary_worker, %{})

    refute ordinary_prompt =~ "## Triage investigation protocol"

    # Router even with triage_origins in ctx never gets worker triage pre-disclosure
    router_disclosure =
      ToolDisclosure.materialize_prepared("router", :internal, triage_ctx_1, im_entries, [])

    refute Map.has_key?(router_disclosure, "triage_investigation")

    router_vis = Map.new(router_disclosure["tools"], &{&1["name"], &1["prompt_visibility"]})

    for name <- triage_manual ++ triage_summary ++ ["im_api.slack.post_message"] do
      assert router_vis[name] == "hidden", name
    end

    router_prompt =
      SalixAgent.ToolPolicy.session_prompt("router", %{}, nil, :internal, router_disclosure, %{})

    refute router_prompt =~ "## Triage investigation protocol"
  end
end
