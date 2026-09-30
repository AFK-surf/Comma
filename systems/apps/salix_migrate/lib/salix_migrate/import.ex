defmodule SalixMigrate.Import do
  @moduledoc """
  Imports a locked Willow agent export into Salix. The Go exporter (which runs
  in the existing cluster, under each agent's lock) emits an agent's
  `messages`/`sessions`/`agent_state`/`vfs_entries` as a portable record; this
  builds the equivalent Salix S3 state so a first claim reconstructs the agent
  exactly:

    * create the agent root as a lease/control shell
    * materialize exported sessions + messages into `InternalSessionStore`
    * write the `ctl/agents/{id}.json` registry record with `migrated: true`
      (the one-way cutover flag)

  A subsequent `SalixStore.Agent.claim/4` loads that root state. Blobs are
  referenced by the same `blobs/` keys the Go system used (same bucket — zero
  blob copying), so VFS manifest entries carry over verbatim.

  Export shape (JSON-ish maps, string keys):

      %{
        "sessions" => [%{"id","status","last_ack_message_id",
                         "summary_sequence","compacted_through","summary"}],
        "messages" => [%{"id","session_id","role","content",
                         "tool_call_id"?,"tool_calls"?,"source_message_id"?}],
        "vfs"      => %{path => %{"ref","size","hash"}},   # optional
        "next_message_id" => integer,
        "tenant_id" => canonical tenant id,
        "group_id" => canonical group id,
        "role" => "worker" | "router",                      # optional; nil ⇒ "worker"
        "router_session_id" => exported canonical router session id, # required for router
        "template" => string,                                 # optional, for ctl
        "prompts" => %{"system_prompt" => s, "router_system_prompt" => s}  # optional
      }

  Agent identity/config is written to the control plane, not runtime state:

    * `"role"`/`"prompts"` land on `ctl/agents/{id}.json`
    * `"llm"` becomes the imported template's `provider_config`
    * internal runtime sessions receive sessions/messages runtime data
    * `"vfs"` becomes an agent workspace operation
  """

  alias SalixStore.{Agent, Ids, Keys, S3}
  alias SalixAgent.{AgentWorkspace, InternalSession, InternalSessionStore}
  alias SalixAgent.State

  @doc """
  Import `export` for `agent_id`. Returns `:ok` or `{:error, reason}`.
  Idempotent on the root object (create-once); re-import of an existing agent is
  `{:error, :exists}` unless `force: true`.
  """
  @spec import_agent(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def import_agent(agent_id, export, opts \\ []) do
    with {:ok, role} <- validate_role(export["role"]),
         :ok <- validate_identity(agent_id, export, role) do
      do_import(agent_id, export, role, opts)
    end
  end

  @spec do_import(String.t(), map(), String.t(), keyword()) :: :ok | {:error, term()}
  defp do_import(agent_id, export, role, opts) do
    state = %State{agent_id: agent_id}

    with :ok <- Agent.seed(agent_id, state, State, Keyword.merge(opts, hwm: 0)),
         :ok <- seed_internal_sessions(agent_id, export, opts),
         :ok <- seed_workspace(agent_id, export),
         :ok <- write_template(export),
         :ok <- write_registry(agent_id, export, role) do
      :ok
    end
  end

  defp seed_workspace(agent_id, export) do
    vfs = export["vfs"] || %{}

    events =
      vfs
      |> Enum.sort_by(fn {path, _meta} -> path end)
      |> Enum.map(fn {path, meta} ->
        %{
          "type" => "vfs_write",
          "path" => path,
          "ref" => meta["ref"],
          "size" => meta["size"],
          "hash" => meta["hash"],
          "modified_at" => meta["modified_at"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
      end)

    with {:ok, _result} <-
           AgentWorkspace.seed_operation(
             agent_id,
             "migrate-workspace",
             %{"imported" => length(events)},
             events
           ) do
      :ok
    end
  end

  defp write_registry(agent_id, export, role) do
    prompts = import_prompts(export["prompts"])
    template_id = template_id(export)
    now = export["migrated_at"] || System.system_time(:second)

    body =
      %{
        "agent_id" => agent_id,
        "tenant_id" => export["tenant_id"] || export["tenant"],
        "group_id" => export["group_id"] || export["group"],
        "role" => role,
        "name" => export["name"] || agent_id,
        "system_prompt" => prompts["system_prompt"] || "",
        "router_system_prompt" => prompts["router_system_prompt"] || "",
        "template_id" => template_id,
        "provider" => template_provider(export["llm"]),
        "db_namespace" => "salix:" <> agent_id,
        "status" => "idle",
        "purpose" => "migrated",
        "created_at" => now,
        "heartbeat_schedule_id" => Ids.new_schedule_id(),
        "migrated" => true,
        "migrated_at" => export["migrated_at"]
      }
      |> put_optional("router_session_id", router_session_id(export, role))
      |> put_optional("source_template", export["template"])
      |> Jason.encode!()

    case S3.put(Keys.ctl_agent(agent_id), body) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp write_template(export) do
    llm = export["llm"] || %{}
    template_id = template_id(export)
    now = export["migrated_at"] || System.system_time(:second)

    body =
      %{
        "template_id" => template_id,
        "name" => export["template"] || template_id,
        "model" => llm["model"] || "migrated",
        "provider" => template_provider(llm),
        "provider_config" => Map.drop(llm, ["model", "max_tokens"]),
        "request_headers" => %{},
        "image_config" => %{},
        "video_config" => %{},
        "vision_describer_config" => %{},
        "analyze_config" => %{},
        "max_tokens" => llm["max_tokens"] || 65_536,
        "context_tokens" => llm["context_tokens"] || 0,
        "created_at" => now
      }
      |> Jason.encode!()

    case S3.put(Keys.ctl_template(template_id), body) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  # ---- role validation (staging edge; never silently normalized) ----

  @spec validate_role(term()) :: {:ok, String.t()} | {:error, :invalid_role}
  defp validate_role(nil), do: {:ok, "worker"}
  defp validate_role(role) when role in ["worker", "router", "meeting"], do: {:ok, role}
  defp validate_role(_), do: {:error, :invalid_role}

  defp validate_identity(agent_id, export, role) do
    tenant_id = export["tenant_id"] || export["tenant"]
    group_id = export["group_id"] || export["group"]

    cond do
      not Ids.valid_group_id_for_tenant?(group_id, tenant_id) ->
        {:error, :invalid_group_identity}

      not Ids.valid_agent_id_for_group?(agent_id, group_id) ->
        {:error, :invalid_agent_identity}

      role == "router" and not valid_router_session?(export) ->
        {:error, :router_session_id_required}

      true ->
        :ok
    end
  end

  defp valid_router_session?(export) do
    session_id = export["router_session_id"]

    is_binary(session_id) and String.trim(session_id) != "" and
      Enum.any?(export["sessions"] || [], &(&1["id"] == session_id))
  end

  defp router_session_id(export, "router"), do: export["router_session_id"]
  defp router_session_id(_export, _role), do: nil

  # ---- internal session materialization ----

  defp seed_internal_sessions(agent_id, export, opts) do
    export
    |> build_internal_sessions(agent_id)
    |> Enum.reduce_while(:ok, fn session, :ok ->
      case InternalSessionStore.prepare_seed(agent_id, session, force: opts[:force]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_internal_sessions(export, agent_id) do
    by_session = Enum.group_by(export["messages"] || [], & &1["session_id"])

    for s <- export["sessions"] || [] do
      sid = s["id"]
      msgs = (by_session[sid] || []) |> Enum.sort_by(& &1["id"]) |> Enum.map(&to_message/1)

      source_ids =
        msgs
        |> Enum.map(& &1[:source_message_id])
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      %InternalSession.State{
        agent_id: agent_id,
        session_id: sid,
        name: s["name"] || "Default",
        hidden: s["hidden"] == true,
        created_at: s["created_at"],
        last_activity_at: s["last_activity_at"] || s["created_at"],
        status: parse_status(s["status"]),
        last_ack_message_id: s["last_ack_message_id"] || 0,
        next_message_id: next_message_id(msgs, export),
        input_dedupe: source_ids,
        summary_sequence: s["summary_sequence"] || 0,
        compacted_through: s["compacted_through"] || 0,
        summary: s["summary"],
        messages: msgs,
        wait: nil,
        billing_context: s["billing_context"] || %{},
        task_origin: s["task_origin"],
        source_session_id: s["source_session_id"],
        source_schedule_id: s["source_schedule_id"]
      }
      # An exported record admitted as a session and normalized by the kernel.
      |> InternalSession.open()
      |> InternalSession.normalize()
    end
  end

  defp next_message_id(messages, export) do
    exported_next = export["next_message_id"]
    max_message_id = messages |> Enum.map(&(&1[:id] || 0)) |> Enum.max(fn -> 0 end)

    max(exported_next || 1, max_message_id + 1)
  end

  # Keep only the two contract keys with string values; default %{}.
  @spec import_prompts(term()) :: %{optional(String.t()) => String.t()}
  defp import_prompts(%{} = prompts) do
    for {k, v} <- prompts,
        k in ["system_prompt", "router_system_prompt"],
        is_binary(v),
        into: %{},
        do: {k, v}
  end

  defp import_prompts(_), do: %{}

  defp template_id(export) do
    export["template_id"] || export["template"] || "migrated-default"
  end

  defp template_provider(%{"protocol" => protocol}) when is_binary(protocol), do: protocol
  defp template_provider(_), do: "migrated"

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp to_message(m) do
    %{
      id: m["id"],
      role: m["role"],
      content: m["content"],
      tool_call_id: m["tool_call_id"],
      tool_calls: m["tool_calls"],
      source_message_id: m["source_message_id"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_status("queued"), do: :queued
  defp parse_status("active"), do: :active
  defp parse_status(_), do: :idle
end
