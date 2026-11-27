defmodule Mix.Tasks.Salix.Prompt.Dump do
  use Mix.Task

  @shortdoc "Dump a complete system prompt using an offline emulated configuration"

  @moduledoc """
  Dumps a complete Salix system prompt without starting applications or reading
  live control/data stores.

      mix salix.prompt.dump
      mix salix.prompt.dump --role worker --runtime script --no-skill
      mix salix.prompt.dump --agent-prompt "Additional agent instructions"

  The default is an internal Router with its full role-eligible static tool
  registry, one representative projected skill, a valid synthetic agent
  identity, and diagnostic agent instructions. Dynamic IM and MCP operations
  are omitted because the emulation has no live connections.

  Deployed releases expose the same entrypoint through:

      bin/comma eval 'SalixAgent.Release.dump_system_prompt()'
  """

  @requirements ["app.config"]
  @switches [
    role: :string,
    runtime: :string,
    agent_prompt: :string,
    skill: :boolean,
    builtin_skills: :boolean,
    cloud_vm_retired: :boolean,
    guest: :boolean,
    triage: :boolean,
    concise: :boolean,
    with_screens: :boolean,
    matrix: :boolean,
    json: :boolean,
    out: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise(
        "usage: mix salix.prompt.dump [--role router|worker|meeting] " <>
          "[--runtime internal|script] [--agent-prompt TEXT] [--no-skill] " <>
          "[--builtin-skills] [--cloud-vm-retired|--no-cloud-vm-retired] " <>
          "[--guest] [--triage] [--concise] [--no-with-screens] " <>
          "[--matrix] [--json] [--out PATH]"
      )
    end

    if opts[:matrix] do
      run_matrix(opts)
    else
      render_opts =
        []
        |> put_if(:role, opts[:role])
        |> put_if(:runtime_kind, opts[:runtime])
        |> put_if(:agent_prompt, opts[:agent_prompt])
        |> put_if(:include_skill, opts[:skill])
        |> put_if(:builtin_skills, opts[:builtin_skills])
        |> put_if(:cloud_vm_retired, opts[:cloud_vm_retired])
        |> put_if(:guest, opts[:guest])
        |> put_if(:triage, opts[:triage])
        |> put_if(:concise, opts[:concise])
        |> put_if(:with_screens, opts[:with_screens])

      if opts[:json] do
        output =
          render_opts |> SalixAgent.SystemPromptDump.describe() |> Jason.encode!(pretty: true)

        write_output(output, opts[:out])
      else
        output = SalixAgent.SystemPromptDump.render(render_opts)
        write_output(output, opts[:out])
      end
    end
  rescue
    error in ArgumentError -> Mix.raise(error.message)
  end

  defp run_matrix(opts) do
    matrix_opts =
      []
      |> put_if(:builtin_skills, opts[:builtin_skills])
      |> put_if(:agent_prompt, opts[:agent_prompt])

    entries = SalixAgent.SystemPromptDump.matrix(matrix_opts)

    output =
      if opts[:json] or is_binary(opts[:out]) do
        Jason.encode!(%{"variants" => entries}, pretty: true)
      else
        header =
          "| variant | chars | approx_tok | prose | tools | skills | listed_tools | sha256 |"

        sep = "|---|---:|---:|---:|---:|---:|---:|---|"

        rows =
          Enum.map(entries, fn e ->
            s = e["sections"]

            "| #{e["name"]} | #{e["chars"]} | #{e["approx_tokens"]} | " <>
              "#{s["prose_chars"]} | #{s["tool_disclosure_chars"]} | #{s["skills_chars"]} | " <>
              "#{s["listed_tools"]} | #{String.slice(e["sha256"], 0, 12)} |"
          end)

        Enum.join([header, sep | rows], "\n") <> "\n"
      end

    write_output(output, opts[:out])
  end

  defp write_output(output, nil), do: IO.write(output)

  defp write_output(output, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, output)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
