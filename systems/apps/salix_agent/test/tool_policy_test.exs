defmodule SalixAgent.ToolPolicyTest do
  @moduledoc """
  Role tool assembly for router and worker agents: static registry role
  eligibility, global IM provider tools, and role system-prompt selection.
  Pure — no S3, no rounds.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{ToolDisclosure, ToolPolicy, Tools}

  # ---- exclusion tables ----

  test "IFC help does not bypass help availability" do
    ctx = %{role: "worker", runtime_kind: :internal, tool_disclosure: %{"tools" => []}}
    assert {:tool_status, "guidance", content, []} = Tools.help(%{"tool" => "ifc"}, ctx)
    assert Jason.decode!(content)["guidance_reason"] == "not_callable"
  end

  test "internal LLM specs use the call envelope plus direct wait and outcome controls" do
    for role <- ["worker", "router", nil] do
      assert ToolPolicy.specs_for(role) |> Enum.map(& &1["name"]) ==
               ["call", "wait_for", "end_turn"]
    end
  end

  test "nil role assembles as worker (default role)" do
    assert ToolPolicy.specs_for(nil) == ToolPolicy.specs_for("worker")
  end

  test "external specs materialize callable canonical tools for each role" do
    worker_names = external_names("worker")
    meeting_names = external_names("meeting")
    router_names = external_names("router")

    assert "fs.read_file" in worker_names
    assert "audio.transcribe" in worker_names
    assert "im.connects_list" in worker_names
    assert "im.provider_apis_list" in worker_names

    assert "agent.list" in router_names
    refute "task.list" in router_names
    refute "task.create" in router_names
    refute "task.update" in router_names
    refute "task.cancel" in router_names
    refute "task.resolve_block" in router_names
    refute "task.complete_gate" in worker_names
    refute "task.complete_gate" in meeting_names
    refute "task.complete_gate" in router_names
    assert "agent.create_worker" in router_names
  end

  test "filtering preserves registry order (invariant #6)" do
    registry_names = Enum.map(Tools.specs(), & &1["name"])

    for role <- ["worker", "router"] do
      policy_names = external_names(role)
      base_names = Enum.filter(policy_names, &(&1 in registry_names))
      assert base_names == Enum.filter(registry_names, &(&1 in base_names))
    end
  end

  # ---- static role eligibility ----

  @memory_names ["memory.get", "memory.search", "memory.write", "memory.ask_worker"]

  test "router-only registry tools are selected by role eligibility" do
    worker_names = external_names("worker")
    router_names = external_names("router")

    assert @memory_names -- router_names == []
    assert "agent.list" in router_names
    refute "task.list" in router_names
    refute "task.create" in router_names
    refute "task.update" in router_names
    refute "task.cancel" in router_names
    refute "task.resolve_block" in router_names
    assert "agent.create_worker" in router_names

    assert Enum.all?(@memory_names, &(&1 not in worker_names))
    refute "agent.list" in worker_names
    refute "task.list" in worker_names
    refute "task.create" in worker_names
    refute "task.update" in worker_names
    refute "task.cancel" in worker_names
    refute "task.resolve_block" in worker_names
    refute "task.complete_gate" in worker_names
    refute "task.complete_gate" in router_names
    refute "agent.create_worker" in worker_names
  end

  test "registry tools dispatch through the single registry path" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    ctx = tool_ctx(agent_id, "worker", :internal)

    [res] =
      Tools.execute(
        [%{"id" => "u1", "name" => "help", "args" => %{"tool" => "help"}}],
        ctx
      )

    assert Jason.decode!(res.content)["name"] == "help"
    assert res.error == false
  end

  test "unknown names still return disclosure guidance" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    ctx = tool_ctx(agent_id, "worker", :external)

    for name <- [
          "no_such_tool",
          "task.create",
          "task.update",
          "task.complete_gate",
          "task.cancel",
          "task.resolve_block"
        ] do
      [res] = Tools.execute([%{"id" => "u1", "name" => name, "args" => %{}}], ctx)
      assert res.status == "guidance"
      assert res.error == false
      assert Jason.decode!(res.content)["error"] == "tool is not callable in this session"
    end
  end

  # ---- role system prompt ----

  test "router prefers router_system_prompt, falls back to system_prompt" do
    both = %{"router_system_prompt" => "route!", "system_prompt" => "base"}
    assert ToolPolicy.system_prompt("router", both) == "route!"
    assert ToolPolicy.system_prompt("router", %{"system_prompt" => "base"}) == "base"
    assert ToolPolicy.system_prompt("router", %{}) == nil
    # Empty strings count as not configured.
    assert ToolPolicy.system_prompt("router", %{
             "router_system_prompt" => "",
             "system_prompt" => ""
           }) == nil
  end

  test "worker uses system_prompt only (router prompt is ignored)" do
    assert ToolPolicy.system_prompt("worker", %{
             "router_system_prompt" => "route!",
             "system_prompt" => "base"
           }) ==
             "base"

    assert ToolPolicy.system_prompt("worker", %{"router_system_prompt" => "route!"}) == nil
    assert ToolPolicy.system_prompt(nil, %{"system_prompt" => "base"}) == "base"
  end

  test "prepend_prompt: configured prompt joins the FIRST summary-role message" do
    messages = [
      %{id: 0, role: "summary", content: "old summary"},
      %{id: 5, role: "user", content: "hi"}
    ]

    prompts = %{"router_system_prompt" => "route!", "system_prompt" => "base"}

    router_prompt = session_prompt("router", prompts)

    assert [%{role: "summary", content: router_content} | ^messages] =
             ToolPolicy.prepend_prompt_snapshot(messages, router_prompt)

    assert router_content == router_prompt
    assert router_content =~ "route!"

    worker_prompt = session_prompt("worker", prompts)

    assert [%{role: "summary", content: worker_content} | ^messages] =
             ToolPolicy.prepend_prompt_snapshot(messages, worker_prompt)

    assert worker_content == worker_prompt
    assert worker_content =~ "base"
  end

  defp external_names(role) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "policy-agent"})
    disclosure = ToolDisclosure.materialize(role, :external, ctx)

    disclosure
    |> ToolPolicy.external_specs_for()
    |> Enum.map(& &1["name"])
  end

  test "the prompt carries the turn reminder catalog for internal sessions only" do
    prompt = session_prompt("worker", %{"system_prompt" => "base"})

    catalog =
      SalixVerifiedKernel.Session.query(
        SalixVerifiedKernel.Session.new("agent", "session"),
        :provider_request_part,
        {:turn_reminder_catalog}
      )

    assert length(String.split(prompt, catalog)) == 2

    external =
      ToolPolicy.compose_session_prompt(
        "worker",
        %{"system_prompt" => "base"},
        nil,
        :external,
        %{"tools" => []},
        nil
      )

    refute external =~ catalog
  end

  defp session_prompt(role, prompts) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "policy-agent"})
    disclosure = ToolDisclosure.materialize(role, :internal, ctx)
    ToolPolicy.session_prompt(role, prompts, nil, :internal, disclosure)
  end

  defp tool_ctx(agent_id, role, runtime_kind) do
    ctx =
      %{agent_id: agent_id, session_id: "s1", role: role, runtime_kind: runtime_kind}
      |> SalixAgent.TestSupport.with_plugin_projection()

    disclosure = ToolDisclosure.materialize(role, runtime_kind, ctx)
    Map.put(ctx, :tool_disclosure, disclosure)
  end
end
