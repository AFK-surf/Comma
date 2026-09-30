defmodule SalixAgent.SystemPromptDump do
  @moduledoc """
  Offline, side-effect-free construction of a complete Salix system prompt.

  The emulation uses the production prompt composer and role-eligible static
  tool registry, but never reads agent control state, skills, plugins, IM
  connects, MCP bindings, S3, or a database. A representative skill and agent
  instruction exercise the optional prompt sections that would otherwise be
  absent on an empty installation.
  """

  alias SalixAgent.{SkillProjection, ToolDisclosure, ToolPolicy}

  @agent_id "agt1_0000000000000000001_0000000000000000002_0000000000000000003"
  @default_agent_prompt """
  You are running with an emulated local Salix configuration for prompt inspection.
  Treat the synthetic identity and example skill as diagnostic data, not live resources.
  """
  @example_skill %{
    "skill_id" => "example-diagnostic-skill",
    "name" => "Example Diagnostic Skill",
    "description" => "Representative projected skill included by the offline prompt dump."
  }

  @roles ~w(router worker meeting)
  @runtime_kinds [:internal, :external, :script]

  @type option ::
          {:role, String.t()}
          | {:runtime_kind, atom() | String.t()}
          | {:agent_prompt, String.t() | nil}
          | {:include_skill, boolean()}

  @spec render([option()]) :: String.t()
  def render(opts \\ []) when is_list(opts) do
    role = normalize_role(Keyword.get(opts, :role, "router"))
    runtime_kind = normalize_runtime_kind(Keyword.get(opts, :runtime_kind, :internal))
    agent_prompt = normalize_agent_prompt(Keyword.get(opts, :agent_prompt, @default_agent_prompt))
    include_skill = Keyword.get(opts, :include_skill, true)

    unless is_boolean(include_skill) do
      raise ArgumentError, "include_skill must be a boolean"
    end

    disclosure =
      ToolDisclosure.materialize_static(role, runtime_kind, %{
        disabled_tools: [],
        recommendation_policy: :ordinary
      })

    skill_prompt_section =
      if include_skill,
        do: SkillProjection.render_prompt_section([@example_skill]),
        else: ""

    ToolPolicy.compose_session_prompt(
      role,
      configured_prompts(role, agent_prompt),
      @agent_id,
      runtime_kind,
      disclosure,
      skill_prompt_section
    )
  end

  @spec print([option()]) :: :ok
  def print(opts \\ []) do
    IO.write(render(opts))
  end

  defp normalize_role(role) when is_atom(role), do: role |> Atom.to_string() |> normalize_role()

  defp normalize_role(role) when is_binary(role) do
    role = String.trim(role)

    if role in @roles do
      role
    else
      raise ArgumentError, "role must be one of: #{Enum.join(@roles, ", ")}"
    end
  end

  defp normalize_role(_role),
    do: raise(ArgumentError, "role must be one of: #{Enum.join(@roles, ", ")}")

  defp normalize_runtime_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> case do
      "internal" -> :internal
      "external" -> :external
      "script" -> :script
      _ -> invalid_runtime_kind!()
    end
  end

  defp normalize_runtime_kind(kind) when kind in @runtime_kinds, do: kind
  defp normalize_runtime_kind(_kind), do: invalid_runtime_kind!()

  defp invalid_runtime_kind! do
    raise ArgumentError,
          "runtime_kind must be one of: " <>
            Enum.map_join(@runtime_kinds, ", ", &Atom.to_string/1)
  end

  defp normalize_agent_prompt(nil), do: nil
  defp normalize_agent_prompt(prompt) when is_binary(prompt), do: prompt

  defp normalize_agent_prompt(_prompt),
    do: raise(ArgumentError, "agent_prompt must be a string or nil")

  defp configured_prompts(_role, nil), do: %{}
  defp configured_prompts("router", prompt), do: %{"router_system_prompt" => prompt}
  defp configured_prompts(_role, prompt), do: %{"system_prompt" => prompt}
end
