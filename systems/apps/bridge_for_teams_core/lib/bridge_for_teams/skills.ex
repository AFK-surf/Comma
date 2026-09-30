defmodule BridgeForTeams.Skills do
  @moduledoc """
  Agent skills for an Agent Swarm's Skills page.

  Salix is the source of truth: skills live in the layered `SalixAgent.SkillStore`
  (global → tenant → group → agent) and reach the dashboard through the same
  session projection the agent's prompt uses (`SalixAgent.SkillCatalog` over
  erpc). Every skill's `"location"` is its session runtime path
  (`/.runtime/skills/<skill_id>/SKILL.md`). Two families render:

    * **System skills** — read-only catalog entries (built-in global skills,
      tenant/plugin-provided ones). The runtime offers no per-agent
      disable/pin override.
    * **User skills** — editable group-level skills created here, uploaded,
      or saved by an agent from chat. A human Agent Swarm admin can delete any
      group-owned entry (`"deletable"` on each entry), regardless of which
      Agent created it. Agent-facing deletion remains creator-owned.

  Callers select an agent from the current Agent Swarm explicitly. Reads are
  best-effort (`{:error, :unavailable}` when Salix is down); the page must
  still render.
  """

  require Logger

  alias BridgeForTeams.{Memberships, Observability, Repo}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Organization, Project}

  @runtime_prefix "/.runtime/skills"
  @slug_pattern ~r/^[a-z0-9][a-z0-9-]*$/

  @type skill :: map()

  @doc """
  Both skill families for the agent: `{:ok, %{system: [..], user: [..]}}`
  (string-keyed maps as documented on `list_agent_skills`; `system` is the
  read-only entries, `user` the editable ones) or `{:error, :unavailable}`
  when Salix can't be reached.
  """
  @spec list_skills(Organization.t(), Agent.t()) ::
          {:ok, %{system: [skill()], user: [skill()]}} | {:error, term()}
  def list_skills(%Organization{salix_tenant_id: tenant_id}, %Agent{salix_agent_id: agent_id})
      when is_binary(tenant_id) and is_binary(agent_id) do
    case Client.impl().list_agent_skills(agent_id, tenant_id) do
      {:ok, %{"skills" => skills} = catalog} when is_list(skills) ->
        {system, user} =
          skills
          |> Enum.filter(&is_map/1)
          |> Enum.split_with(&(&1["editable"] != true))

        {:ok, %{system: system, user: user, miniskill_status: catalog["miniskill_status"]}}

      {:ok, _other} ->
        {:ok, %{system: [], user: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_skills(_org, _agent), do: {:error, :unavailable}

  @doc """
  Create a user skill as a group-level catalog entry whose id is the slugged
  name. `attrs` needs a `"name"`; `"description"` and `"instructions"` are
  optional. Returns `{:error, :invalid_name}` for a blank name and
  `{:error, :duplicate}` when the name is already taken in the projection.
  """
  @spec create_user_skill(Organization.t(), Agent.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_user_skill(
        %Organization{salix_tenant_id: tenant_id},
        %Agent{salix_agent_id: agent_id},
        attrs
      )
      when is_binary(tenant_id) and is_binary(agent_id) and is_map(attrs) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()
    description = attrs |> Map.get("description", "") |> to_string() |> String.trim()
    instructions = attrs |> Map.get("instructions", "") |> to_string() |> String.trim()

    case slugify(name) do
      "" ->
        {:error, :invalid_name}

      slug ->
        Client.impl().create_agent_skill(agent_id, tenant_id, %{
          "skill_id" => slug,
          "name" => name,
          "description" => description,
          "content" => skill_md(name, description, instructions, attrs["activation"] || "regular")
        })
    end
  end

  def create_user_skill(_org, _agent, _attrs), do: {:error, :unavailable}

  @doc """
  Store an uploaded `SKILL.md` body verbatim as a new user skill, after
  `validate_skill_md/1` passes. The skill id and catalog name/description
  come from the frontmatter.
  """
  @spec upload_user_skill(Organization.t(), Agent.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def upload_user_skill(
        %Organization{salix_tenant_id: tenant_id},
        %Agent{salix_agent_id: agent_id},
        body
      )
      when is_binary(tenant_id) and is_binary(agent_id) and is_binary(body) do
    with {:ok, %{"name" => name, "description" => description}} <- validate_skill_md(body) do
      Client.impl().create_agent_skill(agent_id, tenant_id, %{
        "skill_id" => slugify(name),
        "name" => name,
        "description" => description,
        "content" => body
      })
    end
  end

  def upload_user_skill(_org, _agent, _body), do: {:error, :unavailable}

  @doc """
  Delete a user skill by its `SKILL.md` location — removes the catalog record
  (immutable file blobs stay retained). Only runtime skill locations resolve
  (`{:error, :invalid_location}` otherwise); callers should still pass
  locations read back from `list_skills/2`, never client input directly.

  The authenticated human in `opts` must have effective Agent Swarm Admin
  access. BFT makes that RBAC decision and records the audit row; Salix then
  enforces that the target is an editable group-owned skill. The selected
  Agent is a routing context, not the ownership principal.
  """
  @spec delete_user_skill(Organization.t(), Agent.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete_user_skill(org, agent, location, opts \\ [])

  def delete_user_skill(
        %Organization{id: org_id},
        %Agent{id: agent_record_id, project_id: project_id},
        location,
        opts
      )
      when is_binary(location) and is_list(opts) do
    with {:ok, skill_id} <- skill_id_from_location(location),
         {:ok, org, project, agent} <- delete_scope(org_id, project_id, agent_record_id),
         {:ok, actor} <- delete_actor(opts),
         :ok <-
           Memberships.authorize(actor["user_id"], :write, %{
             project_id: project.id,
             min_project_role: "admin"
           }),
         {:ok, result} = ok <-
           Client.impl().delete_agent_skill(
             agent.salix_agent_id,
             org.salix_tenant_id,
             skill_id,
             actor
           ) do
      maybe_record_delete_audit(result, org, project, agent, skill_id, actor)
      ok
    end
  end

  def delete_user_skill(_org, _agent, _location, _opts), do: {:error, :unavailable}

  # /.runtime/skills/<skill_id>/SKILL.md → <skill_id> — and nothing outside
  # the runtime skill mount ever resolves.
  defp skill_id_from_location(location) do
    case String.split(location, "/") do
      ["", ".runtime", "skills", skill_id, "SKILL.md"]
      when skill_id != "" and skill_id != "." and skill_id != ".." ->
        {:ok, skill_id}

      _ ->
        {:error, :invalid_location}
    end
  end

  defp delete_scope(org_id, project_id, agent_id)
       when is_binary(org_id) and is_binary(project_id) and is_binary(agent_id) do
    with %Organization{} = org <- Repo.get(Organization, org_id),
         %Project{org_id: ^org_id} = project <- Repo.get(Project, project_id),
         {:ok, %Agent{project_id: ^project_id} = agent} <-
           BridgeForTeams.Agents.get_agent(agent_id) do
      {:ok, org, project, agent}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp delete_scope(_org_id, _project_id, _agent_id), do: {:error, :forbidden}

  defp delete_actor(opts) do
    user_id = Keyword.get(opts, :actor_user_id)

    if is_binary(user_id) and String.trim(user_id) != "" do
      {:ok,
       %{
         "type" => "user",
         "user_id" => user_id,
         "label" => to_string(Keyword.get(opts, :actor_label) || ""),
         "request_id" => Keyword.get(opts, :request_id) || Ecto.UUID.generate()
       }}
    else
      {:error, :forbidden}
    end
  end

  defp maybe_record_delete_audit(result, org, project, agent, skill_id, actor) do
    attrs = %{
      org_id: org.id,
      actor_user_id: actor["user_id"],
      actor_label: actor["label"],
      action: "skill.group.deleted",
      resource_type: "skill",
      resource_id: skill_id,
      resource_label: "Skill #{skill_id}",
      result: "ok",
      request_id: actor["request_id"],
      metadata: %{
        "project_id" => project.id,
        "project_name" => project.name,
        "salix_group_id" => project.salix_group_id,
        "salix_tenant_id" => org.salix_tenant_id,
        "requested_via_agent_id" => agent.salix_agent_id,
        "created_by_agent_id" => result["created_by_agent_id"]
      },
      redacted_diff: %{"state" => %{"from" => "present", "to" => "deleted"}}
    }

    case Observability.record_audit(attrs) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("skill deletion audit could not be recorded: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Format-check a `SKILL.md` body against what the Salix runtime will accept
  (`SalixAgent.SkillFrontmatter.parse/1` — a line-oriented YAML subset):
  the file must open with a `---` frontmatter block, close it with a second
  `---`, and declare a non-empty `name` that slugs to a valid skill id.

  Returns `{:ok, %{"name" => .., "description" => ..}}` or a tagged error:
  `:missing_frontmatter` | `:missing_frontmatter_close` | `:invalid_name`.
  """
  @spec validate_skill_md(String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_skill_md(body) when is_binary(body) do
    body = String.replace(body, "\r\n", "\n")

    cond do
      not String.starts_with?(body, "---\n") ->
        {:error, :missing_frontmatter}

      match?([_], String.split(body, "\n---", parts: 2)) ->
        {:error, :missing_frontmatter_close}

      true ->
        [_, frontmatter | _] = String.split(body, "---", parts: 3)
        fields = frontmatter_fields(frontmatter)
        name = Map.get(fields, "name", "")

        if name != "" and slugify(name) != "" do
          {:ok, %{"name" => name, "description" => Map.get(fields, "description", "")}}
        else
          {:error, :invalid_name}
        end
    end
  end

  # Top-level `key: value` scalars only — enough to check what the runtime
  # requires; Salix re-parses authoritatively when it reads the file.
  defp frontmatter_fields(frontmatter) do
    for line <- String.split(frontmatter, "\n"),
        not String.starts_with?(line, " "),
        [key, value] <- [String.split(line, ":", parts: 2)],
        into: %{} do
      {String.trim(key), value |> String.trim() |> String.trim("\"") |> String.trim("'")}
    end
  end

  @doc "The `[a-z0-9-]` skill id a skill name will be stored under (\"\" when unusable)."
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if Regex.match?(@slug_pattern, slug), do: slug, else: ""
  end

  @doc "The runtime location a slug will surface at, for UI hints."
  @spec runtime_location(String.t()) :: String.t()
  def runtime_location(slug), do: @runtime_prefix <> "/" <> slug <> "/SKILL.md"

  defp skill_md(name, description, instructions, activation) do
    # Salix's frontmatter parser is a line-oriented YAML subset — keep the
    # scalar values single-line.
    """
    ---
    name: #{single_line(name)}
    description: #{single_line(description)}
    activation: #{single_line(activation)}
    metadata:
      source: dashboard
    ---

    #{if instructions == "", do: "Describe how to perform this skill.", else: instructions}
    """
  end

  defp single_line(value),
    do: value |> String.replace(~r/\s+/, " ") |> String.trim()
end
