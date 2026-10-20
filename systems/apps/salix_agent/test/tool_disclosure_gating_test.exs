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
end
