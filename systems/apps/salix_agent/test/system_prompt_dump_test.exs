defmodule SalixAgent.SystemPromptDumpTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Salix.Prompt.Dump
  alias SalixAgent.SystemPromptDump

  @agent_id "agt1_0000000000000000001_0000000000000000002_0000000000000000003"

  defmodule ExplodingIMProvider do
    def list_connects(_agent_id), do: raise("prompt dump consulted the IM provider")
  end

  defmodule ExplodingMCPProvider do
    def dynamic_disclosure_entries(_agent_id), do: raise("prompt dump consulted MCP")
  end

  test "default emulation renders a prompt without consulting live providers" do
    previous_im = Application.get_env(:salix_agent, :im_provider_mod)
    previous_mcp = Application.get_env(:salix_agent, :mcp_provider_mod)
    Application.put_env(:salix_agent, :im_provider_mod, ExplodingIMProvider)
    Application.put_env(:salix_agent, :mcp_provider_mod, ExplodingMCPProvider)

    on_exit(fn ->
      restore_env(:im_provider_mod, previous_im)
      restore_env(:mcp_provider_mod, previous_mcp)
    end)

    prompt = SystemPromptDump.render()

    assert is_binary(prompt)
    assert prompt =~ "agent_id: #{@agent_id}"
  end

  test "worker external emulation renders without optional inputs" do
    prompt =
      SystemPromptDump.render(
        role: "worker",
        runtime_kind: :external,
        include_skill: false,
        agent_prompt: nil
      )

    assert prompt =~ "agent_id: #{@agent_id}"
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

  test "Mix task rejects unsupported emulation values" do
    assert_raise Mix.Error, ~r/role must be one of: router, worker, meeting/, fn ->
      Dump.run(["--role", "reviewer"])
    end

    assert_raise Mix.Error, ~r/runtime_kind must be one of: internal, external, script/, fn ->
      Dump.run(["--runtime", "native"])
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)
end
