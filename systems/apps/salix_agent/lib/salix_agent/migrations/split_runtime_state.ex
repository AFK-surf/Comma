defmodule SalixAgent.Migrations.SplitRuntimeState do
  @moduledoc """
  One-shot data migration from the legacy split agent root state to the
  post-#154 runtime store layout.

  Before #154 a real agent's root object (`SalixStore.Keys.agent_state/1`) was
  persisted in *split* mode: a metadata header plus content-addressed refs to a
  VFS index object (`agents/<id>/vfs/<ref>.etf.zst`) and one object per session
  (`agents/<id>/sessions/<hex(sid)>/<ref>.etf.zst`). #154 moved runtime session
  state into `SalixAgent.InternalSessionStore`
  (`agents/<id>/internal_runtime/sessions/...`) and the VFS into
  `SalixAgent.AgentWorkspace` (`agents/<id>/workspace/state.etf.zst`), and made
  the root a minimal `SalixAgent.State` shell persisted in *whole* mode. It
  shipped no migration and no compatibility read path, so every pre-#154 agent
  now fails to load — `SalixStore.Agent` rejects split payloads — which silently
  emptied the sessions and websites dashboards and stopped existing bots from
  responding to any event.

  This migration reads each legacy split root, seeds the new internal-session
  and workspace stores from the inlined refs, then CAS-rewrites the root as a
  whole-mode shell. It is idempotent: an already-migrated (whole-mode) root is
  skipped, and re-seeding overwrites deterministically. Agent role / prompt /
  LLM config is intentionally untouched — the new runtime resolves those from
  the control record (`SalixAgent.AgentRuntimeConfig`), not the root state.

  """

  alias SalixAgent.{AgentWorkspace, InternalSession, InternalSessionStore}
  alias SalixStore.{Agent, Codec, Crypto, Keys, S3}

  @root_rewrite_retries 5

  @type counts :: %{
          migrated: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @type stats :: counts()

  @doc """
  Migrate every registered agent.

  External session objects are never listed or migrated.
  """
  @spec run() :: {:ok, stats()} | {:error, term()}
  def run do
    {:ok, _started} = Application.ensure_all_started(:salix_store)

    with {:ok, agent_ids} <- list_agent_ids() do
      agent_stats = Enum.reduce(agent_ids, zero_counts(), &reduce_agent/2)
      CommaLog.log("migrate_split_runtime_state", agent_stats)

      if agent_stats.failed == 0,
        do: {:ok, agent_stats},
        else: {:error, {:split_runtime_state_incomplete, agent_stats}}
    end
  end

  defp zero_counts, do: %{migrated: 0, skipped: 0, failed: 0}

  defp reduce_agent(agent_id, acc) do
    case migrate_agent(agent_id) do
      :migrated ->
        %{acc | migrated: acc.migrated + 1}

      :skipped ->
        %{acc | skipped: acc.skipped + 1}

      {:error, reason} ->
        CommaLog.log("migrate_split_runtime_state_agent_failed", %{
          agent_id: agent_id,
          reason: inspect(reason)
        })

        %{acc | failed: acc.failed + 1}
    end
  end

  @doc """
  Migrate a single agent.

  Returns `:skipped` when the root is absent or already whole-mode, and
  `:migrated` when a legacy split root was converted.
  """
  @spec migrate_agent(String.t()) :: :migrated | :skipped | {:error, term()}
  def migrate_agent(agent_id) when is_binary(agent_id) do
    case Agent.migration_read_root(agent_id) do
      {:ok, %{payload: %{mode: :split, meta: meta, refs: refs}} = root} ->
        migrate_split(agent_id, root, meta, refs)

      {:ok, _whole_or_other} ->
        :skipped

      {:error, :not_found} ->
        :skipped

      {:error, _} = err ->
        err
    end
  end

  # Seed the new stores before flipping the root: if the run dies mid-way the
  # root is still split, so a re-run re-seeds (overwriting) and then converts.
  defp migrate_split(agent_id, root, meta, refs) do
    with :ok <- seed_sessions(agent_id, refs, meta),
         :ok <- seed_workspace(agent_id, refs),
         :ok <- rewrite_root(agent_id, root, @root_rewrite_retries) do
      :migrated
    end
  end

  defp seed_sessions(agent_id, refs, meta) do
    refs
    |> Map.get(:sessions, %{})
    |> Enum.reduce_while(:ok, fn {session_id, ref}, :ok ->
      case load_legacy_session(agent_id, session_id, ref) do
        {:ok, legacy} ->
          state = build_session_state(agent_id, session_id, legacy, meta)

          case InternalSessionStore.prepare_seed(agent_id, state, force: true) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:seed_session_failed, session_id, reason}}}
          end

        # Content-addressed session objects are write-once, so a missing body
        # means the session was already pruned; skip it rather than wedge the
        # whole agent (and keep the surviving sessions + the bot alive).
        {:error, :not_found} ->
          CommaLog.log("migrate_split_runtime_state_session_missing", %{
            agent_id: agent_id,
            session_id: session_id
          })

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:load_session_failed, session_id, reason}}}
      end
    end)
  end

  defp seed_workspace(agent_id, refs) do
    case load_legacy_vfs(agent_id, Map.get(refs, :vfs)) do
      {:ok, vfs} -> AgentWorkspace.prepare_seed(agent_id, vfs)
      {:error, reason} -> {:error, {:load_vfs_failed, reason}}
    end
  end

  defp rewrite_root(_agent_id, _root, 0), do: {:error, :root_rewrite_exhausted}

  defp rewrite_root(agent_id, root, retries) do
    state = root.sm.init(agent_id)

    case Agent.migration_write_whole_root(agent_id, root.etag, root.sm, root.head, state) do
      {:ok, _etag} ->
        :ok

      # A concurrent writer (an old-code pod that still understands split state)
      # moved the root out from under us. Re-read and retry; if it is now
      # whole-mode someone else already converted it.
      {:error, :precondition_failed} ->
        case Agent.migration_read_root(agent_id) do
          {:ok, %{payload: %{mode: :split}} = fresh} -> rewrite_root(agent_id, fresh, retries - 1)
          {:ok, _whole} -> :ok
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # ---- legacy decoding ----

  # A legacy record admitted as a session: `open/1` is the import door, and
  # `prepare_seed/3` normalizes it through the kernel before it is written.
  defp build_session_state(agent_id, session_id, legacy, meta) do
    messages = Map.get(legacy, :messages) || []

    %InternalSession.State{
      agent_id: agent_id,
      session_id: session_id,
      name: Map.get(legacy, :name) || "Default",
      hidden: Map.get(legacy, :hidden) == true,
      created_at: Map.get(legacy, :created_at),
      last_activity_at: Map.get(legacy, :last_activity_at),
      status: legacy_internal_status(Map.get(legacy, :status)),
      last_ack_message_id: Map.get(legacy, :last_ack_message_id) || 0,
      # Message ids were agent-global; per-session they only need to exceed this
      # session's own ids. The kernel normalization `prepare_seed/3` runs keeps
      # it >= 1.
      next_message_id: next_message_id(messages),
      # The legacy dedupe index was agent-global (keyed by source_message_id).
      # Carrying the whole set into each session is safe: it only prevents
      # re-applying inputs already seen. The kernel normalization turns the list
      # into a MapSet.
      input_dedupe: legacy_session_dedupe(meta, messages),
      summary_sequence: Map.get(legacy, :summary_sequence) || 0,
      compacted_through: Map.get(legacy, :compacted_through) || 0,
      summary: Map.get(legacy, :summary),
      messages: messages,
      events: Map.get(legacy, :events) || [],
      wait: Map.get(legacy, :wait),
      async_tool_calls: Map.get(legacy, :async_tool_calls) || %{},
      platform: Map.get(legacy, :platform),
      billing_context: Map.get(legacy, :billing_context) || %{},
      task_origin: Map.get(legacy, :task_origin),
      source_session_id: Map.get(legacy, :source_session_id),
      source_schedule_id: Map.get(legacy, :source_schedule_id),
      system_prompt: Map.get(legacy, :system_prompt),
      live_context_bytes: Map.get(legacy, :live_context_bytes)
    }
    |> InternalSession.open()
  end

  defp next_message_id(messages) when is_list(messages) do
    messages
    |> Enum.map(fn msg -> Map.get(msg, :id) || Map.get(msg, "id") || 0 end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
    |> max(1)
  end

  defp next_message_id(_messages), do: 1

  defp legacy_internal_status(status) when status in [:active, "active"], do: :active
  defp legacy_internal_status(status) when status in [:idle, "idle", nil], do: :idle
  defp legacy_internal_status(status) when status in [:queued, "queued"], do: :idle

  defp legacy_internal_status(status),
    do: raise(ArgumentError, "invalid legacy internal session status #{inspect(status)}")

  defp legacy_session_dedupe(meta, messages) do
    ((Map.get(meta, :dedupe) || []) ++ legacy_message_dedupe(messages))
    |> Enum.reject(&missing_text?/1)
    |> Enum.uniq()
  end

  defp legacy_message_dedupe(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn
      message when is_map(message) ->
        [
          message[:source_message_id],
          message["source_message_id"],
          message[:dedupe_key],
          message["dedupe_key"],
          message[:runtime_message_id],
          message["runtime_message_id"]
        ]

      _ ->
        []
    end)
  end

  defp legacy_message_dedupe(_messages), do: []

  defp missing_text?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_text?(nil), do: true
  defp missing_text?(_value), do: false

  defp load_legacy_vfs(_agent_id, nil), do: {:ok, %{}}

  defp load_legacy_vfs(agent_id, ref) do
    case load_term(legacy_vfs_key(agent_id, ref)) do
      {:ok, vfs} when is_map(vfs) -> {:ok, vfs}
      {:ok, _other} -> {:ok, %{}}
      # The manifest body is gone, so there is nothing to host either way; an
      # empty workspace is the honest result rather than a failed migration.
      {:error, :not_found} -> {:ok, %{}}
      {:error, _} = err -> err
    end
  end

  defp load_legacy_session(agent_id, session_id, ref),
    do: load_term(legacy_session_key(agent_id, session_id, ref))

  defp load_term(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> {:ok, Codec.decode_snapshot(body)}
      {:error, _} = err -> err
    end
  end

  # Legacy key shapes, frozen here because #154 deleted them from
  # `SalixStore.Keys`. They must never change.
  defp legacy_vfs_key(agent_id, ref), do: "agents/#{agent_id}/vfs/#{ref}.etf.zst"

  defp legacy_session_key(agent_id, session_id, ref),
    do: "agents/#{agent_id}/sessions/#{Crypto.hex(session_id)}/#{ref}.etf.zst"

  defp list_agent_ids do
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
end
