defmodule BridgeForTeamsWeb.DashboardSwarmSkills do
  @moduledoc """
  Builds the Agent Swarm Skills page payload and applies its writes for
  `DashboardAPIController`: the custom skills of the swarm and the read-only
  system skills projected into it, one skill's `SKILL.md`, a new skill, an
  uploaded `SKILL.md`, and deleting a custom skill.

  Skills live in Salix and reach the page through the swarm's Router agent
  (or its first agent when it has no Router), the same session projection
  the agent's prompt uses. A read is one Salix page of at most 500 agents,
  the group's Router and one skill catalog; its cost does not grow with the
  number of skills. The list carries each skill's metadata only; one skill's
  content is read when the viewer opens it, with the same reads, so a
  response holds at most one skill body. When Salix is down the page answers
  `status: "unavailable"` and still renders.

  An upload is the file's text in JSON, at most 200 KB, from a `.md` or
  `.markdown` file, as the LiveView upload allowed.

  Every swarm member reads the page; every write is for swarm admins. A
  refused delete records a denied audit entry, as the LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Agents, Observability, Skills}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Agent

  @agent_page 500
  @max_bytes 200_000
  @extensions ~w(.md .markdown)
  # Salix's own validation messages, shown as they are.
  @runtime_messages [
    "activation must be regular or per-message",
    "miniskills require a name and description"
  ]

  # ---- Reads ----

  @doc "The custom and system skills, the agent they are managed through, and the upload limits."
  def page(org, project, role) do
    base = %{
      "project" => %{"id" => project.id, "name" => project.name, "role" => role},
      "agents_href" => "/orgs/#{org.slug}/projects/#{project.id}/agents",
      "limits" => %{"max_bytes" => @max_bytes, "extensions" => @extensions}
    }

    {:ok, Map.merge(base, catalog(org, project))}
  end

  defp catalog(org, project) do
    case skill_agent(project) do
      {:error, _reason} ->
        empty("unavailable", nil)

      nil ->
        empty("ok", nil)

      agent ->
        case Skills.list_skills(org, agent) do
          {:ok, %{system: system, user: custom} = listed} ->
            %{
              "status" => "ok",
              "agent" => public_agent(agent),
              "custom" => Enum.map(custom, &skill/1),
              "system" => Enum.map(system, &skill/1),
              "miniskill_status" => text(listed[:miniskill_status])
            }

          {:error, _reason} ->
            empty("unavailable", agent)
        end
    end
  end

  @doc "One custom or system skill of the swarm with its `SKILL.md` content."
  def show(org, project, skill_id) do
    with {:ok, agent} <- readable_agent(project),
         {:ok, entry} <- find_skill(org, agent, &(&1["skill_id"] == skill_id)) do
      content = if is_binary(entry["content"]), do: entry["content"], else: ""
      {:ok, %{"skill" => Map.put(skill(entry), "content", content)}}
    end
  end

  defp readable_agent(project) do
    case skill_agent(project) do
      %Agent{} = agent -> {:ok, agent}
      nil -> not_found()
      {:error, _reason} -> write_error(:unavailable)
    end
  end

  # The first listed skill `match?` accepts; custom skills before system ones.
  defp find_skill(org, agent, match?) do
    case Skills.list_skills(org, agent) do
      {:ok, %{user: custom, system: system}} ->
        case Enum.find(custom ++ system, match?) do
          %{} = entry -> {:ok, entry}
          nil -> not_found()
        end

      {:error, _reason} ->
        write_error(:unavailable)
    end
  end

  defp not_found, do: {:error, 404, "skill_not_found", gettext("Skill not found."), %{}}

  defp empty(status, agent),
    do: %{
      "status" => status,
      "agent" => agent && public_agent(agent),
      "custom" => [],
      "system" => [],
      "miniskill_status" => nil
    }

  # ---- Writes ----

  @doc "Create a custom skill from a name, a description, instructions and an activation."
  def create(org, _user, project, role, params) do
    with :ok <- admin(role),
         {:ok, agent} <- writable_agent(project) do
      attrs = %{
        "name" => string(params["name"]),
        "description" => string(params["description"]),
        "instructions" => string(params["instructions"]),
        "activation" => string(params["activation"]) || "regular"
      }

      case Skills.create_user_skill(org, agent, attrs) do
        {:ok, _file} ->
          {:ok, %{"notice" => gettext("Skill created.")}}

        {:error, :invalid_name} ->
          message = gettext("Give the skill a name (letters or numbers).")
          {:error, 422, "invalid_skill", message, %{"fields" => %{"name" => [message]}}}

        {:error, reason} ->
          write_error(reason)
      end
    end
  end

  @doc "Store an uploaded `SKILL.md` as a custom skill after checking its frontmatter."
  def upload(org, _user, project, role, params) do
    with :ok <- admin(role),
         {:ok, body} <- upload_body(params),
         {:ok, agent} <- writable_agent(project) do
      case Skills.upload_user_skill(org, agent, body) do
        {:ok, _file} ->
          {:ok, %{"notice" => gettext("Skill uploaded.")}}

        {:error, reason}
        when reason in [:missing_frontmatter, :missing_frontmatter_close, :invalid_name] ->
          {:error, 422, "invalid_skill_file", format_error(reason), %{}}

        {:error, reason} ->
          write_error(reason)
      end
    end
  end

  @doc "Delete a custom skill the swarm's agent lists as deletable."
  def delete(org, user, project, role, skill_id) do
    with :ok <-
           authorize(role, fn ->
             denied(org, user, project, %{"location_configured" => present?(skill_id)})
           end),
         {:ok, agent} <- writable_agent(project),
         {:ok, location} <- deletable_location(org, agent, skill_id) do
      case Skills.delete_user_skill(org, agent, location, audit_opts(user)) do
        {:ok, _result} -> {:ok, %{"notice" => gettext("Skill deleted.")}}
        {:error, reason} -> write_error(reason)
      end
    end
  end

  # Only an editable skill the catalog marks deletable, as `deletable` on the page says.
  defp deletable_location(org, agent, skill_id) do
    with {:ok, entry} <-
           find_skill(
             org,
             agent,
             &(&1["skill_id"] == skill_id and &1["editable"] == true and &1["deletable"] == true)
           ) do
      case entry do
        %{"location" => location} when is_binary(location) -> {:ok, location}
        _other -> not_found()
      end
    end
  end

  defp upload_body(params) do
    content = params["content"]
    name = string(params["filename"]) || ""

    cond do
      not is_binary(content) or not String.valid?(content) or
          String.downcase(Path.extname(name)) not in @extensions ->
        {:error, 422, "invalid_file",
         gettext("Upload a Markdown file with SKILL.md frontmatter."), %{}}

      byte_size(content) > @max_bytes ->
        {:error, 422, "file_too_large", gettext("SKILL.md must be smaller than 200 KB."), %{}}

      true ->
        {:ok, content}
    end
  end

  defp format_error(:missing_frontmatter),
    do: gettext("SKILL.md must start with YAML frontmatter delimited by ---")

  defp format_error(:missing_frontmatter_close),
    do: gettext("SKILL.md frontmatter is missing its closing --- delimiter")

  defp format_error(:invalid_name),
    do: gettext("SKILL.md frontmatter needs a non-empty name (letters or numbers)")

  defp write_error(:duplicate),
    do:
      {:error, 409, "duplicate_skill", gettext("A skill with that name already exists."),
       %{"fields" => %{"name" => [gettext("A skill with that name already exists.")]}}}

  defp write_error(:forbidden), do: admin(nil)

  defp write_error(reason) when reason in @runtime_messages,
    do: {:error, 422, "invalid_skill", reason, %{}}

  defp write_error(_reason),
    do:
      {:error, 503, "runtime_unavailable",
       gettext("The runtime is unreachable right now. Try again shortly."), %{}}

  # ---- The agent skills are managed through ----

  defp writable_agent(project) do
    case skill_agent(project) do
      %Agent{} = agent ->
        {:ok, agent}

      nil ->
        {:error, 409, "no_agent", gettext("Create an Agent Swarm agent first."), %{}}

      {:error, _reason} ->
        write_error(:unavailable)
    end
  end

  # The Router agent, or the first agent when the group has no Router.
  defp skill_agent(project) do
    case Agents.page_agents(project, limit: @agent_page) do
      {:ok, %{items: agents, next_cursor: nil}} ->
        router = router_agent_id(project)
        Enum.find(agents, &(&1.salix_agent_id == router)) || List.first(agents)

      {:ok, _more} ->
        {:error, :agent_page_required}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp router_agent_id(project) do
    client = Client.impl()

    with true <- function_exported?(client, :get_group, 1),
         {:ok, group} <- client.get_group(project.salix_group_id) do
      group["router_agent_id"]
    else
      _unknown -> nil
    end
  end

  defp public_agent(agent) do
    %{"id" => agent.salix_agent_id, "name" => agent_name(agent)}
  end

  defp agent_name(%Agent{salix: %{"name" => name}}) when is_binary(name) and name != "", do: name
  defp agent_name(%Agent{} = agent), do: agent.salix_agent_id

  defp skill(entry) do
    %{
      "id" => entry["skill_id"],
      "location" => entry["location"],
      "name" => entry["name"] || entry["skill_id"],
      "description" => text(entry["description"]),
      "source" => entry["source"],
      "activation" => entry["activation"] || "regular",
      "deletable" => entry["deletable"] == true,
      "delete_reason" => entry["delete_reason"]
    }
  end

  # ---- Authorization and envelopes ----

  defp admin("admin"), do: :ok

  defp admin(_role),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can manage skills."), %{}}

  defp authorize("admin", _record), do: :ok

  defp authorize(role, record) do
    _ = record.()
    admin(role)
  end

  defp denied(org, user, project, metadata) do
    Observability.record_write_attempt(%{
      org_id: org.id,
      actor_user_id: user.id,
      actor_label: actor_label(user),
      action: "skill.group.deleted",
      resource_type: "skill",
      resource_label: project.name,
      result: "denied",
      reason: :forbidden,
      request_id: SystemsRuntime.Proc.uuid(),
      surface: "skills",
      metadata:
        Map.merge(
          %{
            "project_id" => project.id,
            "salix_group_id" => project.salix_group_id,
            "surface" => "skills"
          },
          metadata
        )
    })
  end

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

  defp actor_label(user), do: text(user.email) || text(user.name) || user.id

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
