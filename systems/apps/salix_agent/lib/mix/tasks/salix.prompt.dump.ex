defmodule Mix.Tasks.Salix.Prompt.Dump do
  use Mix.Task

  @shortdoc "Dump a complete system prompt using an offline emulated configuration"

  @moduledoc """
  Dumps a complete Salix system prompt without starting applications or reading
  live control/data stores.

      mix salix.prompt.dump
      mix salix.prompt.dump --role worker --runtime external --no-skill
      mix salix.prompt.dump --agent-prompt "Additional agent instructions"

  The default is an internal Router with its full role-eligible static tool
  registry, one representative projected skill, a valid synthetic agent
  identity, and diagnostic agent instructions. Dynamic IM and MCP operations
  are omitted because the emulation has no live connections.

  Deployed releases expose the same entrypoint through:

      bin/comma eval 'SalixAgent.Release.dump_system_prompt()'
  """

  @requirements ["app.config"]
  @switches [role: :string, runtime: :string, agent_prompt: :string, skill: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise(
        "usage: mix salix.prompt.dump [--role router|worker|meeting] " <>
          "[--runtime internal|external|script] [--agent-prompt TEXT] [--no-skill]"
      )
    end

    render_opts =
      []
      |> put_if(:role, opts[:role])
      |> put_if(:runtime_kind, opts[:runtime])
      |> put_if(:agent_prompt, opts[:agent_prompt])
      |> put_if(:include_skill, opts[:skill])

    SalixAgent.SystemPromptDump.print(render_opts)
  rescue
    error in ArgumentError -> Mix.raise(error.message)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
