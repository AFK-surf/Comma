defmodule SalixAgent.SkillCatalog do
  @moduledoc """
  Control-plane skill catalog API — the dashboard's view of the skills an
  agent's sessions see (`SalixAgent.SkillProjection.materialize/1`) plus every
  group-owned skill, and group-level create/delete performed on behalf of that
  agent.

  Creates use the managed agent as creator. Human deletes use an explicit
  control-plane event after the caller has authenticated and authorized the
  user: any editable group-owned skill can be removed without impersonating
  its creating agent. Agent-facing `skill.delete` remains creator-owned.
  """

  alias SalixAgent.{AgentRuntimeConfig, Control, PluginStore, SkillProjection, SkillStore}

  @doc """
  Every projected skill plus the group's persisted editable skills,
  dashboard-shaped:
  `{:ok, %{"skills" => [..], "revision" => ..}}`. Each entry carries the
  projection record's identity plus `"location"` (the runtime `SKILL.md`
  path the agent's prompt lists), a `"source"` family, the sorted `"files"`
  paths inside the skill, the `SKILL.md` `"content"`, a control-plane `"deletable"` verdict, and a stable
  `"delete_reason"` for protected entries.
  """
  def list(agent_id, tenant_id) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id),
         {:ok, ctx} <- catalog_context(agent_id),
         {:ok, projection} <- SkillProjection.materialize(ctx),
         {:ok, group_skills} <- group_skills(ctx) do
      {:ok,
       %{
         "revision" => projection.revision,
         "miniskill_status" => miniskill_status(projection.skills),
         "skills" =>
           group_skills
           |> merge_projected_skills(projection.skills)
           |> Enum.map(&skill_json(&1, agent_id))
       }}
    end
  end

  @doc """
  One file of a catalog skill by its path inside the skill (`"SKILL.md"`,
  `"references/x.md"`). Only paths the skill lists under `"files"` resolve;
  bodies over `max_bytes` return `{:error, :too_large}`.
  """
  def read_file(agent_id, tenant_id, skill_id, rel_path, max_bytes)
      when is_binary(skill_id) and is_binary(rel_path) and is_integer(max_bytes) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id),
         {:ok, ctx} <- catalog_context(agent_id),
         {:ok, projection} <- SkillProjection.materialize(ctx),
         {:ok, group_skills} <- group_skills(ctx),
         %{} = skill <-
           group_skills
           |> merge_projected_skills(projection.skills)
           |> Enum.find(&(&1["skill_id"] == skill_id)),
         %{} = entry <- get_in(skill, ["files", rel_path]),
         {:ok, body} <- SkillStore.read_entry(agent_id, entry) do
      if byte_size(body) > max_bytes, do: {:error, :too_large}, else: {:ok, body}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Create a group-level editable skill owned by the agent. `attrs` needs
  `"skill_id"` and `"name"`; `"description"` and `"content"` (a full
  `SKILL.md` body) are optional. Returns `{:error, :duplicate}` when the id or
  name already exists in the group catalog or resolves in the agent's projection.
  """
  def create(agent_id, tenant_id, attrs) when is_map(attrs) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id),
         {:ok, ctx} <- catalog_context(agent_id),
         :ok <- ensure_new(ctx, attrs),
         :ok <- authorize(agent_id, "skill_create"),
         {:ok, event} <- SkillStore.prepare_group_create(ctx, attrs),
         {:ok, _result} <- commit("create", event["skill"]["skill_id"], [event]) do
      {:ok, skill_json(Map.put(event["skill"], "layer", "group"), agent_id)}
    end
  end

  @doc """
  Delete an editable group-level skill for an authenticated human control-plane
  actor. Human RBAC is enforced by the calling control plane; the store
  re-validates the explicit actor and group-owned editable boundary at commit.
  """
  def delete(agent_id, tenant_id, skill_id, actor) when is_map(actor) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id),
         {:ok, ctx} <- AgentRuntimeConfig.complete_context(%{agent_id: agent_id}),
         {:ok, skill} <- get_group_skill(ctx, skill_id),
         :ok <- deletable(skill),
         :ok <- authorize(agent_id, "skill_delete"),
         {:ok, event} <- SkillStore.prepare_group_control_plane_delete(ctx, skill_id, actor),
         {:ok, _result} <- commit("delete", skill_id, [event]) do
      {:ok,
       %{
         "skill_id" => skill["skill_id"],
         "deleted" => true,
         "created_by_agent_id" => skill["created_by_agent_id"]
       }}
    end
  end

  defp miniskill_status(skills) do
    candidates = Enum.filter(skills, &(&1["activation"] == "per-message"))

    case candidates do
      [] ->
        "empty"

      _ ->
        case SalixAgent.MiniskillSelector.request(
               %{"content" => String.duplicate("x", 8192)},
               candidates
             ) do
          {:ok, _, _} -> "ready"
          {:error, _} -> "catalog_over_budget"
        end
    end
  end

  # ---- helpers ----

  defp ensure_new(ctx, attrs) do
    with {:ok, persisted_group_skills} <- group_skills(ctx) do
      if duplicate?(persisted_group_skills, attrs) or
           SkillProjection.duplicate?(ctx, attrs["skill_id"] || "", attrs["name"] || "") do
        {:error, :duplicate}
      else
        :ok
      end
    end
  end

  defp catalog_context(agent_id) do
    with {:ok, ctx} <- AgentRuntimeConfig.complete_context(%{agent_id: agent_id}),
         {:ok, projection} <-
           PluginStore.runtime_projection(%{
             "tenant_id" => ctx.tenant_id,
             "group_id" => ctx.group_id
           }) do
      {:ok, Map.put(ctx, :plugin_projection, projection)}
    end
  end

  # Plugin enablement controls runtime visibility, not ownership. Persisted
  # group skills remain manageable even while no enabled plugin references them.
  defp group_skills(ctx) do
    with {:ok, state} <- SkillStore.read_scope(:group, ctx.group_id) do
      {:ok,
       state.skills
       |> Map.values()
       |> Enum.map(
         &(&1
           |> Map.put("scope", state.scope)
           |> Map.put("layer", "group"))
       )}
    end
  end

  defp get_group_skill(ctx, skill_id) do
    with {:ok, skills} <- group_skills(ctx) do
      case Enum.find(skills, &(&1["skill_id"] == skill_id)) do
        nil -> {:error, :not_found}
        skill -> {:ok, skill}
      end
    end
  end

  defp merge_projected_skills(group_skills, projected_skills) do
    (group_skills ++ projected_skills)
    |> Enum.reduce({[], MapSet.new(), MapSet.new()}, fn skill, {skills, ids, names} ->
      id = skill["skill_id"]
      name = SkillStore.normalize_name(skill["name"])

      if MapSet.member?(ids, id) or MapSet.member?(names, name) do
        {skills, ids, names}
      else
        {[skill | skills], MapSet.put(ids, id), MapSet.put(names, name)}
      end
    end)
    |> elem(0)
    |> Enum.sort_by(&{layer_order(&1["layer"]), &1["skill_id"] || ""})
  end

  defp duplicate?(skills, attrs) do
    skill_id = attrs["skill_id"] || ""
    name = SkillStore.normalize_name(attrs["name"] || "")

    Enum.any?(skills, fn skill ->
      skill["skill_id"] == skill_id or SkillStore.normalize_name(skill["name"]) == name
    end)
  end

  defp layer_order("global"), do: 0
  defp layer_order("tenant"), do: 1
  defp layer_order("group"), do: 2
  defp layer_order("agent"), do: 3
  defp layer_order(_layer), do: 4

  defp deletable(skill) do
    if is_nil(delete_reason(skill)), do: :ok, else: {:error, :read_only}
  end

  defp delete_reason(skill) do
    cond do
      skill["editable"] != true -> "read_only"
      skill["layer"] != "group" -> "managed_at_source"
      true -> nil
    end
  end

  defp authorize(agent_id, event_type) do
    SalixAgent.StorageAuthorization.authorize_write(%{
      agent_id: agent_id,
      events: [%{"type" => event_type}],
      billing_context: %{},
      entrypoint: "storage_write",
      actor_type: "control_plane"
    })
  end

  defp commit(verb, skill_id, events) do
    SkillStore.commit_operation(
      "skill-catalog-" <> verb <> ":" <> to_string(skill_id) <> ":" <> random_id(),
      %{"skill_id" => skill_id},
      events
    )
  end

  defp skill_json(skill, agent_id) do
    %{
      "skill_id" => skill["skill_id"],
      "name" => skill["name"],
      "description" => skill["description"] || "",
      "activation" => skill["activation"] || "regular",
      "location" => SkillProjection.skill_path(skill["skill_id"], "SKILL.md"),
      "source" => source(skill),
      "layer" => skill["layer"],
      "editable" => skill["editable"] == true,
      "deletable" => deletable(skill) == :ok,
      "delete_reason" => delete_reason(skill),
      "updated_at" => skill["updated_at"],
      "files" => skill |> Map.get("files", %{}) |> Map.keys() |> Enum.sort(),
      "content" => content(skill, agent_id)
    }
  end

  # The dashboard's family taxonomy: read-only skills render as "system";
  # editable ones keep their catalog origin ("custom" for agent/dashboard
  # creations, "imported" for imports and migrated workspace skills).
  defp source(skill) do
    cond do
      skill["editable"] != true -> "system"
      skill["origin"] in ["imported", "legacy_workspace"] -> "imported"
      true -> "custom"
    end
  end

  defp content(skill, agent_id) do
    with %{} = entry <- get_in(skill, ["files", "SKILL.md"]),
         {:ok, body} <- SkillStore.read_entry(agent_id, entry) do
      body
    else
      _ -> ""
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
