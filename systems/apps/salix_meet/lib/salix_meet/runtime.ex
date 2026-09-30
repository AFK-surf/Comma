defmodule SalixMeet.Runtime do
  @moduledoc """
  Group-scoped meeting runtime control plane.

  A meeting agent is a hidden meeting-role agent owned by exactly one group. It
  owns meeting sessions, artifacts, and provider outbound, but it does not run
  the Comma LLM/tool round runtime.
  """

  require Logger

  alias SalixMeet.Ports.{AgentRuntime, MeetingDispatch}
  alias SalixMeet.Store
  alias SalixStore.{Ids, Keys, S3}

  @purpose "meeting"
  @template_id "__internal_meeting_agent"
  @agent_name "__internal_meeting_agent"
  @agent_prompt """
  You are the group's meeting agent.

  Handle meeting provider events, coordinate meeting artifacts, and publish
  meeting results through provider boundaries.
  """

  @doc "Ensure the group has its hidden meeting agent record and state."
  @spec ensure_for_group(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_for_group(tenant_id, group_id, opts \\ [])
      when is_binary(tenant_id) and is_binary(group_id) do
    with {:ok, group} <- get_group(tenant_id, group_id) do
      case read_meeting_agent(group_id) do
        {:ok, meeting_agent} ->
          ensure_or_discard_invalid_meeting_agent(meeting_agent, group)

        {:error, :not_found} ->
          create_meeting_agent(group, opts)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Return the current durable meeting agent record for a group."
  @spec status_for_group(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def status_for_group(tenant_id, group_id) do
    with {:ok, group} <- get_group(tenant_id, group_id),
         {:ok, meeting_agent} <- read_meeting_agent(group_id) do
      verify_meeting_agent(meeting_agent, group)
    end
  end

  @doc "Mark the meeting actor as running."
  @spec start_for_group(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_for_group(tenant_id, group_id, opts \\ []) do
    now = timestamp(opts)

    with {:ok, meeting_agent} <- ensure_for_group(tenant_id, group_id, opts) do
      update_meeting_agent(meeting_agent, fn rec ->
        rec
        |> Map.put("status", "running")
        |> Map.put("started_at", now)
        |> Map.put("heartbeat_at", now)
        |> Map.put("updated_at", now)
      end)
    end
  end

  @doc "Record a meeting actor heartbeat."
  @spec heartbeat(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def heartbeat(tenant_id, group_id, opts \\ []) do
    now = timestamp(opts)

    with {:ok, meeting_agent} <- status_for_group(tenant_id, group_id) do
      update_meeting_agent(meeting_agent, fn rec ->
        rec
        |> Map.put("status", "running")
        |> Map.put("heartbeat_at", now)
        |> Map.put("updated_at", now)
      end)
    end
  end

  @doc "Mark the meeting actor as stopped."
  @spec stop_for_group(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stop_for_group(tenant_id, group_id, opts \\ []) do
    now = timestamp(opts)

    with {:ok, meeting_agent} <- status_for_group(tenant_id, group_id) do
      update_meeting_agent(meeting_agent, fn rec ->
        rec
        |> Map.put("status", "stopped")
        |> Map.put("stopped_at", now)
        |> Map.put("updated_at", now)
      end)
    end
  end

  @doc """
  Deliver a meeting provider/runtime event into the group's meeting agent.

  This commits directly to the meeting agent state and AgentWorkspace. It does not enqueue
  a Comma LLM/tool round and does not create group/app/bridge conversations.
  """
  @spec deliver_event(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver_event(tenant_id, group_id, event, opts \\ []) when is_map(event) do
    now = timestamp(opts)
    event = stringify(event)

    with {:ok, meeting_agent} <- start_for_group(tenant_id, group_id, opts),
         source_id <- source_message_id(meeting_agent, event),
         {:ok, delivery_state} <- event_delivery_state(meeting_agent, source_id),
         {:ok, prepared} <-
           prepare_meeting_event(
             meeting_agent,
             event,
             opts[:origin_env_id],
             delivery_state
           ),
         {:ok, status} <-
           commit_and_apply_meeting_event(
             meeting_agent,
             source_id,
             prepared,
             now,
             delivery_state
           ) do
      {:ok, %{"status" => Atom.to_string(status), "meeting_agent" => meeting_agent}}
    end
  end

  @doc "Publish meeting output through the configured provider/API boundary."
  @spec publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish(meeting_agent, payload) when is_map(meeting_agent) and is_map(payload) do
    case Application.get_env(:salix_meet, :provider_mod) do
      nil ->
        {:error, :provider_not_configured}

      mod when is_atom(mod) ->
        cond do
          not Code.ensure_loaded?(mod) -> {:error, {:invalid_provider_mod, mod}}
          function_exported?(mod, :publish, 2) -> mod.publish(meeting_agent, payload)
          function_exported?(mod, :publish, 1) -> mod.publish(payload)
          true -> {:error, {:invalid_provider_mod, mod}}
        end

      other ->
        {:error, {:invalid_provider_mod, other}}
    end
  end

  @doc """
  Command the joined bot to post `text` into the live meeting chat (downlink).

  Resolves the meeting's group from stored state and dispatches
  "meeting_send_chat" over the connector bridge to the meetnative session.
  """
  @spec send_chat(String.t(), String.t()) :: {:ok, map()} | :ok | {:error, term()}
  def send_chat(meeting_id, text) when is_binary(meeting_id) and is_binary(text) do
    case Store.get(meeting_id) do
      {:ok, %{"state" => state}, _etag} when is_map(state) ->
        dispatch_chat(meeting_id, text, state, generated_message_id(state, text))

      {:error, _} = err ->
        err
    end
  end

  @spec send_chat(String.t(), String.t(), String.t()) :: {:ok, map()} | :ok | {:error, term()}
  def send_chat(meeting_id, text, message_id)
      when is_binary(meeting_id) and is_binary(text) and is_binary(message_id) do
    case Store.get(meeting_id) do
      {:ok, %{"state" => state}, _etag} when is_map(state) ->
        dispatch_chat(meeting_id, text, state, message_id)

      {:error, _} = err ->
        err
    end
  end

  defp dispatch_chat(meeting_id, text, state, message_id) do
    MeetingDispatch.send_chat(%{
      "meeting_id" => meeting_id,
      "message_id" => message_id,
      "tenant_id" => state["tenant_id"],
      "group_id" => to_string(state["group_id"] || ""),
      "runtime_source" => state["runtime_source"],
      "runtime_policy" => state["runtime_policy"],
      "compute_environment_id" => state["compute_environment_id"],
      "workload_id" => state["workload_id"],
      "attempt" => state["attempt"],
      "text" => text
    })
  end

  defp generated_message_id(state, text) do
    copilot = Map.get(state, "copilot", %{})
    digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    "meeting-chat:" <>
      to_string(state["attempt"] || "1") <>
      ":" <>
      to_string(copilot["caption_cursor"] || 0) <>
      ":" <>
      to_string(copilot["chat_cursor"] || 0) <>
      ":" <> digest
  end

  @doc false
  def purpose, do: @purpose

  # ---- creation ----

  defp create_meeting_agent(group, opts) do
    now = timestamp(opts)
    tenant_id = group["tenant_id"]
    group_id = group["group_id"]
    agent_id = Ids.new_agent_id(group_id)
    session_id = Ids.new_session_id()

    meeting_agent = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_agent_id" => agent_id,
      "meeting_session_id" => session_id,
      "status" => "idle",
      "billing_owner" => group["billing_owner"],
      "created_at" => now,
      "updated_at" => now
    }

    case S3.put(Keys.meet_agent(group_id), Jason.encode!(meeting_agent), if_none_match: "*") do
      {:ok, _} ->
        ensure_or_discard_invalid_meeting_agent(meeting_agent, group)

      {:error, :precondition_failed} ->
        with {:ok, stored} <- read_meeting_agent(group_id) do
          ensure_or_discard_invalid_meeting_agent(stored, group)
        end

      {:error, {:ambiguous, _}} ->
        with {:ok, stored} <- read_meeting_agent(group_id) do
          ensure_or_discard_invalid_meeting_agent(stored, group)
        end

      {:error, _} = err ->
        err
    end
  end

  # ---- storage helpers ----

  defp get_group(tenant_id, group_id) do
    with true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         {:ok, %{"group_id" => ^group_id} = group} <- read_json(Keys.ctl_group(group_id)),
         true <- group["tenant_id"] == tenant_id do
      {:ok, group}
    else
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp read_meeting_agent(group_id), do: read_json(Keys.meet_agent(group_id))

  defp verify_meeting_agent(meeting_agent, group) do
    tenant_id = group["tenant_id"]
    group_id = group["group_id"]
    agent_id = meeting_agent["meeting_agent_id"]
    session_id = meeting_agent["meeting_session_id"]

    with :ok <- expect(meeting_agent["tenant_id"] == tenant_id, :agent_tenant_mismatch),
         :ok <- expect(meeting_agent["group_id"] == group_id, :agent_group_mismatch),
         :ok <-
           expect(Ids.valid_agent_id_for_group?(agent_id, group_id), :meeting_agent_id_mismatch),
         :ok <- expect(Ids.valid_session_id?(session_id), :meeting_session_id_mismatch),
         :ok <-
           AgentRuntime.verify_agent(
             agent_runtime_request(
               tenant_id,
               group_id,
               agent_id,
               session_id,
               System.system_time(:second),
               meeting_billing_context(meeting_agent)
             )
           ) do
      sync_meeting_billing_owner(meeting_agent, group)
    end
  end

  defp ensure_existing_meeting_agent(meeting_agent, group) do
    tenant_id = group["tenant_id"]
    group_id = group["group_id"]
    agent_id = meeting_agent["meeting_agent_id"]
    session_id = meeting_agent["meeting_session_id"]

    with :ok <- expect(meeting_agent["tenant_id"] == tenant_id, :agent_tenant_mismatch),
         :ok <- expect(meeting_agent["group_id"] == group_id, :agent_group_mismatch),
         :ok <-
           expect(Ids.valid_agent_id_for_group?(agent_id, group_id), :meeting_agent_id_mismatch),
         :ok <- expect(Ids.valid_session_id?(session_id), :meeting_session_id_mismatch),
         :ok <-
           AgentRuntime.ensure_agent(
             agent_runtime_request(
               tenant_id,
               group_id,
               agent_id,
               session_id,
               System.system_time(:second),
               meeting_billing_context(meeting_agent)
             )
           ) do
      sync_meeting_billing_owner(meeting_agent, group)
    end
  end

  defp ensure_or_discard_invalid_meeting_agent(meeting_agent, group) do
    case ensure_existing_meeting_agent(meeting_agent, group) do
      {:error, {:invalid_meeting_agent, _reason}} = error ->
        case discard_meeting_agent(group["group_id"], meeting_agent) do
          :ok -> error
          {:error, reason} -> {:error, {:meeting_agent_cleanup_failed, reason, error}}
        end

      result ->
        result
    end
  end

  defp discard_meeting_agent(group_id, expected) do
    key = Keys.meet_agent(group_id)

    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, ^expected} <- Jason.decode(body) do
      case S3.delete(key, if_match: etag) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        {:error, _} = error -> error
      end
    else
      {:ok, _other} -> {:error, :changed}
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp sync_meeting_billing_owner(meeting_agent, group) do
    owner = group["billing_owner"]

    if meeting_agent["billing_owner"] == owner do
      {:ok, meeting_agent}
    else
      update_meeting_agent(meeting_agent, fn rec ->
        rec
        |> Map.put("billing_owner", owner)
        |> Map.put("updated_at", System.system_time(:second))
      end)
    end
  end

  defp update_meeting_agent(meeting_agent, fun),
    do: update_meeting_agent(meeting_agent["group_id"], fun, 5)

  defp update_meeting_agent(_group_id, _fun, 0), do: {:error, :lost}

  defp update_meeting_agent(group_id, fun, retries) do
    key = Keys.meet_agent(group_id)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        current = Jason.decode!(body)
        updated = fun.(current)

        case S3.put(key, Jason.encode!(updated), if_match: etag) do
          {:ok, _} -> {:ok, updated}
          {:error, :precondition_failed} -> update_meeting_agent(group_id, fun, retries - 1)
          {:error, {:ambiguous, _}} -> verify_update(group_id, updated)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp verify_update(group_id, expected) do
    case read_meeting_agent(group_id) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _other} -> {:error, :lost}
      {:error, _} = err -> err
    end
  end

  defp read_json(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # ---- delivery helpers ----

  defp event_committed?(meeting_agent, source_id) do
    AgentRuntime.event_committed?(
      meeting_agent["meeting_agent_id"],
      meeting_agent["meeting_session_id"],
      source_id
    )
  end

  defp workspace_event_committed?(meeting_agent, source_id) do
    AgentRuntime.workspace_event_committed?(
      meeting_agent["meeting_agent_id"],
      meeting_agent["meeting_session_id"],
      source_id
    )
  end

  defp event_delivery_state(meeting_agent, source_id) do
    with {:ok, committed?} <- event_committed?(meeting_agent, source_id) do
      if committed? do
        {:ok, :committed}
      else
        case workspace_event_committed?(meeting_agent, source_id) do
          {:ok, true} -> {:ok, :workspace_committed}
          {:ok, false} -> {:ok, :fresh}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp prepare_meeting_event(meeting_agent, event, _origin_env_id, state)
       when state in [:committed, :workspace_committed],
       do: SalixMeet.RuntimeEvents.recover(meeting_agent, event)

  defp prepare_meeting_event(meeting_agent, event, origin_env_id, :fresh),
    do: SalixMeet.RuntimeEvents.prepare(meeting_agent, event, origin_env_id)

  defp maybe_commit_meeting_event(_meeting_agent, _source_id, _prepared, _now, :committed),
    do: {:ok, :duplicate}

  defp maybe_commit_meeting_event(meeting_agent, source_id, prepared, now, state)
       when state in [:fresh, :workspace_committed] do
    commit_meeting_event(
      meeting_agent,
      source_id,
      prepared.event,
      now,
      prepared.vfs_events
    )
  end

  defp commit_and_apply_meeting_event(meeting_agent, source_id, prepared, now, delivery_state) do
    case maybe_commit_meeting_event(
           meeting_agent,
           source_id,
           prepared,
           now,
           delivery_state
         ) do
      {:ok, :created} ->
        with :ok <- SalixMeet.RuntimeEvents.apply(prepared, source_id), do: {:ok, :created}

      {:ok, :duplicate} ->
        cleanup_prepared_best_effort(prepared, source_id, :duplicate)

        with :ok <- SalixMeet.RuntimeEvents.apply(prepared, source_id), do: {:ok, :duplicate}

      {:error, reason} = error ->
        maybe_cleanup_failed_commit(meeting_agent, source_id, prepared, reason)
        error
    end
  end

  defp maybe_cleanup_failed_commit(meeting_agent, source_id, prepared, reason) do
    if ambiguous_commit?(reason) do
      Logger.warning(
        "meeting workspace commit outcome unknown source=#{source_id}; " <>
          "prepared artifacts retained for durable reconciliation: #{inspect(reason)}"
      )
    else
      case workspace_event_committed?(meeting_agent, source_id) do
        {:ok, false} ->
          cleanup_prepared_best_effort(prepared, source_id, {:commit_failed, reason})

        {:ok, true} ->
          :ok

        {:error, check_reason} ->
          Logger.warning(
            "meeting prepared artifact ownership check failed source=#{source_id}: " <>
              "#{inspect(check_reason)}"
          )
      end
    end
  end

  # A timeout/5xx may return before the conditional workspace PUT lands. An
  # immediate negative read is therefore not proof that the prepared bodies are
  # unowned. Keep their durable intents and let the grace-gated reconciler make
  # the ownership decision after the storage ambiguity window has closed.
  defp ambiguous_commit?({:ambiguous, _reason}), do: true
  defp ambiguous_commit?({:ambiguous_unresolved, _reason}), do: true
  defp ambiguous_commit?({_context, reason}), do: ambiguous_commit?(reason)
  defp ambiguous_commit?(_reason), do: false

  defp cleanup_prepared_best_effort(prepared, source_id, context) do
    case SalixMeet.RuntimeEvents.cleanup_prepared(prepared) do
      :ok ->
        :ok

      {:error, cleanup_reason} ->
        Logger.warning(
          "meeting prepared artifact cleanup deferred source=#{source_id} " <>
            "context=#{inspect(context)}: #{inspect(cleanup_reason)}"
        )
    end
  end

  defp commit_meeting_event(meeting_agent, source_id, event, now, vfs_events) do
    AgentRuntime.commit_event(%{
      "tenant_id" => meeting_agent["tenant_id"],
      "group_id" => meeting_agent["group_id"],
      "agent_id" => meeting_agent["meeting_agent_id"],
      "session_id" => meeting_agent["meeting_session_id"],
      "source_id" => source_id,
      "event" => event,
      "billing_context" => meeting_billing_context(meeting_agent, event),
      "vfs_events" => vfs_events,
      "now" => now
    })
  end

  defp meeting_billing_context(meeting_agent, event) do
    owner = meeting_agent["billing_owner"] || %{}

    %{
      "billing_account_id" => owner["billing_account_id"],
      "surface" => owner["surface"],
      "product_owner_type" => owner["product_owner_type"],
      "product_owner_id" => owner["product_owner_id"],
      "salix_tenant_id" => owner["salix_tenant_id"] || meeting_agent["tenant_id"],
      "salix_group_id" => owner["salix_group_id"] || meeting_agent["group_id"],
      "salix_agent_id" => meeting_agent["meeting_agent_id"],
      "charge_policy" => owner["charge_policy"],
      "entrypoint" => "meeting_runtime",
      "actor_type" => "system",
      "meeting_event_type" => event["type"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp meeting_billing_context(meeting_agent) do
    meeting_billing_context(meeting_agent, %{"type" => "meeting_session"})
  end

  defp source_message_id(meeting_agent, event) do
    event_id =
      event
      |> Map.get("event_id")
      |> present()
      |> Kernel.||(event_hash(event))

    [
      "meeting",
      meeting_agent["tenant_id"],
      meeting_agent["group_id"],
      event_id
    ]
    |> Enum.join(":")
  end

  defp event_hash(event) do
    event
    |> stringify()
    |> Map.delete("runtime_token")
    |> Map.update("artifacts", [], fn artifacts ->
      Enum.map(List.wrap(artifacts), fn artifact ->
        artifact
        |> stringify()
        |> Map.delete("source_ref")
      end)
    end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp timestamp(opts), do: opts[:now] || System.system_time(:second)

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp expect(true, _reason), do: :ok
  defp expect(false, reason), do: invalid(reason)

  defp invalid(reason), do: {:error, {:invalid_meeting_agent, reason}}

  defp meeting_template_ref do
    case Application.get_env(:salix_meet, :agent_template) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> @template_id
    end
  end

  defp agent_runtime_request(tenant_id, group_id, agent_id, session_id, now, billing_context) do
    %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "agent_id" => agent_id,
      "session_id" => session_id,
      "template_id" => meeting_template_ref(),
      "name" => @agent_name,
      "system_prompt" => @agent_prompt,
      "billing_context" => billing_context,
      "now" => now
    }
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
