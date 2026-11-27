defmodule SalixAgent.SystemPromptDumpTest do
  use SystemsClock.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Salix.Prompt.Dump
  alias SalixAgent.SystemPromptDump

  defmodule ExplodingIMProvider do
    def list_connects(_agent_id), do: raise("prompt dump consulted the IM provider")
  end

  defmodule ExplodingMCPProvider do
    def dynamic_disclosure_entries(_agent_id), do: raise("prompt dump consulted MCP")
  end

  test "Mix task writes the complete renderer output" do
    args = ["--no-skill", "--agent-prompt", "CLI diagnostic instructions"]

    output = capture_io(fn -> Dump.run(args) end)

    assert output ==
             SystemPromptDump.render(
               include_skill: false,
               agent_prompt: "CLI diagnostic instructions"
             )
  end

  test "matrix renders all canonical variants with section accounting and sha256" do
    variants = SystemPromptDump.matrix(builtin_skills: false)
    names = Enum.map(variants, & &1["name"])

    assert names == [
             "router_sandbox",
             "router_cloud_vm",
             "router_sandbox_concise",
             "router_guest",
             "worker_sandbox",
             "worker_cloud_vm",
             "worker_triage",
             "meeting"
           ]

    for entry <- variants do
      assert entry["chars"] > 0
      assert byte_size(entry["sha256"]) == 64
      assert entry["sections"]["prose_chars"] > 0
    end

    by_name = Map.new(variants, &{&1["name"], &1})
    assert by_name["router_sandbox_concise"]["chars"] > by_name["router_sandbox"]["chars"]
    assert by_name["worker_triage"]["chars"] < by_name["worker_sandbox"]["chars"]

    assert by_name["router_guest"]["sections"]["listed_tools"] <
             by_name["router_sandbox"]["sections"]["listed_tools"]
  end
end
