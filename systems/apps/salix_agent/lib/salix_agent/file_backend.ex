defmodule SalixAgent.FileBackend do
  @moduledoc """
  Agent-visible file backend dispatcher.

  Normal paths are agent workspace files. `/.runtime/compaction-recovery.md` is
  a read-only runtime session file. `/.runtime/skills/...` is a skill projection
  mount backed by SkillStore. `/drive/...` is the user's Comma Drive
  (`SalixAgent.DriveMount`), whose writes are applied as the tool runs and
  return no journal event.
  """

  alias SalixAgent.{
    AgentWorkspace,
    DriveMount,
    RuntimeFiles,
    SkillProjection,
    SkillStore,
    StorageAuthorization
  }

  @type ctx :: %{required(:agent_id) => String.t(), optional(:session_id) => String.t()}

  @doc "Read a file from the agent-visible filesystem."
  @spec read(ctx(), String.t()) ::
          {:ok, binary(), boolean()} | {:error, :not_found} | {:error, term()}
  def read(ctx, path) do
    ctx = normalize_ctx(ctx)

    cond do
      SkillProjection.matches?(path) ->
        case SkillProjection.read(ctx, path) do
          {:ok, body} -> {:ok, body, false}
          other -> other
        end

      RuntimeFiles.matches?(path) ->
        case RuntimeFiles.read(ctx, path) do
          {:ok, body} -> {:ok, body, false}
          other -> other
        end

      DriveMount.matches?(path) ->
        DriveMount.read(ctx, path)

      true ->
        case AgentWorkspace.read(ctx_agent_id(ctx), path) do
          {:ok, body} -> {:ok, body, false}
          other -> other
        end
    end
  end

  @doc "Stream a file from the agent-visible filesystem."
  @spec stream(ctx(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer()} | {:error, :not_found} | {:error, term()}
  def stream(ctx, path) do
    ctx = normalize_ctx(ctx)

    cond do
      SkillProjection.matches?(path) ->
        SkillProjection.stream(ctx, path)

      RuntimeFiles.matches?(path) ->
        with {:ok, body} <- RuntimeFiles.read(ctx, path), do: {:ok, [body], byte_size(body)}

      DriveMount.matches?(path) ->
        DriveMount.stream(ctx, path)

      true ->
        AgentWorkspace.stream(ctx_agent_id(ctx), path)
    end
  end

  @doc """
  List visible file paths. The Drive mount contributes only when `prefix`
  names it (`/drive/...`): a whole-tree listing does not sweep the Drive.
  """
  @spec list(ctx(), String.t()) :: [String.t()]
  def list(ctx, prefix \\ "") do
    ctx = normalize_ctx(ctx)

    (RuntimeFiles.file_paths(ctx, prefix) ++
       SkillProjection.file_paths(ctx, prefix) ++
       DriveMount.file_paths(ctx, prefix) ++
       AgentWorkspace.list(ctx_agent_id(ctx), prefix))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Stat a visible file path."
  @spec stat(ctx(), String.t()) :: {:ok, map()} | {:error, :not_found} | {:error, term()}
  def stat(ctx, path) do
    ctx = normalize_ctx(ctx)

    cond do
      SkillProjection.matches?(path) ->
        SkillProjection.stat(ctx, path)

      RuntimeFiles.matches?(path) ->
        RuntimeFiles.stat(ctx, path)

      DriveMount.matches?(path) ->
        DriveMount.stat(ctx, path)

      true ->
        AgentWorkspace.stat(ctx_agent_id(ctx), path)
    end
  end

  @doc "Prepare a write event for the correct backend."
  @spec prepare_write(ctx(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def prepare_write(ctx, path, content) when is_binary(content) do
    ctx = normalize_ctx(ctx)

    cond do
      SkillProjection.matches?(path) ->
        with :ok <- authorize_skill_write(ctx, path, "skill_file_write"),
             {:ok, skill, rel_path, _entry} <- SkillProjection.resolve_file(ctx, path) do
          SkillStore.prepare_file_write(ctx, skill, rel_path, content)
        end

      RuntimeFiles.matches?(path) ->
        {:error, "#{RuntimeFiles.prefix()} is read-only"}

      DriveMount.matches?(path) ->
        DriveMount.prepare_write(ctx, path, content)

      true ->
        StorageAuthorization.prepare_write(ctx_agent_id(ctx), path, content, ctx)
    end
  end

  @doc "Prepare a streaming write event for the correct backend."
  @spec prepare_write_stream(ctx(), String.t(), Enumerable.t()) :: {:ok, map()} | {:error, term()}
  def prepare_write_stream(ctx, path, stream) do
    ctx = normalize_ctx(ctx)

    cond do
      SkillProjection.matches?(path) ->
        with :ok <- authorize_skill_write(ctx, path, "skill_file_write"),
             {:ok, skill, rel_path, _entry} <- SkillProjection.resolve_file(ctx, path) do
          SkillStore.prepare_file_write_stream(ctx, skill, rel_path, stream)
        end

      RuntimeFiles.matches?(path) ->
        {:error, "#{RuntimeFiles.prefix()} is read-only"}

      DriveMount.matches?(path) ->
        DriveMount.prepare_write_stream(ctx, path, stream)

      true ->
        StorageAuthorization.prepare_write_stream(ctx_agent_id(ctx), path, stream, ctx)
    end
  end

  @doc "Prepare a delete event for the correct backend."
  @spec prepare_delete(ctx(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_delete(ctx, path) do
    ctx = normalize_ctx(ctx)

    cond do
      SkillProjection.matches?(path) ->
        with :ok <- authorize_skill_write(ctx, path, "skill_file_delete"),
             {:ok, skill, rel_path, _entry} <- SkillProjection.resolve_file(ctx, path) do
          SkillStore.prepare_file_delete(ctx, skill, rel_path)
        end

      RuntimeFiles.matches?(path) ->
        {:error, "#{RuntimeFiles.prefix()} is read-only"}

      DriveMount.matches?(path) ->
        DriveMount.prepare_delete(ctx, path)

      true ->
        {:ok, AgentWorkspace.prepare_delete(path)}
    end
  end

  @doc "Prepare events for copying one visible path to another."
  @spec prepare_copy(ctx(), String.t(), String.t()) ::
          {:ok, [map()], non_neg_integer() | nil} | {:error, term()}
  def prepare_copy(ctx, from, to) do
    ctx = normalize_ctx(ctx)

    cond do
      normal_path?(from) and normal_path?(to) ->
        with {:ok, meta} <- AgentWorkspace.stat(ctx_agent_id(ctx), from) do
          {:ok, [AgentWorkspace.prepare_copy(from, to)], meta[:size] || meta["size"]}
        end

      true ->
        with {:ok, stream, size} <- stream(ctx, from),
             {:ok, event} <- prepare_write_stream(ctx, to, stream) do
          {:ok, journal(event), (event && event["size"]) || size}
        end
    end
  end

  @doc """
  Prepare events for moving one visible path to another. The copy is
  prepared before the delete, so a destination the Drive refuses leaves the
  source in place.
  """
  @spec prepare_move(ctx(), String.t(), String.t()) ::
          {:ok, [map()], non_neg_integer() | nil} | {:error, term()}
  def prepare_move(ctx, from, to) do
    ctx = normalize_ctx(ctx)

    with {:ok, copy_events, size} <- prepare_copy(ctx, from, to),
         {:ok, delete_event} <- prepare_delete(ctx, from) do
      {:ok, copy_events ++ journal(delete_event), size}
    end
  end

  @doc "True for ordinary workspace paths."
  @spec normal_path?(String.t()) :: boolean()
  def normal_path?(path),
    do:
      not RuntimeFiles.matches?(path) and not SkillProjection.matches?(path) and
        not DriveMount.matches?(path)

  @doc """
  The audience a visible file carries, as encoded atoms, or `nil` when it has
  none (`docs/verification.md` §8).

  Only workspace files are labelled. A skill file and a runtime session file
  are the runtime's own text rather than something a write carried into the
  workspace, so neither has a source audience to record. A Drive file is the
  user's own data with no recorded audience either; `nil` makes a read of it
  agent-private, which is the fail-closed reading.
  """
  @spec label(ctx(), String.t()) :: [String.t()] | nil
  def label(ctx, path) do
    ctx = normalize_ctx(ctx)

    if SkillProjection.matches?(path) or RuntimeFiles.matches?(path) or
         DriveMount.matches?(path) do
      nil
    else
      AgentWorkspace.label(ctx_agent_id(ctx), path)
    end
  rescue
    _ -> nil
  end

  # The Drive mount applies its change as the tool runs and returns no event.
  defp journal(nil), do: []
  defp journal(event), do: [event]

  defp normalize_ctx(ctx) when is_map(ctx) do
    case ctx_agent_id(ctx) do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        ctx

      _ ->
        raise ArgumentError, "FileBackend requires a ctx map with agent_id"
    end
  end

  defp normalize_ctx(_ctx),
    do: raise(ArgumentError, "FileBackend requires a ctx map with agent_id")

  defp ctx_agent_id(ctx), do: Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id")

  defp authorize_skill_write(ctx, path, event_type) do
    StorageAuthorization.authorize_write(%{
      agent_id: ctx_agent_id(ctx),
      events: [%{"type" => event_type, "path" => path}],
      billing_context: Map.get(ctx, :billing_context) || Map.get(ctx, "billing_context") || %{},
      entrypoint: "storage_write",
      actor_type: "tool"
    })
  end
end
