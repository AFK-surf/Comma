defmodule SalixAgent.SkillStore do
  @moduledoc """
  Durable user skill catalogs and projected skill file access.

  User skill bodies are immutable SalixStore blobs. Built-in file entries come
  from the node-local BuiltinSkills snapshot and are persisted only on copy.
  Runtime-visible `/.runtime/skills/...` paths are not physical S3 keys.
  """

  alias SalixStore.{Blob, Codec, Keys, S3}

  defmodule State do
    @moduledoc false
    defstruct schema_version: 1,
              scope: %{},
              revision: 0,
              skills: %{},
              name_index: %{},
              operations: %{}

    @type t :: %__MODULE__{
            schema_version: pos_integer(),
            scope: map(),
            revision: non_neg_integer(),
            skills: map(),
            name_index: map(),
            operations: map()
          }
  end

  @skill_event_types MapSet.new([
                       "skill_create",
                       "skill_delete",
                       "skill_control_plane_delete",
                       "skill_file_write",
                       "skill_file_delete"
                     ])
  @max_commit_retries 8
  @max_operations 1_000
  @operation_ttl_seconds 24 * 60 * 60
  @skill_id_re ~r/^[a-z0-9][a-z0-9_-]{0,79}$/

  @type scope :: map()
  @type ctx :: map()

  @doc "Return true when an event mutates skill catalog state."
  @spec skill_event?(map()) :: boolean()
  def skill_event?(event) when is_map(event) do
    type = event["type"] || event[:type]
    MapSet.member?(@skill_event_types, type)
  end

  def skill_event?(_event), do: false

  @doc "Read a skill scope catalog. Missing scopes are empty catalogs."
  @spec read_scope(String.t() | atom(), String.t() | nil) :: {:ok, State.t()} | {:error, term()}
  def read_scope(layer, id \\ nil) do
    scope = normalize_scope(layer, id)

    case S3.get(scope_key(scope)) do
      {:ok, %{body: body}} -> {:ok, normalize_state(scope, Codec.decode_snapshot(body))}
      {:error, :not_found} -> {:ok, %State{scope: scope}}
      {:error, _} = err -> err
    end
  end

  @doc "Build the ordered scopes that participate in a session projection."
  @spec projection_scopes(ctx()) :: [scope()]
  def projection_scopes(ctx) when is_map(ctx) do
    [
      normalize_scope(:global, nil),
      maybe_scope(:tenant, value(ctx, :tenant_id)),
      maybe_scope(:group, value(ctx, :group_id)),
      maybe_scope(:agent, value(ctx, :agent_id))
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Create a group-level skill event after validating local identifiers."
  @spec prepare_group_create(ctx(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_group_create(ctx, attrs) when is_map(attrs) do
    with {:ok, group_id} <- required(ctx, :group_id),
         {:ok, agent_id} <- required(ctx, :agent_id),
         {:ok, skill_id} <- normalize_skill_id(attrs["skill_id"] || attrs[:skill_id]),
         {:ok, name} <- required_attr(attrs, "name"),
         {:ok, _} <- validate_relative_path("SKILL.md"),
         description <- string(attrs["description"] || attrs[:description]),
         content <- skill_content(name, description, attrs["content"] || attrs[:content]),
         {:ok, metadata} <-
           SalixAgent.SkillFrontmatter.metadata(content, %{
             "name" => name,
             "description" => description
           }),
         {:ok, entry} <- blob_entry(agent_id, "SKILL.md", content, media_type_for("SKILL.md")) do
      now = System.os_time(:second)
      name = if metadata["activation"] == "per-message", do: string(metadata["name"]), else: name

      description =
        if metadata["activation"] == "per-message",
          do: string(metadata["description"]),
          else: description

      {:ok,
       %{
         "type" => "skill_create",
         "scope" => %{"layer" => "group", "id" => group_id},
         "skill" => %{
           "skill_id" => skill_id,
           "name" => name,
           "normalized_name" => normalize_name(name),
           "description" => description,
           "activation" => metadata["activation"],
           "origin" => "agent_created",
           "created_by_agent_id" => agent_id,
           "editable" => true,
           "version" => 1,
           "created_at" => now,
           "updated_at" => now,
           "files" => %{"SKILL.md" => entry}
         }
       }}
    end
  end

  @doc "Delete a skill from the group layer."
  @spec prepare_group_delete(ctx(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_group_delete(ctx, skill_id) do
    with {:ok, group_id} <- required(ctx, :group_id),
         {:ok, agent_id} <- required(ctx, :agent_id),
         {:ok, skill_id} <- normalize_skill_id(skill_id) do
      {:ok,
       %{
         "type" => "skill_delete",
         "scope" => %{"layer" => "group", "id" => group_id},
         "created_by_agent_id" => agent_id,
         "skill_id" => skill_id
       }}
    end
  end

  @doc "Delete a group skill as an authenticated human control-plane actor."
  @spec prepare_group_control_plane_delete(ctx(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def prepare_group_control_plane_delete(ctx, skill_id, actor) when is_map(actor) do
    with {:ok, group_id} <- required(ctx, :group_id),
         {:ok, agent_id} <- required(ctx, :agent_id),
         {:ok, skill_id} <- normalize_skill_id(skill_id),
         {:ok, actor} <- normalize_control_plane_actor(actor) do
      {:ok,
       %{
         "type" => "skill_control_plane_delete",
         "scope" => %{"layer" => "group", "id" => group_id},
         "requested_via_agent_id" => agent_id,
         "actor" => actor,
         "skill_id" => skill_id
       }}
    end
  end

  def prepare_group_control_plane_delete(_ctx, _skill_id, _actor),
    do: {:error, "control-plane actor is required"}

  @doc "Copy a projected skill into a new group-level editable skill."
  @spec prepare_group_copy(ctx(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_group_copy(ctx, source_skill, attrs) when is_map(source_skill) and is_map(attrs) do
    with {:ok, group_id} <- required(ctx, :group_id),
         {:ok, agent_id} <- required(ctx, :agent_id),
         {:ok, skill_id} <- normalize_skill_id(attrs["skill_id"] || attrs[:skill_id]),
         name <- copy_name(source_skill, attrs),
         {:ok, name} <- require_non_empty("name", name),
         {:ok, files} <- copy_files(agent_id, source_skill["files"] || %{}) do
      now = System.os_time(:second)

      # Stored files share immutable blobs. Local built-ins become durable
      # blobs only when the agent copies the skill.
      {:ok,
       %{
         "type" => "skill_create",
         "scope" => %{"layer" => "group", "id" => group_id},
         "skill" => %{
           "skill_id" => skill_id,
           "name" => name,
           "activation" => source_skill["activation"] || "regular",
           "normalized_name" => normalize_name(name),
           "description" =>
             string(attrs["description"] || attrs[:description] || source_skill["description"]),
           "origin" => "agent_created",
           "created_by_agent_id" => agent_id,
           "editable" => true,
           "version" => 1,
           "created_at" => now,
           "updated_at" => now,
           "files" => files
         }
       }}
    end
  end

  @doc "Prepare writing a runtime skill file."
  @spec prepare_file_write(ctx(), map(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def prepare_file_write(ctx, skill, rel_path, content)
      when is_map(skill) and is_binary(content) do
    with :ok <- ensure_mutable(ctx, skill),
         {:ok, rel_path} <- validate_relative_path(rel_path),
         scope <- skill_scope(skill),
         {:ok, agent_id} <- required(ctx, :agent_id),
         :ok <- validate_miniskill_file(skill, rel_path, content),
         {:ok, entry} <- blob_entry(agent_id, rel_path, content, media_type_for(rel_path)) do
      {:ok, file_write_event(scope, skill, rel_path, agent_id, entry, content)}
    end
  end

  @doc "Prepare writing a streamed runtime skill file."
  @spec prepare_file_write_stream(ctx(), map(), String.t(), Enumerable.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_file_write_stream(ctx, skill, rel_path, stream) when is_map(skill) do
    with :ok <- ensure_mutable(ctx, skill),
         {:ok, rel_path} <- validate_relative_path(rel_path),
         scope <- skill_scope(skill),
         {:ok, agent_id} <- required(ctx, :agent_id) do
      prepare_streamed_file_write(scope, skill, rel_path, agent_id, stream)
    end
  end

  @doc "Prepare deleting a runtime skill file."
  @spec prepare_file_delete(ctx(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_file_delete(ctx, skill, rel_path) when is_map(skill) do
    with :ok <- ensure_mutable(ctx, skill),
         {:ok, rel_path} <- validate_relative_path(rel_path),
         {:ok, agent_id} <- required(ctx, :agent_id),
         true <- rel_path != "SKILL.md" or {:error, "cannot delete SKILL.md; delete the skill"} do
      {:ok,
       %{
         "type" => "skill_file_delete",
         "scope" => skill_scope(skill),
         "skill_id" => skill["skill_id"],
         "created_by_agent_id" => agent_id,
         "path" => rel_path
       }}
    end
  end

  @doc "Commit skill catalog events behind an idempotent operation id."
  @spec commit_operation(String.t(), term(), [map()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def commit_operation(operation_id, result, events, opts \\ [])

  def commit_operation(operation_id, result, events, opts)
      when is_binary(operation_id) and operation_id != "" and is_list(events) do
    result =
      try do
        events
        |> Enum.group_by(&normalize_scope_from_event!/1)
        |> Enum.reduce_while({:ok, result}, fn {scope, scope_events}, {:ok, _} ->
          scoped_operation_id =
            operation_id <> ":" <> scope["layer"] <> ":" <> to_string(scope["id"] || "")

          case do_commit_operation(
                 scope,
                 scoped_operation_id,
                 result,
                 scope_events,
                 opts,
                 @max_commit_retries
               ) do
            {:ok, result} -> {:cont, {:ok, result}}
            {:error, _} = err -> {:halt, err}
          end
        end)
      rescue
        exception -> {:error, {exception.__struct__, Exception.message(exception)}}
      end

    invalidate_projection_cache()
    result
  end

  def commit_operation(_operation_id, _result, _events, _opts),
    do: {:error, :invalid_operation_id}

  defp invalidate_projection_cache do
    SalixAgent.SkillProjection.invalidate_cache()
  rescue
    _exception -> :ok
  end

  @doc "Read a local built-in file or a stored skill blob."
  @spec read_entry(String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def read_entry(_agent_id, %{"local_path" => path}), do: File.read(path)
  def read_entry(agent_id, %{"ref" => ref}), do: Blob.get(agent_id, ref)
  def read_entry(agent_id, %{ref: ref}), do: Blob.get(agent_id, ref)
  def read_entry(_agent_id, _entry), do: {:error, :not_found}

  @doc "Stream a local built-in file or a stored skill blob."
  @spec stream_entry(String.t(), map()) ::
          {:ok, Enumerable.t(), non_neg_integer()} | {:error, term()}
  def stream_entry(_agent_id, %{"local_path" => path}) do
    with {:ok, stat} <- File.stat(path) do
      {:ok, File.stream!(path, 64 * 1024), stat.size}
    end
  end

  def stream_entry(agent_id, %{"ref" => ref}), do: Blob.stream(agent_id, ref)
  def stream_entry(agent_id, %{ref: ref}), do: Blob.stream(agent_id, ref)
  def stream_entry(_agent_id, _entry), do: {:error, :not_found}

  @doc false
  def normalize_skill_id(raw) do
    skill_id =
      raw
      |> string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-_")

    cond do
      skill_id == "" -> {:error, "skill_id is required"}
      skill_id in ["index", "index.md"] -> {:error, "reserved skill_id"}
      Regex.match?(@skill_id_re, skill_id) -> {:ok, skill_id}
      true -> {:error, "invalid skill_id"}
    end
  end

  @doc false
  def normalize_name(value), do: value |> string() |> String.downcase() |> String.trim()

  # ---- internal ----

  defp do_commit_operation(_scope, _operation_id, _result, _events, _opts, 0),
    do: {:error, :stale_skill_scope}

  defp do_commit_operation(scope, operation_id, result, events, opts, retries) do
    with {:ok, state, etag} <- read_state_for_update(scope) do
      case Map.fetch(state.operations, operation_id) do
        {:ok, committed} ->
          {:ok, committed["result"]}

        :error ->
          now = opts[:committed_at] || System.os_time(:second)

          record = %{
            "operation_id" => operation_id,
            "result" => result,
            "event_count" => length(events),
            "committed_at" => now
          }

          with {:ok, validated_state} <- validate_events(state, events) do
            next_state =
              validated_state
              |> put_operation(operation_id, record, now)

            case write_state(scope, next_state, etag) do
              :ok ->
                {:ok, result}

              {:error, :precondition_failed} ->
                do_commit_operation(scope, operation_id, result, events, opts, retries - 1)

              {:error, _} = err ->
                err
            end
          end
      end
    end
  end

  defp read_state_for_update(scope) do
    case S3.get(scope_key(scope)) do
      {:ok, %{body: body, etag: etag}} ->
        {:ok, normalize_state(scope, Codec.decode_snapshot(body)), etag}

      {:error, :not_found} ->
        {:ok, %State{scope: scope}, nil}

      {:error, _} = err ->
        err
    end
  end

  defp write_state(scope, %State{} = state, nil) do
    body = Codec.encode_snapshot(state)

    case S3.put(scope_key(scope), body, if_none_match: "*") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp write_state(scope, %State{} = state, etag) do
    body = Codec.encode_snapshot(state)

    case S3.put(scope_key(scope), body, if_match: etag) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp apply_skill_event(%{"type" => "skill_create", "skill" => skill}, %State{} = state) do
    skill = normalize_skill_record(skill)
    skill_id = skill["skill_id"]
    normalized_name = skill["normalized_name"]
    old_skill = Map.get(state.skills, skill_id)

    name_index =
      if old_skill do
        Map.delete(state.name_index, old_skill["normalized_name"])
      else
        state.name_index
      end

    %State{
      state
      | revision: state.revision + 1,
        skills: Map.put(state.skills, skill_id, skill),
        name_index: Map.put(name_index, normalized_name, skill_id)
    }
  end

  defp apply_skill_event(%{"type" => type, "skill_id" => skill_id}, %State{} = state)
       when type in ["skill_delete", "skill_control_plane_delete"] do
    skill = Map.get(state.skills, skill_id)
    normalized_name = skill && skill["normalized_name"]

    %State{
      state
      | revision: state.revision + 1,
        skills: Map.delete(state.skills, skill_id),
        name_index:
          if(normalized_name,
            do: Map.delete(state.name_index, normalized_name),
            else: state.name_index
          )
    }
  end

  defp apply_skill_event(
         %{
           "type" => "skill_file_write",
           "skill_id" => skill_id,
           "path" => path,
           "entry" => entry
         } = event,
         %State{} = state
       ) do
    update_skill(state, skill_id, fn skill ->
      now = System.os_time(:second)
      files = Map.put(skill["files"] || %{}, path, normalize_file_entry(entry))

      skill
      |> Map.put("files", files)
      |> Map.put("updated_at", now)
      |> Map.update("version", 1, &((&1 || 0) + 1))
      |> refresh_skill_md_metadata(path, event["skill_md_metadata"])
    end)
  end

  defp apply_skill_event(
         %{"type" => "skill_file_delete", "skill_id" => skill_id, "path" => path},
         %State{} = state
       ) do
    update_skill(state, skill_id, fn skill ->
      now = System.os_time(:second)

      skill
      |> Map.put("files", Map.delete(skill["files"] || %{}, path))
      |> Map.put("updated_at", now)
      |> Map.update("version", 1, &((&1 || 0) + 1))
    end)
  end

  defp apply_skill_event(_event, %State{} = state), do: state

  defp update_skill(%State{} = state, skill_id, fun) do
    case Map.get(state.skills, skill_id) do
      nil ->
        state

      skill ->
        next = fun.(skill)

        %State{
          state
          | revision: state.revision + 1,
            skills: Map.put(state.skills, skill_id, next),
            name_index:
              state.name_index
              |> Map.delete(skill["normalized_name"])
              |> Map.put(next["normalized_name"], skill_id)
        }
    end
  end

  defp refresh_skill_md_metadata(skill, "SKILL.md", metadata) when is_map(metadata) do
    skill
    |> maybe_put_metadata("name", metadata["name"])
    |> maybe_put_metadata("description", metadata["description"])
    |> Map.put("activation", metadata["activation"] || "regular")
    |> then(fn skill -> Map.put(skill, "normalized_name", normalize_name(skill["name"])) end)
  end

  defp refresh_skill_md_metadata(skill, _path, _entry), do: skill

  defp maybe_put_metadata(skill, _key, value) when value in [nil, ""], do: skill
  defp maybe_put_metadata(skill, key, value), do: Map.put(skill, key, string(value))

  defp put_operation(%State{} = state, operation_id, record, now) do
    cutoff = now - @operation_ttl_seconds

    operations =
      state.operations
      |> Map.put(operation_id, record)
      |> Enum.filter(fn {_id, rec} -> (rec["committed_at"] || 0) >= cutoff end)
      |> Enum.sort_by(fn {_id, rec} -> rec["committed_at"] || 0 end, :desc)
      |> Enum.take(@max_operations)
      |> Map.new()

    %State{state | operations: operations}
  end

  defp validate_events(%State{} = state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, current} ->
      case validate_event(current, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_event(%State{} = state, %{"type" => "skill_create", "skill" => skill} = event) do
    skill = normalize_skill_record(skill)
    skill_id = skill["skill_id"]
    normalized_name = skill["normalized_name"]
    upsert? = event["mode"] == "upsert"

    existing_by_id = Map.get(state.skills, skill_id)
    existing_by_name = Map.get(state.name_index, normalized_name)

    cond do
      existing_by_id == nil and existing_by_name == nil ->
        {:ok, apply_skill_event(event, state)}

      upsert? and existing_by_id != nil and existing_by_name in [nil, skill_id] ->
        {:ok, apply_skill_event(event, state)}

      existing_by_id != nil ->
        {:error, "skill_id already exists in this scope"}

      true ->
        {:error, "skill name already exists in this scope"}
    end
  end

  defp validate_event(%State{} = state, %{"type" => "skill_file_write"} = event) do
    validate_mutating_file_event(state, event)
    |> case do
      :ok -> {:ok, apply_skill_event(event, state)}
      {:error, _} = err -> err
    end
  end

  defp validate_event(%State{} = state, %{"type" => "skill_file_delete"} = event) do
    validate_mutating_file_event(state, event)
    |> case do
      :ok -> {:ok, apply_skill_event(event, state)}
      {:error, _} = err -> err
    end
  end

  defp validate_event(%State{} = state, %{"type" => "skill_delete"} = event) do
    skill_id = string(event["skill_id"] || event[:skill_id])
    actor_agent_id = string(event["created_by_agent_id"] || event[:created_by_agent_id])

    case Map.get(state.skills, skill_id) do
      nil ->
        {:error, "skill not found"}

      %{"editable" => true, "created_by_agent_id" => ^actor_agent_id} ->
        {:ok, apply_skill_event(event, state)}

      %{"editable" => true} ->
        {:error, "only the creating agent can delete this skill"}

      _ ->
        {:error, "skill is read-only"}
    end
  end

  defp validate_event(
         %State{} = state,
         %{"type" => "skill_control_plane_delete"} = event
       ) do
    skill_id = string(event["skill_id"] || event[:skill_id])

    case Map.get(state.skills, skill_id) do
      nil ->
        {:error, "skill not found"}

      %{"editable" => true} ->
        with {:ok, _actor} <- normalize_control_plane_actor(event["actor"] || event[:actor]) do
          {:ok, apply_skill_event(event, state)}
        end

      _ ->
        {:error, "skill is read-only"}
    end
  end

  defp validate_event(%State{} = state, event), do: {:ok, apply_skill_event(event, state)}

  defp validate_mutating_file_event(%State{} = state, event) do
    skill_id = string(event["skill_id"] || event[:skill_id])
    actor_agent_id = string(event["created_by_agent_id"] || event[:created_by_agent_id])

    case Map.get(state.skills, skill_id) do
      nil ->
        {:error, "skill not found"}

      %{"editable" => true, "created_by_agent_id" => ^actor_agent_id} = skill ->
        validate_skill_md_metadata_change(state, event, skill)

      %{"editable" => true} ->
        {:error, "only the creating agent can modify this skill"}

      _ ->
        {:error, "skill is read-only"}
    end
  end

  defp validate_skill_md_metadata_change(
         %State{} = state,
         %{
           "type" => "skill_file_write",
           "path" => "SKILL.md",
           "skill_md_metadata" => metadata
         },
         skill
       )
       when is_map(metadata) do
    case string(metadata["name"]) do
      "" ->
        :ok

      name ->
        normalized_name = normalize_name(name)
        skill_id = skill["skill_id"]

        case Map.get(state.name_index, normalized_name) do
          nil -> :ok
          ^skill_id -> :ok
          _ -> {:error, "skill name already exists in this scope"}
        end
    end
  end

  defp validate_skill_md_metadata_change(
         _state,
         %{"type" => "skill_file_write", "path" => "SKILL.md"},
         _skill
       ) do
    {:error, "SKILL.md write metadata is missing"}
  end

  defp validate_skill_md_metadata_change(_state, _event, _skill), do: :ok

  defp prepare_streamed_file_write(scope, skill, "SKILL.md" = rel_path, agent_id, stream) do
    with {:ok, content} <- collect_bounded_stream(stream, Blob.max_bytes()),
         :ok <- validate_miniskill_file(skill, rel_path, content),
         {:ok, entry} <- blob_entry(agent_id, rel_path, content, media_type_for(rel_path)) do
      {:ok, file_write_event(scope, skill, rel_path, agent_id, entry, content)}
    end
  end

  defp prepare_streamed_file_write(scope, skill, rel_path, agent_id, stream) do
    with {:ok, ref} <- Blob.put_stream(agent_id, stream) do
      entry = entry_from_ref(ref, media_type_for(rel_path))
      {:ok, file_write_event(scope, skill, rel_path, agent_id, entry, nil)}
    end
  end

  defp validate_miniskill_file(skill, "SKILL.md", content) do
    defaults = Map.take(skill, ["name", "description"])

    case SalixAgent.SkillFrontmatter.metadata(content, defaults) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_miniskill_file(_, _, _), do: :ok

  defp file_write_event(scope, skill, rel_path, agent_id, entry, content) do
    %{
      "type" => "skill_file_write",
      "scope" => scope,
      "skill_id" => skill["skill_id"],
      "path" => rel_path,
      "created_by_agent_id" => agent_id,
      "entry" => entry
    }
    |> maybe_put_skill_md_metadata(rel_path, content)
  end

  defp maybe_put_skill_md_metadata(event, "SKILL.md", content) when is_binary(content) do
    frontmatter = SalixAgent.SkillFrontmatter.parse(content)

    metadata =
      %{"activation" => frontmatter["activation"] || "regular"}
      |> maybe_put_metadata("name", frontmatter["name"])
      |> maybe_put_metadata("description", frontmatter["description"] || frontmatter["summary"])

    Map.put(event, "skill_md_metadata", metadata)
  end

  defp maybe_put_skill_md_metadata(event, _rel_path, _content), do: event

  defp collect_bounded_stream(stream, max_bytes) do
    stream
    |> Enum.reduce_while({:ok, [], 0}, fn chunk, {:ok, chunks, size} ->
      chunk_size = :erlang.iolist_size(chunk)
      next_size = size + chunk_size

      if next_size > max_bytes do
        {:halt, {:error, :too_large}}
      else
        chunk = IO.iodata_to_binary(chunk)
        {:cont, {:ok, [chunk | chunks], next_size}}
      end
    end)
    |> case do
      {:ok, chunks, _size} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_state(scope, %State{} = state) do
    # The requested scope determines the physical catalog key and is the
    # authority. A snapshot's redundant scope may predate an owner-ID
    # migration and must never redirect projection or mutation events.
    %State{
      state
      | scope: normalize_scope_map(scope),
        revision: int(state.revision, 0),
        skills: normalize_skills(state.skills || %{}),
        name_index: state.name_index || %{},
        operations: state.operations || %{}
    }
  end

  defp normalize_state(scope, state) when is_map(state) do
    %State{
      schema_version: int(value(state, :schema_version), 1),
      scope: normalize_scope_map(scope),
      revision: int(value(state, :revision), 0),
      skills: normalize_skills(value(state, :skills) || %{}),
      name_index: value(state, :name_index) || %{},
      operations: value(state, :operations) || %{}
    }
  end

  defp normalize_state(scope, _state), do: %State{scope: scope}

  defp normalize_skills(skills) when is_map(skills) do
    skills
    |> Enum.map(fn {skill_id, skill} -> {to_string(skill_id), normalize_skill_record(skill)} end)
    |> Map.new()
  end

  defp normalize_skill_record(skill) when is_map(skill) do
    skill_id = string(skill["skill_id"] || skill[:skill_id])
    name = string(skill["name"] || skill[:name])

    %{
      "skill_id" => skill_id,
      "name" => name,
      "normalized_name" =>
        string(skill["normalized_name"] || skill[:normalized_name] || normalize_name(name)),
      "description" => string(skill["description"] || skill[:description]),
      "activation" => skill["activation"] || skill[:activation] || "regular",
      "origin" => string(skill["origin"] || skill[:origin] || "imported"),
      "created_by_agent_id" =>
        string(skill["created_by_agent_id"] || skill[:created_by_agent_id]),
      "legacy_source_path" => string(skill["legacy_source_path"] || skill[:legacy_source_path]),
      "editable" => truthy?(skill["editable"] || skill[:editable]),
      "version" => int(skill["version"] || skill[:version], 1),
      "created_at" => int(skill["created_at"] || skill[:created_at], 0),
      "updated_at" => int(skill["updated_at"] || skill[:updated_at], 0),
      "files" => normalize_files(skill["files"] || skill[:files] || %{})
    }
  end

  defp normalize_files(files) when is_map(files) do
    files
    |> Enum.map(fn {path, entry} -> {to_string(path), normalize_file_entry(entry)} end)
    |> Map.new()
  end

  defp normalize_files(_files), do: %{}

  defp normalize_file_entry(entry) when is_map(entry) do
    %{
      "ref" => stringify_ref(entry["ref"] || entry[:ref]),
      "size" => int(entry["size"] || entry[:size], 0),
      "hash" => string(entry["hash"] || entry[:hash]),
      "media_type" =>
        string(entry["media_type"] || entry[:media_type] || "application/octet-stream"),
      "modified_at" => int(entry["modified_at"] || entry[:modified_at], System.os_time(:second))
    }
  end

  defp normalize_file_entry(_entry), do: %{}

  defp blob_entry(agent_id, _path, content, media_type) do
    case Blob.put(agent_id, content) do
      {:ok, ref} -> {:ok, entry_from_ref(ref, media_type)}
      {:error, _} = err -> err
    end
  end

  defp copy_files(agent_id, files) do
    Enum.reduce_while(files, {:ok, %{}}, fn
      {path, %{"local_path" => _} = entry}, {:ok, acc} ->
        with {:ok, body} <- read_entry(agent_id, entry),
             {:ok, stored} <- blob_entry(agent_id, path, body, entry["media_type"]) do
          {:cont, {:ok, Map.put(acc, path, stored)}}
        else
          {:error, _} = error -> {:halt, error}
        end

      {path, entry}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, path, entry)}}
    end)
  end

  defp entry_from_ref(ref, media_type) do
    %{
      "ref" => stringify_ref(ref),
      "size" => ref.size,
      "hash" => ref.hash,
      "media_type" => media_type,
      "modified_at" => System.os_time(:second)
    }
  end

  defp stringify_ref(%{kind: kind, uuid: uuid, size: size, hash: hash}),
    do: %{"kind" => kind, "uuid" => uuid, "size" => size, "hash" => hash}

  defp stringify_ref(%{"kind" => _kind, "uuid" => _uuid} = ref), do: ref
  defp stringify_ref(ref), do: ref

  defp skill_content(name, description, nil), do: default_skill_content(name, description)
  defp skill_content(name, description, ""), do: default_skill_content(name, description)
  defp skill_content(_name, _description, content), do: to_string(content)

  defp default_skill_content(name, description) do
    [
      "---",
      "name: #{name}",
      if(description != "", do: "description: #{description}", else: nil),
      "---",
      "",
      "# #{name}",
      "",
      description
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp ensure_mutable(ctx, skill) do
    cond do
      skill["editable"] != true ->
        {:error, "skill is read-only"}

      string(skill["created_by_agent_id"]) != string(value(ctx, :agent_id)) ->
        {:error, "only the creating agent can modify this skill"}

      true ->
        :ok
    end
  end

  defp validate_relative_path(path) do
    path =
      path
      |> string()
      |> String.trim()

    cond do
      path == "" ->
        {:error, "skill file path is required"}

      path == "." ->
        {:error, "invalid skill file path"}

      String.starts_with?(path, "/") ->
        {:error, "skill file path must be relative"}

      path == "index.md" ->
        {:error, "index.md is reserved in /.runtime/skills"}

      String.length(path) > 512 ->
        {:error, "skill file path is too long"}

      String.contains?(path, "\\") ->
        {:error, "invalid skill file path"}

      String.split(path, "/") |> Enum.any?(&(&1 in ["", ".", ".."])) ->
        {:error, "invalid skill file path"}

      skill_md_directory?(path) ->
        {:error, "SKILL.md cannot be used as a directory"}

      true ->
        {:ok, path}
    end
  end

  defp skill_md_directory?(path) do
    case String.split(path, "/") do
      ["SKILL.md", _ | _] -> true
      _ -> false
    end
  end

  defp skill_scope(skill), do: normalize_scope_map(skill["scope"] || skill[:scope] || %{})

  defp normalize_scope_from_event!(event) do
    event
    |> Map.fetch!("scope")
    |> normalize_scope_map()
  end

  defp normalize_scope(layer, id) do
    case to_string(layer) do
      "global" -> %{"layer" => "global"}
      "tenant" -> %{"layer" => "tenant", "id" => string(id)}
      "group" -> %{"layer" => "group", "id" => string(id)}
      "agent" -> %{"layer" => "agent", "id" => string(id)}
    end
  end

  defp normalize_scope_map(%{layer: layer, id: id}), do: normalize_scope(layer, id)
  defp normalize_scope_map(%{"layer" => layer, "id" => id}), do: normalize_scope(layer, id)
  defp normalize_scope_map(%{"layer" => "global"}), do: normalize_scope(:global, nil)
  defp normalize_scope_map(%{layer: :global}), do: normalize_scope(:global, nil)
  defp normalize_scope_map(%{}), do: normalize_scope(:global, nil)

  defp maybe_scope(_layer, value) when value in [nil, ""], do: nil
  defp maybe_scope(layer, value), do: normalize_scope(layer, value)

  defp scope_key(%{"layer" => "global"}), do: Keys.ctl_skill_scope_global()
  defp scope_key(%{"layer" => "tenant", "id" => id}), do: Keys.ctl_skill_scope_tenant(id)
  defp scope_key(%{"layer" => "group", "id" => id}), do: Keys.ctl_skill_scope_group(id)
  defp scope_key(%{"layer" => "agent", "id" => id}), do: Keys.ctl_skill_scope_agent(id)

  defp required(ctx, key) do
    case value(ctx, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp required_attr(attrs, key) do
    case string(attrs[key] || attrs[String.to_atom(key)]) |> String.trim() do
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp normalize_control_plane_actor(actor) when is_map(actor) do
    type = string(value(actor, :type))
    user_id = string(value(actor, :user_id))
    request_id = string(value(actor, :request_id))

    cond do
      type != "user" ->
        {:error, "control-plane actor must be a user"}

      user_id == "" ->
        {:error, "control-plane actor user_id is required"}

      request_id == "" ->
        {:error, "control-plane actor request_id is required"}

      true ->
        {:ok,
         %{
           "type" => "user",
           "user_id" => user_id,
           "label" => string(value(actor, :label)),
           "request_id" => request_id
         }}
    end
  end

  defp normalize_control_plane_actor(_actor),
    do: {:error, "control-plane actor is required"}

  defp require_non_empty(key, value) do
    case string(value) do
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp copy_name(source_skill, attrs) do
    string(attrs["name"] || attrs[:name] || source_skill["name"])
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  # Catalog metadata (name, description, frontmatter refreshes) is rendered
  # into every session's prompt and must stay JSON-encodable; scope state is
  # an ETF snapshot, so invalid bytes accepted here would persist silently
  # and corrupt each prompt built from the catalog.
  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value |> SalixAgent.Utf8.scrub() |> String.trim()
  defp string(value), do: value |> to_string() |> string()

  defp int(value, _default) when is_integer(value), do: value

  defp int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp int(_value, default), do: default

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp media_type_for(path) do
    case String.downcase(Path.extname(path)) do
      ".md" -> "text/markdown"
      ".txt" -> "text/plain"
      ".json" -> "application/json"
      ".yaml" -> "application/yaml"
      ".yml" -> "application/yaml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".pdf" -> "application/pdf"
      _ -> "application/octet-stream"
    end
  end
end
