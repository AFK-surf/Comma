defmodule SalixAgent.ToolPolicyTest do
  @moduledoc """
  Role tool assembly for router and worker agents: static registry role
  eligibility, global IM provider tools, and role system-prompt selection.
  Pure — no S3, no rounds.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{ToolDisclosure, ToolPolicy, Tools}

  # ---- exclusion tables ----

  # ---- static role eligibility ----

  @memory_names ["memory.get", "memory.search", "memory.write", "memory.ask_worker"]

  test "router-only registry tools are selected by role eligibility" do
    worker_names = callable_names("worker")
    router_names = callable_names("router")

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

  test "unknown names still return disclosure guidance" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    ctx = tool_ctx(agent_id, "worker", :internal)

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

  test "a concise reply style adds its section to the Router and Worker prompts" do
    concise = %{"reply_style" => "concise"}

    refute session_prompt("router", %{}) =~ "## Reply style: concise"
    refute session_prompt("router", %{"reply_style" => "default"}) =~ "## Reply style: concise"
    assert session_prompt("router", concise) =~ "## Reply style: concise"
    assert session_prompt("worker", concise) =~ "## Reply style: concise"
    refute session_prompt("worker", %{}) =~ "## Reply style: concise"

    # The owner's own instructions follow the preset, so theirs decide.
    prompt =
      session_prompt("router", Map.put(concise, "router_system_prompt", "Answer in detail."))

    {style_at, _} = :binary.match(prompt, "## Reply style: concise")
    {own_at, _} = :binary.match(prompt, "Answer in detail.")
    assert style_at < own_at
  end

  # Text the Router reads calls the person it serves "the user": "the owner"
  # came out as 主人 in Chinese replies.
  test "the Router prompt and proactive tools call the person the user, not the owner" do
    prompt = session_prompt("router", %{"reply_style" => "concise"})
    descriptions = Enum.map_join(SalixAgent.Tools.Proactive.defs(), "\n", &inspect/1)

    refute prompt =~ ~r/\bthe owner\b/i
    refute descriptions =~ ~r/\bthe owner\b/i
  end

  test "help tool summary lists every hidden discovery namespace" do
    entry = Tools.find_entry("help")
    desc = Tools.entry_description(entry)

    for ns <- ToolDisclosure.discovery_namespaces() do
      assert String.contains?(desc, ns),
             "Expected help tool description to mention discovery namespace #{inspect(ns)}"
    end
  end

  test "sandbox Router prompt does not tell the Router to copy local files to a retired Cloud VM" do
    ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{
        agent_id: "policy-agent",
        cloud_vm_retired: true
      })

    disclosure =
      "router"
      |> ToolDisclosure.materialize(:internal, ctx)
      |> Map.put("cloud_vm_retired", true)

    prompt = ToolPolicy.session_prompt("router", %{}, nil, :internal, disclosure)

    refute prompt =~ "or must run on the Cloud VM or in a sandbox."
    assert prompt =~ "or must run in a sandbox."
  end

  test "meeting role omits tool disclosure, turn rules, and web/shopping guidance" do
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "meeting-agent"})
    disclosure = ToolDisclosure.materialize("meeting", :internal, ctx)

    assert disclosure["tools"] == []
    assert ToolPolicy.specs_for("meeting") == []

    prompt =
      ToolPolicy.compose_session_prompt(
        "meeting",
        %{"system_prompt" => "Summarize the meeting."},
        "meeting-agent",
        :internal,
        disclosure,
        "Available skills:\n- example"
      )

    assert prompt =~ "Summarize the meeting."
    refute prompt =~ "## Tool Disclosure"
    refute prompt =~ "## Turn rules"
    refute prompt =~ "## Compatibility and purchase checks"
    refute prompt =~ "## Sites that refuse cloud machines"
    refute prompt =~ "Available skills:"
  end

  test "guest Router omits task, station, Slack, and desktop-browser sections" do
    ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{
        agent_id: "guest-agent",
        guest_policy: :restricted
      })

    disclosure =
      "router"
      |> ToolDisclosure.materialize(:internal, ctx)
      |> Map.put("guest_policy", "restricted")

    prompt = ToolPolicy.session_prompt("router", %{}, nil, :internal, disclosure)

    assert prompt =~ "This workspace is a guest trial."
    assert prompt =~ "## History and memory"
    assert prompt =~ "search this session's history"
    assert prompt =~ "im_api.internal.read_conversation"
    assert prompt =~ "## Compatibility and purchase checks"
    assert prompt =~ "## Tool Disclosure"
    refute prompt =~ "skill.create, then edit /.runtime/skills/"
    refute prompt =~ "## What you do yourself and what goes to a Task"
    refute prompt =~ "## Task execution"
    refute prompt =~ "## Worker results"
    refute prompt =~ "## Task requests"
    refute prompt =~ "## Multi-agent collaboration"
    refute prompt =~ "## Slack"
    refute prompt =~ "## Sites that refuse cloud machines"
    refute prompt =~ "station.list lists the workspace's Stations"
  end

  test "triage Worker uses slim triage base and omits irrelevant worker sections" do
    ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{
        agent_id: "triage-worker",
        cloud_vm_retired: true,
        triage_investigation: true
      })

    disclosure =
      "worker"
      |> ToolDisclosure.materialize(:internal, ctx)
      |> Map.put("cloud_vm_retired", true)

    prompt =
      ToolPolicy.compose_session_prompt(
        "worker",
        %{},
        "triage-worker",
        :internal,
        disclosure,
        "Available skills:\n- agent-migration: migrate"
      )

    assert prompt =~ "You are a Triage Worker agent"
    assert prompt =~ "## Triage investigation protocol"
    assert prompt =~ "## Public voice for Triage replies"
    assert prompt =~ "## Information flow"
    refute prompt =~ "create a sandbox Task for it"
    refute prompt =~ "record it with a milestone block"
    refute prompt =~ "## Evidence and investigation"
    refute prompt =~ "## Multi-agent collaboration"
    refute prompt =~ "## Answers for people"
    refute prompt =~ "## Compatibility and purchase checks"
    refute prompt =~ "## Sites that refuse cloud machines"
    refute prompt =~ "Available skills:"
  end

  test "router prompt starts read-only lookup tasks immediately and tries before reporting blocked sites" do
    prompt = session_prompt("router", %{})

    assert prompt =~ "For read-only research, fact-checking, or lookup Tasks"
    assert prompt =~ "do not pause to ask where or how to run"

    assert prompt =~
             "forward the user's actual request and any attachment into a Task immediately"

    assert prompt =~
             "Never skip a lookup or stop early on the assumption that a site will block cloud machines"

    assert prompt =~
             "retry the site directly in the Comma in-app browser on that computer without asking first"
  end

  defp callable_names(role) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "policy-agent"})
    disclosure = ToolDisclosure.materialize(role, :internal, ctx)

    for %{"callable" => true, "name" => name} <- disclosure["tools"], do: name
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
