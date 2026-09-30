defmodule SalixAgent.Migrations.SkillWorkspace do
  @moduledoc """
  One-shot migration from legacy workspace-backed skills to SkillStore.

  Legacy `skill.find` treated agent workspace files under `/.salix/skills/**`
  as user skill sources. The runtime now exposes skills only through
  SkillStore-backed `/.runtime/skills/...` files, so this migration imports
  existing workspace skill roots into SkillStore and removes the imported legacy
  source files from the workspace manifest. The live runtime path does not read
  old workspace skill sources.
  """

  alias SalixAgent.{
    AgentRuntimeConfig,
    AgentWorkspace,
    SkillFrontmatter,
    SkillProjection,
    SkillStore
  }

  alias SalixStore.{Codec, Keys, S3}

  @legacy_prefix "/.salix/skills/"
  @max_retries 5

  @type counts :: %{
          migrated: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Migrate every discoverable agent workspace skill root."
  @spec run() :: {:ok, counts()} | {:error, term()}
  def run do
    {:ok, _started} = Application.ensure_all_started(:salix_store)

    with {:ok, agent_ids} <- list_agent_ids() do
      stats = Enum.reduce(agent_ids, zero_counts(), &reduce_agent/2)
      CommaLog.log("migrate_skill_workspace", stats)
      finish_run(stats)
    end
  end

  @doc "Migrate one agent workspace."
  @spec migrate_agent(String.t()) :: :migrated | :skipped | {:error, term()}
  def migrate_agent(agent_id) when is_binary(agent_id) do
    migrate_agent(agent_id, @max_retries)
  end

  defp migrate_agent(_agent_id, 0), do: {:error, :workspace_skill_migration_exhausted}

  defp migrate_agent(agent_id, retries) do
    with {:ok, state, _etag} <- read_workspace_state(agent_id),
         skill_roots <- legacy_skill_roots(state.vfs) do
      if skill_roots == [] do
        :skipped
      else
        case import_roots(agent_id, state, skill_roots) do
          {:ok, cleanup_roots, 0} ->
            case cleanup_workspace_roots(agent_id, cleanup_roots) do
              :ok -> :migrated
              {:error, :precondition_failed} -> migrate_agent(agent_id, retries - 1)
              {:error, _} = err -> err
            end

          {:ok, _cleanup_roots, failed} ->
            {:error, {:workspace_skill_import_failed, failed}}

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp import_roots(agent_id, state, roots) do
    Enum.reduce_while(roots, {:ok, [], 0}, fn root, {:ok, cleanup, failed} ->
      case import_root(agent_id, state, root) do
        :ok ->
          {:cont, {:ok, [root | cleanup], failed}}

        :already_imported ->
          {:cont, {:ok, [root | cleanup], failed}}

        {:error, reason} ->
          CommaLog.log("migrate_skill_workspace_root_failed", %{
            agent_id: agent_id,
            root: root,
            reason: inspect(reason)
          })

          {:cont, {:ok, cleanup, failed + 1}}
      end
    end)
  end

  defp import_root(agent_id, %AgentWorkspace.State{} = state, root) do
    with {:ok, ctx, scope} <- migration_context(agent_id),
         {:ok, scope_state} <- SkillStore.read_scope(scope["layer"], scope["id"]) do
      cond do
        already_imported?(scope_state, root) ->
          :already_imported

        true ->
          with {:ok, files} <- root_files(agent_id, state.vfs || %{}, root),
               {:ok, skill_md_entry} <- Map.fetch(files, "SKILL.md"),
               {:ok, skill_md} <- SkillStore.read_entry(agent_id, skill_md_entry),
               {:ok, skill_id, name} <- choose_identity(ctx, root, skill_md),
               description <- skill_description(skill_md),
               now <- System.os_time(:second),
               event <- %{
                 "type" => "skill_create",
                 "mode" => "upsert",
                 "scope" => scope,
                 "skill" => %{
                   "skill_id" => skill_id,
                   "name" => name,
                   "normalized_name" => SkillStore.normalize_name(name),
                   "description" => description,
                   "origin" => "legacy_workspace",
                   "legacy_source_path" => root,
                   "created_by_agent_id" => agent_id,
                   "editable" => true,
                   "version" => 1,
                   "created_at" => now,
                   "updated_at" => now,
                   "files" => files
                 }
               },
               operation_id <- "migrate-workspace-skill:" <> agent_id <> ":" <> path_digest(root),
               result <- %{
                 "agent_id" => agent_id,
                 "legacy_source_path" => root,
                 "skill_id" => skill_id
               },
               {:ok, _} <- SkillStore.commit_operation(operation_id, result, [event]) do
            :ok
          end
      end
    end
  end

  defp migration_context(agent_id) do
    case AgentRuntimeConfig.resolve(agent_id) do
      {:ok, %{tenant_id: tenant_id, group_id: group_id}}
      when is_binary(group_id) and group_id != "" ->
        {:ok, %{agent_id: agent_id, tenant_id: tenant_id, group_id: group_id},
         %{"layer" => "group", "id" => group_id}}

      {:ok, %{tenant_id: tenant_id}} ->
        {:ok, %{agent_id: agent_id, tenant_id: tenant_id},
         %{"layer" => "agent", "id" => agent_id}}

      {:error, _} ->
        {:ok, %{agent_id: agent_id}, %{"layer" => "agent", "id" => agent_id}}
    end
  end

  defp already_imported?(%SkillStore.State{} = state, root) do
    Enum.any?(state.skills || %{}, fn {_id, skill} ->
      skill["origin"] == "legacy_workspace" and skill["legacy_source_path"] == root
    end)
  end

  defp root_files(agent_id, vfs, root) do
    prefix = root <> "/"

    vfs
    |> Enum.filter(fn {path, _entry} -> String.starts_with?(path, prefix) end)
    |> Enum.reduce_while({:ok, %{}}, fn {path, entry}, {:ok, acc} ->
      rel_path = String.replace_prefix(path, prefix, "")

      with :ok <- validate_relative_path(rel_path),
           {:ok, normalized} <- normalize_workspace_entry(agent_id, rel_path, entry) do
        {:cont, {:ok, Map.put(acc, rel_path, normalized)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, %{"SKILL.md" => _} = files} -> {:ok, files}
      {:ok, _files} -> {:error, :missing_skill_md}
      {:error, _} = err -> err
    end
  end

  defp normalize_workspace_entry(_agent_id, rel_path, entry) when is_map(entry) do
    ref = entry["ref"] || entry[:ref]
    size = entry["size"] || entry[:size] || ref_value(ref, "size")
    hash = entry["hash"] || entry[:hash] || ref_value(ref, "hash")
    modified_at = entry["modified_at"] || entry[:modified_at] || System.os_time(:second)

    with {:ok, ref} <- normalize_ref(ref),
         {:ok, size} <- normalize_size(size),
         {:ok, hash} <- normalize_hash(hash) do
      {:ok,
       %{
         "ref" => ref,
         "size" => size,
         "hash" => hash,
         "media_type" => media_type_for(rel_path),
         "modified_at" => modified_at
       }}
    end
  end

  defp normalize_workspace_entry(_agent_id, _rel_path, _entry),
    do: {:error, :invalid_workspace_entry}

  defp normalize_ref(%{"kind" => "blob", "uuid" => uuid} = ref) when is_binary(uuid),
    do: {:ok, ref}

  defp normalize_ref(%{kind: "blob", uuid: uuid}) when is_binary(uuid) do
    {:ok, %{"kind" => "blob", "uuid" => uuid}}
  end

  defp normalize_ref(%{kind: "blob", uuid: uuid, size: size, hash: hash}) when is_binary(uuid) do
    {:ok, %{"kind" => "blob", "uuid" => uuid, "size" => size, "hash" => hash}}
  end

  defp normalize_ref(_ref), do: {:error, :invalid_blob_ref}

  defp normalize_size(size) when is_integer(size) and size >= 0, do: {:ok, size}
  defp normalize_size(_size), do: {:error, :missing_size}

  defp normalize_hash(hash) when is_binary(hash) and hash != "", do: {:ok, hash}
  defp normalize_hash(_hash), do: {:error, :missing_hash}

  defp choose_identity(ctx, root, skill_md) do
    base_id =
      root
      |> Path.basename()
      |> SkillStore.normalize_skill_id()
      |> case do
        {:ok, id} -> id
        {:error, _} -> "legacy-skill-" <> path_digest(root)
      end

    base_name =
      case SkillFrontmatter.parse(skill_md) do
        %{"name" => name} when is_binary(name) and name != "" -> name
        _ -> human_name(base_id)
      end

    choose_identity(ctx, base_id, base_name, path_digest(root), 0)
  end

  defp choose_identity(_ctx, _base_id, _base_name, _digest, 100),
    do: {:error, :skill_identity_exhausted}

  defp choose_identity(ctx, base_id, base_name, digest, n) do
    {skill_id, name} =
      if n == 0 do
        {base_id, base_name}
      else
        suffix = "#{digest}-#{n}"
        {skill_id_with_suffix(base_id, suffix), "#{base_name} (migrated #{suffix})"}
      end

    if SkillProjection.duplicate?(ctx, skill_id, name) do
      choose_identity(ctx, base_id, base_name, digest, n + 1)
    else
      {:ok, skill_id, name}
    end
  end

  defp skill_id_with_suffix(base_id, suffix) do
    suffix_bytes = byte_size(suffix)
    max_base_bytes = max(80 - suffix_bytes - 1, 1)
    trimmed_base = truncate_utf8(base_id, max_base_bytes) |> String.trim("-_")

    case SkillStore.normalize_skill_id(trimmed_base <> "-" <> suffix) do
      {:ok, skill_id} -> skill_id
      {:error, _} -> "legacy-skill-" <> suffix
    end
  end

  defp truncate_utf8(value, max_bytes) do
    value
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme

      if byte_size(next) <= max_bytes do
        {:cont, next}
      else
        {:halt, acc}
      end
    end)
  end

  defp skill_description(skill_md) do
    case SkillFrontmatter.parse(skill_md) do
      %{"description" => description} when is_binary(description) -> description
      %{"summary" => summary} when is_binary(summary) -> summary
      _ -> ""
    end
  end

  defp human_name(skill_id) do
    skill_id
    |> String.replace(["-", "_"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp cleanup_workspace_roots(_agent_id, []), do: :ok

  defp cleanup_workspace_roots(agent_id, roots) do
    with {:ok, state, etag} <- read_workspace_state(agent_id) do
      cleanup = MapSet.new(roots)

      next_vfs =
        Map.reject(state.vfs, fn {path, _entry} ->
          Enum.any?(cleanup, fn root -> path == root or String.starts_with?(path, root <> "/") end)
        end)

      if next_vfs == state.vfs do
        :ok
      else
        write_workspace_state(agent_id, %AgentWorkspace.State{state | vfs: next_vfs}, etag)
      end
    end
  end

  defp legacy_skill_roots(vfs) when is_map(vfs) do
    vfs
    |> Map.keys()
    |> Enum.filter(fn path ->
      String.starts_with?(path, @legacy_prefix) and String.ends_with?(path, "/SKILL.md")
    end)
    |> Enum.map(&String.replace_suffix(&1, "/SKILL.md", ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validate_relative_path(path) do
    cond do
      path == "" ->
        {:error, :invalid_skill_path}

      String.starts_with?(path, "/") ->
        {:error, :invalid_skill_path}

      String.contains?(path, "\\") ->
        {:error, :invalid_skill_path}

      String.split(path, "/") |> Enum.any?(&(&1 in ["", ".", ".."])) ->
        {:error, :invalid_skill_path}

      String.starts_with?(path, "SKILL.md/") ->
        {:error, :invalid_skill_path}

      true ->
        :ok
    end
  end

  defp media_type_for(path) do
    case String.downcase(Path.extname(path)) do
      ".md" -> "text/markdown"
      ".txt" -> "text/plain"
      ".json" -> "application/json"
      ".js" -> "text/javascript"
      ".ts" -> "text/typescript"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      _ -> "application/octet-stream"
    end
  end

  defp ref_value(%{} = ref, key), do: ref[key] || ref[String.to_atom(key)]
  defp ref_value(_ref, _key), do: nil

  defp path_digest(path) do
    :crypto.hash(:sha256, path)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 8)
    |> String.downcase()
  end

  defp read_workspace_state(agent_id) do
    case S3.get(Keys.agent_workspace_state(agent_id)) do
      {:ok, %{body: body, etag: etag}} ->
        {:ok, normalize_workspace_state(agent_id, Codec.decode_snapshot(body)), etag}

      {:error, :not_found} ->
        {:ok, %AgentWorkspace.State{agent_id: agent_id}, nil}

      {:error, _} = err ->
        err
    end
  end

  defp write_workspace_state(_agent_id, %AgentWorkspace.State{} = _state, nil), do: :ok

  defp write_workspace_state(_agent_id, %AgentWorkspace.State{} = state, etag) do
    body = Codec.encode_snapshot(state)

    case S3.put(Keys.agent_workspace_state(state.agent_id), body, if_match: etag) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp normalize_workspace_state(agent_id, %AgentWorkspace.State{} = state) do
    %AgentWorkspace.State{
      state
      | agent_id: state.agent_id || agent_id,
        vfs: state.vfs || %{},
        operations: state.operations || %{}
    }
  end

  defp normalize_workspace_state(agent_id, state) when is_map(state) do
    %AgentWorkspace.State{
      agent_id: Map.get(state, :agent_id) || Map.get(state, "agent_id") || agent_id,
      vfs: Map.get(state, :vfs) || Map.get(state, "vfs") || %{},
      operations: Map.get(state, :operations) || Map.get(state, "operations") || %{}
    }
  end

  defp normalize_workspace_state(agent_id, _state), do: %AgentWorkspace.State{agent_id: agent_id}

  defp list_agent_ids do
    with {:ok, registered_ids} <- list_registered_agent_ids(),
         {:ok, workspace_ids} <- list_workspace_agent_ids() do
      ids =
        registered_ids
        |> MapSet.new()
        |> MapSet.union(MapSet.new(workspace_ids))
        |> MapSet.to_list()
        |> Enum.sort()

      {:ok, ids}
    end
  end

  defp list_registered_agent_ids do
    prefix = Keys.ctl_agents_prefix()

    case S3.list_all(prefix) do
      {:ok, objects} ->
        ids =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn key ->
            key
            |> String.replace_prefix(prefix, "")
            |> String.replace_suffix(".json", "")
          end)
          |> Enum.reject(&(&1 == ""))

        {:ok, ids}

      {:error, reason} ->
        {:error, {:list_agents_failed, reason}}
    end
  end

  defp list_workspace_agent_ids do
    prefix = Keys.agents_prefix()
    suffix = Keys.agent_workspace_state_suffix()

    case S3.list_all(prefix) do
      {:ok, objects} ->
        ids =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, suffix)))
          |> Enum.map(fn key ->
            key
            |> String.replace_prefix(prefix, "")
            |> String.replace_suffix(suffix, "")
          end)
          |> Enum.reject(&(&1 == "" or String.contains?(&1, "/")))

        {:ok, ids}

      {:error, reason} ->
        {:error, {:list_workspaces_failed, reason}}
    end
  end

  defp zero_counts, do: %{migrated: 0, skipped: 0, failed: 0}

  defp finish_run(%{failed: 0} = stats), do: {:ok, stats}
  defp finish_run(stats), do: {:error, {:agent_migrations_failed, stats}}

  defp reduce_agent(agent_id, acc) do
    case migrate_agent(agent_id) do
      :migrated ->
        %{acc | migrated: acc.migrated + 1}

      :skipped ->
        %{acc | skipped: acc.skipped + 1}

      {:error, reason} ->
        CommaLog.log("migrate_skill_workspace_agent_failed", %{
          agent_id: agent_id,
          reason: inspect(reason)
        })

        %{acc | failed: acc.failed + 1}
    end
  end
end
