defmodule SalixAgent.Tools.Skill do
  @moduledoc """
  Skill catalog mutation tools.

  Skill file contents and resources are edited through the normal fs tools on
  `/.runtime/skills/...`; these tools only create, copy, and delete catalog
  records.
  """

  alias SalixAgent.{AgentRuntimeConfig, SkillProjection, SkillStore}

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  @doc "Tool defs in stable registry order."
  @spec defs() :: [{String.t(), String.t(), (map(), map() -> term()), pos_integer()}]
  def defs do
    [
      {"skill.create",
       "Create a group-shared editable skill. After creation, edit SKILL.md and resources with fs tools under /.runtime/skills/<skill_id>/.",
       &__MODULE__.create/2, @normal_auto_wait_seconds},
      {"skill.copy",
       "Copy a visible skill into a new group-shared editable skill. Use this to customize read-only skills without modifying the source.",
       &__MODULE__.copy/2, @normal_auto_wait_seconds},
      {"skill.delete",
       "Delete a skill created by the current agent. This removes the group-level skill record; immutable file blobs remain retained.",
       &__MODULE__.delete/2, @normal_auto_wait_seconds}
    ]
  end

  @doc false
  def create(args, ctx) do
    ctx = complete_ctx(ctx)
    skill_id = required_arg(args, "skill_id")
    name = required_arg(args, "name")

    if SkillProjection.duplicate?(ctx, skill_id, name) do
      raise "skill already exists in the current projection"
    end

    with :ok <- authorize_catalog_write(ctx, "skill_create") do
      case SkillStore.prepare_group_create(ctx, args) do
        {:ok, event} ->
          skill_id = event["skill"]["skill_id"]

          {Jason.encode!(%{
             "skill_id" => skill_id,
             "path" => SkillProjection.skill_path(skill_id, "SKILL.md"),
             "created" => true,
             "editable" => true
           }), [event]}

        {:error, reason} ->
          raise error_message(reason)
      end
    else
      {:error, reason} -> raise error_message(reason)
    end
  end

  @doc false
  def copy(args, ctx) do
    ctx = complete_ctx(ctx)
    source_skill_id = required_arg(args, "source_skill_id")
    skill_id = required_arg(args, "skill_id")
    name = required_arg(args, "name")

    with :ok <- authorize_catalog_write(ctx, "skill_create"),
         {:ok, source} <- SkillProjection.get_skill(ctx, source_skill_id),
         false <- SkillProjection.duplicate?(ctx, skill_id, name),
         {:ok, event} <- SkillStore.prepare_group_copy(ctx, source, Map.put(args, "name", name)) do
      skill_id = event["skill"]["skill_id"]

      {Jason.encode!(%{
         "source_skill_id" => source_skill_id,
         "skill_id" => skill_id,
         "path" => SkillProjection.skill_path(skill_id, "SKILL.md"),
         "created" => true,
         "editable" => true
       }), [event]}
    else
      {:error, :not_found} -> raise "source skill not found"
      true -> raise "skill already exists in the current projection"
      {:error, reason} -> raise error_message(reason)
    end
  end

  @doc false
  def delete(args, ctx) do
    ctx = complete_ctx(ctx)
    skill_id = required_arg(args, "skill_id")

    with :ok <- authorize_catalog_write(ctx, "skill_delete"),
         {:ok, skill} <- SkillProjection.get_skill(ctx, skill_id),
         :ok <- ensure_deletable(ctx, skill),
         {:ok, event} <- SkillStore.prepare_group_delete(ctx, skill_id) do
      {Jason.encode!(%{"skill_id" => skill_id, "deleted" => true}), [event]}
    else
      {:error, :not_found} -> raise "skill not found"
      {:error, reason} -> raise error_message(reason)
    end
  end

  defp authorize_catalog_write(ctx, event_type) do
    SalixAgent.StorageAuthorization.authorize_write(%{
      agent_id: ctx[:agent_id] || ctx["agent_id"],
      events: [%{"type" => event_type}],
      billing_context: ctx[:billing_context] || ctx["billing_context"] || %{},
      entrypoint: "storage_write",
      actor_type: "tool"
    })
  end

  # ---- helpers ----

  defp ensure_deletable(ctx, skill) do
    cond do
      skill["editable"] != true ->
        {:error, "skill is read-only"}

      skill["layer"] != "group" ->
        {:error, "only group skills can be deleted by agents"}

      to_string(skill["created_by_agent_id"] || "") !=
          to_string(ctx[:agent_id] || ctx["agent_id"] || "") ->
        {:error, "only the creating agent can delete this skill"}

      true ->
        :ok
    end
  end

  defp complete_ctx(ctx) do
    case AgentRuntimeConfig.complete_context(ctx) do
      {:ok, ctx} -> ctx
      {:error, reason} -> raise error_message(reason)
    end
  end

  defp required_arg(args, key) do
    case arg(args, key) do
      "" -> raise "#{key} is required"
      value -> value
    end
  end

  defp arg(args, key),
    do: to_string(args[key] || args[String.to_atom(key)] || "") |> String.trim()

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end
