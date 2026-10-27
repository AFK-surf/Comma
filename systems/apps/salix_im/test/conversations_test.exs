defmodule SalixIM.ConversationsTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:conversation_search_jobs]

  use SalixAgent.TestSupport.Settle
  @participant_identity_slots_field "_participant_identity_slots"

  alias SalixIM.{
    ConversationMessageCodec,
    ConversationParticipantActivity,
    ConversationPlacement,
    ConversationSearchProjection,
    ConversationServer,
    Conversations,
    Provider,
    RouterConversationInput
  }

  alias SalixIM.Provider.Slack.ConversationIngress, as: SlackConversationIngress
  alias SalixIM.ConversationSeedInput
  alias SalixStore.{CasRecord, ConversationSearch, Ids, Keys, Repo, S3, SearchDocumentEnvelope}

  defmodule RealtimeSessionActivity do
    @moduledoc false
    @behaviour SalixIM.Ports.SessionActivity

    @state_key {__MODULE__, :state}

    def configure(owner, agent_id, session_id, snapshot) do
      SystemsRuntime.PersistentTerm.put(@state_key, %{
        owner: owner,
        default_ref: {agent_id, session_id},
        fail_next_gets: %{},
        snapshots: %{{agent_id, session_id} => snapshot},
        subscribers: %{}
      })
    end

    def track_gets do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      SystemsRuntime.PersistentTerm.put(@state_key, Map.put(state, :track_gets, true))
    end

    def block_next_get do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      SystemsRuntime.PersistentTerm.put(@state_key, Map.put(state, :block_next_get, true))
    end

    def fail_next_get(agent_id, session_id) do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      ref = {agent_id, session_id}

      SystemsRuntime.PersistentTerm.put(@state_key, %{
        state
        | fail_next_gets: Map.update(state.fail_next_gets, ref, 1, &(&1 + 1))
      })
    end

    def publish(snapshot) do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      {agent_id, session_id} = state.default_ref
      publish(agent_id, session_id, snapshot)
    end

    def replace_without_notify(snapshot) do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      ref = state.default_ref

      SystemsRuntime.PersistentTerm.put(@state_key, %{
        state
        | snapshots: Map.put(state.snapshots, ref, snapshot)
      })

      :ok
    end

    def publish(agent_id, session_id, snapshot) do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      ref = {agent_id, session_id}
      next_state = %{state | snapshots: Map.put(state.snapshots, ref, snapshot)}
      SystemsRuntime.PersistentTerm.put(@state_key, next_state)

      state.subscribers
      |> Map.get(ref, MapSet.new())
      |> Enum.each(&send(&1, {:session_activity_updated, agent_id, session_id}))

      :ok
    end

    def clear, do: SystemsRuntime.PersistentTerm.erase(@state_key)

    @impl true
    def get(agent_id, session_id) do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      ref = {agent_id, session_id}

      if state[:block_next_get] do
        SystemsRuntime.PersistentTerm.put(@state_key, Map.delete(state, :block_next_get))

        SystemsRuntime.Proc.send(
          state.owner,
          {:session_activity_blocked, SystemsRuntime.Proc.self()}
        )

        SystemsRuntime.Proc.receive do
          :release_session_activity -> :ok
        end
      end

      if state[:track_gets],
        do:
          SystemsRuntime.Proc.send(
            state.owner,
            {:participant_activity_read, SystemsRuntime.Proc.self()}
          )

      case Map.get(state.fail_next_gets, ref, 0) do
        remaining when remaining > 0 ->
          next_failures =
            if remaining == 1,
              do: Map.delete(state.fail_next_gets, ref),
              else: Map.put(state.fail_next_gets, ref, remaining - 1)

          SystemsRuntime.PersistentTerm.put(@state_key, %{state | fail_next_gets: next_failures})
          {:error, :temporary_session_activity_unavailable}

        _none ->
          Map.fetch(state.snapshots, ref)
      end
    end

    @impl true
    def subscribe(agent_id, session_id) do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      ref = {agent_id, session_id}

      SystemsRuntime.PersistentTerm.put(@state_key, %{
        state
        | subscribers:
            Map.update(
              state.subscribers,
              ref,
              MapSet.new([SystemsRuntime.Proc.self()]),
              &MapSet.put(&1, SystemsRuntime.Proc.self())
            )
      })

      SystemsRuntime.Proc.send(
        state.owner,
        {:participant_session_subscription, SystemsRuntime.Proc.self(), agent_id, session_id}
      )

      :ok
    end

    @impl true
    def unsubscribe(agent_id, session_id) do
      state = SystemsRuntime.PersistentTerm.get(@state_key)
      ref = {agent_id, session_id}

      remaining =
        state.subscribers
        |> Map.get(ref, MapSet.new())
        |> MapSet.delete(SystemsRuntime.Proc.self())

      subscribers =
        if MapSet.size(remaining) == 0,
          do: Map.delete(state.subscribers, ref),
          else: Map.put(state.subscribers, ref, remaining)

      SystemsRuntime.PersistentTerm.put(@state_key, %{state | subscribers: subscribers})

      SystemsRuntime.Proc.send(
        state.owner,
        {:participant_session_unsubscription, SystemsRuntime.Proc.self(), agent_id, session_id}
      )

      :ok
    end
  end

  defmodule ReadProbe do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(
          fn -> %{active: 0, max_active: 0, gets: %{}, owner: nil, key_prefix: nil} end,
          name: __MODULE__
        )

    def reset(owner \\ nil, key_prefix \\ nil),
      do:
        Agent.update(__MODULE__, fn _ ->
          %{active: 0, max_active: 0, gets: %{}, owner: owner, key_prefix: key_prefix}
        end)

    def begin_get(key) do
      caller = SystemsRuntime.Proc.self()

      Agent.get_and_update(__MODULE__, fn state ->
        tracked_key? =
          is_nil(state.key_prefix) or String.starts_with?(key, state.key_prefix)

        if tracked_key? and (is_nil(state.owner) or state.owner == caller) do
          active = state.active + 1

          {true,
           %{
             state
             | active: active,
               max_active: max(state.max_active, active),
               gets: Map.update(state.gets, key, 1, &(&1 + 1))
           }}
        else
          {false, state}
        end
      end)
    end

    def end_get, do: Agent.update(__MODULE__, &%{&1 | active: &1.active - 1})
    def snapshot, do: Agent.get(__MODULE__, & &1)

    def handle_telemetry(event, _measurements, metadata, test_pid),
      do: SystemsRuntime.Proc.send(test_pid, {event, metadata})
  end

  defmodule LegacyOrphanReadBarrier do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{key: nil, owner: nil, captured: 0} end, name: __MODULE__)

    def arm(key, owner),
      do: Agent.update(__MODULE__, fn _ -> %{key: key, owner: owner, captured: 0} end)

    def capture(key) do
      try do
        Agent.get_and_update(__MODULE__, fn state ->
          if state.key == key and state.captured < 2 do
            {{:wait, state.owner}, %{state | captured: state.captured + 1}}
          else
            {:pass, state}
          end
        end)
      catch
        :exit, _reason -> :pass
      end
    end
  end

  defmodule LegacyOrphanBarrierS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def get(key, opts) do
      result = SalixStore.S3.Fake.get(key, opts)

      case LegacyOrphanReadBarrier.capture(key) do
        {:wait, owner} ->
          SystemsRuntime.Proc.send(
            owner,
            {:legacy_orphan_read_waiting, SystemsRuntime.Proc.self(), key}
          )

          SystemsRuntime.Proc.receive do
            {:release_legacy_orphan_read, ^key} -> result
          after
            5_000 -> {:error, :legacy_orphan_read_timeout}
          end

        :pass ->
          result
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule InstrumentedS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def get(key, opts) do
      tracked? = ReadProbe.begin_get(key)
      if tracked?, do: SystemsClock.sleep(20)

      try do
        SalixStore.S3.Fake.get(key, opts)
      after
        if tracked?, do: ReadProbe.end_get()
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule MessageSegmentReadBarrierS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @state_key {__MODULE__, :state}

    def arm(key, reader, owner),
      do: SystemsRuntime.PersistentTerm.put(@state_key, %{key: key, reader: reader, owner: owner})

    def clear, do: SystemsRuntime.PersistentTerm.erase(@state_key)

    @impl true
    def get(key, opts) do
      result = SalixStore.S3.Fake.get(key, opts)

      systems_self = SystemsRuntime.Proc.self()

      case SystemsRuntime.PersistentTerm.get(@state_key, nil) do
        %{key: ^key, reader: reader, owner: owner} when reader == systems_self ->
          SystemsRuntime.PersistentTerm.erase(@state_key)

          SystemsRuntime.Proc.send(
            owner,
            {:message_segment_read_parked, SystemsRuntime.Proc.self(), key}
          )

          SystemsRuntime.Proc.receive do
            {:release_message_segment_read, ^key} -> result
          after
            5_000 -> {:error, :message_segment_read_barrier_timeout}
          end

        _other ->
          result
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule ConversationHydrationErrorS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def get(key, opts) do
      if String.contains?(key, "/cnv1_0000000000000000003/") do
        {:error, {:http, 503}}
      else
        SalixStore.S3.Fake.get(key, opts)
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule ConversationListScanProbe do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{gets: 0, lists: 0, owner: nil} end, name: __MODULE__)

    def reset do
      owner = SystemsRuntime.Proc.self()
      Agent.update(__MODULE__, fn _ -> %{gets: 0, lists: 0, owner: owner} end)
    end

    def increment(kind) do
      callers = [SystemsRuntime.Proc.self() | Process.get(:"$callers", [])]

      Agent.update(__MODULE__, fn state ->
        if is_nil(state.owner) or state.owner in callers,
          do: Map.update!(state, kind, &(&1 + 1)),
          else: state
      end)
    end

    def snapshot, do: Agent.get(__MODULE__, &Map.take(&1, [:gets, :lists]))
  end

  defmodule CountingConversationListS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def get(key, opts) do
      ConversationListScanProbe.increment(:gets)
      SalixStore.S3.Fake.get(key, opts)
    end

    @impl true
    def list(prefix, opts) do
      ConversationListScanProbe.increment(:lists)
      SalixStore.S3.Fake.list(prefix, opts)
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule ParticipantStateScanProbe do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(fn -> %{lists: 0, max_requested: 0, max_returned: 0} end,
          name: __MODULE__
        )

    def reset,
      do: Agent.update(__MODULE__, fn _ -> %{lists: 0, max_requested: 0, max_returned: 0} end)

    def record(opts, result) do
      returned =
        case result do
          {:ok, %{objects: objects}} -> length(objects)
          _ -> 0
        end

      Agent.update(__MODULE__, fn state ->
        %{
          lists: state.lists + 1,
          max_requested: max(state.max_requested, opts[:max_keys] || 0),
          max_returned: max(state.max_returned, returned)
        }
      end)
    end

    def snapshot, do: Agent.get(__MODULE__, & &1)
  end

  defmodule CountingParticipantStateS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def list(prefix, opts) do
      result = SalixStore.S3.Fake.list(prefix, opts)

      if String.contains?(prefix, "/participant") do
        ParticipantStateScanProbe.record(opts, result)
      end

      result
    end

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule ParticipantSecondPageFailureS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def list(prefix, opts) do
      if String.contains?(prefix, "/participant_states/") and is_binary(opts[:start_after]) do
        {:error, {:http, 503}}
      else
        SalixStore.S3.Fake.list(prefix, opts)
      end
    end

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule BlockingAgentDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent_id, _payload, _opts) do
      test_pid = SystemsRuntime.fetch_env!(:salix_im, :blocking_agent_delivery_test_pid)
      SystemsRuntime.Proc.send(test_pid, {:agent_delivery_blocked, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :release_agent_delivery -> {:ok, :created}
      after
        5_000 -> {:error, :test_delivery_timeout}
      end
    end

    @impl true
    defdelegate get_session(agent_id, session_id, opts),
      to: SalixIM.TestSupport.AgentDelivery

    @impl true
    defdelegate get_session_messages(agent_id, session_id),
      to: SalixIM.TestSupport.AgentDelivery
  end

  defmodule BlockingProviderDelivery do
    def post_message(_, _, _, _), do: BlockingAgentDelivery.deliver(nil, nil, [])
    def find_message(_, _, _, _, _), do: {:ok, nil}
  end

  defmodule LostConversationHints do
    def notify_conversation(_, _), do: :ok
  end

  defmodule CaptureAgentDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    @impl true
    def conversation_progress(_, _, participant),
      do: CasRecord.get("test/conversation-delivery/#{participant}")

    def deliver(agent_id, payload, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :capture_agent_delivery_test_pid),
        {:captured_agent_delivery, agent_id, payload, opts}
      )

      {:ok, :created}
    end

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_implemented}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_implemented}
  end

  defmodule TaskSessionActivity do
    @moduledoc false
    @behaviour SalixIM.Ports.SessionActivity

    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(
          fn ->
            %{
              activities: %{},
              subscriptions: MapSet.new(),
              get_failures: %{},
              get_counts: %{}
            }
          end,
          name: __MODULE__
        )

    def fail_next_gets(agent_id, session_id, count) when is_integer(count) and count > 0 do
      Agent.update(
        __MODULE__,
        &put_in(&1, [:get_failures, {agent_id, session_id}], count)
      )
    end

    def get_count(agent_id, session_id),
      do: Agent.get(__MODULE__, &Map.get(&1.get_counts, {agent_id, session_id}, 0))

    def set(agent_id, session_id, state, updated_at, issue \\ nil, version \\ nil, status \\ "") do
      version = if version == :missing, do: nil, else: version || Integer.to_string(updated_at)

      activity =
        %{
          "state" => state,
          "status" => status,
          "updated_at" => updated_at
        }
        |> then(fn activity ->
          if is_binary(version), do: Map.put(activity, "version", version), else: activity
        end)
        |> then(fn activity ->
          if is_binary(issue), do: Map.put(activity, "issue", issue), else: activity
        end)

      Agent.update(
        __MODULE__,
        &put_in(&1, [:activities, {agent_id, session_id}], activity)
      )
    end

    def notify(agent_id, session_id) do
      __MODULE__
      |> Agent.get(
        &Enum.filter(&1.subscriptions, fn {id, sid, _pid} ->
          id == agent_id and sid == session_id
        end)
      )
      |> Enum.each(fn {_id, _sid, pid} ->
        SystemsRuntime.Proc.send(pid, {:session_activity_updated, agent_id, session_id})
      end)
    end

    def subscribed?(agent_id, session_id, pid),
      do:
        Agent.get(
          __MODULE__,
          &MapSet.member?(&1.subscriptions, {agent_id, session_id, pid})
        )

    @impl true
    def get(agent_id, session_id) do
      session_ref = {agent_id, session_id}

      Agent.get_and_update(__MODULE__, fn state ->
        failures = Map.get(state.get_failures, session_ref, 0)

        state =
          update_in(
            state,
            [:get_counts],
            &Map.update(&1, session_ref, 1, fn count -> count + 1 end)
          )

        if failures > 0 do
          state = put_in(state, [:get_failures, session_ref], failures - 1)
          {{:error, :injected_activity_read_failure}, state}
        else
          case Map.get(state.activities, session_ref) do
            nil -> {{:error, :not_found}, state}
            activity -> {{:ok, activity}, state}
          end
        end
      end)
    end

    @impl true
    def subscribe(agent_id, session_id) do
      subscriber = SystemsRuntime.Proc.self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscriptions, fn subscriptions ->
          MapSet.put(subscriptions, {agent_id, session_id, subscriber})
        end)
      )

      :ok
    end

    @impl true
    def unsubscribe(agent_id, session_id) do
      subscriber = SystemsRuntime.Proc.self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscriptions, fn subscriptions ->
          MapSet.delete(subscriptions, {agent_id, session_id, subscriber})
        end)
      )

      :ok
    end
  end

  defmodule DeliveryAckFaultS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def put(key, body, opts) do
      if SystemsRuntime.get_env(:salix_im, :drop_delivery_ack_once, false) and
           delivered_record?(body) do
        SystemsRuntime.put_env(:salix_im, :drop_delivery_ack_once, false)

        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_im, :delivery_ack_fault_test_pid),
          {:delivery_ack_write_dropped, key}
        )

        {:error, {:ambiguous, :injected}}
      else
        SalixStore.S3.Fake.put(key, body, opts)
      end
    end

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    defp delivered_record?(body) do
      case Jason.decode(IO.iodata_to_binary(body)) do
        {:ok, %{"status" => "delivered"}} -> true
        _ -> false
      end
    end
  end

  defmodule ConversationWriteFaultOnceS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def put(key, body, opts) do
      cond do
        SystemsRuntime.get_env(:salix_im, :fail_conversation_tombstone_once, false) and
          key == SystemsRuntime.get_env(:salix_im, :conversation_tombstone_fault_key) and
            tombstone?(body) ->
          SystemsRuntime.put_env(:salix_im, :fail_conversation_tombstone_once, false)
          {:error, {:http, 503}}

        SystemsRuntime.get_env(:salix_im, :inject_participant_collision, false) and
          String.contains?(key, "/participant_states/") and
          String.ends_with?(key, ".json") and opts[:if_none_match] == "*" ->
          SystemsRuntime.put_env(:salix_im, :inject_participant_collision, false)
          SystemsRuntime.put_env(:salix_im, :participant_collision_key, key)
          {:error, :precondition_failed}

        SystemsRuntime.get_env(:salix_im, :fail_participant_state_once, false) and
          String.contains?(key, "/participant_states/") and opts[:if_none_match] == "*" ->
          SystemsRuntime.put_env(:salix_im, :fail_participant_state_once, false)
          SystemsRuntime.put_env(:salix_im, :failed_participant_state_key, key)
          {:error, {:http, 503}}

        SystemsRuntime.get_env(:salix_im, :fail_message_segment_once, false) and
            String.contains?(key, "/messages/segments/") ->
          SystemsRuntime.put_env(:salix_im, :fail_message_segment_once, false)
          {:error, {:http, 503}}

        true ->
          SalixStore.S3.Fake.put(key, body, opts)
      end
    end

    @impl true
    def get(key, opts) do
      if key == SystemsRuntime.get_env(:salix_im, :participant_collision_key) do
        {:ok, %{body: "{}", etag: "collision"}}
      else
        SalixStore.S3.Fake.get(key, opts)
      end
    end

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    defp tombstone?(body) do
      case Jason.decode(IO.iodata_to_binary(body)) do
        {:ok, %{"deleted_at" => deleted_at}} when not is_nil(deleted_at) -> true
        _ -> false
      end
    end
  end

  defmodule ConversationDeleteFaultOnceS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def delete(key, opts) do
      conversation_prefix =
        SystemsRuntime.get_env(:salix_im, :delete_fault_conversation_prefix, "")

      if SystemsRuntime.get_env(:salix_im, :fail_conversation_child_delete_once, false) and
           conversation_prefix != "" and String.starts_with?(key, conversation_prefix) and
           not String.ends_with?(key, "/meta.json") do
        SystemsRuntime.put_env(:salix_im, :fail_conversation_child_delete_once, false)

        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_im, :conversation_delete_fault_test_pid),
          {:conversation_child_delete_failed, key}
        )

        {:error, {:http, 503}}
      else
        SalixStore.S3.Fake.delete(key, opts)
      end
    end

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule ConversationDeleteRaceS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def list(prefix, opts) do
      cond do
        SystemsRuntime.get_env(:salix_im, :drop_participant_state_after_list_once, false) and
            prefix ==
              SystemsRuntime.get_env(:salix_im, :delete_race_participant_states_prefix) ->
          case SalixStore.S3.Fake.list(prefix, opts) do
            {:ok, %{objects: [object | _rest]}} = result ->
              SystemsRuntime.put_env(:salix_im, :drop_participant_state_after_list_once, false)
              :ok = SalixStore.S3.Fake.delete(object.key, [])

              SystemsRuntime.Proc.send(
                SystemsRuntime.fetch_env!(:salix_im, :conversation_delete_race_test_pid),
                {:participant_state_deleted_after_list, object.key}
              )

              result

            result ->
              result
          end

        SystemsRuntime.get_env(:salix_im, :fail_delete_cleanup_stage_not_found_once, false) and
            prefix == SystemsRuntime.get_env(:salix_im, :delete_cleanup_stage_prefix) ->
          SystemsRuntime.put_env(:salix_im, :fail_delete_cleanup_stage_not_found_once, false)

          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:salix_im, :conversation_delete_race_test_pid),
            :conversation_cleanup_stage_not_found
          )

          {:error, :not_found}

        true ->
          SalixStore.S3.Fake.list(prefix, opts)
      end
    end

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule ConversationTombstoneOwnerCrashS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def put(key, body, opts) do
      result = SalixStore.S3.Fake.put(key, body, opts)

      if SystemsRuntime.get_env(:salix_im, :crash_tombstone_owner_once, false) and
           key == SystemsRuntime.get_env(:salix_im, :crash_tombstone_key) and
           tombstone?(body) and match?({:ok, _}, result) do
        SystemsRuntime.put_env(:salix_im, :crash_tombstone_owner_once, false)

        if SystemsRuntime.get_env(
             :salix_im,
             :fail_recovery_meta_get_after_tombstone_crash_once,
             false
           ) do
          SystemsRuntime.put_env(
            :salix_im,
            :fail_recovery_meta_get_after_tombstone_crash_once,
            false
          )

          SystemsRuntime.put_env(:salix_im, :fail_recovery_meta_get_once, true)
        end

        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_im, :crash_tombstone_test_pid),
          :tombstone_committed
        )

        exit(:kill)
      end

      result
    end

    @impl true
    def list(prefix, opts) do
      cleanup_prefix =
        SystemsRuntime.get_env(:salix_im, :crash_participant_states_prefix)

      if SystemsRuntime.get_env(:salix_im, :block_deleted_participant_cleanup, false) and
           is_binary(cleanup_prefix) and String.starts_with?(prefix, cleanup_prefix) do
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_im, :crash_tombstone_test_pid),
          :deleted_participant_cleanup_blocked
        )

        {:error, {:http, 503}}
      else
        SalixStore.S3.Fake.list(prefix, opts)
      end
    end

    @impl true
    def get(key, opts) do
      if SystemsRuntime.get_env(:salix_im, :fail_recovery_meta_get_once, false) and
           key == SystemsRuntime.get_env(:salix_im, :crash_tombstone_key) do
        SystemsRuntime.put_env(:salix_im, :fail_recovery_meta_get_once, false)

        test_pid = SystemsRuntime.fetch_env!(:salix_im, :crash_tombstone_test_pid)
        SystemsRuntime.Proc.send(test_pid, :recovery_meta_get_failed)

        if SystemsRuntime.get_env(:salix_im, :block_recovery_meta_get_once, false) do
          SystemsRuntime.Proc.send(
            test_pid,
            {:recovery_meta_get_blocked, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
            :release_recovery_meta_get -> :ok
          after
            5_000 -> :ok
          end
        end

        {:error, {:http, 503}}
      else
        SalixStore.S3.Fake.get(key, opts)
      end
    end

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    defp tombstone?(body) do
      case Jason.decode(IO.iodata_to_binary(body)) do
        {:ok, %{"deleted_at" => deleted_at}} when not is_nil(deleted_at) -> true
        _ -> false
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    prev_session_activity = SystemsRuntime.get_env(:salix_im, :session_activity_mod)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    SystemsRuntime.put_env(
      :salix_im,
      :session_activity_mod,
      SalixIM.TestSupport.SessionActivity
    )

    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, prev_s3)
        restore(:salix_agent, :llm, prev_llm)
        restore(:salix_im, :agent_delivery_mod, prev_agent_delivery)
        restore(:salix_im, :session_activity_mod, prev_session_activity)
        SystemsRuntime.delete_env(:salix_im, :delete_fault_conversation_prefix)
        SystemsRuntime.delete_env(:salix_im, :fail_conversation_child_delete_once)
        SystemsRuntime.delete_env(:salix_im, :conversation_delete_fault_test_pid)
        SystemsRuntime.delete_env(:salix_im, :drop_participant_state_after_list_once)
        SystemsRuntime.delete_env(:salix_im, :delete_race_participant_states_prefix)
        SystemsRuntime.delete_env(:salix_im, :fail_delete_cleanup_stage_not_found_once)
        SystemsRuntime.delete_env(:salix_im, :delete_cleanup_stage_prefix)
        SystemsRuntime.delete_env(:salix_im, :conversation_delete_race_test_pid)
        SystemsRuntime.delete_env(:salix_im, :fail_conversation_tombstone_once)
        SystemsRuntime.delete_env(:salix_im, :conversation_tombstone_fault_key)
        SystemsRuntime.delete_env(:salix_im, :crash_tombstone_owner_once)
        SystemsRuntime.delete_env(:salix_im, :crash_tombstone_key)
        SystemsRuntime.delete_env(:salix_im, :crash_tombstone_test_pid)
        SystemsRuntime.delete_env(:salix_im, :fail_recovery_meta_get_after_tombstone_crash_once)
        SystemsRuntime.delete_env(:salix_im, :fail_recovery_meta_get_once)
        SystemsRuntime.delete_env(:salix_im, :block_recovery_meta_get_once)
        SystemsRuntime.delete_env(:salix_im, :crash_participant_states_prefix)
        SystemsRuntime.delete_env(:salix_im, :fail_participant_state_once)
        SystemsRuntime.delete_env(:salix_im, :failed_participant_state_key)
        SystemsRuntime.delete_env(:salix_im, :block_deleted_participant_cleanup)
        SystemsRuntime.delete_env(:salix_im, :blocking_agent_delivery_test_pid)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "IM"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    router_id = router["agent_id"]
    worker_id = worker["agent_id"]

    {:ok, group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router_id)
      end)

    {:ok,
     %{
       tenant_id: tenant_id,
       group_id: group_id,
       router: router,
       router_id: router_id,
       router_session_id: router["router_session_id"],
       router_conversation_id: group["router_conversation_id"],
       worker: worker,
       worker_id: worker_id
     }}
  end

  @tag :desktop_meeting
  test "meeting entry waits, reuses its Task and archives an unrecorded reminder", ctx do
    entry = %{
      "occurrence_id" => "meeting-occurrence-test-1",
      "name" => "Zoom",
      "started_at" => 1_000,
      "archive_date" => "2026-09-09"
    }

    assert {:ok, task} =
             SalixIM.DesktopMeetingInput.ensure(
               ctx.group_id,
               ctx.router_id,
               ctx.worker_id,
               "owner-user-1",
               entry
             )

    id = task["conversation_id"]
    assert task["metadata"]["desktop_meeting"]["phase"] == "awaiting_recording"

    assert {:ok, again} =
             SalixIM.DesktopMeetingInput.ensure(
               ctx.group_id,
               ctx.router_id,
               ctx.worker_id,
               "owner-user-1",
               entry
             )

    assert again["conversation_id"] == id

    assert {:ok, [context]} =
             Conversations.list_group_conversation_messages(ctx.group_id, id, limit: 10)

    assert context["delivery_filter"] == %{"participant_ids" => []}

    assert {:ok, archived} =
             ConversationServer.desktop_meeting(ctx.group_id, id, "owner-user-1", %{
               "action" => "dismiss",
               "version" => 1
             })

    assert archived["status"] == "archived"
    assert archived["archived_from_status"] == "cancelled"

    assert {:error, :not_found} =
             ConversationServer.desktop_meeting(ctx.group_id, id, "another-user", %{
               "action" => "recording",
               "version" => 2
             })

    assert {:ok, same} =
             ConversationServer.desktop_meeting(ctx.group_id, id, "owner-user-1", %{
               "action" => "recording",
               "version" => 1
             })

    assert same["status"] == "archived"

    assert {:ok, recovered} =
             SalixIM.DesktopMeetingInput.ensure(
               ctx.group_id,
               ctx.router_id,
               ctx.worker_id,
               "owner-user-1",
               entry
             )

    assert recovered["status"] == "archived"
    assert recovered["metadata"]["desktop_meeting"]["phase"] == "dismissed"
  end

  test "generic create cannot persist product-owned meeting activation refs", %{
    group_id: group_id
  } do
    connect_id = "conn_create_authz"
    signing_key = "conversation-create-authorization-key"

    assert {:ok, activation_ref} =
             SalixIM.Provider.Feishu.MeetingActivationRef.encode(
               SalixIM.Provider.Feishu.MeetingActivationAuthorization.ref_scope(
                 group_id,
                 connect_id
               ),
               signing_key,
               %{
                 "meeting_id" => "meeting-create-authz",
                 "expires_at" => SystemsClock.system_time(:second) + 3_600,
                 "target" => %{
                   "message_id" => "om_create_authz",
                   "chat_id" => "oc_create_authz",
                   "chat_type" => "group",
                   "thread_id" => "omt_create_authz",
                   "reply_in_thread" => true
                 },
                 "allowed_mentions" => []
               }
             )

    protected_refs = [%{"connect_id" => connect_id, "ref" => activation_ref}]

    case SalixIM.ConversationInput.create_group_conversation(group_id, %{
           "title" => "Reject protected source refs",
           "source_refs" => %{"meeting_activation_refs" => protected_refs}
         }) do
      {:error, {:bad_request, "meeting_activation_refs are product-owned"}} ->
        :ok

      {:ok, %{"conversation_id" => conversation_id}} ->
        assert {:ok, persisted} =
                 Conversations.get_group_conversation(group_id, conversation_id)

        assert persisted["source_refs"]["meeting_activation_refs"] == protected_refs

        flunk("generic conversation create persisted product-owned meeting_activation_refs")

      other ->
        flunk("generic conversation create returned unexpected result: #{inspect(other)}")
    end

    assert {:error, {:bad_request, "meeting_activation_refs are product-owned"}} =
             SalixIM.ConversationInput.create_group_conversation_with_id(
               group_id,
               Ids.new_conversation_id(),
               %{
                 "title" => "Reject protected source refs with id",
                 "source_refs" => %{"meeting_activation_refs" => protected_refs}
               }
             )
  end

  test "message pages are positioned by seq, bounded, and report the span they read", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Message page reads",
               "participants" => [user_participant(SystemsClock.system_time(:millisecond))]
             })

    page = fn opts ->
      Conversations.list_group_conversation_message_page(group_id, conversation_id, opts)
    end

    # An empty Conversation has an empty tail page and no bounds; no seq exists
    # to position on.
    assert {:ok,
            %{
              "messages" => [],
              "covered" => nil,
              "bounds" => nil,
              "has_older" => false,
              "has_newer" => false
            }} = page.([])

    assert {:error, :not_found} = page.(before: 1)

    for index <- 1..12 do
      assert {:ok, %{"seq" => ^index}} =
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 %{"content" => "page #{index}", "client_request_id" => "page-#{index}"}
               )
    end

    seqs = fn %{"messages" => messages} -> Enum.map(messages, & &1["seq"]) end
    bounds = %{"head_seq" => 1, "tail_seq" => 12}

    assert {:ok, tail} = page.(limit: 5)
    assert seqs.(tail) == [8, 9, 10, 11, 12]

    assert %{
             "covered" => %{"first_seq" => 8, "last_seq" => 12},
             "has_older" => true,
             "has_newer" => false,
             "bounds" => ^bounds
           } = tail

    assert {:ok, before} = page.(before: 8, limit: 5)
    assert seqs.(before) == [3, 4, 5, 6, 7]
    assert %{"has_older" => true, "has_newer" => true, "bounds" => ^bounds} = before

    # A page that reaches the head is short and says there is nothing older.
    assert {:ok, head} = page.(before: "3", limit: "5")
    assert seqs.(head) == [1, 2]
    assert %{"covered" => %{"first_seq" => 1, "last_seq" => 2}, "has_older" => false} = head

    assert {:ok, %{"messages" => [], "covered" => nil, "has_older" => false, "has_newer" => true}} =
             page.(before: 1)

    assert {:ok, after_page} = page.(after: 10, limit: 5)
    assert seqs.(after_page) == [11, 12]
    assert %{"has_older" => true, "has_newer" => false} = after_page

    assert {:ok, %{"messages" => [], "covered" => nil, "has_older" => true, "has_newer" => false}} =
             page.(after: 12)

    assert {:ok, around} = page.(around: 6, limit: 5)
    assert seqs.(around) == [4, 5, 6, 7, 8]
    assert %{"has_older" => true, "has_newer" => true} = around

    # Near an end, an around page fills toward the other end.
    assert {:ok, around_tail} = page.(around: 12, limit: 5)
    assert seqs.(around_tail) == [8, 9, 10, 11, 12]

    # Without a limit, a page holds every later message here.
    assert {:ok, default_page} = page.(after: 1)
    assert seqs.(default_page) == Enum.to_list(2..12)

    # A seq outside this Conversation's head and tail is not a position.
    assert {:error, :not_found} = page.(around: 206)
    assert {:error, :not_found} = page.(after: 9_999)

    for bad <- [
          [before: 8, after: 2],
          [before: 0],
          [around: "six"],
          [after: Ids.new_message_id()],
          [limit: 0],
          [limit: "ten"]
        ] do
      assert {:error, {:bad_request, _message}} = page.(bad)
    end
  end

  test "a message page never reads another Conversation's Messages", %{group_id: group_id} do
    # Same Group. The other Conversation is longer, so its tail seq and its
    # Message ids are well formed but are not positions in the reader.
    [reader, other] =
      for {title, count} <- [{"Page reader", 3}, {"Other Conversation", 6}] do
        assert {:ok, %{"conversation_id" => conversation_id}} =
                 SalixIM.ConversationInput.create_group_conversation(group_id, %{
                   "title" => title,
                   "participants" => [user_participant(SystemsClock.system_time(:millisecond))]
                 })

        for index <- 1..count do
          assert {:ok, _} =
                   ConversationServer.append_group_conversation_message(
                     group_id,
                     conversation_id,
                     %{
                       "content" => "#{title} #{index}",
                       "client_request_id" => "#{title}-#{index}"
                     }
                   )
        end

        conversation_id
      end

    assert {:ok, %{"messages" => [%{"message_id" => foreign_id} | _] = foreign}} =
             Conversations.list_group_conversation_message_page(group_id, other, limit: 6)

    foreign_ids = MapSet.new(foreign, & &1["message_id"])

    for position <- [:before, :after, :around] do
      assert {:error, :not_found} =
               Conversations.list_group_conversation_message_page(group_id, reader, [
                 {position, 6}
               ])

      assert {:error, {:bad_request, _}} =
               Conversations.list_group_conversation_message_page(group_id, reader, [
                 {position, foreign_id}
               ])

      # A seq both Conversations have reads only the reader's Messages.
      assert {:ok, %{"messages" => messages}} =
               Conversations.list_group_conversation_message_page(group_id, reader, [
                 {position, 2}
               ])

      assert messages != []
      refute Enum.any?(messages, &MapSet.member?(foreign_ids, &1["message_id"]))
      assert Enum.all?(messages, &(&1["conversation_id"] in [nil, reader]))
    end
  end

  test "conversation subscriptions publish each committed message once", %{group_id: group_id} do
    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Subscribed task",
               "participants" => [user_participant(SystemsClock.system_time(:millisecond))]
             })

    conversation_id = conversation["conversation_id"]

    assert {:ok, %{"owner_pid" => _owner, "tail_seq" => 0}} =
             ConversationServer.subscribe_group_conversation(
               group_id,
               conversation_id,
               SystemsRuntime.Proc.self()
             )

    attrs = %{"content" => "first", "client_request_id" => "subscribed-message-1"}

    assert {:ok, %{"inserted" => true, "message_id" => message_id, "seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    settle_receive({:conversation_message_created, ^group_id, ^conversation_id, ^message_id, 1})
    meta_key = Keys.ctl_group_conversation_meta(group_id, conversation_id)
    meta_before_retry = SalixStore.S3.Fake.dump()[meta_key].body

    assert {:ok, %{"inserted" => false, "seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert SalixStore.S3.Fake.dump()[meta_key].body == meta_before_retry

    settle_refute_receive(
      {:conversation_message_created, ^group_id, ^conversation_id, ^message_id, 1},
      100
    )
  end

  test "group task-list subscriptions invalidate on canonical task create, update, and message append",
       %{
         group_id: group_id
       } do
    assert {:ok, %{"owner_pid" => owner_pid}} =
             ConversationServer.subscribe_group_conversation_list(
               group_id,
               "agent_task",
               SystemsRuntime.Proc.self()
             )

    assert SystemsRuntime.Proc.is_process(owner_pid)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "SSE task",
               "status" => "active",
               "participants" => [user_participant(SystemsClock.system_time(:millisecond))]
             })

    settle_receive(
      {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conversation_id,
       first_version}
    )

    assert is_binary(first_version)

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "status" => "completed"
             })

    settle_receive(
      {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conversation_id,
       second_version}
    )

    assert second_version != first_version

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "client_request_id" => "task-list-sse-follow-up",
                 "content" => "follow up"
               }
             )

    settle_receive(
      {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conversation_id,
       third_version}
    )

    assert third_version != second_version
  end

  test "participant direct reads recover a missed realtime draft clear invalidation", %{
    group_id: group_id,
    router_id: router_id,
    router_session_id: router_session_id
  } do
    now = SystemsClock.system_time(:millisecond)

    participant =
      router_id
      |> agent_participant("router", now)
      |> Map.put("payload", %{"session_id" => router_session_id})

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant realtime status",
               "participants" => [participant]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    initial_activity = %{
      "session_id" => router_session_id,
      "state" => "active",
      "status" => "is thinking...",
      "updated_at" => now
    }

    previous_session_activity = SystemsRuntime.get_env(:salix_im, :session_activity_mod)

    RealtimeSessionActivity.configure(
      SystemsRuntime.Proc.self(),
      router_id,
      router_session_id,
      initial_activity
    )

    SystemsRuntime.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)

    on_exit(fn ->
      RealtimeSessionActivity.clear()
      restore(:salix_im, :session_activity_mod, previous_session_activity)
    end)

    assert {:ok,
            %{
              "owner_pid" => participant_owner,
              "status" => %{
                "conversation_id" => ^conversation_id,
                "participant_id" => ^participant_id,
                "activity" => %{
                  "state" => "active",
                  "status" => "is thinking...",
                  "updated_at" => ^now
                }
              }
            }} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id,
               SystemsRuntime.Proc.self()
             )

    settle_receive(
      {:participant_session_subscription, ^participant_owner, ^router_id, ^router_session_id}
    )

    response_key =
      "rsp_" <> Base.url_encode64(:binary.copy(<<7>>, 18), padding: false)

    assert :ok =
             RealtimeSessionActivity.publish(
               ConversationParticipantActivity.session_snapshot(
                 initial_activity,
                 nil,
                 %{
                   "agent_group_id" => group_id,
                   "conversation_id" => conversation_id,
                   "participant_id" => participant_id,
                   "response_key" => response_key,
                   "revision" => 2,
                   "status" => "streaming",
                   "text" => "这只是 Participant draft",
                   "source_message_ids" => ["groupconv:source-message"]
                 }
               )
             )

    settle_receive(
      {:conversation_participant_status_changed, ^group_id, ^conversation_id, ^participant_id}
    )

    assert {:ok,
            %{
              "conversation_id" => ^conversation_id,
              "participant_id" => ^participant_id,
              "activity" => %{"state" => "active"},
              "draft" => %{
                "response_key" => ^response_key,
                "revision" => 2,
                "status" => "streaming",
                "text" => "这只是 Participant draft"
              }
            }} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )

    assert :ok = RealtimeSessionActivity.publish(initial_activity)

    settle_receive(
      {:conversation_participant_status_changed, ^group_id, ^conversation_id, ^participant_id}
    )

    assert {:ok,
            %{
              "conversation_id" => ^conversation_id,
              "participant_id" => ^participant_id,
              "activity" => %{"state" => "active"}
            }} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )

    assert :ok =
             RealtimeSessionActivity.publish(
               ConversationParticipantActivity.session_snapshot(
                 initial_activity,
                 nil,
                 %{
                   "agent_group_id" => group_id,
                   "conversation_id" => conversation_id,
                   "participant_id" => participant_id,
                   "response_key" => response_key,
                   "revision" => 3,
                   "status" => "streaming",
                   "text" => "即将静默清除的 Participant draft",
                   "source_message_ids" => ["groupconv:source-message"]
                 }
               )
             )

    settle_receive(
      {:conversation_participant_status_changed, ^group_id, ^conversation_id, ^participant_id}
    )

    assert {:ok, %{"draft" => %{"revision" => 3}}} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )

    # Session callbacks are invalidation hints, so a synchronous read must
    # recover the current owner snapshot even when the clear hint is lost.
    assert :ok = RealtimeSessionActivity.replace_without_notify(initial_activity)

    settle_refute_receive(
      {:conversation_participant_status_changed, ^group_id, ^conversation_id, ^participant_id},
      100
    )

    assert {:ok, status_after_missed_clear} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )

    refute Map.has_key?(status_after_missed_clear, "draft")
  end

  test "group conversation lifecycle admits addressed messages into participant Sessions", %{
    group_id: group_id,
    router_id: router_id,
    router_session_id: router_session_id,
    worker_id: worker_id
  } do
    now = SystemsClock.system_time(:millisecond)

    {:ok, conversation} =
      SalixIM.ConversationInput.create_group_conversation(group_id, %{
        "title" => "Alpha project 深色 e\u0301",
        "participants" => [
          user_participant(now),
          agent_participant(router_id, "router", now),
          agent_participant(worker_id, "worker", now)
        ],
        "created_at" => now,
        "updated_at" => now
      })

    conversation_id = conversation["conversation_id"]
    assert Ids.valid_conversation_id?(conversation_id)
    assert conversation["message_count"] == 0

    assert {:ok, %{"data" => listed_conversations, "has_more" => false}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.any?(listed_conversations, &(&1["conversation_id"] == conversation_id))

    assert {:ok, [%{"conversation_id" => ^conversation_id}]} =
             Conversations.search_group_conversations(group_id, "alpha", limit: 10)

    for {query, opts} <- [
          {"A", [limit: nil]},
          {"深", [limit: "invalid"]},
          {"e\u0301", [limit: 1_000]}
        ] do
      assert {:ok, [%{"conversation_id" => ^conversation_id}]} =
               Conversations.search_group_conversations(group_id, query, opts)
    end

    assert {:ok, result} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "content" => "hello worker and router",
               "client_request_id" => "msg-user-1",
               "created_at" => now + 1
             })

    assert result["inserted"] == true
    assert result["delivery_status"] == "queued"
    user_message_id = result["message_id"]
    assert Ids.valid_message_id?(user_message_id)

    assert {:ok, duplicate} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "content" => "hello worker and router",
               "client_request_id" => "msg-user-1",
               "created_at" => now + 1
             })

    assert duplicate["inserted"] == false
    assert duplicate["delivery_status"] == "queued"
    assert duplicate["message_id"] == user_message_id

    assert {:ok, agent_result} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "kind" => "message",
                 "content" => [%{"type" => "text", "text" => "worker report"}],
                 "client_request_id" => "msg-worker-1",
                 "created_at" => now + 2
               }
             )

    assert agent_result["delivery_status"] == "queued"
    worker_message_id = agent_result["message_id"]
    assert Ids.valid_message_id?(worker_message_id)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert Enum.map(messages, & &1["message_id"]) == [user_message_id, worker_message_id]

    assert {:ok, after_messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id,
               after_id: user_message_id,
               limit: 20
             )

    assert Enum.map(after_messages, & &1["message_id"]) == [worker_message_id]

    assert {:ok, after_seq_messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id,
               after_seq: result["seq"],
               limit: 20
             )

    assert Enum.map(after_seq_messages, & &1["message_id"]) == [worker_message_id]

    for {message, agent} <- [
          {user_message_id, router_id},
          {user_message_id, worker_id},
          {worker_message_id, router_id}
        ] do
      assert eventually_value(fn -> admitted?(group_id, conversation_id, message, agent) end)
    end

    refute admitted?(group_id, conversation_id, worker_message_id, worker_id)

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert Enum.find(participants, &(&1["agent_id"] == router_id))["payload"]["session_id"] ==
             router_session_id

    assert Ids.valid_session_id?(
             Enum.find(participants, &(&1["agent_id"] == worker_id))["payload"]["session_id"]
           )
  end

  test "message metadata rejects delivery billing context", %{group_id: group_id} do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Message metadata boundary",
               "participants" => [user_participant(now)]
             })

    assert {:error, {:bad_request, "billing_context is delivery-only"}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "content" => "must not persist billing",
                 "metadata" => %{"billing_context" => %{"billing_account_id" => "ba_wrong"}}
               }
             )

    assert {:ok, []} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)
  end

  test "redelivery E2E restages an existing message without rewinding the participant", %{
    group_id: group_id,
    worker_id: worker_id
  } do
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)

    SystemsRuntime.put_env(
      :salix_im,
      :capture_agent_delivery_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :capture_agent_delivery_test_pid) end)

    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Missing external session recovery",
               "participants" => [
                 user_participant(now),
                 agent_participant(worker_id, "worker", now)
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant = Enum.find(participants, &(&1["agent_id"] == worker_id))
    participant_id = participant["participant_id"]

    assert {:ok, %{"message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "content" => "continue the interrupted task",
               "client_request_id" => "missing-session-message"
             })

    settle_receive({:captured_agent_delivery, ^worker_id, first_payload, first_opts})
    first_source_id = first_opts[:source_message_id]

    request_id = "recover-missing-session-1"

    assert {:ok, %{"delivery_status" => "queued"}} =
             ConversationServer.redeliver_group_conversation_agent_message(
               group_id,
               conversation_id,
               %{
                 "participant_id" => participant_id,
                 "message_id" => message_id,
                 "request_id" => request_id
               }
             )

    settle_receive({:captured_agent_delivery, ^worker_id, second_payload, second_opts})

    assert Map.drop(second_payload, [:pre_deliveries, :trusted_origin, :delivered_at_ms]) ==
             Map.drop(first_payload, [:pre_deliveries, :trusted_origin, :delivered_at_ms])

    assert first_payload.trusted_origin["source_message_id"] == first_source_id
    assert second_payload.trusted_origin["source_message_id"] == second_opts[:source_message_id]

    assert Map.delete(second_payload.trusted_origin, "source_message_id") ==
             Map.delete(first_payload.trusted_origin, "source_message_id")

    assert second_opts[:source_message_id] ==
             first_source_id <> ":redelivery:" <> SalixStore.Crypto.hex(request_id)

    assert [first_context] = first_payload.pre_deliveries
    assert [second_context] = second_payload.pre_deliveries

    assert first_context.content =~ "- source_message_id: #{first_source_id}\n"
    assert second_context.content =~ "- source_message_id: #{second_opts[:source_message_id]}\n"

    assert Map.drop(second_context, [:source_message_id, :content]) ==
             Map.drop(first_context, [:source_message_id, :content])

    assert second_context.source_message_id ==
             second_opts[:source_message_id] <> ":source-context"

    assert second_context.content =~
             "explicitly redelivered after its earlier runtime delivery was diagnosed as missing"

    refute first_context.content =~ "explicitly redelivered"

    assert {:ok,
            [
              %{"message_id" => ^message_id},
              %{"metadata" => %{"event_type" => "message.redelivery"}}
            ]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert {:ok, %{"participants" => current}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert Enum.find(current, &(&1["participant_id"] == participant_id))["delivery_cursor_seq"] ==
             participant["delivery_cursor_seq"]

    assert {:ok, %{"delivery_status" => "exists"}} =
             ConversationServer.redeliver_group_conversation_agent_message(
               group_id,
               conversation_id,
               %{
                 "participant_id" => participant_id,
                 "message_id" => message_id,
                 "request_id" => request_id
               }
             )

    settle_refute_receive({:captured_agent_delivery, ^worker_id, _payload, _opts}, 200)
  end

  test "public create cannot use preallocated participant ids to bypass agent membership validation",
       %{
         group_id: group_id
       } do
    missing_agent_id = Ids.new_agent_id(group_id)

    assert {:error, :not_found} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Reject caller-preallocated agent",
               "preallocated_participants" => true,
               "participants" => [
                 %{
                   "participant_id" => Ids.new_participant_id(),
                   "actor_type" => "agent",
                   "agent_id" => missing_agent_id,
                   "role_label" => "worker"
                 }
               ]
             })
  end

  test "ordinary Message mentions address explicit participants while participant policy can block",
       %{
         group_id: group_id,
         router_id: router_id,
         worker_id: worker_id
       } do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Mention acceptance",
               "participants" => [
                 user_participant(now),
                 agent_participant(worker_id, "worker", now)
                 |> Map.put("notification_filter", %{
                   "messages" => "mentioned",
                   "statuses" => "none"
                 }),
                 agent_participant(router_id, "router", now)
                 |> Map.put("notification_filter", %{
                   "messages" => "none",
                   "statuses" => "none"
                 })
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    sender = Enum.find(participants, &(&1["actor_type"] == "user"))
    worker = Enum.find(participants, &(&1["agent_id"] == worker_id))
    router = Enum.find(participants, &(&1["agent_id"] == router_id))

    assert worker["notification_filter"]["messages"] == "mentioned"
    assert router["notification_filter"]["messages"] == "none"

    assert {:ok, %{"delivery_status" => "queued", "message_id" => unmentioned_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "participant_id" => sender["participant_id"],
                 "content" => "shared context",
                 "client_request_id" => "mention-shared-context"
               }
             )

    assert eventually_value(fn ->
             with {:ok, worker_state} <-
                    Conversations.get_group_conversation_participant(
                      group_id,
                      conversation_id,
                      worker["participant_id"]
                    ),
                  {:ok, router_state} <-
                    Conversations.get_group_conversation_participant(
                      group_id,
                      conversation_id,
                      router["participant_id"]
                    ) do
               worker_state["delivery_cursor_seq"] >= 1 and
                 router_state["delivery_cursor_seq"] >= 1
             else
               _ -> false
             end
           end)

    refute admitted?(group_id, conversation_id, unmentioned_id, worker_id)

    refute admitted?(group_id, conversation_id, unmentioned_id, router_id)

    mentions = %{"participant_ids" => [worker["participant_id"], router["participant_id"]]}

    assert {:ok, %{"delivery_status" => "queued", "message_id" => mentioned_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "participant_id" => sender["participant_id"],
                 "content" => "explicit request",
                 "mentions" => mentions,
                 "client_request_id" => "mention-explicit-request"
               }
             )

    assert eventually_value(fn ->
             admitted?(group_id, conversation_id, mentioned_id, worker_id)
           end)

    refute admitted?(group_id, conversation_id, mentioned_id, router_id)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert %{"message_id" => ^mentioned_id, "mentions" => ^mentions} =
             Enum.find(messages, &(&1["message_id"] == mentioned_id))
  end

  test "owner serialization assigns distinct sequences and one idempotent append", %{
    group_id: group_id
  } do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Concurrent append",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"conversation_id" => idempotent_conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Concurrent idempotent append",
               "participants" => [user_participant(now)]
             })

    append = fn target_conversation_id, request_id, text ->
      SystemsRuntime.Task.async(fn ->
        ConversationServer.append_group_conversation_message(
          group_id,
          target_conversation_id,
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "content" => text,
            "client_request_id" => request_id
          }
        )
      end)
    end

    first = append.(conversation_id, "split-a", "first")
    second = append.(conversation_id, "split-b", "second")

    assert {:ok, %{"inserted" => true}} = settled_await(first)
    assert {:ok, %{"inserted" => true}} = settled_await(second)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert Enum.map(messages, & &1["seq"]) == [1, 2]

    assert MapSet.new(Enum.map(messages, & &1["client_request_id"])) ==
             MapSet.new(["split-a", "split-b"])

    assert messages |> Enum.map(& &1["message_id"]) |> Enum.uniq() |> length() == 2

    duplicate_a =
      append.(idempotent_conversation_id, "same-request", "same")

    duplicate_b =
      append.(idempotent_conversation_id, "same-request", "same")

    duplicate_results = [settled_await(duplicate_a), settled_await(duplicate_b)]

    assert Enum.sort(Enum.map(duplicate_results, fn {:ok, result} -> result["inserted"] end)) == [
             false,
             true
           ]

    assert {:ok, [idempotent_message]} =
             Conversations.list_group_conversation_messages(
               group_id,
               idempotent_conversation_id,
               limit: 10
             )

    assert idempotent_message["seq"] == 1
    assert idempotent_message["client_request_id"] == "same-request"
  end

  test "owner serialization cannot leave the same sequence in different segments", %{
    group_id: group_id
  } do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Concurrent segment boundary",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => "current",
                 "content" => String.duplicate("s", 850_000),
                 "client_request_id" => "segment-seed"
               }
             )

    append = fn request_id, content ->
      SystemsRuntime.Task.async(fn ->
        ConversationServer.append_group_conversation_message(
          group_id,
          conversation_id,
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "content" => content,
            "client_request_id" => request_id
          }
        )
      end)
    end

    small = append.("segment-small", "small")
    large = append.("segment-large", String.duplicate("l", 200_000))

    assert {:ok, small_result} = settled_await(small)
    assert {:ok, large_result} = settled_await(large)
    assert small_result["inserted"] == true
    assert large_result["inserted"] == true

    segment_prefix =
      Keys.ctl_group_conversation_messages_segments_prefix(group_id, conversation_id)

    assert {:ok, segment_objects} = SalixStore.S3.list_all(segment_prefix)

    raw_messages =
      Enum.flat_map(segment_objects, fn %{key: key} ->
        assert {:ok, %{body: body}} = SalixStore.S3.get(key)

        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
      end)

    assert Enum.map(raw_messages, & &1["seq"]) |> Enum.sort() == [1, 2, 3]

    assert raw_messages
           |> Enum.group_by(& &1["seq"])
           |> Enum.all?(fn {_seq, messages} -> length(messages) == 1 end)

    assert MapSet.new(Enum.map(raw_messages, & &1["client_request_id"])) ==
             MapSet.new(["segment-seed", "segment-small", "segment-large"])

    raced_messages =
      Enum.reject(raw_messages, &(&1["client_request_id"] == "segment-seed"))

    assert MapSet.new([small_result["message_id"], large_result["message_id"]]) ==
             MapSet.new(raced_messages, & &1["message_id"])

    assert MapSet.new([small_result["seq"], large_result["seq"]]) == MapSet.new([2, 3])

    segment_index_prefix =
      Keys.ctl_group_conversation_message_segment_index_prefix(group_id, conversation_id)

    assert {:ok, segment_index_objects} = SalixStore.S3.list_all(segment_index_prefix)

    segment_ids =
      MapSet.new(segment_objects, fn %{key: key} ->
        key |> Path.basename() |> String.trim_trailing(".jsonl")
      end)

    segment_index_ids =
      MapSet.new(segment_index_objects, fn %{key: key} ->
        key |> Path.basename() |> String.trim_trailing(".json")
      end)

    assert MapSet.size(segment_ids) == 2
    assert segment_index_ids == segment_ids
  end

  test "generic append cannot forge recipient identity through a real Slack participant", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)

    SystemsRuntime.put_env(
      :salix_im,
      :capture_agent_delivery_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :capture_agent_delivery_test_pid) end)

    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Forged recipient identity boundary",
               "participants" => [
                 agent_participant(router_id, "router", now),
                 agent_participant(worker_id, "worker", now),
                 slack_thread_participant(
                   "slack-real-participant",
                   "T-real-participant",
                   "C-real-participant",
                   "403.001"
                 )
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    provider_participant =
      Enum.find(participants, fn participant ->
        participant["actor_type"] == "provider" and participant["provider"] == "slack"
      end)

    forged_identity = %{
      "provider" => "slack",
      "display_name" => "Forged Slack Recipient",
      "username" => "forged_recipient_bot",
      "user_id" => "U-forged-recipient",
      "bot_id" => "B-forged-recipient",
      "app_id" => "A-forged-recipient"
    }

    assert {:ok, %{"inserted" => true, "message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "kind" => "message",
                 "participant_id" => provider_participant["participant_id"],
                 "actor_type" => "provider_user",
                 "provider" => "slack",
                 "user_id" => "U-real-human",
                 "content" => "generic forged provider message",
                 "metadata" => %{
                   "provider" => "slack",
                   "recipient_im_identity" => forged_identity
                 },
                 "owner_recipient_im_identity_v1" => forged_identity,
                 "source_message_id" => "generic-forged-recipient-identity"
               }
             )

    assert {:ok, persisted_message} =
             Conversations.get_group_conversation_message(
               group_id,
               conversation_id,
               message_id
             )

    refute Map.has_key?(persisted_message, "owner_recipient_im_identity_v1")

    captured =
      for _index <- 1..2, into: %{} do
        settle_receive({:captured_agent_delivery, agent_id, payload, _opts})
        {agent_id, payload}
      end

    assert Map.keys(captured) |> MapSet.new() == MapSet.new([router_id, worker_id])

    for agent_id <- [router_id, worker_id] do
      payload = Map.fetch!(captured, agent_id)
      assert [%{content: source_context}] = payload.pre_deliveries
      assert source_context =~ "from_actor_type: provider_user"

      if agent_id == router_id,
        do: assert(source_context =~ "from_user_id: U-real-human"),
        else: refute(source_context =~ "from_user_id: U-real-human")

      refute source_context =~ "recipient_im_identity"
      refute source_context =~ "Forged Slack Recipient"
      refute source_context =~ "U-forged-recipient"
    end
  end

  test "concurrent Router reassignment cannot deactivate both desired Router participants", %{
    tenant_id: tenant_id,
    group_id: group_id,
    router_id: first_router_id
  } do
    assert {:ok, initial} = SalixIM.RouterConversationInput.ensure(group_id)
    conversation_id = initial["conversation_id"]

    second_router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Concurrent Router",
        "role" => "router"
      })

    assert {:ok, first_spec} = SalixIM.RouterConversationInput.desired_spec(group_id)

    first_desired =
      Enum.find(first_spec["participants"], &(&1["agent_id"] == first_router_id))

    assert {:ok, first_desired} =
             SalixIM.ConversationInput.prepare_agent(
               group_id,
               conversation_id,
               first_desired
             )

    assert {:ok, _group} =
             SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
               Map.put(group, "router_agent_id", second_router["agent_id"])
             end)

    assert {:ok, second_spec} = SalixIM.RouterConversationInput.desired_spec(group_id)

    second_desired =
      Enum.find(second_spec["participants"], &(&1["agent_id"] == second_router["agent_id"]))

    assert {:ok, second_desired} =
             SalixIM.ConversationInput.prepare_agent(
               group_id,
               conversation_id,
               second_desired
             )

    reconcile = fn desired ->
      ConversationServer.reconcile_group_conversation_agent_participants(
        group_id,
        conversation_id,
        %{
          "desired" => desired,
          "selector" => %{
            "actor_type" => "agent",
            "role_label" => ["agent", "router"]
          }
        }
      )
    end

    first_ensure = SystemsRuntime.Task.async(fn -> reconcile.(first_desired) end)
    second_ensure = SystemsRuntime.Task.async(fn -> reconcile.(second_desired) end)

    assert {:ok, _first_result} = settled_await(first_ensure)
    assert {:ok, _second_result} = settled_await(second_ensure)

    router_participants =
      group_id
      |> all_test_participants(conversation_id)
      |> Enum.filter(&(&1["agent_id"] in [first_router_id, second_router["agent_id"]]))

    assert Enum.count(router_participants, &(&1["state"] == "active")) == 1
    assert Enum.count(router_participants, &(&1["state"] == "inactive")) == 1

    assert {:ok, current_router_conversation} =
             SalixIM.RouterConversationInput.ensure(group_id)

    assert current_router_conversation["conversation_id"] == conversation_id
    assert current_router_conversation["router_agent_id"] == second_router["agent_id"]

    assert {:error, :stale_group_router_authority} =
             ConversationServer.reconcile_group_conversation_agent_participants(
               group_id,
               conversation_id,
               %{
                 "desired" => first_desired,
                 "selector" => %{
                   "actor_type" => "agent",
                   "role_label" => ["agent", "router"]
                 },
                 "authority_guard" => %{
                   "type" => "group_router",
                   "router_agent_id" => first_router_id
                 }
               }
             )

    router_participants_after_stale =
      group_id
      |> all_test_participants(conversation_id)
      |> Enum.filter(&(&1["agent_id"] in [first_router_id, second_router["agent_id"]]))

    assert Enum.any?(router_participants_after_stale, fn participant ->
             participant["agent_id"] == first_router_id and participant["state"] == "inactive"
           end)

    assert Enum.any?(router_participants_after_stale, fn participant ->
             participant["agent_id"] == second_router["agent_id"] and
               participant["state"] == "active"
           end)
  end

  test "conversation owner completes one idempotent append across ambiguous segment and meta writes",
       %{
         group_id: group_id
       } do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Recovered append",
               "participants" => [user_participant(now)]
             })

    segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    conversation_key = Keys.ctl_group_conversation(group_id, conversation_id)
    sequence_key = Keys.ctl_group_conversation_message_seq_index(group_id, conversation_id, 1)
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, sequence_key})
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, segment_key})
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, conversation_key})

    attrs = %{
      "content" => "persist exactly once",
      "client_request_id" => "ambiguous-append"
    }

    assert {:ok, %{"inserted" => true, "message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, %{"inserted" => false, "message_id" => ^message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, [%{"message_id" => ^message_id, "content" => content}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )

    assert content == [%{"type" => "text", "text" => "persist exactly once"}]
  end

  test "conversation list owns bounded kind filtering and paginates canonical Tasks", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    assert {:ok, _chat} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Newest internal chat",
               "updated_at" => 60
             })

    task_ids =
      for {title, timestamp} <- [
            {"Task three", 50},
            {"Task two", 40},
            {"Task one", 30}
          ] do
        assert {:ok, task} =
                 create_task_conversation(group_id, router_id, worker_id, %{
                   "title" => title,
                   "content" => title,
                   "created_at" => timestamp
                 })

        task["conversation_id"]
      end

    assert {:ok,
            %{
              "data" => first_page,
              "has_more" => true,
              "next_cursor" => cursor
            }} =
             Conversations.list_group_conversations(group_id,
               kind: "agent_task",
               limit: 2
             )

    first_ids = Enum.map(first_page, & &1["conversation_id"])
    assert length(first_ids) == 2
    assert Enum.all?(first_ids, &(&1 in task_ids))
    assert Enum.all?(first_page, &(&1["kind"] == "agent_task"))
    assert is_binary(cursor)

    assert {:ok, %{"data" => second_page, "has_more" => false}} =
             Conversations.list_group_conversations(group_id,
               kind: "agent_task",
               limit: 2,
               cursor: cursor
             )

    second_ids = Enum.map(second_page, & &1["conversation_id"])
    assert length(second_ids) == 1
    assert Enum.all?(second_page, &(&1["kind"] == "agent_task"))
    assert MapSet.new(first_ids ++ second_ids) == MapSet.new(task_ids)
  end

  # A change writes the Conversation's newer list entry before it commits and deletes the older one after. A
  # listing that ran before the newer entry existed holds only the older one; the Conversation is still listed, once,
  # at its new place.
  test "a conversation changed while the list was read is listed at its new place", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => older_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Older chat",
               "updated_at" => 10
             })

    assert {:ok, %{"conversation_id" => changed_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Changed chat",
               "updated_at" => 20
             })

    entry_of = fn conversation_id ->
      assert {:ok, %{objects: objects}} =
               S3.list(Keys.ctl_group_conversation_list_prefix(group_id))

      Enum.find_value(objects, fn %{key: key} ->
        assert {:ok, %{body: body}} = S3.get(key)
        if Jason.decode!(body)["conversation_id"] == conversation_id, do: {key, body}
      end)
    end

    {older_key, older_body} = entry_of.(changed_id)

    assert {:ok, _changed} =
             ConversationServer.update_group_conversation(group_id, changed_id, %{
               "title" => "Changed chat, renamed"
             })

    {newer_key, _newer_body} = entry_of.(changed_id)
    assert newer_key < older_key

    # The store as that listing saw it: the older entry, not the newer one.
    assert {:ok, _} = S3.put(older_key, older_body)
    assert :ok = S3.delete(newer_key)

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert [
             %{"conversation_id" => ^changed_id, "title" => "Changed chat, renamed"},
             %{"conversation_id" => ^older_id}
           ] =
             Enum.filter(listed, &(&1["conversation_id"] in [changed_id, older_id]))
  end

  test "deleting a conversation retires its participants and pin after admission", %{
    tenant_id: tenant_id,
    group_id: group_id,
    worker_id: worker_id
  } do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Delete outbox",
               "participants" => [
                 user_participant(now),
                 %{
                   "actor_type" => "agent",
                   "agent_id" => worker_id,
                   "state" => "active",
                   "notification_filter" => %{"messages" => "all", "statuses" => "none"}
                 }
               ]
             })

    assert {:ok, _participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               bft_participant()
             )

    conversation_meta_key = Keys.ctl_group_conversation(group_id, conversation_id)

    assert {:ok, %{body: meta_body}} = SalixStore.S3.get(conversation_meta_key)
    assert is_map(Jason.decode!(meta_body)[@participant_identity_slots_field])
    assert {:ok, _pin} = ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)
    assert {:ok, %{"data" => [_]}} = Conversations.list_conversation_pins(group_id, tenant_id)

    assert {:ok, %{"delivery_status" => "queued", "message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "content" => "wake worker",
               "client_request_id" => "delete-outbox-message"
             })

    assert eventually_value(fn ->
             admitted?(group_id, conversation_id, message_id, worker_id)
           end)

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)
    assert {:error, :not_found} = Conversations.get_group_conversation(group_id, conversation_id)

    assert eventually_value(fn ->
             if delivery_records(group_id, conversation_id) == %{}, do: true
           end)

    assert eventually_value(fn ->
             if SalixStore.S3.get(conversation_meta_key) == {:error, :not_found}, do: true
           end)

    assert {:ok, %{"data" => []}} = Conversations.list_conversation_pins(group_id, tenant_id)
  end

  test "explicit rebuild repairs missing message documents even when state metadata is current",
       %{
         group_id: group_id
       } do
    reset_search_projection!()

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Repair subtitle",
               "participants" => [user_participant(SystemsClock.system_time(:millisecond))]
             })

    assert {:ok, %{"delivery_status" => "recorded"}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "content" => "Repair this searchable Task body",
               "client_request_id" => "repair-search-subtitle"
             })

    assert eventually_value(fn ->
             if SalixIM.ConversationSearchEnqueuer.pending_count() == 0 and
                  search_job_count(group_id, conversation_id) == 1,
                do: true
           end)

    assert {:ok, initial_claim} = ConversationSearch.claim_one("initial-projector", 30_000)
    assert initial_claim.conversation_id == conversation_id
    assert :ok = ConversationSearchProjection.process_claim(initial_claim)
    assert :ok = ConversationSearch.complete(initial_claim)

    assert {:ok,
            [
              %{
                "conversation_id" => ^conversation_id,
                "content_match" => %{"snippet" => initial_snippet}
              }
            ]} = Conversations.search_group_tasks(group_id, "Repair")

    assert initial_snippet =~ "Repair"

    Repo.query!(
      "DELETE FROM conversation_search_documents " <>
        "WHERE writer_generation = 'test-search-generation' " <>
        "AND agent_group_id = $1 AND conversation_id = $2 " <>
        "AND document_type = 'message'",
      [group_id, conversation_id]
    )

    assert {:ok, [%{"conversation_id" => ^conversation_id} = title_only]} =
             Conversations.search_group_tasks(group_id, "Repair")

    refute Map.has_key?(title_only, "content_match")

    assert :ok = ConversationSearch.enqueue_rebuild(group_id, conversation_id)
    assert {:ok, repair_claim} = ConversationSearch.claim_one("repair-projector", 30_000)
    assert repair_claim.operation == :rebuild
    assert :ok = ConversationSearchProjection.process_claim(repair_claim)
    assert :ok = ConversationSearch.complete(repair_claim)

    assert {:ok,
            [
              %{
                "conversation_id" => ^conversation_id,
                "content_match" => %{"snippet" => repaired_snippet}
              }
            ]} = Conversations.search_group_tasks(group_id, "Repair")

    assert repaired_snippet =~ "Repair this searchable Task body"
  end

  test "Task search keeps its log frontier while omitting internal delivery content", %{
    group_id: group_id
  } do
    conversation_id = Ids.new_conversation_id()

    rows = [
      task_search_row(1, "Visible worker result"),
      task_search_row(2, "Private provider context")
      |> Map.merge(%{"actor_type" => "system", "agent_input" => %{}}),
      task_search_row(3, "Internal delivery status")
      |> Map.merge(%{
        "actor_type" => "system",
        "kind" => "app_event",
        "metadata" => %{"event_type" => "provider.status"}
      })
    ]

    segment_id = task_search_segment_id(1)
    put_task_search_segment(group_id, conversation_id, segment_id, rows, nil)
    put_task_search_pointer(group_id, conversation_id, hd(rows), segment_id)

    assert {:ok, window} =
             Conversations.task_search_content_window(
               task_search_conversation(group_id, conversation_id, 3)
             )

    assert [%{seq: 1, envelope: %{content: "Visible worker result"}}] = window.messages
  end

  test "delete tombstone hides the aggregate before bounded cleanup and resumes after owner restart",
       %{
         tenant_id: tenant_id,
         group_id: group_id
       } do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Durable delete tombstone",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "content" => "delete me",
                 "client_request_id" => "durable-delete-message"
               }
             )

    assert {:ok, _pin} =
             ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)

    prefix = Keys.ctl_group_conversation_dir(group_id, conversation_id)
    SystemsRuntime.put_env(:salix_store, :s3_backend, ConversationDeleteFaultOnceS3)
    SystemsRuntime.put_env(:salix_im, :delete_fault_conversation_prefix, prefix)
    SystemsRuntime.put_env(:salix_im, :fail_conversation_child_delete_once, true)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_delete_fault_test_pid,
      SystemsRuntime.Proc.self()
    )

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)
    settle_receive({:conversation_child_delete_failed, failed_key})
    assert String.starts_with?(failed_key, prefix)

    assert {:error, :not_found} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:error, :not_found} =
             Conversations.get_group_conversation_with_messages(group_id, conversation_id)

    assert {:error, :not_found} =
             Conversations.list_group_conversation_messages(group_id, conversation_id)

    assert {:error, :not_found} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert {:error, :not_found} =
             Conversations.get_group_conversation_message(
               group_id,
               conversation_id,
               message_id
             )

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    refute Enum.any?(listed, &(&1["conversation_id"] == conversation_id))

    assert {:ok, []} = Conversations.search_group_conversations(group_id, "durable delete")
    assert {:ok, %{"data" => []}} = Conversations.list_conversation_pins(group_id, tenant_id)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:ok, restarted_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    assert restarted_owner != owner

    assert eventually_value(fn ->
             with {:ok, %{objects: []}} <- SalixStore.S3.list(prefix, max_keys: 1),
                  {:ok, %{objects: []}} <-
                    SalixStore.S3.list(
                      Keys.ctl_group_conversation_delivery_wakeups_prefix(
                        group_id,
                        conversation_id
                      ),
                      max_keys: 1
                    ),
                  {:ok, %{"data" => []}} <-
                    Conversations.list_conversation_pins(group_id, tenant_id) do
               true
             else
               _ -> nil
             end
           end)
  end

  test "delegator Tasks record the creator and inherit the requester through an existing Task", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    owner_user_id = "owner-user-1"
    trusted_activation_refs = [%{"ref" => "trusted-task-activation"}]

    assert {:ok, %{"conversation_id" => parent_conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Parent chat",
               "owner_user_id" => owner_user_id
             })

    assert {:ok, result} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               %{
                 "content" => "check creator metadata",
                 "source_refs" => %{
                   "parent_conversation_id" => parent_conversation_id,
                   "meeting_activation_refs" => trusted_activation_refs
                 }
               }
             )

    conversation_id = result["conversation_id"]

    assert result["conversation_kind"] == "agent_task"

    assert {:ok, conversation} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert conversation["created_by_agent_id"] == router_id
    assert conversation["owner_user_id"] == owner_user_id
    refute Map.has_key?(conversation, "created_by_user_id")
    assert conversation["source_refs"]["parent_conversation_id"] == parent_conversation_id
    assert conversation["source_refs"]["meeting_activation_refs"] == trusted_activation_refs

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert %{"participant_id" => participant_id, "user_id" => ^owner_user_id} =
             Enum.find(participants, &(&1["actor_type"] == "user"))

    assert Ids.valid_participant_id?(participant_id)

    assert {:ok, child} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               %{
                 "content" => "create separate work from the existing Task",
                 "source_refs" => %{
                   "parent_conversation_id" => conversation_id,
                   "parent_message_id" => result["message_id"]
                 }
               }
             )

    assert {:ok, child_conversation} =
             Conversations.get_group_conversation(group_id, child["conversation_id"])

    assert child_conversation["owner_user_id"] == owner_user_id
    assert child_conversation["source_refs"]["parent_conversation_id"] == conversation_id
    assert child_conversation["source_refs"]["parent_message_id"] == result["message_id"]

    assert {:ok, %{"participants" => child_participants}} =
             Conversations.list_group_conversation_participants(
               group_id,
               child["conversation_id"]
             )

    assert %{"user_id" => ^owner_user_id} =
             Enum.find(child_participants, &(&1["actor_type"] == "user"))
  end

  test "ordinary task sends its initial command directly to the worker", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id, "message_id" => message_id}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               %{
                 "title" => "Explicit task delivery target",
                 "content" => "research the task",
                 "client_request_id" => "explicit-task-delivery-target"
               }
             )

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert %{
             "notification_filter" => %{"messages" => "all", "statuses" => "none"}
           } = Enum.find(participants, &(&1["agent_id"] == router_id))

    assert %{"participant_id" => worker_participant_id} =
             Enum.find(participants, &(&1["agent_id"] == worker_id))

    assert {:ok, [%{"message_id" => ^message_id} = message]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert message["delivery_filter"] == %{"participant_ids" => [worker_participant_id]}
    refute Map.has_key?(message, "mentions")
  end

  test "TaskWorkerWatch reminds a silent stopped Worker once, then tells the Router", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-nudge")

    stopped_at = SystemsClock.system_time(:millisecond)
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version, token}
    )

    settle_receive({:captured_agent_delivery, ^worker_id, nudge, _opts})
    assert nudge.content =~ "publish exactly one result Message"
    settle_refute_receive({:captured_agent_delivery, ^router_id, _, _}, 100)
    assert {:acted, ^version, :stopped, nil, nil, nil} = :sys.get_state(watch, :infinity).stop

    # A replayed timer for the same stop is ignored.
    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version, token}
    )

    settle_refute_receive({:captured_agent_delivery, _, _, _}, 100)
    # The reminder woke the Worker; it stops again without publishing.
    TaskSessionActivity.set(worker_id, session_id, "active", stopped_at + 500)
    TaskSessionActivity.notify(worker_id, session_id)
    assert eventually_value(fn -> :sys.get_state(watch, :infinity).stop == nil end)

    stopped_again = stopped_at + 1_000
    version_again = Integer.to_string(stopped_again)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_again)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version_again, :stopped, nil, _timer, token_again} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version_again, token_again}
    )

    settle_receive({:captured_agent_delivery, ^router_id, notice, _opts})
    assert notice.content =~ "stopped without publishing a result (stopped_after_reminder)"
    settle_refute_receive({:captured_agent_delivery, ^worker_id, _, _}, 100)
    # A third silent stop in the same delegation sends nothing more.
    stopped_third = stopped_at + 2_000
    version_third = Integer.to_string(stopped_third)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_third)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version_third, :stopped, nil, _timer, token_third} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version_third, token_third}
    )

    assert eventually_value(fn ->
             match?({:acted, _, _, _, _, _}, :sys.get_state(watch, :infinity).stop)
           end)

    settle_refute_receive({:captured_agent_delivery, _, _, _}, 100)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    watch_messages =
      Enum.filter(
        messages,
        &(get_in(&1, ["metadata", "message_type"]) in ["task_worker_nudge", "task_worker_stopped"])
      )

    assert Enum.map(watch_messages, &get_in(&1, ["metadata", "message_type"])) ==
             ["task_worker_nudge", "task_worker_stopped"]

    [nudge_message, notice_message] = watch_messages
    assert nudge_message["actor_type"] == "system"
    assert get_in(nudge_message, ["metadata", "task_worker_watch", "activity_version"]) == version

    assert get_in(nudge_message, ["mentions", "participant_ids"]) == [
             nudge_message["delivery_filter"]["participant_ids"] |> hd()
           ]

    assert get_in(notice_message, ["metadata", "task_worker_watch", "reason"]) ==
             "stopped_after_reminder"

    assert {:ok, %{"status" => "active"}} =
             Conversations.get_group_conversation(group_id, conversation_id)
  end

  test "TaskWorkerWatch reminds a Worker that recorded only milestones before it stopped", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-milestone")

    # A step the Worker finished is progress, not the result it owes.
    assert {:ok, _message} =
             append_task_result_message(
               group_id,
               conversation_id,
               worker_id,
               "task-worker-watch-milestone-step",
               [%{"type" => "milestone", "title" => "Read the thread"}]
             )

    stopped_at = SystemsClock.system_time(:millisecond)
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version, token}
    )

    settle_receive({:captured_agent_delivery, ^worker_id, nudge, _opts})
    assert nudge.content =~ "publish exactly one result Message"
    settle_refute_receive({:captured_agent_delivery, ^router_id, _, _}, 100)
    assert :sys.get_state(watch, :infinity).review == nil
  end

  @tag :desktop_meeting
  test "TaskWorkerWatch leaves a meeting Task's Worker alone until its recording arrives", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    configure_task_worker_watch()

    assert {:ok, %{"conversation_id" => id}} =
             SalixIM.DesktopMeetingInput.ensure(group_id, router_id, worker_id, "owner-user-1", %{
               "occurrence_id" => "meeting-worker-watch",
               "name" => "Zoom",
               "started_at" => 1_000,
               "archive_date" => "2026-09-09"
             })

    {session_id, watch} = watched_worker_session(group_id, id, worker_id)

    stop = fn stopped_at ->
      version = Integer.to_string(stopped_at)
      TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
      TaskSessionActivity.notify(worker_id, session_id)

      assert {:scheduled, ^version, :stopped, nil, _timer, token} =
               eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

      SystemsRuntime.Proc.send(
        watch,
        {:task_worker_stopped_timeout, {worker_id, session_id}, version, token}
      )

      assert eventually_value(fn ->
               match?({:acted, ^version, _, _, _, _}, :sys.get_state(watch, :infinity).stop)
             end)
    end

    # The entry went to no participant: a stop before the recording owes nothing.
    stop.(SystemsClock.system_time(:millisecond))
    settle_refute_receive({:captured_agent_delivery, _, _, _}, 100)

    assert {:ok, [_entry]} =
             Conversations.list_group_conversation_messages(group_id, id, limit: 10)

    assert {:ok, %{"status" => "active"}} =
             ConversationServer.desktop_meeting(
               group_id,
               id,
               "owner-user-1",
               %{
                 "action" => "finalize",
                 "version" => 1,
                 "smart_summary" => true,
                 "recording" => %{"recording_id" => "watched-audio"}
               },
               %{
                 "actor_type" => "user",
                 "user_id" => "owner-user-1",
                 "content" => "Process this saved meeting recording.",
                 "client_request_id" => "meeting-audio:watched-audio"
               }
             )

    settle_receive({:captured_agent_delivery, ^worker_id, _recording, _opts})

    # The recording is the Worker's delegation: a silent stop is reminded as in any Task.
    stop.(SystemsClock.system_time(:millisecond) + 1_000)
    settle_receive({:captured_agent_delivery, ^worker_id, nudge, _opts})
    assert nudge.content =~ "publish exactly one result Message"
  end

  test "TaskWorkerWatch tells the Router once when it settles after a Worker result without deciding the status",
       %{group_id: group_id, router_id: router_id, worker_id: worker_id} do
    {conversation_id, watch, router_session_id} =
      watched_task_with_worker_result(group_id, router_id, worker_id, "task-status-pending")

    # The Worker already published, so it is not reminded; the Router is still
    # busy, so it is not woken a second time either.
    settle_refute_receive({:captured_agent_delivery, _, _, _}, 100)

    assert %{phase: :waiting, result_seq: result_seq, result_at: result_at} =
             :sys.get_state(watch, :infinity).review

    assert eventually_value(fn ->
             TaskSessionActivity.subscribed?(router_id, router_session_id, watch)
           end)

    # A stop from before the result is an earlier turn that never saw it.
    TaskSessionActivity.set(router_id, router_session_id, "stopped", result_at - 2_000)
    TaskSessionActivity.notify(router_id, router_session_id)
    assert %{phase: :waiting} = :sys.get_state(watch, :infinity).review

    # The Router ends its turn and leaves the Task active.
    router_stopped = SystemsClock.system_time(:millisecond) + 1
    router_version = Integer.to_string(router_stopped)
    TaskSessionActivity.set(router_id, router_session_id, "stopped", router_stopped)
    TaskSessionActivity.notify(router_id, router_session_id)

    assert %{phase: {:scheduled, ^router_version, _timer, token}} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).review end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_status_pending_timeout, {router_id, router_session_id}, router_version, token}
    )

    settle_receive({:captured_agent_delivery, ^router_id, notice, _opts})
    assert notice.content =~ "Decide its status now"
    settle_refute_receive({:captured_agent_delivery, ^worker_id, _, _}, 100)

    # Once notified, the Router session is no longer followed.
    assert %{phase: :acted, result_seq: ^result_seq} = :sys.get_state(watch, :infinity).review
    refute TaskSessionActivity.subscribed?(router_id, router_session_id, watch)

    # A replayed timer or a later Router turn sends nothing more for this result.
    SystemsRuntime.Proc.send(
      watch,
      {:task_status_pending_timeout, {router_id, router_session_id}, router_version, token}
    )

    TaskSessionActivity.set(router_id, router_session_id, "stopped", router_stopped + 1_000)
    TaskSessionActivity.notify(router_id, router_session_id)
    settle_refute_receive({:captured_agent_delivery, _, _, _}, 100)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert [status_message] =
             Enum.filter(messages, &(&1["actor_type"] == "system"))

    assert get_in(status_message, ["metadata", "message_type"]) == "task_status_pending"
    assert get_in(status_message, ["metadata", "task_worker_watch", "result_seq"]) == result_seq

    # A restarted watch finds the notice in the Task and does not review the
    # same result again.
    %{session_ref: {^worker_id, worker_session_id}} = :sys.get_state(watch, :infinity)
    :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)
    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    assert {:ok, restarted} = SalixIM.ConversationActor.task_worker_watch(owner)
    refute restarted == watch

    assert {:scheduled, worker_version, :stopped, nil, _timer, worker_token} =
             eventually_value(fn -> :sys.get_state(restarted, :infinity).stop end)

    SystemsRuntime.Proc.send(
      restarted,
      {:task_worker_stopped_timeout, {worker_id, worker_session_id}, worker_version, worker_token}
    )

    assert eventually_value(fn ->
             match?(
               {:acted, ^worker_version, _, _, _, _},
               :sys.get_state(restarted, :infinity).stop
             )
           end)

    assert :sys.get_state(restarted, :infinity).review == nil
    refute TaskSessionActivity.subscribed?(router_id, router_session_id, restarted)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert [_one] =
             Enum.filter(
               messages,
               &(get_in(&1, ["metadata", "message_type"]) == "task_status_pending")
             )

    assert {:ok, %{"status" => "active"}} =
             Conversations.get_group_conversation(group_id, conversation_id)
  end

  test "TaskWorkerWatch leaves a Loop Task's results to its running Loop and reviews them once it stopped",
       %{group_id: group_id, router_id: router_id, worker_id: worker_id} do
    SalixIM.TestSupport.TaskLoops.install(
      {:all, %{"status" => "active", "trigger" => %{"every_minutes" => 60}}}
    )

    # Each result of a Loop Task is one run: while its Loop runs, the Router is
    # not asked to decide the status after it.
    {_conversation_id, watch, _router_session_id} =
      watched_task_with_worker_result(
        group_id,
        router_id,
        worker_id,
        "loop-task-review",
        %{"loop" => %{"cadence" => %{"every_minutes" => 60}}}
      )

    assert :sys.get_state(watch, :infinity).review == nil

    # The Loop stopped on its own: the Worker's next stop is reviewed as in
    # any Task.
    SalixIM.TestSupport.TaskLoops.put_views(
      {:all,
       %{"status" => "paused", "paused_by" => "budget", "trigger" => %{"every_minutes" => 60}}}
    )

    %{session_ref: {^worker_id, session_id}} = :sys.get_state(watch, :infinity)
    stopped_at = SystemsClock.system_time(:millisecond) + 5_000
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version, token}
    )

    assert %{phase: :waiting} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).review end)
  end

  test "TaskWorkerWatch tells the Router at once when billing refuses the Worker", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-billing")

    failed_at = SystemsClock.system_time(:millisecond)
    version = Integer.to_string(failed_at)

    TaskSessionActivity.set(
      worker_id,
      session_id,
      "error",
      failed_at,
      "insufficient_credits",
      nil,
      "error: not enough credits; add credits and try again"
    )

    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :error, "insufficient_credits", _timer, token} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version, token}
    )

    settle_receive({:captured_agent_delivery, ^router_id, notice, _opts})
    assert notice.content =~ "blocked by billing (insufficient_credits)"
    assert notice.content =~ "add credits"
    assert notice.content =~ "not a platform outage"
    settle_refute_receive({:captured_agent_delivery, ^worker_id, _, _}, 100)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    refute Enum.any?(
             messages,
             &(get_in(&1, ["metadata", "message_type"]) == "task_worker_nudge")
           )

    assert [notice_message] =
             Enum.filter(
               messages,
               &(get_in(&1, ["metadata", "message_type"]) == "task_worker_stopped")
             )

    assert get_in(notice_message, ["metadata", "task_worker_watch", "issue"]) ==
             "insufficient_credits"
  end

  @tag :task_archive
  test "a Task's latest run starts when it becomes active, and only then", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    assert {:ok, %{"conversation_id" => id}} =
             create_task_conversation(group_id, router_id, worker_id, %{
               "title" => "Run start",
               "content" => "work",
               "client_request_id" => "run-start"
             })

    assert {:ok, %{"run_started_at" => first}} =
             Conversations.get_group_conversation(group_id, id)

    assert is_integer(first) and first > 0

    # A rename, a review and its acceptance start no run.
    assert {:ok, %{"run_started_at" => ^first}} =
             ConversationServer.update_group_conversation(group_id, id, %{"title" => "Renamed"})

    assert {:ok, %{"run_started_at" => ^first, "updated_at" => review_version}} =
             ConversationServer.update_group_conversation(group_id, id, %{
               "status" => "ready_for_review"
             })

    assert {:ok, %{"status" => "completed", "run_started_at" => ^first}} =
             ConversationServer.accept_task_review(group_id, id, review_version)

    # Running again does.
    SystemsClock.sleep(2)

    assert {:ok, %{"run_started_at" => again}} =
             ConversationServer.update_group_conversation(group_id, id, %{"status" => "active"})

    assert again > first

    assert {:ok, %{"run_started_at" => ^again}} =
             ConversationServer.update_group_conversation(group_id, id, %{
               "title" => "Still running"
             })
  end

  test "Task archive survives owner restart and rejects stale mutations", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    assert {:ok, %{"conversation_id" => id}} =
             create_task_conversation(group_id, router_id, worker_id, %{
               "title" => "Archive regression",
               "content" => "work",
               "client_request_id" => "archive-regression"
             })

    assert {:ok, _} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               id,
               %{"user_id" => "current"}
             )

    assert {:ok, ready} =
             ConversationServer.update_group_conversation(group_id, id, %{
               "status" => "ready_for_review"
             })

    assert {:ok, archived} =
             ConversationServer.set_task_archived(group_id, id, :archive, ready["updated_at"])

    assert archived["status"] == "archived"
    assert archived["archived_from_status"] == "ready_for_review"

    assert {:ok, %{"migrated" => false, "status" => "archived"}} =
             ConversationServer.migrate_legacy_task_status(group_id, id)

    assert {:error, {:conflict, _}} =
             ConversationServer.append_group_conversation_message(group_id, id, %{
               "content" => "new archived instruction",
               "client_request_id" => "archive-new-command"
             })

    assert {:error, {:conflict, _}} =
             ConversationServer.update_group_conversation(group_id, id, %{"status" => "active"})

    assert {:error, {:conflict, _}} =
             ConversationServer.update_group_conversation(group_id, id, %{
               "title" => "hidden edit"
             })

    assert {:error, {:conflict, _}} =
             ConversationServer.accept_task_review(group_id, id, ready["updated_at"])

    assert {:ok, ^archived} =
             ConversationServer.set_task_archived(group_id, id, :archive, ready["updated_at"])

    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:ok, read_back} = Conversations.get_group_conversation(group_id, id)
    assert read_back["archived_from_status"] == "ready_for_review"

    assert {:error, {:conflict, _}} =
             ConversationServer.set_task_archived(group_id, id, :unarchive, ready["updated_at"])

    assert {:ok, restored} =
             ConversationServer.set_task_archived(
               group_id,
               id,
               :unarchive,
               archived["updated_at"]
             )

    assert restored["status"] == "ready_for_review"
    refute Map.has_key?(restored, "archived_from_status")
  end

  test "a user ends a Task by hand, its Agents are told once, and only a human turn reopens it",
       %{group_id: group_id, router_id: router_id, worker_id: worker_id} do
    manual_notices = fn id ->
      {:ok, messages} = Conversations.list_group_conversation_messages(group_id, id, limit: 50)
      Enum.filter(messages, &(get_in(&1, ["metadata", "message_type"]) == "task_manual_status"))
    end

    agent_participant = fn id, agent_id ->
      {:ok, %{"participants" => participants}} =
        Conversations.list_group_conversation_participants(group_id, id)

      Enum.find(participants, &(&1["agent_id"] == agent_id))["participant_id"]
    end

    assert {:ok, %{"conversation_id" => id}} =
             create_task_conversation(group_id, router_id, worker_id, %{
               "title" => "Manual cancel",
               "content" => "work",
               "client_request_id" => "manual-cancel"
             })

    assert {:ok, current} = Conversations.get_group_conversation(group_id, id)
    assert current["status"] == "active"

    assert {:error, {:conflict, _}} =
             ConversationServer.set_task_status(
               group_id,
               id,
               "cancelled",
               current["updated_at"] - 1,
               "user-1"
             )

    assert {:ok, cancelled} =
             ConversationServer.set_task_status(
               group_id,
               id,
               "cancelled",
               current["updated_at"],
               "user-1"
             )

    assert cancelled["status"] == "cancelled"
    assert cancelled["manual_status_change"]["from_status"] == "active"

    notices = manual_notices.(id)
    assert length(notices) == 2

    targets =
      notices
      |> Enum.map(&(&1["delivery_filter"]["participant_ids"] |> List.first()))
      |> MapSet.new()

    assert targets ==
             MapSet.new([agent_participant.(id, router_id), agent_participant.(id, worker_id)])

    assert Enum.all?(notices, &(&1["actor_type"] == "system"))

    # The same version cannot apply twice; the notices stay single.
    assert {:error, {:conflict, _}} =
             ConversationServer.set_task_status(
               group_id,
               id,
               "completed",
               current["updated_at"],
               "user-1"
             )

    assert length(manual_notices.(id)) == 2

    reopen = %{"status" => "active", router_agent_id: router_id}

    ended_at = cancelled["manual_status_change"]["at"]

    for turn_at <- [nil, ended_at] do
      assert {:error, {:forbidden, _}} =
               ConversationServer.update_group_conversation(
                 group_id,
                 id,
                 Map.put(reopen, :router_human_turn_at, turn_at)
               )
    end

    assert {:ok, %{"status" => "active"} = reopened} =
             ConversationServer.update_group_conversation(
               group_id,
               id,
               Map.put(reopen, :router_human_turn_at, ended_at + 1)
             )

    refute Map.has_key?(reopened, "manual_status_change")

    # A review acceptance tells only the Router.
    assert {:ok, ready} =
             ConversationServer.update_group_conversation(group_id, id, %{
               "status" => "ready_for_review"
             })

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.set_task_status(
               group_id,
               id,
               "completed",
               ready["updated_at"],
               "user-1"
             )

    assert [_, _, accepted] = manual_notices.(id)

    assert accepted["delivery_filter"]["participant_ids"] == [
             agent_participant.(id, router_id)
           ]

    assert accepted["metadata"]["task_manual_status"] == %{
             "status" => "completed",
             "from_status" => "ready_for_review",
             "user_id" => "user-1"
           }
  end

  test "an ordinary Task changes lifecycle only through the Conversation API",
       %{
         tenant_id: tenant_id,
         group_id: group_id,
         router_id: router_id,
         worker_id: worker_id
       } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               %{
                 "title" => "Completion fact",
                 "content" => "build the requested artifact",
                 "client_request_id" => "completion-fact-task"
               }
             )

    assert {:ok, initial} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert initial["status"] == "active"
    refute Map.has_key?(initial, "task_completion")
    refute Map.has_key?(initial, "task_last_command_seq")

    task_completion = %{
      "outcome" => "succeeded",
      "unexpected" => ["arbitrary", %{"nested" => true}]
    }

    assert {:ok, %{"inserted" => true, "message_id" => legacy_message_id, "seq" => 2}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "content" => "ordinary Message with inert historical metadata",
                 "client_request_id" => "legacy-task-completion",
                 "metadata" => %{"task_completion" => task_completion},
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, after_legacy_message} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert after_legacy_message["status"] == "active"
    refute Map.has_key?(after_legacy_message, "task_completion")
    refute Map.has_key?(after_legacy_message, "task_last_command_seq")

    assert {:ok, legacy_message} =
             Conversations.get_group_conversation_message(
               group_id,
               conversation_id,
               legacy_message_id
             )

    assert legacy_message["metadata"]["task_completion"] == task_completion

    result_attrs = %{
      "content" => "The artifact is ready.",
      "client_request_id" => "worker-result",
      "delivery_filter" => %{"participant_ids" => []}
    }

    assert {:ok, %{"inserted" => true, "message_id" => result_message_id, "seq" => 3}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               result_attrs
             )

    assert {:ok, after_result} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert after_result["status"] == "active"
    refute Map.has_key?(after_result, "task_completion")
    refute Map.has_key?(after_result, "task_last_command_seq")

    assert {:ok, %{"status" => "ready_for_review", "updated_at" => review_version}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "status" => "ready_for_review"
             })

    assert is_integer(review_version) and review_version > after_result["updated_at"]

    assert {:error, {:conflict, "Task review changed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version - 1)

    assert {:ok, %{"tail_seq" => 3}} =
             ConversationServer.subscribe_group_conversation(
               group_id,
               conversation_id,
               SystemsRuntime.Proc.self()
             )

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    settle_receive({:conversation_status_changed, ^group_id, ^conversation_id, "completed"})

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    settle_refute_receive(
      {:conversation_status_changed, ^group_id, ^conversation_id, "completed"},
      100
    )

    peer =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Peer context agent",
        "role" => "worker"
      })

    assert {:ok, _peer_participant} =
             SalixIM.ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{"agent_id" => peer["agent_id"], "role_label" => "researcher"}
             )

    assert {:ok, %{"inserted" => true, "seq" => 4}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               peer["agent_id"],
               %{
                 "content" => "Supporting context, not a new command.",
                 "client_request_id" => "peer-task-context",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, context_only} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert context_only["status"] == "completed"

    assert {:ok, %{"inserted" => false, "message_id" => ^result_message_id, "seq" => 3}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               result_attrs
             )

    assert {:ok, %{"inserted" => true, "seq" => 5}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               router_id,
               %{
                 "content" => "Please add keyboard controls.",
                 "client_request_id" => "task-follow-up",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, reopened} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert reopened["status"] == "completed"
    refute Map.has_key?(reopened, "task_completion")
    refute Map.has_key?(reopened, "task_last_command_seq")

    assert {:ok, %{"status" => "active"}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "status" => "active"
             })

    assert {:error, {:conflict, "Task review changed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert Enum.map(messages, & &1["seq"]) == [1, 2, 3, 4, 5]
  end

  # A change whose stale list-index delete failed leaves two index records;
  # the restarted owner converges them to the canonical Task.
  for {name, change, expected_status} <- [
        {"Task list repair", :accept_review, "completed"},
        {"message append list repair", :agent_message, "ready_for_review"}
      ] do
  end

  test "trusted ingress task retry rejects different content", %{
    group_id: group_id,
    worker_id: worker_id
  } do
    conversation_id = Ids.new_conversation_id()
    created_at = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "title" => "First external task",
                 "command" => "Handle the first external request",
                 "created_at" => created_at
               }
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "title" => "First external task",
                 "command" => "Handle the first external request",
                 "created_at" => created_at
               }
             )

    assert {:error, {:conflict, _reason}} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "title" => "Different external task",
                 "command" => "Handle a different external request",
                 "created_at" => created_at + 1
               }
             )
  end

  test "trusted ingress task materialization cannot be overwritten by generic update", %{
    group_id: group_id,
    worker_id: worker_id
  } do
    conversation_id = Ids.new_conversation_id()
    created_at = SystemsClock.system_time(:millisecond)

    original = %{
      "title" => "Immutable external task",
      "command" => "Keep the original external command",
      "created_at" => created_at
    }

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               conversation_id,
               worker_id,
               original
             )

    assert {:error, {:conflict, _reason}} =
             ConversationServer.update_group_conversation(
               group_id,
               conversation_id,
               %{
                 "task_materialization" => %{
                   "title" => "Replacement task",
                   "command" => "Replace the canonical external command",
                   "created_at" => created_at + 1
                 }
               }
             )

    assert {:ok, %{"task_materialization" => ^original}} =
             Conversations.get_group_conversation(group_id, conversation_id)
  end

  test "router fixed conversation materializes through Router input and admits its committed log",
       %{
         group_id: group_id,
         router_id: router_id,
         router_conversation_id: router_conversation_id,
         router_session_id: router_session_id,
         worker_id: worker_id
       } do
    :ok =
      SalixStore.S3.delete(Keys.ctl_group_conversation(group_id, router_conversation_id))

    assert {:error, :not_found} =
             SalixIM.RouterConversationProjection.get_group_router_conversation(group_id)

    assert {:error, :not_found} =
             Conversations.list_group_conversation_messages(group_id, router_conversation_id)

    assert {:error, :not_found} =
             Conversations.get_group_conversation_with_messages(
               group_id,
               router_conversation_id
             )

    assert {:ok, projection} = RouterConversationInput.ensure(group_id)
    assert projection["conversation_id"] == router_conversation_id
    assert projection["kind"] == "user_chat"
    assert projection["message_count"] == 0

    assert {:ok, same_projection} =
             Conversations.get_group_conversation(group_id, projection["conversation_id"])

    assert same_projection["conversation_id"] == projection["conversation_id"]

    assert {:ok, worker_participant} =
             SalixIM.ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               router_conversation_id,
               %{"agent_id" => worker_id, "role_label" => "worker"}
             )

    assert {:ok, result} =
             RouterConversationInput.append_user_message(group_id, %{
               "kind" => "message",
               "content" => "route this",
               "client_request_id" => "msg-router-user"
             })

    assert result["conversation_id"] == projection["conversation_id"]
    assert result["delivery_status"] == "queued"
    router_message_id = result["message_id"]

    assert [%{"participant_id" => user_participant_id}] =
             group_id
             |> all_test_participants(router_conversation_id)
             |> Enum.filter(&(&1["actor_type"] == "user" and &1["role_label"] == "user"))

    assert {:ok, [%{"participant_id" => ^user_participant_id}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               router_conversation_id,
               limit: 10
             )

    assert eventually_value(fn ->
             with {:ok, session} <-
                    SalixAgent.InternalSessionStore.read(router_id, router_session_id),
                  %{"seq" => seq} <-
                    SalixAgent.InternalSession.conversation_sources(session)[
                      projection["router_participant_id"]
                    ] do
               seq >= result["seq"]
             else
               _ -> false
             end
           end)

    {:ok, source} =
      SalixIM.ConversationSourceIdentity.encode(
        router_conversation_id,
        router_message_id,
        projection["router_participant_id"],
        nil
      )

    {:ok, session} = SalixAgent.InternalSessionStore.read(router_id, router_session_id)
    assert SalixAgent.InternalSession.input_dedupe_member?(session, source)
    assert delivery_records(group_id, projection["conversation_id"]) == %{}

    assert {:ok, %{"state" => "active"}} =
             Conversations.get_group_conversation_participant(
               group_id,
               router_conversation_id,
               worker_participant["participant_id"]
             )
  end

  test "conversation transcript seed materializes router conversation without dispatch", %{
    group_id: group_id,
    router_id: router_id,
    router_conversation_id: conversation_id,
    router_session_id: router_session_id
  } do
    seed = %{
      "created_at" => "2026-07-01T00:00:00Z",
      "conversation" => %{
        "kind" => "user_chat",
        "title" => "Comma",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "role_label" => "user"
          },
          %{
            "actor_type" => "agent",
            "agent_id" => router_id,
            "role_label" => "agent",
            "payload" => %{"session_id" => router_session_id}
          }
        ]
      },
      "messages" => [
        %{
          "client_request_id" => "seed-user-1",
          "actor_type" => "user",
          "user_id" => "current",
          "content" => [%{"type" => "text", "text" => "remember project Lyra"}],
          "created_at" => "2026-07-01T00:00:01Z"
        },
        %{
          "client_request_id" => "seed-agent-1",
          "actor_type" => "agent",
          "agent_id" => router_id,
          "role_label" => "agent",
          "content" => [%{"type" => "text", "text" => "noted"}],
          "created_at" => "2026-07-01T00:00:02Z"
        }
      ]
    }

    assert {:ok,
            %{
              "requested_count" => 2,
              "appended_count" => 2,
              "skipped_count" => 0,
              "message_count" => 2
            }} =
             seed_group_conversation_transcript(
               group_id,
               conversation_id,
               seed
             )

    assert length(all_test_participants(group_id, conversation_id)) == 2

    durable_meta =
      read_json_record!(Keys.ctl_group_conversation(group_id, conversation_id))

    refute Map.has_key?(durable_meta, "participant_count")

    assert {:error, :not_found} =
             SalixAgent.InternalSessionStore.read(router_id, router_session_id)

    assert {:ok, router_conversation} =
             SalixIM.RouterConversationProjection.get_group_router_conversation(group_id)

    assert router_conversation["conversation_id"] == conversation_id
    assert router_conversation["message_count"] == 2
    assert router_conversation["kind"] == "user_chat"

    assert {:ok, %{"data" => listed}} = Conversations.list_group_conversations(group_id)
    assert Enum.any?(listed, &(&1["conversation_id"] == conversation_id))

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id)

    seeded_message_ids = Enum.map(messages, & &1["message_id"])
    assert Enum.all?(seeded_message_ids, &Ids.valid_message_id?/1)
    refute Enum.any?(messages, &Map.has_key?(&1, "dispatch_targets"))

    assert {:ok,
            %{
              "conversation" => %{"conversation_id" => ^conversation_id},
              "messages" => snapshot_messages
            }} =
             Conversations.get_group_conversation_with_messages(group_id, conversation_id)

    assert Enum.map(snapshot_messages, & &1["message_id"]) == seeded_message_ids

    assert {:ok, %{"appended_count" => 0, "skipped_count" => 2, "message_count" => 2}} =
             seed_group_conversation_transcript(
               group_id,
               conversation_id,
               seed
             )

    changed_seed = put_in(seed, ["conversation", "title"], "A different conversation")

    assert {:error, {:conflict, _reason}} =
             seed_group_conversation_transcript(
               group_id,
               conversation_id,
               changed_seed
             )
  end

  test "slack worker thread creates a task and sends one provider-only supervision link", %{
    tenant_id: tenant_id,
    group_id: group_id,
    worker_id: worker_id
  } do
    template =
      "https://teams.example.test/tasks/{tenant_id}/{group_id}/{conversation_id}"

    put_conversation_links_config(tenant_id, template)

    connect = slack_connect(tenant_id, group_id, worker_id)
    now = SystemsClock.system_time(:millisecond)

    attrs =
      %{
        "channel_id" => "C-supervision",
        "thread_ts" => "123.456",
        "message_ts" => "123.456",
        "source_message_id" => "slack-msg-1",
        "user_id" => "U-slack-user",
        "content" => [%{"type" => "text", "text" => "please fix this"}],
        "created_at" => now
      }

    assert {:ok, first} =
             SlackConversationIngress.append_worker_thread_message(connect, worker_id, attrs)

    conversation_id = first["conversation_id"]

    expected_url =
      "https://teams.example.test/tasks/#{tenant_id}/#{group_id}/#{conversation_id}"

    assert first["conversation_kind"] == "agent_task"
    assert first["worker_agent_id"] == worker_id

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert %{"payload" => %{"thread_url" => thread_url}} =
             provider_participant =
             Enum.find(participants, fn participant ->
               participant["actor_type"] == "provider" and
                 get_in(participant, ["payload", "connect_id"]) == connect["connect_id"] and
                 get_in(participant, ["payload", "channel_id"]) == "C-supervision" and
                 get_in(participant, ["payload", "thread_ts"]) == "123.456"
             end)

    assert Ids.valid_participant_id?(provider_participant["participant_id"])

    assert thread_url ==
             "https://app.slack.com/client/T-supervision/C-supervision/thread/C-supervision-123.456"

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    message = Enum.find(messages, &(&1["actor_type"] == "provider_user"))

    first_message_id = message["message_id"]
    assert first_message_id == first["message_id"]
    assert Ids.valid_message_id?(first_message_id)
    assert message["actor_type"] == "provider_user"
    assert message["participant_id"] == provider_participant["participant_id"]
    assert message["user_id"] == "U-slack-user"

    deliveries =
      eventually_value(fn ->
        deliveries = delivery_records(group_id, conversation_id) |> Map.values()

        has_link? = Enum.any?(deliveries, &(&1["notification_kind"] == "conversation_link"))

        has_worker? = admitted?(group_id, conversation_id, first_message_id, worker_id)

        if has_link? and has_worker?, do: deliveries
      end)

    assert [link_delivery] =
             Enum.filter(deliveries, &(&1["notification_kind"] == "conversation_link"))

    assert link_delivery["delivery_kind"] == "participant_notification"
    assert link_delivery["participant_actor_type"] == "provider"
    assert get_in(link_delivery, ["participant_payload", "connect_id"]) == connect["connect_id"]
    assert get_in(link_delivery, ["participant_payload", "channel_id"]) == "C-supervision"
    assert get_in(link_delivery, ["participant_payload", "thread_ts"]) == "123.456"
    assert link_delivery["source_actor_type"] == "product"
    assert link_delivery["message_metadata"]["source"] == "conversation_link"
    assert link_delivery["message_metadata"]["url"] == expected_url

    assert link_delivery["message_content"] == [
             %{"type" => "text", "text" => expected_url}
           ]

    binding_key =
      Keys.ctl_im_slack_thread_binding(
        group_id,
        connect["connect_id"],
        attrs["channel_id"],
        attrs["thread_ts"]
      )

    assert {:ok,
            %{
              "version" => 2,
              "task_materialization" => %{"command" => "please fix this"}
            }} = CasRecord.get(binding_key)

    assert {:ok, %{"version" => 1}} =
             CasRecord.update(binding_key, fn binding ->
               binding
               |> Map.put("version", 1)
               |> Map.delete("task_materialization")
             end)

    assert {:ok, _legacy_conversation} =
             CasRecord.update(
               Keys.ctl_group_conversation(group_id, conversation_id),
               fn conversation ->
                 Map.delete(conversation, "task_materialization")
               end
             )

    assert {:ok, second} =
             SlackConversationIngress.append_worker_thread_message(
               connect,
               worker_id,
               %{
                 attrs
                 | "source_message_id" => "slack-msg-2",
                   "message_ts" => "123.457",
                   "content" => [%{"type" => "text", "text" => "more context"}],
                   "created_at" => now + 1
               }
             )

    assert second["conversation_id"] == conversation_id

    assert {:ok, %{"version" => 1}} = CasRecord.get(binding_key)

    assert {:ok, %{"task_materialization" => %{"command" => "please fix this"}}} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert Enum.map(
             Enum.filter(messages, &(&1["actor_type"] == "provider_user")),
             & &1["message_id"]
           ) == [
             first_message_id,
             second["message_id"]
           ]

    assert Ids.valid_message_id?(second["message_id"])

    link_deliveries =
      delivery_records(group_id, conversation_id)
      |> Map.values()
      |> Enum.filter(&(&1["notification_kind"] == "conversation_link"))

    assert length(link_deliveries) == 1
  end

  test "provider participant message command writes provider-only delivery", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Provider command",
               "participants" => [
                 slack_thread_participant("sl-command", "T-command", "C-command", "333.000")
               ]
             })

    assert {:ok, %{"participants" => [provider_participant]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant_id = provider_participant["participant_id"]

    assert {:ok, result} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "provider-command-link",
                 "content" => [%{"type" => "text", "text" => "Task: https://task.example"}],
                 "metadata" => %{"source" => "test_command"}
               }
             )

    assert result["delivery_status"] == "queued"
    assert result["participant_id"] == participant_id
    assert Ids.valid_message_id?(result["message_id"])

    assert {:ok, [command]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert command["delivery_filter"] == %{"participant_ids" => [participant_id]}
    assert eventually_value(fn -> map_size(delivery_records(group_id, conversation_id)) == 1 end)

    deliveries = delivery_records(group_id, conversation_id) |> Map.values()

    assert [delivery] =
             Enum.filter(deliveries, &(&1["notification_kind"] == "provider_participant_message"))

    assert delivery["delivery_kind"] == "participant_notification"
    assert delivery["participant_actor_type"] == "provider"
    assert get_in(delivery, ["participant_payload", "connect_id"]) == "sl-command"
    assert get_in(delivery, ["participant_payload", "channel_id"]) == "C-command"
    assert get_in(delivery, ["participant_payload", "thread_ts"]) == "333.000"

    assert delivery["message_content"] == [
             %{"type" => "text", "text" => "Task: https://task.example"}
           ]
  end

  test "pins are group-owned while activity surface dismissal is conversation-owned", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Pinned task"
             })

    assert {:ok, dismissal} =
             ConversationServer.dismiss_group_conversation_activity_surface(
               group_id,
               conversation_id
             )

    assert is_integer(dismissal["activity_surface_dismissed_at"])

    assert {:ok, pin} = ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)
    assert pin["conversation_id"] == conversation_id

    assert {:ok, %{"data" => [listed_pin]}} =
             Conversations.list_conversation_pins(group_id, tenant_id)

    assert listed_pin["conversation_id"] == conversation_id

    assert :ok = ConversationServer.unpin_conversation(group_id, conversation_id, tenant_id)
    assert {:ok, %{"data" => []}} = Conversations.list_conversation_pins(group_id, tenant_id)
  end

  test "concurrent creates share one client request identity across owner restart", %{
    group_id: group_id
  } do
    attrs = %{
      "title" => "One logical create",
      "client_request_id" => "concurrent-create-request",
      "participants" => [user_participant(SystemsClock.system_time(:millisecond))]
    }

    results =
      1..10
      |> Task.async_stream(
        fn _ -> SalixIM.ConversationInput.create_group_conversation(group_id, attrs) end,
        ordered: false,
        max_concurrency: 10,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, conversation}} -> conversation end)

    assert [conversation_id] =
             results
             |> Enum.map(& &1["conversation_id"])
             |> Enum.uniq()

    assert {:ok, %{"participants" => [participant]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, attrs)

    assert {:ok, %{"participants" => [same_participant]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert same_participant["participant_id"] == participant["participant_id"]

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.count(listed, &(&1["conversation_id"] == conversation_id)) == 1

    assert {:error, {:conflict, _reason}} =
             SalixIM.ConversationInput.create_group_conversation(
               group_id,
               Map.put(attrs, "title", "Conflicting create")
             )
  end

  test "ambiguous appends remain idempotent across conversation owner restarts", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Restart-safe append",
               "participants" => [user_participant(SystemsClock.system_time(:millisecond))]
             })

    first_attrs = %{
      "content" => "ambiguous before",
      "client_request_id" => "append-before-restart"
    }

    first_segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, first_segment_key})

    assert {:ok, %{"inserted" => true, "message_id" => first_message_id, "seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               first_attrs
             )

    assert {:ok, first_owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(first_owner, :normal)

    assert {:ok, %{"inserted" => false, "message_id" => ^first_message_id, "seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               first_attrs
             )

    second_attrs = %{
      "content" => "ambiguous after",
      "client_request_id" => "append-after-restart"
    }

    second_segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, second_segment_key})

    assert {:ok, %{"inserted" => true, "message_id" => second_message_id, "seq" => 2}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               second_attrs
             )

    assert {:ok, second_owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(second_owner, :normal)

    assert {:ok, %{"inserted" => false, "message_id" => ^second_message_id, "seq" => 2}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               second_attrs
             )

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert Enum.map(messages, &{&1["message_id"], &1["seq"]}) == [
             {first_message_id, 1},
             {second_message_id, 2}
           ]
  end

  test "delivery filters survive owner restart without widening or replaying", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)

    SystemsRuntime.put_env(
      :salix_im,
      :capture_agent_delivery_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :capture_agent_delivery_test_pid) end)

    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Filtered restart",
               "participants" => [
                 user_participant(now),
                 agent_participant(router_id, "router", now),
                 agent_participant(worker_id, "worker", now)
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    worker_participant = Enum.find(participants, &(&1["agent_id"] == worker_id))
    router_participant = Enum.find(participants, &(&1["agent_id"] == router_id))

    attrs = %{
      "content" => "worker only after restart",
      "client_request_id" => "filtered-owner-restart",
      "delivery_filter" => %{
        "participant_ids" => [worker_participant["participant_id"]]
      }
    }

    assert {:ok, %{"inserted" => true, "message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    settle_receive({:captured_agent_delivery, ^worker_id, _payload, _opts})
    settle_refute_receive({:captured_agent_delivery, ^router_id, _payload, _opts}, 200)

    assert eventually_value(fn ->
             case Conversations.group_conversation_delivery_status(
                    group_id,
                    conversation_id,
                    participant_id: worker_participant["participant_id"],
                    message_id: message_id,
                    limit: 1
                  ) do
               {:ok, %{"source_progress" => %{"seq" => 1} = progress}} -> progress
               _ -> nil
             end
           end)

    assert {:ok, %{"deliveries" => []}} =
             Conversations.group_conversation_delivery_status(
               group_id,
               conversation_id,
               participant_id: router_participant["participant_id"],
               message_id: message_id,
               limit: 1
             )

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:ok, %{"inserted" => false, "message_id" => ^message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    settle_refute_receive({:captured_agent_delivery, _agent_id, _payload, _opts}, 300)

    assert {:ok, [%{"delivery_filter" => delivery_filter}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert delivery_filter == attrs["delivery_filter"]
  end

  test "multipage membership recovers completely and public delete removes the aggregate", %{
    group_id: group_id
  } do
    now = SystemsClock.system_time(:millisecond)

    participants =
      for index <- 1..101 do
        user_participant(now)
        |> Map.put("user_id", "multipage-delete-user-#{index}")
        |> Map.put("notification_filter", %{"messages" => "none", "statuses" => "none"})
      end

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Multipage delete",
               "participants" => participants
             })

    all_participants = all_test_participants(group_id, conversation_id)
    first_participant_id = hd(all_participants)["participant_id"]

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "participant_id" => first_participant_id,
                 "content" => "delete the whole aggregate",
                 "client_request_id" => "multipage-delete-message"
               }
             )

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:ok, %{"message_count" => 1}} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert length(all_participants) == 101
    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert {:error, :not_found} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:error, :not_found} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation_id,
               limit: 100
             )

    assert {:error, :not_found} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    refute Enum.any?(listed, &(&1["conversation_id"] == conversation_id))
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp user_participant(now) do
    %{
      "actor_type" => "user",
      "user_id" => "current",
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "created_at" => now,
      "updated_at" => now
    }
  end

  defp bft_participant do
    %{
      "actor_type" => "provider",
      "provider" => "bft",
      "target_key" => "bft",
      "role_label" => "bridge_for_teams",
      "state" => "active",
      "notification_filter" => %{"messages" => "none", "statuses" => "none"},
      "payload" => %{"surface" => "dashboard"}
    }
  end

  defp all_test_participants(group_id, conversation_id, cursor \\ nil, acc \\ []) do
    opts = [limit: 100]
    opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

    {:ok, page} =
      Conversations.list_group_conversation_participants(group_id, conversation_id, opts)

    acc = acc ++ page["participants"]

    if page["next_cursor"],
      do: all_test_participants(group_id, conversation_id, page["next_cursor"], acc),
      else: acc
  end

  defp agent_participant(agent_id, role_label, now) do
    %{
      "actor_type" => "agent",
      "agent_id" => agent_id,
      "agent_name" => agent_id,
      "role_label" => role_label,
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "created_at" => now,
      "updated_at" => now
    }
  end

  # Session activity and agent deliveries as the TaskWorkerWatch tests set and read them.
  defp configure_task_worker_watch do
    start_supervised!(TaskSessionActivity)
    start_supervised!(SalixIM.TestSupport.Fleet.Cleanup)
    SystemsRuntime.put_env(:salix_im, :session_activity_mod, TaskSessionActivity)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)

    SystemsRuntime.put_env(
      :salix_im,
      :capture_agent_delivery_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SystemsRuntime.delete_env(:salix_im, :capture_agent_delivery_test_pid)
      SystemsRuntime.delete_env(:salix_im, :task_worker_watch_fail_next_append)
    end)
  end

  # A plain Task whose Worker session the TaskWorkerWatch is
  # already subscribed to; returns the ids the watch tests key on.
  defp start_watched_plain_task(
         group_id,
         router_id,
         worker_id,
         request_id,
         configure \\ true,
         attrs \\ %{}
       ) do
    if configure, do: configure_task_worker_watch()

    assert {:ok, %{"conversation_id" => conversation_id}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               Map.merge(attrs, %{
                 "content" => "Summarize the thread and report back.",
                 "client_request_id" => request_id
               })
             )

    settle_receive({:captured_agent_delivery, ^worker_id, _command, _opts})
    {session_id, watch} = watched_worker_session(group_id, conversation_id, worker_id)
    {conversation_id, session_id, watch}
  end

  # The Task's Worker session, once its TaskWorkerWatch is subscribed to it.
  defp watched_worker_session(group_id, conversation_id, worker_id) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    worker = Enum.find(participants, &(&1["agent_id"] == worker_id))
    session_id = get_in(worker, ["payload", "session_id"])
    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    assert {:ok, watch} = SalixIM.ConversationActor.task_worker_watch(owner)

    assert eventually_value(fn ->
             TaskSessionActivity.subscribed?(worker_id, session_id, watch)
           end)

    {session_id, watch}
  end

  # A watched plain Task whose Worker published a result and stopped while
  # its Router was still busy; returns the ids the status tests key on.
  defp watched_task_with_worker_result(group_id, router_id, worker_id, request_id, attrs \\ %{}) do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, request_id, true, attrs)

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    router_session_id =
      participants
      |> Enum.find(&(&1["agent_id"] == router_id))
      |> get_in(["payload", "session_id"])

    assert is_binary(router_session_id)
    busy_since = SystemsClock.system_time(:millisecond)
    TaskSessionActivity.set(router_id, router_session_id, "active", busy_since)

    assert {:ok, _message} =
             append_task_result_message(
               group_id,
               conversation_id,
               worker_id,
               request_id <> "-result",
               "Here is the summary."
             )

    stopped_at = SystemsClock.system_time(:millisecond) + 1
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch, :infinity).stop end)

    SystemsRuntime.Proc.send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version, token}
    )

    assert eventually_value(fn ->
             match?({:acted, ^version, _, _, _, _}, :sys.get_state(watch, :infinity).stop)
           end)

    {conversation_id, watch, router_session_id}
  end

  defp create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs) do
    command = String.trim(attrs["content"])
    created_at = attrs["created_at"] || SystemsClock.system_time(:millisecond)

    with {:ok, conversation_id} <-
           ConversationServer.reserve_task_conversation_id(
             group_id,
             delegator_agent_id,
             worker_agent_id,
             attrs
           ) do
      SalixIM.TaskConversationInput.create_with_id(
        group_id,
        conversation_id,
        delegator_agent_id,
        worker_agent_id,
        attrs
        |> Map.put("schedule", %{"schedule_id" => nil, "command" => command})
        |> Map.put("initial_message_attrs", %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => delegator_agent_id,
          "content" => command,
          "metadata" => %{"message_type" => "task_command"},
          "client_request_id" => "delegate-task-" <> conversation_id,
          "created_at" => created_at
        })
      )
    end
  end

  defp append_task_result_message(
         group_id,
         conversation_id,
         agent_id,
         client_request_id,
         content
       ) do
    ConversationServer.append_group_conversation_agent_message(
      group_id,
      conversation_id,
      agent_id,
      %{
        "content" => content,
        "client_request_id" => client_request_id,
        "delivery_filter" => %{"participant_ids" => []}
      }
    )
  end

  defp seed_group_conversation_transcript(group_id, conversation_id, attrs) do
    with {:ok, seed} <-
           ConversationSeedInput.prepare(group_id, conversation_id, attrs) do
      ConversationServer.seed_group_conversation_transcript(group_id, conversation_id, seed)
    end
  end

  defp slack_connect(tenant_id, group_id, worker_id) do
    app_id = "A-supervision-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, pending} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant_id, group_id, %{
               "app_id" => app_id,
               "client_id" => "client-supervision",
               "client_secret" => "secret-supervision",
               "signing_secret" => "signing-supervision",
               "inbound_agent_id" => worker_id
             })

    assert {:ok, connected} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(pending, %{
               "bot_token" => "xoxb-supervision",
               "bot_user_id" => "B-supervision",
               "workspace_id" => "T-supervision",
               "workspace_name" => "Supervision",
               "enterprise_id" => "",
               "owner_user_id" => "U-owner"
             })

    connected
  end

  defp slack_thread_participant(connect_id, workspace_id, channel_id, thread_ts) do
    %{
      "actor_type" => "provider",
      "provider" => "slack",
      "role_label" => "slack_thread",
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "payload" => %{
        "connect_id" => connect_id,
        "workspace_id" => workspace_id,
        "channel_id" => channel_id,
        "thread_ts" => thread_ts
      }
    }
  end

  defp put_conversation_links_config(tenant_id, template) do
    # Discrete tenant configs live in Postgres now
    # (docs/storage-search.md); seed through the same data
    # module the runtime writer (Salix.Control.Tenants.update_config) uses.
    assert {:ok, _} =
             SalixStore.TenantConfigs.put(%{
               "tenant_id" => tenant_id,
               "name" => "conversation_links",
               "value" => %{"conversation_url_template" => template},
               "updated_at" => SystemsClock.system_time(:second)
             })
  end

  defp admitted?(group, conversation, message, agent) do
    with {:ok, %{"participants" => participants}} <-
           Conversations.list_group_conversation_participants(group, conversation),
         %{} = participant <- Enum.find(participants, &(&1["agent_id"] == agent)),
         {:ok, source} <-
           SalixIM.ConversationSourceIdentity.encode(
             conversation,
             message,
             participant["participant_id"],
             nil
           ),
         {:ok, session} <-
           SalixAgent.InternalSessionStore.read(agent, participant["payload"]["session_id"]) do
      SalixAgent.InternalSession.input_dedupe_member?(session, source)
    else
      _ -> false
    end
  end

  defp delivery_records(group_id, conversation_id) do
    participant_delivery_records(group_id, conversation_id)
    |> Map.new(fn {_key, rec, _etag} ->
      participant_key = rec["participant_agent_id"] || rec["participant_id"]
      {{rec["conversation_id"], rec["message_id"], participant_key}, rec}
    end)
  end

  defp participant_delivery_records(group_id, conversation_id) do
    case SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id,
           limit: 1000
         ) do
      {:ok, %{"participants" => participants}} ->
        participants
        |> Enum.flat_map(fn participant ->
          participant_id = participant["participant_id"] || ""

          group_id
          |> Keys.ctl_group_conversation_participant_deliveries_prefix(
            conversation_id,
            participant_id
          )
          |> raw_delivery_records()
        end)

      {:error, _reason} ->
        []
    end
  end

  defp raw_delivery_records(prefix) do
    case SalixStore.S3.list_all(prefix) do
      {:ok, objects} ->
        objects
        |> Enum.filter(&String.ends_with?(&1.key, "/state.json"))
        |> Enum.flat_map(fn %{key: key} ->
          case SalixStore.S3.get(key) do
            {:ok, %{body: body, etag: etag}} -> [{key, Jason.decode!(body), etag}]
            {:error, _reason} -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp read_json_record!(key) do
    assert {:ok, %{body: body}} = SalixStore.S3.get(key)
    Jason.decode!(body)
  end

  defp task_search_row(seq, nil) do
    %{
      "message_id" => Ids.new_message_id(),
      "seq" => seq,
      "actor_type" => "user",
      "kind" => "app_event",
      "content" => [],
      "metadata" => %{},
      "request_fingerprint" => "task-search-fixture-#{seq}",
      "created_at" => seq
    }
  end

  defp task_search_row(seq, text) when is_binary(text) do
    %{
      "message_id" => Ids.new_message_id(),
      "seq" => seq,
      "actor_type" => "user",
      "kind" => "message",
      "content" => [%{"type" => "text", "text" => text}],
      "metadata" => %{},
      "request_fingerprint" => "task-search-fixture-#{seq}",
      "created_at" => seq
    }
  end

  defp task_search_conversation(group_id, conversation_id, tail_seq) do
    %{
      "kind" => "agent_task",
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "message_head_seq" => if(tail_seq > 0, do: 1, else: 0),
      "message_tail_seq" => tail_seq
    }
  end

  defp task_search_segment_id(seq) do
    seq
    |> Integer.to_string()
    |> String.pad_leading(18, "0")
  end

  defp put_task_search_segment(group_id, conversation_id, segment_id, rows, next_segment_id) do
    body =
      rows
      |> Enum.map(fn row ->
        assert {:ok, line} = ConversationMessageCodec.encode_row(row)
        line
      end)
      |> IO.iodata_to_binary()

    assert byte_size(body) <= 1_000_000

    segment_key =
      Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    assert {:ok, _result} = S3.put(segment_key, body)

    index =
      rows
      |> ConversationMessageCodec.segment_facts(body)
      |> Map.put("segment_id", segment_id)
      |> maybe_put_task_search_next_segment(next_segment_id)

    index_key =
      Keys.ctl_group_conversation_message_segment_index(group_id, conversation_id, segment_id)

    assert {:ok, _result} = S3.put(index_key, Jason.encode!(index))
  end

  defp maybe_put_task_search_next_segment(index, next_segment_id)
       when is_binary(next_segment_id),
       do: Map.put(index, "next_segment_id", next_segment_id)

  defp maybe_put_task_search_next_segment(index, _next_segment_id), do: index

  defp put_task_search_pointer(group_id, conversation_id, row, segment_id) do
    pointer = %{
      "message_id" => row["message_id"],
      "seq" => row["seq"],
      "segment_id" => segment_id
    }

    key = Keys.ctl_group_conversation_message_seq_index(group_id, conversation_id, row["seq"])
    assert {:ok, _result} = S3.put(key, Jason.encode!(pointer))
  end

  defp reset_search_projection! do
    Repo.query!(
      "TRUNCATE conversation_search_gc_runs, conversation_search_jobs, " <>
        "conversation_search_states, conversation_search_discovery_cursors, " <>
        "conversation_search_backfill_runs CASCADE"
    )

    Repo.query!(
      "DELETE FROM salix_cutover_markers " <>
        "WHERE name = 'conversation_search_projection_v1'"
    )

    Repo.query!("""
    INSERT INTO conversation_search_backfill_runs
      (writer_generation, writer_barrier_authority, writer_barrier_at,
       required_discovery_cycle, sealed_at, inserted_at, updated_at)
    VALUES ('test-search-generation', 'conversation-test-fixture', now(),
            1, now(), now(), now())
    """)

    Repo.query!("""
    INSERT INTO conversation_search_discovery_cursors
      (id, writer_generation, completed_cycles, cycle_started_at,
       last_cycle_completed_at, inserted_at, updated_at)
    VALUES ('main', 'test-search-generation', 1, now(), now(), now(), now())
    """)

    Repo.query!("""
    INSERT INTO salix_cutover_markers (name, completed_at, evidence)
    VALUES ('conversation_search_projection_v1', now(),
            jsonb_build_object(
              'writer_generation', 'test-search-generation',
              'mode', 'conversation-test-fixture'
            ))
    """)
  end

  defp search_job_count(group_id, conversation_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM conversation_search_jobs " <>
          "WHERE writer_generation = 'test-search-generation' " <>
          "AND agent_group_id = $1 AND conversation_id = $2",
        [group_id, conversation_id]
      )

    count
  end

  defp eventually_value(fun, retries \\ 1500)
  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, retries) do
    case fun.() do
      nil ->
        SystemsClock.sleep(20)
        eventually_value(fun, retries - 1)

      false ->
        SystemsClock.sleep(20)
        eventually_value(fun, retries - 1)

      value ->
        value
    end
  end
end
