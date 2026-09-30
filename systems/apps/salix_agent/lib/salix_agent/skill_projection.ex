defmodule SalixAgent.SkillProjection do
  @moduledoc """
  Session skill projection and `/.runtime/skills` virtual tree.
  """

  alias SalixAgent.{AgentRuntimeConfig, BuiltinSkills, SkillStore}

  @runtime_prefix "/.runtime/skills"
  @index_path @runtime_prefix <> "/index.md"
  @cache_table :salix_agent_skill_projection_cache
  @cache_ttl_ms 60_000

  @doc false
  def create_table do
    :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
  end

  @type ctx :: map()
  @type projection :: %{
          required(:revision) => String.t(),
          required(:skills) => [map()],
          required(:paths) => map()
        }

  @doc "Runtime path prefix for skills."
  @spec prefix() :: String.t()
  def prefix, do: @runtime_prefix

  @doc "True when a path is in the skill runtime mount."
  @spec matches?(term()) :: boolean()
  def matches?(path) when is_binary(path) do
    path = clean(path)
    path == @runtime_prefix or String.starts_with?(path, @runtime_prefix <> "/")
  end

  def matches?(_path), do: false

  @doc "Build the session-visible skill projection."
  @spec materialize(ctx()) :: {:ok, projection()} | {:error, term()}
  def materialize(ctx) when is_map(ctx) do
    with {:ok, ctx} <- AgentRuntimeConfig.complete_context(ctx) do
      case lookup_cache(ctx) do
        {:ok, projection} ->
          {:ok, projection}

        :miss ->
          scopes = SkillStore.projection_scopes(ctx)

          with {:ok, states} <- read_scopes(scopes),
               {:ok, projection} <- build_projection(states, ctx) do
            store_cache(ctx, projection)
            {:ok, projection}
          end
      end
    end
  end

  @doc false
  @spec prepare_materialization(ctx()) ::
          {:ok, {:cached, projection()} | {:states, [SkillStore.State.t()]}} | {:error, term()}
  def prepare_materialization(ctx) when is_map(ctx) do
    case lookup_cache(ctx) do
      {:ok, projection} ->
        {:ok, {:cached, projection}}

      :miss ->
        with {:ok, states} <- ctx |> SkillStore.projection_scopes() |> read_scopes() do
          {:ok, {:states, states}}
        end
    end
  end

  @doc false
  @spec finish_materialization(
          {:cached, projection()} | {:states, [SkillStore.State.t()]},
          ctx()
        ) :: {:ok, projection()} | {:error, term()}
  def finish_materialization({:cached, _projection}, ctx) when is_map(ctx) do
    case lookup_cache(ctx) do
      {:ok, current} ->
        {:ok, current}

      :miss ->
        with {:ok, states} <- ctx |> SkillStore.projection_scopes() |> read_scopes() do
          finish_materialization({:states, states}, ctx)
        end
    end
  end

  def finish_materialization({:states, states}, ctx) when is_list(states) and is_map(ctx) do
    with {:ok, projection} <- build_projection(states, ctx) do
      store_cache(ctx, projection)
      {:ok, projection}
    end
  end

  @doc "Drop cached projections after any committed skill catalog or file change."
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    table = cache_table()
    :ets.delete_all_objects(table)
    :ok
  end

  @doc "Return a compact revision string for prompt snapshot invalidation."
  @spec revision(ctx()) :: {:ok, String.t()} | {:error, term()}
  def revision(ctx) do
    with {:ok, projection} <- materialize(ctx), do: {:ok, projection.revision}
  end

  @doc "Render the prompt skill section from the same projection used by runtime files."
  @spec prompt_section(ctx()) :: String.t()
  def prompt_section(ctx) do
    case materialize(ctx) do
      {:ok, projection} ->
        render_prompt_section(projection.skills)

      {:error, _reason} ->
        ""
    end
  end

  @doc false
  @spec render_prompt_section([map()]) :: String.t()
  def render_prompt_section([]), do: ""

  def render_prompt_section(skills) when is_list(skills) do
    regular = Enum.reject(skills, &(&1["activation"] == "per-message"))
    render_regular_prompt_section(regular)
  end

  defp render_regular_prompt_section([]), do: ""

  defp render_regular_prompt_section(skills) do
    [
      "Available skills are exposed as session runtime files. Read a skill before applying it.",
      "",
      "Skill index: #{@index_path}",
      "",
      skills
      |> Enum.map(fn skill ->
        [
          "- #{skill["name"]} (#{skill["skill_id"]})",
          "  description: #{skill["description"]}",
          "  location: #{skill_path(skill["skill_id"], "SKILL.md")}"
        ]
        |> Enum.join("\n")
      end)
      |> Enum.join("\n")
    ]
    |> Enum.join("\n")
  end

  @doc "Return all virtual file paths visible under a prefix."
  @spec file_paths(ctx(), String.t()) :: [String.t()]
  def file_paths(ctx, prefix \\ "") do
    with {:ok, projection} <- materialize(ctx) do
      projection.paths
      |> Map.keys()
      |> Enum.filter(&overlap_or_under?(&1, prefix))
      |> Enum.sort()
    else
      _ -> []
    end
  end

  @doc "Read a virtual skill path."
  @spec read(ctx(), String.t()) :: {:ok, binary()} | {:error, :not_found} | {:error, term()}
  def read(ctx, path) do
    with {:ok, projection} <- materialize(ctx),
         {:ok, agent_id} <- required(ctx, :agent_id) do
      path = clean(path)

      case Map.get(projection.paths, path) do
        %{"kind" => "index", "body" => body} ->
          {:ok, body}

        %{"kind" => "file", "entry" => entry} ->
          SkillStore.read_entry(agent_id, entry)

        _ ->
          {:error, :not_found}
      end
    end
  end

  @doc "Stream a virtual skill path."
  @spec stream(ctx(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer()} | {:error, :not_found} | {:error, term()}
  def stream(ctx, path) do
    with {:ok, projection} <- materialize(ctx),
         {:ok, agent_id} <- required(ctx, :agent_id) do
      path = clean(path)

      case Map.get(projection.paths, path) do
        %{"kind" => "index", "body" => body} ->
          {:ok, [body], byte_size(body)}

        %{"kind" => "file", "entry" => entry} ->
          SkillStore.stream_entry(agent_id, entry)

        _ ->
          {:error, :not_found}
      end
    end
  end

  @doc "Stat a virtual skill path."
  @spec stat(ctx(), String.t()) :: {:ok, map()} | {:error, :not_found} | {:error, term()}
  def stat(ctx, path) do
    with {:ok, projection} <- materialize(ctx) do
      path = clean(path)

      cond do
        path == @runtime_prefix ->
          {:ok, %{kind: "dir", size: 0}}

        Map.has_key?(projection.paths, path) ->
          case Map.fetch!(projection.paths, path) do
            %{"kind" => "index", "body" => body} ->
              {:ok, %{kind: "file", size: byte_size(body)}}

            %{"kind" => "file", "entry" => entry, "skill" => skill} ->
              {:ok,
               %{
                 kind: "file",
                 size: entry["size"],
                 hash: entry["hash"],
                 media_type: entry["media_type"],
                 modified_at: entry["modified_at"],
                 skill_id: skill["skill_id"],
                 editable: skill["editable"] == true
               }}
          end

        directory?(projection, path) ->
          {:ok, %{kind: "dir", size: 0}}

        true ->
          {:error, :not_found}
      end
    end
  end

  @doc "Resolve a concrete runtime skill file to projection metadata."
  @spec resolve_file(ctx(), String.t()) :: {:ok, map(), String.t(), map()} | {:error, term()}
  def resolve_file(ctx, path) do
    with {:ok, projection} <- materialize(ctx) do
      path = clean(path)

      case Map.get(projection.paths, path) do
        %{"kind" => "file", "skill" => skill, "rel_path" => rel_path, "entry" => entry} ->
          {:ok, skill, rel_path, entry}

        %{"kind" => "index"} ->
          {:error, "skill index is read-only"}

        _ ->
          case parse_skill_path(path) do
            {:ok, skill_id, rel_path} ->
              case Enum.find(projection.skills, &(&1["skill_id"] == skill_id)) do
                nil -> {:error, :not_found}
                skill -> {:ok, skill, rel_path, nil}
              end

            :error ->
              {:error, :not_found}
          end
      end
    end
  end

  @doc "Check whether the current projection already contains a skill id or name."
  @spec duplicate?(ctx(), String.t(), String.t()) :: boolean()
  def duplicate?(ctx, skill_id, name) do
    normalized_id =
      case SkillStore.normalize_skill_id(skill_id) do
        {:ok, id} -> id
        _ -> to_string(skill_id)
      end

    normalized_name = SkillStore.normalize_name(name)

    case materialize(ctx) do
      {:ok, projection} ->
        Enum.any?(projection.skills, fn skill ->
          skill["skill_id"] == normalized_id or
            SkillStore.normalize_name(skill["name"]) == normalized_name
        end)

      _ ->
        false
    end
  end

  @doc "Return a skill by id."
  @spec get_skill(ctx(), String.t()) :: {:ok, map()} | {:error, :not_found} | {:error, term()}
  def get_skill(ctx, skill_id) do
    with {:ok, projection} <- materialize(ctx) do
      case Enum.find(projection.skills, &(&1["skill_id"] == skill_id)) do
        nil -> {:error, :not_found}
        skill -> {:ok, skill}
      end
    end
  end

  @doc "Build a runtime path for a skill-relative file."
  @spec skill_path(String.t(), String.t()) :: String.t()
  def skill_path(skill_id, rel_path), do: @runtime_prefix <> "/" <> skill_id <> "/" <> rel_path

  # ---- internal ----

  defp read_scopes(scopes) do
    observability_context = SystemsObservability.Context.capture()

    scopes
    |> Task.async_stream(
      fn scope ->
        SystemsObservability.Context.run(observability_context, fn ->
          SkillStore.read_scope(scope["layer"], scope["id"])
        end)
      end,
      ordered: true,
      max_concurrency: 4,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, state}}, {:ok, acc} -> {:cont, {:ok, [state | acc]}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:skill_scope_read_failed, reason}}}
    end)
    |> case do
      {:ok, states} -> {:ok, Enum.reverse(states)}
      {:error, _} = error -> error
    end
  end

  defp without_stored_builtins(%{scope: %{"layer" => "global"}} = state) do
    %{
      state
      | skills: Map.reject(state.skills, fn {_id, skill} -> skill["origin"] == "builtin" end)
    }
  end

  defp without_stored_builtins(state), do: state

  defp build_projection(states, ctx) do
    with {:ok, builtin} <- BuiltinSkills.snapshot() do
      persisted = Enum.map(states, &without_stored_builtins/1)
      {:ok, do_build_projection([builtin | persisted], ctx)}
    end
  end

  defp do_build_projection(states, ctx) do
    {skills, _seen_ids, _seen_names} =
      states
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new(), MapSet.new()}, fn state, {skills, ids, names} ->
        state.skills
        |> Map.values()
        |> Enum.filter(&SalixAgent.PluginPolicy.visible_skill?(ctx, &1["skill_id"]))
        |> Enum.sort_by(& &1["skill_id"])
        |> Enum.reduce({skills, ids, names}, fn skill, {skills, ids, names} ->
          skill =
            skill
            |> Map.put("scope", state.scope)
            |> Map.put("layer", state.scope["layer"])

          skill_id = skill["skill_id"]
          name = SkillStore.normalize_name(skill["name"])

          if MapSet.member?(ids, skill_id) or MapSet.member?(names, name) do
            {skills, ids, names}
          else
            {[skill | skills], MapSet.put(ids, skill_id), MapSet.put(names, name)}
          end
        end)
      end)

    skills = Enum.sort_by(skills, &{layer_order(&1["layer"]), &1["skill_id"] || ""})
    index_body = render_index(skills)

    paths =
      skills
      |> Enum.reduce(%{@index_path => %{"kind" => "index", "body" => index_body}}, fn skill,
                                                                                      acc ->
        skill["files"]
        |> Enum.reduce(acc, fn {rel_path, entry}, acc ->
          Map.put(acc, skill_path(skill["skill_id"], rel_path), %{
            "kind" => "file",
            "skill" => skill,
            "rel_path" => rel_path,
            "entry" => entry
          })
        end)
      end)

    %{
      revision: projection_revision(states),
      skills: skills,
      paths: paths
    }
  end

  defp layer_order("global"), do: 0
  defp layer_order("tenant"), do: 1
  defp layer_order("group"), do: 2
  defp layer_order("agent"), do: 3
  defp layer_order(_), do: 4

  defp render_index([]) do
    """
    # Skills

    No skills are visible in this session.
    """
    |> String.trim()
  end

  defp render_index(skills) do
    [
      "# Skills",
      "",
      "This file lists skills visible to the current runtime session.",
      "",
      skills
      |> Enum.map(fn skill ->
        resource_paths =
          skill
          |> Map.get("files", %{})
          |> Map.keys()
          |> Enum.reject(&(&1 == "SKILL.md"))
          |> Enum.sort()

        [
          "## #{skill["name"]}",
          "",
          "- skill_id: #{skill["skill_id"]}",
          "- description: #{skill["description"]}",
          "- layer: #{skill["layer"]}",
          "- editable: #{skill["editable"] == true}",
          "- location: #{skill_path(skill["skill_id"], "SKILL.md")}",
          resource_paths_section(skill, resource_paths)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      end)
      |> Enum.join("\n\n")
    ]
    |> Enum.join("\n")
  end

  defp resource_paths_section(_skill, []), do: ""

  defp resource_paths_section(skill, paths) do
    [
      "- resource_paths:",
      paths
      |> Enum.map(fn path -> "  - #{skill_path(skill["skill_id"], path)}" end)
      |> Enum.join("\n")
    ]
    |> Enum.join("\n")
  end

  defp projection_revision(states) do
    states
    |> Enum.map(fn state ->
      layer = state.scope["layer"]
      id = state.scope["id"] || ""
      "#{layer}:#{id}:#{state.revision || 0}"
    end)
    |> Enum.join("|")
  end

  defp parse_skill_path(path) do
    path = clean(path)

    if String.starts_with?(path, @runtime_prefix <> "/") do
      rest = String.replace_prefix(path, @runtime_prefix <> "/", "")

      case String.split(rest, "/", parts: 2) do
        [skill_id, rel_path] when skill_id != "" and rel_path != "" -> {:ok, skill_id, rel_path}
        _ -> :error
      end
    else
      :error
    end
  end

  defp directory?(projection, path) do
    prefix = String.trim_trailing(clean(path), "/") <> "/"
    Enum.any?(Map.keys(projection.paths), &String.starts_with?(&1, prefix))
  end

  defp overlap_or_under?(_path, ""), do: true

  defp overlap_or_under?(path, prefix) do
    prefix = clean(prefix)
    path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")
  end

  defp lookup_cache(ctx) do
    with {:ok, key} <- requested_cache_key(ctx) do
      table = cache_table()

      case :ets.lookup(table, key) do
        [{^key, projection, inserted_at}] ->
          if cache_fresh?(inserted_at) do
            {:ok, projection}
          else
            :ets.delete(table, key)
            :miss
          end

        _ ->
          :miss
      end
    end
  end

  defp store_cache(ctx, projection) do
    with {:ok, key} <- materialized_cache_key(ctx, projection) do
      table = cache_table()
      now = System.monotonic_time(:millisecond)
      prune_cache(table, now)
      :ets.insert(table, {key, projection, now})
    end

    :ok
  end

  defp cache_fresh?(inserted_at) when is_integer(inserted_at),
    do: System.monotonic_time(:millisecond) - inserted_at <= @cache_ttl_ms

  defp cache_fresh?(_inserted_at), do: false

  defp prune_cache(table, now) do
    cutoff = now - @cache_ttl_ms

    :ets.foldl(
      fn
        {key, _projection, inserted_at}, :ok
        when is_integer(inserted_at) and inserted_at < cutoff ->
          :ets.delete(table, key)
          :ok

        _entry, :ok ->
          :ok
      end,
      :ok,
      table
    )
  end

  defp requested_cache_key(ctx), do: cache_key(ctx, value(ctx, :skill_projection_revision))

  defp materialized_cache_key(ctx, projection), do: cache_key(ctx, projection.revision)

  defp cache_key(ctx, revision) do
    with {:ok, tenant_id} <- required(ctx, :tenant_id),
         {:ok, group_id} <- required(ctx, :group_id),
         {:ok, agent_id} <- required(ctx, :agent_id),
         revision when is_binary(revision) and revision != "" <- revision do
      case BuiltinSkills.snapshot() do
        {:ok, builtin} ->
          {:ok,
           {tenant_id, group_id, agent_id, revision, plugin_projection_revision(ctx),
            builtin.revision}}

        _ ->
          :miss
      end
    else
      _ -> :miss
    end
  end

  defp cache_table, do: @cache_table

  defp required(ctx, key) do
    case value(ctx, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp plugin_projection_revision(ctx) do
    cond do
      is_binary(value(ctx, :plugin_projection_revision)) ->
        value(ctx, :plugin_projection_revision)

      is_map(value(ctx, :plugin_projection)) ->
        value(value(ctx, :plugin_projection), :revision) || ""

      true ->
        ""
    end
  end

  defp clean(path), do: Path.expand(to_string(path || ""), "/")
end
