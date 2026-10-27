defmodule SalixIM.ConversationServer do
  @moduledoc """
  Routes validated commands to the exact conversation or group owner.

  The owner-serialized Task-thread Participant delivery-fence command is
  modeled in `tla/salix/SlackTaskThreadDeliveryFence.tla`.
  """

  require SystemsRuntime.Proc, as: Proc

  alias SalixIM.SourceRefProtection
  alias SalixStore.{CasRecord, Crypto, Ids, Keys, S3}

  @owner_call_timeout_ms 30_000
  @generated_id_retries 8
  @conversation_kinds ~w(agent_task user_chat)
  @generic_create_trusted_atom_fields ~w(
    task_materialization
    task_worker_agent_id
    archived_from_status
    archived_at
    preallocated_identity
    preallocated_participants
    storage_migration
    messages
    mark_participants_delivered
    advance_participant_delivery_cursors
  )a
  @generic_create_trusted_fields Enum.map(@generic_create_trusted_atom_fields, &Atom.to_string/1)

  @doc false
  def authorize_source_reply(group_id, conversation_id, agent_id, scope),
    do: call(group_id, conversation_id, {:authorize_source_reply, agent_id, scope})

  @doc false
  def agent_source_snapshot(group_id, conversation_id, participant_id),
    do: call(group_id, conversation_id, {:agent_source_snapshot, participant_id})

  def recover_log(group_id, conversation_id, target),
    do: call(group_id, conversation_id, {:recover_log, target})

  def complete_log_recovery(group_id, conversation_id, target, observed_memberships),
    do: call(group_id, conversation_id, {:complete_log_recovery, target, observed_memberships})

  def delivery_sources(group_id, conversation_id),
    do: call(group_id, conversation_id, :delivery_sources)

  @doc false
  def repair_display_projection(group_id, conversation_id),
    do: call(group_id, conversation_id, :repair_display_projection)

  @doc false
  def repair_task_activity_projection(group_id, conversation_id),
    do: call(group_id, conversation_id, :repair_task_activity_projection, wake_on_recovery: false)

  def list_group_activity_tasks(group_id) do
    with :ok <- call_group(group_id, :activity_tasks),
         do: SalixIM.Conversations.list_group_activity_tasks(group_id)
  end

  def create_group_conversation(group_id, attrs) when is_map(attrs) do
    with :ok <- SalixIM.TaskArchive.ordinary_update(%{}, attrs),
         :ok <- validate_create_conversation_kind(attrs),
         :ok <- reject_caller_identity(attrs, "conversation_id"),
         :ok <- SourceRefProtection.validate_create(attrs["source_refs"] || attrs[:source_refs]) do
      attrs = sanitize_generic_create_attrs(attrs)

      create_with_owner_id(group_id, attrs, attrs, fn conversation_id, reserved? ->
        create_attrs = Map.put(attrs, "conversation_id", conversation_id)

        create_attrs =
          if reserved?,
            do: Map.put(create_attrs, "preallocated_identity", true),
            else: create_attrs

        {:create_group_conversation, create_attrs}
      end)
    end
  end

  def create_group_conversation_with_id(group_id, conversation_id, attrs) when is_map(attrs) do
    with :ok <- SalixIM.TaskArchive.ordinary_update(%{}, attrs),
         :ok <- validate_create_conversation_kind(attrs),
         {:ok, conversation_id} <- require_conversation_id(conversation_id),
         :ok <- SourceRefProtection.validate_create(attrs["source_refs"] || attrs[:source_refs]) do
      call(
        group_id,
        conversation_id,
        {:create_group_conversation,
         attrs
         |> sanitize_generic_create_attrs()
         |> Map.put("conversation_id", conversation_id)}
      )
    end
  end

  def update_group_conversation(group_id, conversation_id, attrs) when is_map(attrs) do
    with :ok <- validate_update_conversation_kind(attrs) do
      call(group_id, conversation_id, {:update_group_conversation, attrs})
    end
  end

  def link_task_mail(group_id, conversation_id, router_id, ref) when is_map(ref),
    do: call(group_id, conversation_id, {:link_task_mail, router_id, ref})

  def deliver_task_mail_followup(group_id, conversation_id, router_id, ref, request_id),
    do: call(group_id, conversation_id, {:deliver_task_mail_followup, router_id, ref, request_id})

  # Task labels are changed by the Conversation owner, never by the catalog store.
  def add_task_labels(group_id, conversation_id, label_ids),
    do: call(group_id, conversation_id, {:add_task_labels, label_ids})

  def apply_task_label_proposal(
        group_id,
        conversation_id,
        proposal_id,
        label_ids,
        expected_revision,
        mode
      ),
      do:
        call(
          group_id,
          conversation_id,
          {:apply_task_label_proposal, proposal_id, label_ids, expected_revision, mode}
        )

  def set_task_archived(group_id, conversation_id, action, version)
      when action in [:archive, :unarchive] and is_integer(version) and version > 0,
      do: call(group_id, conversation_id, {:set_task_archived, action, version})

  def set_task_archived(_, _, _, _),
    do: {:error, {:bad_request, "expected_updated_at must be a positive integer"}}

  def set_task_status(group_id, conversation_id, status, version, user_id)
      when is_integer(version) and version > 0 and is_binary(user_id) and user_id != "",
      do: call(group_id, conversation_id, {:set_task_status, status, version, user_id})

  def set_task_status(_group_id, _conversation_id, _status, _version, _user_id),
    do: {:error, {:bad_request, "expected_updated_at must be a positive integer"}}

  @doc """
  Records where a Task runs now and its Worker participant as it is from now
  on, and writes the Worker its `notice` (`SalixIM.TaskRun`): `run` carries
  `runs_on` (nil inside Salix), `worker` (the participant's agent_id,
  role_label, state, notification_filter and payload) and `notice` (a system
  Message's attrs). The Task record, or why not.
  """
  def switch_task_run(
        group_id,
        conversation_id,
        %{"worker" => %{}, "notice" => %{}} = run
      ),
      do: call(group_id, conversation_id, {:switch_task_run, run})

  def accept_task_review(group_id, conversation_id, review_version)
      when is_integer(review_version) and review_version > 0,
      do: call(group_id, conversation_id, {:accept_task_review, review_version})

  def accept_task_review(_group_id, _conversation_id, _review_version),
    do: {:error, {:bad_request, "review_version must be a positive integer"}}

  def delete_group_conversation(group_id, conversation_id),
    do: call(group_id, conversation_id, :delete_group_conversation)

  def append_group_conversation_message(group_id, conversation_id, attrs) when is_map(attrs),
    do: call(group_id, conversation_id, {:append_group_conversation_message, attrs})

  def append_provider_input(
        group_id,
        conversation_id,
        participant_id,
        source_id,
        payload,
        metadata
      ),
      do:
        call(
          group_id,
          conversation_id,
          {:append_provider_input, participant_id, source_id, payload, metadata}
        )

  def redeliver_group_conversation_agent_message(group_id, conversation_id, attrs)
      when is_map(attrs) do
    request_id = trim(attrs["request_id"])

    with :ok <- require_nonblank(request_id, "request_id") do
      call(
        group_id,
        conversation_id,
        {:redeliver_group_conversation_agent_message, Map.put(attrs, "request_id", request_id)}
      )
    end
  end

  # Product state that clients render beside an earlier Message, such as the
  # current status of a card. Hidden from Agents and from clients that do not
  # know the event type. Setup cards use the highest offer revision, not the
  # latest Message sequence, because an older publisher may finish later.
  @product_event_types ~w(device_setup_offer.updated)

  def append_product_event(group_id, conversation_id, event_type, data, idempotency_key)
      when event_type in @product_event_types and is_map(data) and is_binary(idempotency_key) and
             idempotency_key != "",
      do:
        call(
          group_id,
          conversation_id,
          {:append_product_event, event_type, data, idempotency_key}
        )

  def append_product_event(_group_id, _conversation_id, _event_type, _data, _key),
    do: {:error, {:bad_request, "unsupported product event"}}

  def append_platform_message(
        group_id,
        conversation_id,
        presentation,
        idempotency_key,
        reply_source \\ nil
      ),
      do:
        call(
          group_id,
          conversation_id,
          {:append_platform_message, presentation, idempotency_key, reply_source}
        )

  def ensure_group_conversation_provider_participant(group_id, conversation_id, attrs)
      when is_map(attrs),
      do:
        call(
          group_id,
          conversation_id,
          {:ensure_group_conversation_provider_participant, attrs}
        )

  def ensure_group_conversation_provider_participant_incarnation(
        group_id,
        conversation_id,
        attrs,
        contract
      )
      when is_map(attrs) and is_map(contract),
      do:
        call(
          group_id,
          conversation_id,
          {:ensure_group_conversation_provider_participant_incarnation, attrs, contract}
        )

  def ensure_group_conversation_user_participant(group_id, conversation_id, attrs)
      when is_map(attrs),
      do:
        call(
          group_id,
          conversation_id,
          {:ensure_group_conversation_user_participant, attrs}
        )

  def ensure_group_conversation_agent_participant(group_id, conversation_id, attrs)
      when is_map(attrs),
      do:
        call(
          group_id,
          conversation_id,
          {:ensure_group_conversation_agent_participant, attrs}
        )

  def remember_router_read_hint(group_id, agent_id),
    do: call_group(group_id, {:router_read_hint, agent_id})

  def resident_group_conversation(group_id, conversation_id),
    do: call(group_id, conversation_id, :conversation_snapshot)

  # A bounded read of the owner's membership projection; no reconciliation writes.
  def match_group_conversation_participants(group_id, conversation_id, desired, selector)
      when is_list(desired) and length(desired) <= 2 and is_map(selector),
      do: call(group_id, conversation_id, {:match_participants, desired, selector})

  def reconcile_group_conversation_agent_participants(group_id, conversation_id, attrs)
      when is_map(attrs),
      do:
        call(
          group_id,
          conversation_id,
          {:reconcile_group_conversation_agent_participants, attrs}
        )

  def reconcile_group_conversation_provider_participants(group_id, conversation_id, attrs)
      when is_map(attrs),
      do:
        call(
          group_id,
          conversation_id,
          {:reconcile_group_conversation_provider_participants, attrs}
        )

  def deactivate_group_conversation_participant(group_id, conversation_id, participant_id) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call(
        group_id,
        conversation_id,
        {:deactivate_group_conversation_participant, participant_id}
      )
    end
  end

  def deactivate_group_conversation_participant_if_payload(
        group_id,
        conversation_id,
        participant_id,
        expected_payload
      )
      when is_map(expected_payload) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call(
        group_id,
        conversation_id,
        {:deactivate_group_conversation_participant_if_payload, participant_id, expected_payload}
      )
    end
  end

  @doc false
  def fence_group_conversation_provider_participant_incarnation(
        group_id,
        conversation_id,
        participant_id,
        expected_payload,
        fence_token
      )
      when is_map(expected_payload) do
    with {:ok, participant_id} <- require_participant_id(participant_id),
         :ok <- require_nonblank(trim(fence_token), "fence_token") do
      call(
        group_id,
        conversation_id,
        {:fence_group_conversation_provider_participant_incarnation, participant_id,
         expected_payload, trim(fence_token)}
      )
    end
  end

  # The cold no-recovery-wake edge and participant tombstone ordering are
  # modeled by ParticipantDelivery.ColdDeleteSpec; keep this entrypoint and
  # tla/salix/ParticipantDelivery.tla in sync.
  def delete_group_conversation_provider_participant(group_id, conversation_id, participant_id) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call(
        group_id,
        conversation_id,
        {:delete_group_conversation_provider_participant, participant_id},
        wake_on_recovery: false
      )
    end
  end

  def reserve_group_conversation_message(group_id, conversation_id, attrs) when is_map(attrs),
    do: call(group_id, conversation_id, {:reserve_group_conversation_message, attrs})

  def seed_group_conversation_transcript(group_id, conversation_id, attrs) when is_map(attrs),
    do:
      call(
        group_id,
        conversation_id,
        {:seed_group_conversation_transcript, attrs}
      )

  def import_legacy_group_conversation_delivery(
        group_id,
        conversation_id,
        participant_id,
        facts
      )
      when is_map(facts),
      do:
        call(
          group_id,
          conversation_id,
          {:import_legacy_group_conversation_delivery, participant_id, facts}
        )

  def migrate_legacy_group_conversation_delivery_participant_fields(
        group_id,
        conversation_id,
        participant_id,
        delivery_id
      ),
      do:
        call(
          group_id,
          conversation_id,
          {:migrate_legacy_group_conversation_delivery_participant_fields, participant_id,
           delivery_id}
        )

  @doc false
  def retire_task_graph(group_id, conversation_id),
    do: call(group_id, conversation_id, :retire_task_graph)

  def migrate_legacy_task_status(group_id, conversation_id),
    do: call(group_id, conversation_id, :migrate_legacy_task_status)

  @doc false
  def backfill_message_threads(group_id, conversation_id, after_seq \\ 0),
    do:
      call(group_id, conversation_id, {:backfill_message_threads, after_seq},
        wake_on_recovery: false
      )

  @doc false
  def migrate_participant_notification_filter(group_id, conversation_id, participant_id),
    do:
      call(
        group_id,
        conversation_id,
        {:migrate_participant_notification_filter, participant_id}
      )

  def finish_seed_group_conversation(group_id, conversation_id),
    do: call(group_id, conversation_id, :finish_seed_group_conversation)

  def append_group_conversation_agent_message(group_id, conversation_id, agent_id, attrs)
      when is_map(attrs) do
    with {:ok, group_id} <- require_group_id(group_id),
         {:ok, conversation_id} <- require_conversation_id(conversation_id),
         {:ok, pid} <-
           SalixIM.SendTiming.measure("im_send_placement", fn ->
             SalixIM.ConversationPlacement.ensure_started(group_id, conversation_id, [])
           end) do
      SalixIM.SendTiming.measure("im_send_call", fn ->
        call_owner(pid, group_id, conversation_id, SalixIM.SendTiming.envelope(agent_id, attrs))
      end)
    end
  end

  def record_triage_source(group_id, conversation_id, agent_id, snapshot),
    do: call(group_id, conversation_id, {:record_triage_source, agent_id, snapshot})

  def escalate_triage_command_delivery(group_id, conversation_id, record),
    do: call(group_id, conversation_id, {:escalate_triage_command_delivery, record})

  def complete_triage_investigation(group_id, conversation_id, agent_id, source_id, decision),
    do:
      call(
        group_id,
        conversation_id,
        {:complete_triage_investigation, agent_id, source_id, decision}
      )

  def send_provider_participant_message(group_id, conversation_id, participant_id, attrs)
      when is_map(attrs) do
    send_provider_participant_message(group_id, conversation_id, participant_id, attrs, [])
  end

  def send_provider_participant_message(
        group_id,
        conversation_id,
        participant_id,
        attrs,
        opts
      ) do
    with {:ok, participant_id} <- require_participant_id(participant_id),
         {:ok, attrs} <- SalixIM.ParticipantNotificationInput.validate(attrs) do
      call(
        group_id,
        conversation_id,
        {:send_provider_participant_message, participant_id, attrs, opts}
      )
    end
  end

  def accept_slack_task_card_event(group_id, conversation_id, participant_id, event)
      when is_map(event) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call(
        group_id,
        conversation_id,
        {:accept_slack_task_card_event, participant_id, event}
      )
    end
  end

  def mail_interaction(group_id, conversation_id, owner_id, agent_id, command),
    do: call(group_id, conversation_id, {:mail_interaction, owner_id, agent_id, command})

  def configure_proactive(group_id, conversation_id, owner_id, enabled, request_id),
    do: call(group_id, conversation_id, {:configure_proactive, owner_id, enabled, request_id})

  def desktop_meeting(group_id, conversation_id, owner_id, command, message \\ nil),
    do: call(group_id, conversation_id, {:desktop_meeting, owner_id, command, message})

  def join_triage_investigation(group_id, conversation_id, source_id),
    do: call(group_id, conversation_id, {:join_triage_investigation, source_id})

  def settle_triage_investigation(group_id, conversation_id, source_id, effect),
    do: call(group_id, conversation_id, {:settle_triage_investigation, source_id, effect})

  def reserve_task_conversation_id(group_id, delegator_agent_id, target_agent_id, attrs)
      when is_map(attrs) do
    with {:ok, conversation_id, _attrs} <-
           reserve_task_conversation(group_id, delegator_agent_id, target_agent_id, attrs),
         do: {:ok, conversation_id}
  end

  @doc "Reserve a Task and recover the winning automatic placement before an invitation."
  def reserve_task_conversation(group_id, delegator_agent_id, target_agent_id, attrs)
      when is_map(attrs) do
    with :ok <- reject_caller_identity(attrs, "conversation_id") do
      reservation =
        attrs
        |> Map.put("delegator_agent_id", delegator_agent_id)
        |> Map.put("target_agent_id", target_agent_id)

      case trim(attrs["client_request_id"] || attrs[:client_request_id]) do
        "" ->
          with {:ok, id} <- reserve_generated_conversation_id(group_id, @generated_id_retries),
               do: {:ok, id, attrs}

        request_id ->
          with {:ok, binding} <-
                 ensure_conversation_create_request(group_id, request_id, reservation) do
            pinned =
              if attrs["automatic_task_place"] == true,
                do: Map.merge(attrs, binding["task_placement"] || %{}),
                else: attrs

            {:ok, binding["conversation_id"], pinned}
          end
      end
    end
  end

  @doc """
  Reads one existing Task request binding and its canonical Conversation.

  No reservation, creation or repair occurs here. A durable reservation alone
  is not evidence that a Task exists. Callers own project/group read authority.
  This uses the same primary key as reservation, with no second index or state.
  """
  def lookup_task_create_request(group_id, request_identity)
      when is_binary(request_identity) and byte_size(request_identity) in 1..512 do
    with {:ok, group_id} <- require_group_id(group_id),
         {:ok, _group} <- SalixIM.GroupDirectory.get_group(group_id) do
      key = Keys.ctl_group_conversation_create_request(group_id, Crypto.hex(request_identity))

      case CasRecord.get(key, :invalid_conversation_create_request) do
        {:ok,
         %{
           "group_id" => ^group_id,
           "request_identity" => ^request_identity,
           "conversation_id" => conversation_id
         }} ->
          lookup_reserved_task(group_id, conversation_id)

        {:error, :not_found} ->
          {:ok, %{"disposition" => "not_created"}}

        {:error, _reason} = error ->
          error

        _invalid ->
          {:error, :invalid_conversation_create_request}
      end
    end
  end

  def lookup_task_create_request(_group_id, _request_identity),
    do: {:error, :invalid_conversation_create_request}

  @doc "The automatic target already reserved by this exact creation request, if any."
  def task_request_placement(group_id, request_identity)
      when is_binary(request_identity) and request_identity != "" do
    key = Keys.ctl_group_conversation_create_request(group_id, Crypto.hex(request_identity))

    case CasRecord.get(key, :invalid_conversation_create_request) do
      {:ok, %{"group_id" => ^group_id, "request_identity" => ^request_identity} = binding} ->
        {:ok, binding["task_placement"]}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_conversation_create_request}
    end
  end

  def task_request_placement(_, _), do: {:ok, nil}

  defp lookup_reserved_task(group_id, conversation_id) do
    if Ids.valid_conversation_id?(conversation_id) do
      case SalixIM.Conversations.get_group_conversation(group_id, conversation_id) do
        {:ok, %{"kind" => "agent_task", "conversation_id" => ^conversation_id}} ->
          {:ok, %{"disposition" => "created", "conversation_id" => conversation_id}}

        {:error, :not_found} ->
          # Absence also covers a deleted Task. Do not claim it never existed.
          {:ok, %{"disposition" => "reserved_task_unavailable"}}

        {:error, _reason} = error ->
          error

        _invalid ->
          {:error, :invalid_conversation_create_request}
      end
    else
      {:error, :invalid_conversation_create_request}
    end
  end

  @doc false
  def create_task(group_id, conversation_id, spec) when is_map(spec),
    do: call(group_id, conversation_id, {:create_task, spec})

  def notify_task_schedule(group_id, conversation_id, schedule_id, scheduled_for_ms, opts \\ [])
      when is_binary(schedule_id) and is_integer(scheduled_for_ms),
      do:
        call(
          group_id,
          conversation_id,
          {:notify_task_schedule, schedule_id, scheduled_for_ms, opts}
        )

  @doc """
  A wake or lifecycle notice of the Task's Background Loop
  (`SalixIM.TaskLoop`), appended as private input to its Worker.
  """
  def task_loop_wake(group_id, conversation_id, loop, payload, source_id),
    do: call(group_id, conversation_id, {:task_loop_wake, loop, payload, source_id})

  @doc "Reopen an ended Loop Task with the command for its new Loop request."
  def restart_task_loop(group_id, conversation_id, request, command, router_id, source, human_at),
    do:
      call(
        group_id,
        conversation_id,
        {:restart_task_loop, request, command, router_id, source, human_at}
      )

  @doc "The Task's Loop ended (`fact`: `ended_reason` and the Loop's limits)."
  def task_loop_ended(group_id, conversation_id, loop, fact) when is_map(loop) and is_map(fact),
    do: call(group_id, conversation_id, {:task_loop_ended, loop, fact})

  @doc """
  The sandbox Session of a coding Task ended its turn with Message `seq`
  (`SalixWeb.StationTasks`): an `active` coding Task whose latest Message
  that still is goes into review.
  """
  def coding_turn_ended(group_id, conversation_id, seq) when is_integer(seq) and seq > 0,
    do: call(group_id, conversation_id, {:coding_turn_ended, seq})

  def replace_task_schedule(group_id, conversation_id, current, replacement)
      when is_map(current) and is_map(replacement),
      do: call(group_id, conversation_id, {:replace_task_schedule, current, replacement})

  def pin_conversation(group_id, conversation_id, tenant_id),
    do: call_group(group_id, {:pin, conversation_id, tenant_id})

  def unpin_conversation(group_id, conversation_id, tenant_id),
    do: call_group(group_id, {:unpin, conversation_id, tenant_id})

  def import_conversation_pin(group_id, pin) when is_map(pin),
    do: call_group(group_id, {:import_pin, pin})

  def put_task_order(group_id, bucket, conversation_ids, tenant_id)
      when is_binary(bucket) and is_list(conversation_ids),
      do: call_group(group_id, {:put_task_order, bucket, conversation_ids, tenant_id})

  def dismiss_group_conversation_activity_surface(group_id, conversation_id),
    do: call(group_id, conversation_id, :dismiss_group_conversation_activity_surface)

  def subscribe_group_conversation(group_id, conversation_id, subscriber)
      when Proc.is_process(subscriber),
      do: call(group_id, conversation_id, {:subscribe, subscriber})

  def subscribe_group_conversation_list(group_id, kind, subscriber)
      when kind in ["agent_task", "user_chat"] and Proc.is_process(subscriber) do
    with {:ok, group_id} <- require_group_id(group_id),
         {:ok, pid} <- SalixIM.ConversationPlacement.ensure_group_started(group_id) do
      SalixIM.ConversationGroupActor.subscribe_conversation_list(pid, kind, subscriber)
    end
  end

  def subscribe_group_conversation_mutations(group_id, subscriber)
      when Proc.is_process(subscriber) do
    with {:ok, group_id} <- require_group_id(group_id),
         {:ok, pid} <- SalixIM.ConversationPlacement.ensure_group_started(group_id) do
      SalixIM.ConversationGroupActor.subscribe_conversation_mutations(pid, subscriber)
    end
  end

  # Indexed identity lookup; status remains owned by the exact Participant.
  def get_group_conversation_agent_participant_identity(group_id, conversation_id, agent_id),
    do:
      call(
        group_id,
        conversation_id,
        {:conversation_api, {:get_agent_participant_identity, agent_id}}
      )

  # Whether the Agent is the Task's station Worker; nothing else of it.
  def group_conversation_station_worker?(group_id, conversation_id, agent_id),
    do: call(group_id, conversation_id, {:conversation_api, {:station_worker?, agent_id}})

  def get_group_conversation_participant_status(group_id, conversation_id, participant_id) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call_participant_realtime(group_id, conversation_id, participant_id, :get_realtime_status)
    end
  end

  def resolve_worker_memory_target(group_id, conversation_id, participant_id) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call(
        group_id,
        conversation_id,
        {:resolve_worker_memory_target, participant_id},
        wake_on_recovery: false
      )
    end
  end

  def subscribe_group_conversation_participant(
        group_id,
        conversation_id,
        participant_id,
        subscriber
      )
      when Proc.is_process(subscriber) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call_participant_realtime(
        group_id,
        conversation_id,
        participant_id,
        {:subscribe_realtime_status, subscriber}
      )
    end
  end

  defp call_participant_realtime(group_id, conversation_id, participant_id, command) do
    with {:ok, pid} <-
           call(group_id, conversation_id, {:participant_realtime_owner, participant_id}) do
      call_external_owner(pid, group_id <> ":" <> conversation_id, command)
    end
  end

  def wake_participant(group_id, conversation_id, participant_id) do
    with {:ok, participant_id} <- require_participant_id(participant_id) do
      call(group_id, conversation_id, {:wake_participant, participant_id})
    end
  end

  defp call_group(group_id, command) do
    with {:ok, group_id} <- require_group_id(group_id),
         {:ok, pid} <- SalixIM.ConversationPlacement.ensure_group_started(group_id) do
      call_group_owner(pid, group_id, command)
    end
  end

  defp sanitize_generic_create_attrs(attrs),
    do: Map.drop(attrs, @generic_create_trusted_fields ++ @generic_create_trusted_atom_fields)

  defp validate_create_conversation_kind(attrs) do
    case attrs["kind"] do
      nil -> :ok
      kind -> validate_conversation_kind(kind)
    end
  end

  defp validate_update_conversation_kind(attrs) do
    if Map.has_key?(attrs, "kind"),
      do: validate_conversation_kind(attrs["kind"]),
      else: :ok
  end

  defp validate_conversation_kind(kind) when is_binary(kind) do
    if String.trim(kind) in @conversation_kinds,
      do: :ok,
      else: {:error, {:bad_request, "invalid conversation kind"}}
  end

  defp validate_conversation_kind(_kind),
    do: {:error, {:bad_request, "invalid conversation kind"}}

  defp call_group_owner(pid, group_id, {:router_read_hint, agent_id}),
    do: call_external_owner(pid, group_id, {:router_read_hint, agent_id})

  defp call_group_owner(pid, group_id, :activity_tasks),
    do: call_external_owner(pid, group_id, :activity_tasks)

  defp call_group_owner(pid, group_id, {:pin, conversation_id, tenant_id}) do
    with {:ok, conversation_id} <- require_conversation_id(conversation_id) do
      call_external_owner(pid, group_id, {:pin, conversation_id, tenant_id})
    end
  end

  defp call_group_owner(pid, group_id, {:unpin, conversation_id, tenant_id}) do
    with {:ok, conversation_id} <- require_conversation_id(conversation_id) do
      call_external_owner(pid, group_id, {:unpin, conversation_id, tenant_id})
    end
  end

  defp call_group_owner(pid, group_id, {:put_task_order, bucket, conversation_ids, tenant_id})
       when is_binary(bucket) and is_list(conversation_ids),
       do:
         call_external_owner(
           pid,
           group_id,
           {:put_task_order, bucket, conversation_ids, tenant_id}
         )

  defp call_group_owner(pid, group_id, {:import_pin, %{"agent_group_id" => group_id} = pin}),
    do: call_external_owner(pid, group_id, {:import_pin, pin})

  defp call_group_owner(_pid, _group_id, {:import_pin, _pin}),
    do: {:error, :invalid_pin}

  defp call(group_id, conversation_id, command), do: call(group_id, conversation_id, command, [])

  defp call(group_id, conversation_id, command, placement_opts) do
    with {:ok, group_id} <- require_group_id(group_id),
         {:ok, conversation_id} <- require_conversation_id(conversation_id),
         {:ok, pid} <-
           SalixIM.ConversationPlacement.ensure_started(
             group_id,
             conversation_id,
             placement_opts
           ) do
      call_owner(pid, group_id, conversation_id, command)
    end
  end

  defp create_with_owner_id(group_id, attrs, reservation_attrs, command) do
    case trim(attrs["client_request_id"] || attrs[:client_request_id]) do
      "" ->
        create_with_generated_id(group_id, command, @generated_id_retries)

      request_identity ->
        create_with_reserved_id(
          group_id,
          request_identity,
          reservation_attrs,
          command,
          @generated_id_retries
        )
    end
  end

  defp create_with_generated_id(_group_id, _command, 0), do: {:error, :id_collision}

  defp create_with_generated_id(group_id, command, attempts) do
    conversation_id = Ids.new_conversation_id()

    case dispatch_owner_command(group_id, conversation_id, command.(conversation_id, false)) do
      {:error, :exists} ->
        create_with_generated_id(group_id, command, attempts - 1)

      {:error, {:participant_id_collision, _}} ->
        create_with_generated_id(group_id, command, attempts - 1)

      result ->
        result
    end
  end

  defp reserve_generated_conversation_id(group_id, _attempts) do
    conversation_id = Ids.new_conversation_id()

    with :ok <- ensure_conversation_id_available(group_id, conversation_id) do
      {:ok, conversation_id}
    end
  end

  defp create_with_reserved_id(group_id, request_identity, attrs, command, _attempts) do
    with {:ok, binding} <- ensure_conversation_create_request(group_id, request_identity, attrs) do
      conversation_id = binding["conversation_id"]
      dispatch_owner_command(group_id, conversation_id, command.(conversation_id, true))
    end
  end

  defp dispatch_owner_command(_group_id, _conversation_id, {:error, _reason} = error), do: error

  defp dispatch_owner_command(group_id, conversation_id, command),
    do: call(group_id, conversation_id, command)

  defp call_owner(
         pid,
         group_id,
         conversation_id,
         {:append_group_conversation_message, _} = command
       ) do
    scope = SalixStore.ReadScope.capture()

    call_external_owner(
      pid,
      group_id <> ":" <> conversation_id,
      {:with_read_scope, scope, command}
    )
  end

  defp call_owner(pid, group_id, conversation_id, command) do
    call_external_owner(pid, group_id <> ":" <> conversation_id, command)
  end

  defp call_external_owner(pid, owner_ref, command) do
    SystemsRuntime.Server.call(pid, command, @owner_call_timeout_ms)
  catch
    :exit, {:timeout, _} ->
      {:error, {:owner_unreachable, owner_ref, :timeout}}

    :exit, reason ->
      {:error, {:owner_unreachable, owner_ref, reason}}
  end

  defp ensure_conversation_create_request(group_id, request_identity, attrs) do
    request_identity = trim(request_identity)
    fingerprint = create_request_fingerprint(attrs)
    key = Keys.ctl_group_conversation_create_request(group_id, Crypto.hex(request_identity))

    candidate = %{
      "version" => 1,
      "group_id" => group_id,
      "request_identity" => request_identity,
      "request_fingerprint" => fingerprint,
      "conversation_id" => Ids.new_conversation_id(),
      "created_at" => now()
    }

    candidate =
      if attrs["automatic_task_place"] == true,
        do: Map.put(candidate, "task_placement", Map.take(attrs, ~w(runs_on session_model))),
        else: candidate

    with {:ok, _group} <- SalixIM.GroupDirectory.get_group(group_id),
         :ok <- require_nonblank(request_identity, "client_request_id") do
      CasRecord.update(key, fn
        nil ->
          candidate

        %{
          "group_id" => ^group_id,
          "request_identity" => ^request_identity,
          "request_fingerprint" => ^fingerprint,
          "conversation_id" => conversation_id
        } = existing ->
          if Ids.valid_conversation_id?(conversation_id),
            do: {:unchanged, existing},
            else: {:error, :invalid_conversation_create_request}

        _existing ->
          {:error, {:conflict, "conversation create request was reused with different content"}}
      end)
    end
  end

  defp create_request_fingerprint(attrs) do
    attrs =
      if attrs["automatic_task_place"] == true, do: Map.delete(attrs, "runs_on"), else: attrs

    attrs
    |> Map.drop(["conversation_id", "created_at", "updated_at"])
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  defp ensure_conversation_id_available(group_id, conversation_id) do
    case S3.get(Keys.ctl_group_conversation(group_id, conversation_id)) do
      {:ok, _conversation} -> {:error, :exists}
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp now, do: SystemsClock.system_time(:millisecond)

  defp require_nonblank(value, field) do
    if trim(value) == "", do: {:error, {:bad_request, field <> " is required"}}, else: :ok
  end

  defp require_group_id(value), do: require_id(value, "group_id", &Ids.valid_group_id?/1)

  defp require_conversation_id(value),
    do: require_id(value, "conversation_id", &Ids.valid_conversation_id?/1)

  defp require_participant_id(value),
    do: require_id(value, "participant_id", &Ids.valid_participant_id?/1)

  defp require_id(value, field, valid?) do
    value = trim(value)

    cond do
      value == "" -> {:error, {:bad_request, field <> " is required"}}
      valid?.(value) -> {:ok, value}
      true -> {:error, {:bad_request, "invalid " <> field}}
    end
  end

  defp reject_caller_identity(attrs, field) do
    if trim(attrs[field] || attrs[:conversation_id]) == "",
      do: :ok,
      else: {:error, {:bad_request, field <> " is assigned by the conversation owner"}}
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
