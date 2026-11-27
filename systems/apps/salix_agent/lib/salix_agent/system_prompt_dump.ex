defmodule SalixAgent.SystemPromptDump do
  @moduledoc """
  Offline, side-effect-free construction of a complete Salix system prompt.

  The emulation uses the production prompt composer and role-eligible static
  tool registry, but never reads agent control state, skills, plugins, IM
  connects, MCP bindings, S3, or a database. A representative skill and agent
  instruction exercise the optional prompt sections that would otherwise be
  absent on an empty installation.
  """

  alias SalixAgent.{BuiltinSkills, SkillProjection, ToolDisclosure, ToolPolicy}

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
  @runtime_kinds [:internal, :script]

  @type option ::
          {:role, String.t()}
          | {:runtime_kind, atom() | String.t()}
          | {:agent_prompt, String.t() | nil}
          | {:include_skill, boolean()}
          | {:builtin_skills, boolean()}
          | {:cloud_vm_retired, boolean() | nil}
          | {:guest, boolean()}
          | {:triage, boolean()}
          | {:concise, boolean()}
          | {:with_screens, boolean()}

  @spec render([option()]) :: String.t()
  def render(opts \\ []) when is_list(opts) do
    describe(opts)["prompt"]
  end

  @doc """
  Render one offline variant along with section byte/character breakdown for
  deterministic Before/After prompt diffing.
  """
  @spec describe([option()]) :: map()
  def describe(opts \\ []) when is_list(opts) do
    role = normalize_role(Keyword.get(opts, :role, "router"))
    runtime_kind = normalize_runtime_kind(Keyword.get(opts, :runtime_kind, :internal))
    agent_prompt = normalize_agent_prompt(Keyword.get(opts, :agent_prompt, @default_agent_prompt))
    include_skill = normalize_bool!(Keyword.get(opts, :include_skill, true), "include_skill")
    builtin_skills = normalize_bool!(Keyword.get(opts, :builtin_skills, false), "builtin_skills")

    cloud_vm_retired =
      normalize_optional_bool!(Keyword.get(opts, :cloud_vm_retired), "cloud_vm_retired")

    guest = normalize_bool!(Keyword.get(opts, :guest, false), "guest")
    triage = normalize_bool!(Keyword.get(opts, :triage, false), "triage")
    concise = normalize_bool!(Keyword.get(opts, :concise, false), "concise")
    with_screens = normalize_bool!(Keyword.get(opts, :with_screens, true), "with_screens")

    ctx =
      %{
        disabled_tools: if(with_screens, do: [], else: ["device.screens"]),
        recommendation_policy: :ordinary
      }
      |> maybe_put(:cloud_vm_retired, cloud_vm_retired)
      |> maybe_put(:guest_policy, if(guest, do: "restricted"))
      |> maybe_put(:triage_investigation, if(triage and role == "worker", do: true))

    disclosure =
      role
      |> ToolDisclosure.materialize_static(runtime_kind, ctx)
      |> maybe_put_string_key("cloud_vm_retired", cloud_vm_retired)
      |> maybe_put_string_key("guest_policy", if(guest, do: "restricted"))

    skill_prompt_section = skill_section(role, include_skill, builtin_skills)
    prompts = configured_prompts(role, agent_prompt, concise)

    prompt =
      ToolPolicy.compose_session_prompt(
        role,
        prompts,
        @agent_id,
        runtime_kind,
        disclosure,
        skill_prompt_section
      )

    tool_disclosure_section = ToolDisclosure.prompt_section(disclosure, runtime_kind) || ""
    tool_disclosure_chars = String.length(tool_disclosure_section)
    skills_chars = String.length(skill_prompt_section || "")
    total_chars = String.length(prompt)
    total_bytes = byte_size(prompt)

    %{
      "role" => role,
      "runtime_kind" => Atom.to_string(runtime_kind),
      "options" => %{
        "cloud_vm_retired" => cloud_vm_retired,
        "guest" => guest,
        "triage" => triage and role == "worker",
        "concise" => concise,
        "with_screens" => with_screens,
        "builtin_skills" => builtin_skills,
        "include_skill" => include_skill
      },
      "chars" => total_chars,
      "bytes" => total_bytes,
      "approx_tokens" => div(total_bytes + 3, 4),
      "sha256" => :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower),
      "sections" => %{
        "tool_disclosure_chars" => tool_disclosure_chars,
        "skills_chars" => skills_chars,
        "prose_chars" => max(total_chars - tool_disclosure_chars - skills_chars, 0),
        "listed_tools" => length(ToolDisclosure.listed_tools(disclosure))
      },
      "prompt" => prompt
    }
  end

  @doc """
  Canonical offline variant matrix covering Router, Worker, Triage Worker,
  Guest, Concise, Cloud VM, Sandbox, and Meeting prompt shapes.
  """
  @spec matrix([option()]) :: [map()]
  def matrix(base_opts \\ []) when is_list(base_opts) do
    builtin_skills = Keyword.get(base_opts, :builtin_skills, true)
    agent_prompt = Keyword.get(base_opts, :agent_prompt, nil)

    variants = [
      {"router_sandbox", [role: "router", cloud_vm_retired: true, with_screens: true]},
      {"router_cloud_vm", [role: "router", cloud_vm_retired: false, with_screens: true]},
      {"router_sandbox_concise",
       [role: "router", cloud_vm_retired: true, with_screens: true, concise: true]},
      {"router_guest",
       [role: "router", cloud_vm_retired: true, guest: true, with_screens: false]},
      {"worker_sandbox", [role: "worker", cloud_vm_retired: true]},
      {"worker_cloud_vm", [role: "worker", cloud_vm_retired: false]},
      {"worker_triage", [role: "worker", cloud_vm_retired: true, triage: true]},
      {"meeting", [role: "meeting", include_skill: false]}
    ]

    Enum.map(variants, fn {name, variant_opts} ->
      opts =
        [builtin_skills: builtin_skills, agent_prompt: agent_prompt]
        |> Keyword.merge(variant_opts)

      opts
      |> describe()
      |> Map.put("name", name)
    end)
  end

  @spec print([option()]) :: :ok
  def print(opts \\ []) do
    IO.write(render(opts))
  end

  defp skill_section(_role, false, _builtin_skills), do: ""

  defp skill_section(role, true, true) do
    case BuiltinSkills.snapshot() do
      {:ok, %{skills: skills}} when is_map(skills) and map_size(skills) > 0 ->
        skills
        |> Map.values()
        |> Enum.sort_by(&(&1["skill_id"] || ""))
        |> SkillProjection.render_prompt_section(role: role)

      _ ->
        SkillProjection.render_prompt_section([@example_skill])
    end
  end

  defp skill_section(role, true, false),
    do: SkillProjection.render_prompt_section([@example_skill], role: role)

  defp normalize_bool!(value, _name) when is_boolean(value), do: value
  defp normalize_bool!(_value, name), do: raise(ArgumentError, "#{name} must be a boolean")

  defp normalize_optional_bool!(nil, _name), do: nil
  defp normalize_optional_bool!(value, _name) when is_boolean(value), do: value

  defp normalize_optional_bool!(_value, name),
    do: raise(ArgumentError, "#{name} must be a boolean or nil")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_string_key(map, _key, nil), do: map
  defp maybe_put_string_key(map, key, value), do: Map.put(map, key, value)

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

  defp configured_prompts(role, prompt, concise) do
    base =
      case {role, prompt} do
        {_role, nil} -> %{}
        {"router", text} -> %{"router_system_prompt" => text}
        {_role, text} -> %{"system_prompt" => text}
      end

    if concise, do: Map.put(base, "reply_style", "concise"), else: base
  end
end
