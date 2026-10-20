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
end
