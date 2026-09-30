defmodule SalixIM.ConversationsTest do
  use ExUnit.Case, async: false

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
      :persistent_term.put(@state_key, %{
        owner: owner,
        default_ref: {agent_id, session_id},
        fail_next_gets: %{},
        snapshots: %{{agent_id, session_id} => snapshot},
        subscribers: %{}
      })
    end

    def track_gets do
      state = :persistent_term.get(@state_key)
      :persistent_term.put(@state_key, Map.put(state, :track_gets, true))
    end

    def block_next_get do
      state = :persistent_term.get(@state_key)
      :persistent_term.put(@state_key, Map.put(state, :block_next_get, true))
    end

    def fail_next_get(agent_id, session_id) do
      state = :persistent_term.get(@state_key)
      ref = {agent_id, session_id}

      :persistent_term.put(@state_key, %{
        state
        | fail_next_gets: Map.update(state.fail_next_gets, ref, 1, &(&1 + 1))
      })
    end

    def publish(snapshot) do
      state = :persistent_term.get(@state_key)
      {agent_id, session_id} = state.default_ref
      publish(agent_id, session_id, snapshot)
    end

    def replace_without_notify(snapshot) do
      state = :persistent_term.get(@state_key)
      ref = state.default_ref

      :persistent_term.put(@state_key, %{
        state
        | snapshots: Map.put(state.snapshots, ref, snapshot)
      })

      :ok
    end

    def publish(agent_id, session_id, snapshot) do
      state = :persistent_term.get(@state_key)
      ref = {agent_id, session_id}
      next_state = %{state | snapshots: Map.put(state.snapshots, ref, snapshot)}
      :persistent_term.put(@state_key, next_state)

      state.subscribers
      |> Map.get(ref, MapSet.new())
      |> Enum.each(&send(&1, {:session_activity_updated, agent_id, session_id}))

      :ok
    end

    def clear, do: :persistent_term.erase(@state_key)

    @impl true
    def get(agent_id, session_id) do
      state = :persistent_term.get(@state_key)
      ref = {agent_id, session_id}

      if state[:block_next_get] do
        :persistent_term.put(@state_key, Map.delete(state, :block_next_get))
        send(state.owner, {:session_activity_blocked, self()})

        receive do
          :release_session_activity -> :ok
        end
      end

      if state[:track_gets], do: send(state.owner, {:participant_activity_read, self()})

      case Map.get(state.fail_next_gets, ref, 0) do
        remaining when remaining > 0 ->
          next_failures =
            if remaining == 1,
              do: Map.delete(state.fail_next_gets, ref),
              else: Map.put(state.fail_next_gets, ref, remaining - 1)

          :persistent_term.put(@state_key, %{state | fail_next_gets: next_failures})
          {:error, :temporary_session_activity_unavailable}

        _none ->
          Map.fetch(state.snapshots, ref)
      end
    end

    @impl true
    def subscribe(agent_id, session_id) do
      state = :persistent_term.get(@state_key)
      ref = {agent_id, session_id}

      :persistent_term.put(@state_key, %{
        state
        | subscribers:
            Map.update(
              state.subscribers,
              ref,
              MapSet.new([self()]),
              &MapSet.put(&1, self())
            )
      })

      send(state.owner, {:participant_session_subscription, self(), agent_id, session_id})
      :ok
    end

    @impl true
    def unsubscribe(agent_id, session_id) do
      state = :persistent_term.get(@state_key)
      ref = {agent_id, session_id}

      remaining =
        state.subscribers
        |> Map.get(ref, MapSet.new())
        |> MapSet.delete(self())

      subscribers =
        if MapSet.size(remaining) == 0,
          do: Map.delete(state.subscribers, ref),
          else: Map.put(state.subscribers, ref, remaining)

      :persistent_term.put(@state_key, %{state | subscribers: subscribers})

      send(state.owner, {:participant_session_unsubscription, self(), agent_id, session_id})
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
      caller = self()

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
      do: send(test_pid, {event, metadata})
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
          send(owner, {:legacy_orphan_read_waiting, self(), key})

          receive do
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
      if tracked?, do: Process.sleep(20)

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
      do: :persistent_term.put(@state_key, %{key: key, reader: reader, owner: owner})

    def clear, do: :persistent_term.erase(@state_key)

    @impl true
    def get(key, opts) do
      result = SalixStore.S3.Fake.get(key, opts)

      case :persistent_term.get(@state_key, nil) do
        %{key: ^key, reader: reader, owner: owner} when reader == self() ->
          :persistent_term.erase(@state_key)
          send(owner, {:message_segment_read_parked, self(), key})

          receive do
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
      owner = self()
      Agent.update(__MODULE__, fn _ -> %{gets: 0, lists: 0, owner: owner} end)
    end

    def increment(kind) do
      callers = [self() | Process.get(:"$callers", [])]

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
      test_pid = Application.fetch_env!(:salix_im, :blocking_agent_delivery_test_pid)
      send(test_pid, {:agent_delivery_blocked, self()})

      receive do
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
      send(
        Application.fetch_env!(:salix_im, :capture_agent_delivery_test_pid),
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
        send(pid, {:session_activity_updated, agent_id, session_id})
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
      subscriber = self()

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
      subscriber = self()

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
      if Application.get_env(:salix_im, :drop_delivery_ack_once, false) and
           delivered_record?(body) do
        Application.put_env(:salix_im, :drop_delivery_ack_once, false)

        send(
          Application.fetch_env!(:salix_im, :delivery_ack_fault_test_pid),
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
        Application.get_env(:salix_im, :fail_conversation_tombstone_once, false) and
          key == Application.get_env(:salix_im, :conversation_tombstone_fault_key) and
            tombstone?(body) ->
          Application.put_env(:salix_im, :fail_conversation_tombstone_once, false)
          {:error, {:http, 503}}

        Application.get_env(:salix_im, :inject_participant_collision, false) and
          String.contains?(key, "/participant_states/") and
          String.ends_with?(key, ".json") and opts[:if_none_match] == "*" ->
          Application.put_env(:salix_im, :inject_participant_collision, false)
          Application.put_env(:salix_im, :participant_collision_key, key)
          {:error, :precondition_failed}

        Application.get_env(:salix_im, :fail_participant_state_once, false) and
          String.contains?(key, "/participant_states/") and opts[:if_none_match] == "*" ->
          Application.put_env(:salix_im, :fail_participant_state_once, false)
          Application.put_env(:salix_im, :failed_participant_state_key, key)
          {:error, {:http, 503}}

        Application.get_env(:salix_im, :fail_message_segment_once, false) and
            String.contains?(key, "/messages/segments/") ->
          Application.put_env(:salix_im, :fail_message_segment_once, false)
          {:error, {:http, 503}}

        true ->
          SalixStore.S3.Fake.put(key, body, opts)
      end
    end

    @impl true
    def get(key, opts) do
      if key == Application.get_env(:salix_im, :participant_collision_key) do
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
        Application.get_env(:salix_im, :delete_fault_conversation_prefix, "")

      if Application.get_env(:salix_im, :fail_conversation_child_delete_once, false) and
           conversation_prefix != "" and String.starts_with?(key, conversation_prefix) and
           not String.ends_with?(key, "/meta.json") do
        Application.put_env(:salix_im, :fail_conversation_child_delete_once, false)

        send(
          Application.fetch_env!(:salix_im, :conversation_delete_fault_test_pid),
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
        Application.get_env(:salix_im, :drop_participant_state_after_list_once, false) and
            prefix ==
              Application.get_env(:salix_im, :delete_race_participant_states_prefix) ->
          case SalixStore.S3.Fake.list(prefix, opts) do
            {:ok, %{objects: [object | _rest]}} = result ->
              Application.put_env(:salix_im, :drop_participant_state_after_list_once, false)
              :ok = SalixStore.S3.Fake.delete(object.key, [])

              send(
                Application.fetch_env!(:salix_im, :conversation_delete_race_test_pid),
                {:participant_state_deleted_after_list, object.key}
              )

              result

            result ->
              result
          end

        Application.get_env(:salix_im, :fail_delete_cleanup_stage_not_found_once, false) and
            prefix == Application.get_env(:salix_im, :delete_cleanup_stage_prefix) ->
          Application.put_env(:salix_im, :fail_delete_cleanup_stage_not_found_once, false)

          send(
            Application.fetch_env!(:salix_im, :conversation_delete_race_test_pid),
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

      if Application.get_env(:salix_im, :crash_tombstone_owner_once, false) and
           key == Application.get_env(:salix_im, :crash_tombstone_key) and
           tombstone?(body) and match?({:ok, _}, result) do
        Application.put_env(:salix_im, :crash_tombstone_owner_once, false)

        if Application.get_env(
             :salix_im,
             :fail_recovery_meta_get_after_tombstone_crash_once,
             false
           ) do
          Application.put_env(
            :salix_im,
            :fail_recovery_meta_get_after_tombstone_crash_once,
            false
          )

          Application.put_env(:salix_im, :fail_recovery_meta_get_once, true)
        end

        send(Application.fetch_env!(:salix_im, :crash_tombstone_test_pid), :tombstone_committed)
        exit(:kill)
      end

      result
    end

    @impl true
    def list(prefix, opts) do
      cleanup_prefix =
        Application.get_env(:salix_im, :crash_participant_states_prefix)

      if Application.get_env(:salix_im, :block_deleted_participant_cleanup, false) and
           is_binary(cleanup_prefix) and String.starts_with?(prefix, cleanup_prefix) do
        send(
          Application.fetch_env!(:salix_im, :crash_tombstone_test_pid),
          :deleted_participant_cleanup_blocked
        )

        {:error, {:http, 503}}
      else
        SalixStore.S3.Fake.list(prefix, opts)
      end
    end

    @impl true
    def get(key, opts) do
      if Application.get_env(:salix_im, :fail_recovery_meta_get_once, false) and
           key == Application.get_env(:salix_im, :crash_tombstone_key) do
        Application.put_env(:salix_im, :fail_recovery_meta_get_once, false)

        test_pid = Application.fetch_env!(:salix_im, :crash_tombstone_test_pid)
        send(test_pid, :recovery_meta_get_failed)

        if Application.get_env(:salix_im, :block_recovery_meta_get_once, false) do
          send(test_pid, {:recovery_meta_get_blocked, self()})

          receive do
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

    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_agent_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    prev_session_activity = Application.get_env(:salix_im, :session_activity_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    Application.put_env(
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
        Application.delete_env(:salix_im, :delete_fault_conversation_prefix)
        Application.delete_env(:salix_im, :fail_conversation_child_delete_once)
        Application.delete_env(:salix_im, :conversation_delete_fault_test_pid)
        Application.delete_env(:salix_im, :drop_participant_state_after_list_once)
        Application.delete_env(:salix_im, :delete_race_participant_states_prefix)
        Application.delete_env(:salix_im, :fail_delete_cleanup_stage_not_found_once)
        Application.delete_env(:salix_im, :delete_cleanup_stage_prefix)
        Application.delete_env(:salix_im, :conversation_delete_race_test_pid)
        Application.delete_env(:salix_im, :fail_conversation_tombstone_once)
        Application.delete_env(:salix_im, :conversation_tombstone_fault_key)
        Application.delete_env(:salix_im, :crash_tombstone_owner_once)
        Application.delete_env(:salix_im, :crash_tombstone_key)
        Application.delete_env(:salix_im, :crash_tombstone_test_pid)
        Application.delete_env(:salix_im, :fail_recovery_meta_get_after_tombstone_crash_once)
        Application.delete_env(:salix_im, :fail_recovery_meta_get_once)
        Application.delete_env(:salix_im, :block_recovery_meta_get_once)
        Application.delete_env(:salix_im, :crash_participant_states_prefix)
        Application.delete_env(:salix_im, :fail_participant_state_once)
        Application.delete_env(:salix_im, :failed_participant_state_key)
        Application.delete_env(:salix_im, :block_deleted_participant_cleanup)
        Application.delete_env(:salix_im, :blocking_agent_delivery_test_pid)
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

  @tag :desktop_meeting
  test "meeting pause and audio-only completion use the entry Task", ctx do
    entry = %{
      "occurrence_id" => "meeting-occurrence-test-2",
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

    assert {:ok, _} =
             ConversationServer.desktop_meeting(ctx.group_id, id, "owner-user-1", %{
               "action" => "recording",
               "version" => 1
             })

    assert {:ok, paused} =
             ConversationServer.desktop_meeting(ctx.group_id, id, "owner-user-1", %{
               "action" => "paused",
               "version" => 2
             })

    assert paused["metadata"]["desktop_meeting"]["phase"] == "paused"

    command = %{
      "action" => "finalize",
      "version" => 3,
      "smart_summary" => false,
      "recording" => %{"recording_id" => "audio-only-recording"}
    }

    message = %{
      "actor_type" => "user",
      "user_id" => "owner-user-1",
      "client_request_id" => "audio-only-recording",
      "content" => "Audio saved"
    }

    assert {:ok, saved} =
             ConversationServer.desktop_meeting(
               ctx.group_id,
               id,
               "owner-user-1",
               command,
               message
             )

    assert saved["conversation_id"] == id
    assert saved["status"] == "completed"

    assert {:ok, repeated} =
             ConversationServer.desktop_meeting(
               ctx.group_id,
               id,
               "owner-user-1",
               command,
               message
             )

    assert repeated["updated_at"] == saved["updated_at"]

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(ctx.group_id, id, limit: 10)

    assert length(messages) == 2
    assert Enum.all?(messages, &(&1["delivery_filter"] == %{"participant_ids" => []}))
  end

  @tag :desktop_meeting
  test "failed audio append retains the original finalize command for retry", ctx do
    entry = %{
      "occurrence_id" => "meeting-failed-finalize",
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

    command = %{
      "action" => "finalize",
      "version" => 1,
      "smart_summary" => false,
      "recording" => %{"recording_id" => "retained-audio"}
    }

    invalid = %{
      "actor_type" => "agent",
      "agent_id" => "invalid-agent",
      "content" => "Audio saved",
      "client_request_id" => "retained-audio"
    }

    assert {:error, _} =
             ConversationServer.desktop_meeting(
               ctx.group_id,
               id,
               "owner-user-1",
               command,
               invalid
             )

    assert {:error, {:conflict, _}} =
             ConversationServer.desktop_meeting(ctx.group_id, id, "owner-user-1", %{
               "action" => "dismiss",
               "version" => 2
             })

    valid = %{
      "actor_type" => "user",
      "user_id" => "owner-user-1",
      "content" => "Audio saved",
      "client_request_id" => "retained-audio"
    }

    assert {:ok, saved} =
             ConversationServer.desktop_meeting(ctx.group_id, id, "owner-user-1", command, valid)

    assert saved["status"] == "completed"
    refute Map.has_key?(saved["metadata"]["desktop_meeting"], "pending_finalize")
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
                 "expires_at" => System.system_time(:second) + 3_600,
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

  test "owner reservation keeps the canonical message id stable until append", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Reserved identity",
               "participants" => [user_participant(now)]
             })

    conversation_id = conversation["conversation_id"]

    attrs = %{
      "kind" => "message",
      "content" => "aggregate-first",
      "client_request_id" => "reserved-user-message",
      "created_at" => now + 1
    }

    assert {:ok, %{"message_id" => reserved_message_id}} =
             ConversationServer.reserve_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert Ids.valid_message_id?(reserved_message_id)

    assert {:ok, []} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert {:error, {:conflict, _}} =
             ConversationServer.reserve_group_conversation_message(
               group_id,
               conversation_id,
               Map.put(attrs, "content", "different")
             )

    assert {:ok, %{"message_id" => ^reserved_message_id, "inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )
  end

  test "append propagates a canonical message pointer read outage", %{
    group_id: group_id
  } do
    attrs = %{
      "kind" => "message",
      "content" => "do not append through an unknown pointer state",
      "client_request_id" => "pointer-read-outage"
    }

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Pointer outage",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, %{"message_id" => message_id}} =
             ConversationServer.reserve_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    pointer_key =
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        SalixStore.Crypto.hex(message_id)
      )

    assert :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :get, pointer_key})

    assert {:error, {:http, 503}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )
  end

  test "message lookup rejects a cross-wired canonical identity pointer", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Pointer identity integrity",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, %{"message_id" => first_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "first", "client_request_id" => "pointer-integrity-first"}
             )

    assert {:ok, %{"message_id" => second_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "second", "client_request_id" => "pointer-integrity-second"}
             )

    first_pointer_key =
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        SalixStore.Crypto.hex(first_id)
      )

    second_pointer_key =
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        SalixStore.Crypto.hex(second_id)
      )

    assert {:ok, %{body: second_pointer_body}} = SalixStore.S3.get(second_pointer_key)
    assert {:ok, _etag} = SalixStore.S3.put(first_pointer_key, second_pointer_body)

    assert {:error, :invalid_message_pointer} =
             Conversations.get_group_conversation_message(
               group_id,
               conversation_id,
               first_id
             )
  end

  test "message list rejects an after_id pointer whose target row has another identity", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "After pointer target integrity",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, %{"message_id" => first_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "first", "client_request_id" => "after-pointer-first"}
             )

    assert {:ok, %{"seq" => second_seq}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "second", "client_request_id" => "after-pointer-second"}
             )

    first_pointer_key =
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        SalixStore.Crypto.hex(first_id)
      )

    assert {:ok, %{body: first_pointer_body, etag: first_pointer_etag}} =
             SalixStore.S3.get(first_pointer_key)

    cross_wired_pointer =
      first_pointer_body
      |> Jason.decode!()
      |> Map.put("seq", second_seq)
      |> Jason.encode!()

    assert {:ok, _etag} =
             SalixStore.S3.put(first_pointer_key, cross_wired_pointer,
               if_match: first_pointer_etag
             )

    assert {:error, :invalid_message_pointer} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               after_id: first_id,
               limit: 20
             )
  end

  test "message list fails closed when the starting sequence index is missing", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Missing sequence index",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "must remain visible", "client_request_id" => "missing-seq-index"}
             )

    sequence_key =
      Keys.ctl_group_conversation_message_seq_index(group_id, conversation_id, 1)

    assert :ok = SalixStore.S3.delete(sequence_key)

    assert {:error, :message_sequence_index_missing} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )
  end

  test "message pages are positioned by seq, bounded, and report the span they read", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Message page reads",
               "participants" => [user_participant(System.system_time(:millisecond))]
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

    # The default is 100 and a larger limit is clamped to 200.
    assert {:ok, default_page} = page.(after: 1)
    assert seqs.(default_page) == Enum.to_list(2..12)

    for index <- 13..205 do
      assert {:ok, %{"seq" => ^index}} =
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 %{"content" => "page #{index}", "client_request_id" => "page-#{index}"}
               )
    end

    assert {:ok, default_tail} = page.([])
    assert length(default_tail["messages"]) == 100
    assert {:ok, clamped} = page.(limit: 500)
    assert %{"covered" => %{"first_seq" => 6, "last_seq" => 205}} = clamped
    assert length(clamped["messages"]) == 200

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
                   "participants" => [user_participant(System.system_time(:millisecond))]
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

  test "message lookup reports a dangling pointer as integrity failure", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Dangling message pointer",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, %{"message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "pointer target", "client_request_id" => "dangling-pointer"}
             )

    pointer_key =
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        SalixStore.Crypto.hex(message_id)
      )

    assert {:ok, %{body: pointer_body}} = SalixStore.S3.get(pointer_key)
    pointer = Jason.decode!(pointer_body)

    segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        pointer["segment_id"]
      )

    assert :ok = SalixStore.S3.delete(segment_key)

    assert {:error, :message_pointer_target_missing} =
             Conversations.get_group_conversation_message(
               group_id,
               conversation_id,
               message_id
             )
  end

  test "a lagging segment index (append crash window) wedges neither reads nor appends", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Lagging index",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, %{"message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "row one", "client_request_id" => "lag-one"}
             )

    assert {:ok, _} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "row two", "client_request_id" => "lag-two"}
             )

    pointer_key =
      Keys.ctl_group_conversation_message_identity(
        group_id,
        conversation_id,
        SalixStore.Crypto.hex(message_id)
      )

    assert {:ok, %{body: pointer_body}} = SalixStore.S3.get(pointer_key)
    segment_id = Jason.decode!(pointer_body)["segment_id"]

    segment_key =
      Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    index_key =
      Keys.ctl_group_conversation_message_segment_index(group_id, conversation_id, segment_id)

    # Rewind the index to the snapshot an append crash leaves behind: the
    # body carries both rows, the index only ever saw the first.
    assert {:ok, %{body: segment_body}} = SalixStore.S3.get(segment_key)
    [first_line | _] = String.split(segment_body, "\n", trim: true)
    prefix_body = first_line <> "\n"
    {:ok, [first_row]} = SalixIM.ConversationMessageCodec.decode_segment(prefix_body)

    assert {:ok, %{body: index_body}} = SalixStore.S3.get(index_key)

    lagging =
      index_body
      |> Jason.decode!()
      |> Map.merge(SalixIM.ConversationMessageCodec.segment_facts([first_row], prefix_body))

    assert {:ok, _} = SalixStore.S3.put(index_key, Jason.encode!(lagging))

    # Reads treat the segment as authoritative instead of returning 500.
    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert length(messages) == 2

    # The next append repairs the index from the segment instead of wedging.
    assert {:ok, _} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "row three", "client_request_id" => "lag-three"}
             )

    assert {:ok, %{body: repaired_segment}} = SalixStore.S3.get(segment_key)
    {:ok, repaired_rows} = SalixIM.ConversationMessageCodec.decode_segment(repaired_segment)
    assert {:ok, %{body: repaired_index}} = SalixStore.S3.get(index_key)

    facts = SalixIM.ConversationMessageCodec.segment_facts(repaired_rows, repaired_segment)
    assert Map.take(Jason.decode!(repaired_index), Map.keys(facts)) == facts

    assert length(repaired_rows) == 3
  end

  test "message reads recover when an append lands after the segment read", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Concurrent segment append",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, _message} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "row one", "client_request_id" => "race-one"}
             )

    segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    previous_backend = Application.fetch_env!(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, MessageSegmentReadBarrierS3)

    on_exit(fn ->
      MessageSegmentReadBarrierS3.clear()
      Application.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    reader =
      Task.async(fn ->
        receive do
          :read_messages -> :ok
        end

        Conversations.list_group_conversation_messages(
          group_id,
          conversation_id,
          limit: 20
        )
      end)

    MessageSegmentReadBarrierS3.arm(segment_key, reader.pid, self())
    send(reader.pid, :read_messages)

    assert_receive {:message_segment_read_parked, reader_pid, ^segment_key}, 2_000
    assert reader_pid == reader.pid

    assert {:ok, _message} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "row two", "client_request_id" => "race-two"}
             )

    send(reader_pid, {:release_message_segment_read, segment_key})

    assert {:ok, messages} = Task.await(reader, 5_000)
    assert Enum.map(messages, & &1["seq"]) in [[1], [1, 2]]
  end

  test "conversation subscriptions publish each committed message once", %{group_id: group_id} do
    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Subscribed task",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    conversation_id = conversation["conversation_id"]

    assert {:ok, %{"owner_pid" => _owner, "tail_seq" => 0}} =
             ConversationServer.subscribe_group_conversation(group_id, conversation_id, self())

    attrs = %{"content" => "first", "client_request_id" => "subscribed-message-1"}

    assert {:ok, %{"inserted" => true, "message_id" => message_id, "seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert_receive {:conversation_message_created, ^group_id, ^conversation_id, ^message_id, 1}

    meta_key = Keys.ctl_group_conversation_meta(group_id, conversation_id)
    meta_before_retry = SalixStore.S3.Fake.dump()[meta_key].body

    assert {:ok, %{"inserted" => false, "seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert SalixStore.S3.Fake.dump()[meta_key].body == meta_before_retry

    refute_receive {:conversation_message_created, ^group_id, ^conversation_id, ^message_id, 1},
                   100
  end

  test "group task-list subscriptions invalidate on canonical task create, update, and message append",
       %{
         group_id: group_id
       } do
    assert {:ok, %{"owner_pid" => owner_pid}} =
             ConversationServer.subscribe_group_conversation_list(
               group_id,
               "agent_task",
               self()
             )

    assert is_pid(owner_pid)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "SSE task",
               "status" => "active",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                    ^conversation_id, first_version}

    assert is_binary(first_version)

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "status" => "completed"
             })

    assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                    ^conversation_id, second_version}

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

    assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                    ^conversation_id, third_version}

    assert third_version != second_version
  end

  test "group task-list subscriptions invalidate when a canonical Task is materialized", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    assert {:ok, %{"version" => subscribed_version}} =
             ConversationServer.subscribe_group_conversation_list(
               group_id,
               "agent_task",
               self()
             )

    assert {:ok, %{"conversation_id" => conversation_id}} =
             create_task_conversation(group_id, router_id, worker_id, %{
               "content" => "materialize a Task from the router"
             })

    # Materializing a Task announces its initial Message and then the created
    # Conversation. The owner knows the Task's kind for both, so neither is
    # dropped as an unattributable mutation.
    assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                    ^conversation_id, message_version}

    assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                    ^conversation_id, created_version}

    assert subscribed_version not in [message_version, created_version]
    assert message_version != created_version

    # The owner keeps that kind for the rest of its lifetime, so later work in
    # the same Task keeps invalidating the list.
    seen =
      [subscribed_version, message_version, created_version] ++
        drain_task_list_invalidations(group_id, conversation_id)

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "agent",
                 "agent_id" => worker_id,
                 "client_request_id" => "materialized-task-progress",
                 "content" => "working on it"
               }
             )

    assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                    ^conversation_id, appended_version}

    assert appended_version not in seen
  end

  test "an unattributable group conversation mutation is logged, not silently dropped", %{
    group_id: group_id
  } do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 SalixIM.ConversationGroupActor.notify_conversation_mutation_if_running(
                   group_id,
                   %{
                     event: :conversation_upsert,
                     conversation_id: Ids.new_conversation_id(),
                     kind: nil
                   }
                 )
      end)

    assert log =~ "dropped unattributable group conversation mutation"
  end

  test "group list subscriptions keep independent owner versions for each conversation kind", %{
    group_id: group_id
  } do
    assert {:ok, %{"version" => task_version}} =
             ConversationServer.subscribe_group_conversation_list(
               group_id,
               "agent_task",
               self()
             )

    assert {:ok, %{"version" => chat_version}} =
             ConversationServer.subscribe_group_conversation_list(
               group_id,
               "user_chat",
               self()
             )

    assert {:ok, %{"conversation_id" => chat_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Independent Chat version"
             })

    assert_receive {:group_conversation_list_invalidated, ^group_id, "user_chat", ^chat_id,
                    next_chat_version}

    assert next_chat_version != chat_version

    assert {:ok, %{"version" => ^task_version}} =
             ConversationServer.subscribe_group_conversation_list(
               group_id,
               "agent_task",
               self()
             )

    assert {:ok, %{"conversation_id" => task_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Independent Task version",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task", ^task_id,
                    next_task_version}

    assert next_task_version != task_version

    assert {:ok, %{"version" => ^next_chat_version}} =
             ConversationServer.subscribe_group_conversation_list(
               group_id,
               "user_chat",
               self()
             )
  end

  @tag participant_refresh_burst: true
  test "activity bursts refresh the latest state without replaying every invalidation", %{
    group_id: group_id,
    router_id: router_id,
    router_session_id: session_id
  } do
    participant = agent_participant(router_id, "router", System.system_time(:millisecond))
    participant = Map.put(participant, "payload", %{"session_id" => session_id})

    {:ok, conversation} =
      SalixIM.ConversationInput.create_group_conversation(group_id, %{
        "participants" => [participant]
      })

    cid = conversation["conversation_id"]

    {:ok, %{"participants" => [participant]}} =
      Conversations.list_group_conversation_participants(group_id, cid)

    participant_id = participant["participant_id"]
    initial = %{"state" => "active", "status" => "is thinking...", "updated_at" => 1}
    RealtimeSessionActivity.configure(self(), router_id, session_id, initial)
    Application.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)
    on_exit(fn -> RealtimeSessionActivity.clear() end)

    {:ok, %{"owner_pid" => owner}} =
      ConversationServer.subscribe_group_conversation_participant(
        group_id,
        cid,
        participant_id,
        self()
      )

    RealtimeSessionActivity.track_gets()
    RealtimeSessionActivity.block_next_get()
    RealtimeSessionActivity.publish(initial)
    assert_receive {:session_activity_blocked, ^owner}, 2_000

    # These arrive while the first read holds an older snapshot. The final
    # invalidation must still cause a read after that in-flight read finishes.
    try do
      for revision <- 2..101 do
        RealtimeSessionActivity.publish(%{
          "state" => "active",
          "status" => "is working...",
          "updated_at" => revision
        })
      end
    after
      send(owner, :release_session_activity)
    end

    assert_receive {:participant_activity_read, ^owner}, 2_000
    assert_receive {:participant_activity_read, ^owner}, 2_000

    assert_receive {:conversation_participant_status_changed, ^group_id, ^cid, ^participant_id},
                   2_000

    # A same-sender barrier after the published burst lets the actor finish
    # handling all queued invalidations before checking the read bound.
    :sys.get_state(owner)
    refute_receive {:participant_activity_read, ^owner}, 100

    assert {:ok, %{"activity" => %{"updated_at" => 101, "status" => "is working..."}}} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               cid,
               participant_id
             )
  end

  for operation <- [:snapshot, :subscribe] do
    @tag participant_send_isolation: true
    test "#{operation} waits for Session activity without blocking a visible send", %{
      group_id: group_id,
      router_id: router_id,
      router_session_id: session_id
    } do
      operation = unquote(operation)
      participant = agent_participant(router_id, "router", System.system_time(:millisecond))
      participant = Map.put(participant, "payload", %{"session_id" => session_id})

      {:ok, conversation} =
        SalixIM.ConversationInput.create_group_conversation(group_id, %{
          "participants" => [participant]
        })

      cid = conversation["conversation_id"]

      {:ok, %{"participants" => [participant]}} =
        Conversations.list_group_conversation_participants(group_id, cid)

      pid = participant["participant_id"]

      RealtimeSessionActivity.configure(self(), router_id, session_id, %{
        "state" => "active",
        "updated_at" => 1
      })

      Application.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)
      on_exit(fn -> RealtimeSessionActivity.clear() end)

      assert {:ok, _} =
               ConversationServer.get_group_conversation_participant_status(group_id, cid, pid)

      RealtimeSessionActivity.block_next_get()
      subscriber = self()

      reader =
        Task.async(fn ->
          case operation do
            :snapshot ->
              ConversationServer.get_group_conversation_participant_status(group_id, cid, pid)

            :subscribe ->
              ConversationServer.subscribe_group_conversation_participant(
                group_id,
                cid,
                pid,
                subscriber
              )
          end
        end)

      assert_receive {:session_activity_blocked, participant_owner}, 2_000

      sender =
        Task.async(fn ->
          Provider.call_api(router_id, "internal", "internal.send_message", %{
            "connect_id" => "internal",
            "params" => %{
              "conversation_id" => cid,
              "content" => [%{"type" => "text", "text" => "Ready"}],
              "delivery_filter" => %{"participant_ids" => []}
            }
          })
        end)

      try do
        assert {:ok, {:ok, %{"sent" => true}}} = Task.yield(sender, 1_000)
      after
        send(participant_owner, :release_session_activity)
        Task.await(reader, 5_000)
        Task.shutdown(sender)
      end
    end
  end

  test "participant direct reads recover a missed realtime draft clear invalidation", %{
    group_id: group_id,
    router_id: router_id,
    router_session_id: router_session_id
  } do
    now = System.system_time(:millisecond)

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

    previous_session_activity = Application.get_env(:salix_im, :session_activity_mod)

    RealtimeSessionActivity.configure(
      self(),
      router_id,
      router_session_id,
      initial_activity
    )

    Application.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)

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
               self()
             )

    assert_receive {:participant_session_subscription, ^participant_owner, ^router_id,
                    ^router_session_id}

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

    assert_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id}

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

    assert_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id}

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

    assert_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id}

    assert {:ok, %{"draft" => %{"revision" => 3}}} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )

    # Session callbacks are invalidation hints, so a synchronous read must
    # recover the current owner snapshot even when the clear hint is lost.
    assert :ok = RealtimeSessionActivity.replace_without_notify(initial_activity)

    refute_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id},
                   100

    assert {:ok, status_after_missed_clear} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )

    refute Map.has_key?(status_after_missed_clear, "draft")
  end

  test "participant status retains its last reliable snapshot across a transient read failure", %{
    group_id: group_id,
    router_id: router_id,
    router_session_id: router_session_id
  } do
    now = System.system_time(:millisecond)

    participant =
      router_id
      |> agent_participant("router", now)
      |> Map.put("payload", %{"session_id" => router_session_id})

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant last reliable status",
               "participants" => [participant]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    reliable = %{
      "session_id" => router_session_id,
      "state" => "active",
      "status" => "still working",
      "updated_at" => now
    }

    previous_session_activity = Application.get_env(:salix_im, :session_activity_mod)
    RealtimeSessionActivity.configure(self(), router_id, router_session_id, reliable)
    Application.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)

    on_exit(fn ->
      RealtimeSessionActivity.clear()
      restore(:salix_im, :session_activity_mod, previous_session_activity)
    end)

    assert {:ok, %{"status" => %{"activity" => %{"status" => "still working"}}}} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id,
               self()
             )

    RealtimeSessionActivity.fail_next_get(router_id, router_session_id)
    assert :ok = RealtimeSessionActivity.publish(reliable)

    refute_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id},
                   100

    assert {:ok,
            %{
              "conversation_id" => ^conversation_id,
              "participant_id" => ^participant_id,
              "activity" => %{
                "state" => "active",
                "status" => "still working",
                "updated_at" => ^now
              }
            }} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )

    assert {:ok, %{"status" => %{"activity" => %{"status" => "still working"}}}} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id,
               self()
             )
  end

  test "participant status retains its last reliable snapshot after the last subscriber leaves",
       %{
         group_id: group_id,
         router_id: router_id,
         router_session_id: router_session_id
       } do
    now = System.system_time(:millisecond)

    participant =
      router_id
      |> agent_participant("router", now)
      |> Map.put("payload", %{"session_id" => router_session_id})

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant status survives subscriber turnover",
               "participants" => [participant]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    reliable = %{
      "session_id" => router_session_id,
      "state" => "active",
      "status" => "cached reliable status",
      "updated_at" => now
    }

    previous_session_activity = Application.get_env(:salix_im, :session_activity_mod)
    RealtimeSessionActivity.configure(self(), router_id, router_session_id, reliable)
    Application.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)

    on_exit(fn ->
      RealtimeSessionActivity.clear()
      restore(:salix_im, :session_activity_mod, previous_session_activity)
    end)

    parent = self()

    subscriber =
      spawn(fn ->
        result =
          ConversationServer.subscribe_group_conversation_participant(
            group_id,
            conversation_id,
            participant_id,
            self()
          )

        send(parent, {:participant_subscribed, self(), result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:participant_subscribed, ^subscriber,
                    {:ok, %{"status" => %{"activity" => %{"status" => "cached reliable status"}}}}}

    assert_receive {:participant_session_subscription, participant_owner, ^router_id,
                    ^router_session_id}

    subscriber_ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^subscriber_ref, :process, ^subscriber, :normal}

    assert_receive {:participant_session_unsubscription, ^participant_owner, ^router_id,
                    ^router_session_id}

    RealtimeSessionActivity.fail_next_get(router_id, router_session_id)

    assert {:ok,
            %{
              "activity" => %{
                "state" => "active",
                "status" => "cached reliable status",
                "updated_at" => ^now
              }
            }} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )
  end

  test "participant status keeps display text separate from its exact presentation on a shared session",
       %{
         group_id: group_id,
         router_id: router_id,
         router_session_id: router_session_id
       } do
    now = System.system_time(:millisecond)

    participant =
      router_id
      |> agent_participant("router", now)
      |> Map.put("payload", %{"session_id" => router_session_id})

    assert {:ok, %{"conversation_id" => first_conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "First shared-session participant",
               "participants" => [participant]
             })

    assert {:ok, %{"conversation_id" => second_conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Second shared-session participant",
               "participants" => [participant]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => first_participant_id}]}} =
             Conversations.list_group_conversation_participants(
               group_id,
               first_conversation_id
             )

    assert {:ok, %{"participants" => [%{"participant_id" => second_participant_id}]}} =
             Conversations.list_group_conversation_participants(
               group_id,
               second_conversation_id
             )

    response_key =
      "rsp_" <> Base.url_encode64(:binary.copy(<<8>>, 18), padding: false)

    canonical = %{
      "session_id" => router_session_id,
      "state" => "active",
      "status" => "canonical session activity",
      "updated_at" => now
    }

    snapshot =
      ConversationParticipantActivity.session_snapshot(
        canonical,
        %{
          "agent_group_id" => group_id,
          "conversation_id" => first_conversation_id,
          "participant_id" => first_participant_id,
          "phase" => "thinking",
          "status" => "running",
          "summary" => "first participant only",
          "summary_class" => "public",
          "producer_epoch" => "participant-test-epoch",
          "response_key" => response_key,
          "sequence" => 1,
          "source_message_ids" => ["first-participant-source"],
          "updated_at" => now
        },
        %{
          "agent_group_id" => group_id,
          "conversation_id" => first_conversation_id,
          "participant_id" => first_participant_id,
          "response_key" => response_key,
          "revision" => 1,
          "status" => "streaming",
          "text" => "first participant draft",
          "source_message_ids" => ["first-participant-source"],
          "updated_at" => now
        }
      )

    previous_session_activity = Application.get_env(:salix_im, :session_activity_mod)

    RealtimeSessionActivity.configure(self(), router_id, router_session_id, snapshot)
    Application.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)

    on_exit(fn ->
      RealtimeSessionActivity.clear()
      restore(:salix_im, :session_activity_mod, previous_session_activity)
    end)

    assert {:ok,
            %{
              "status" => %{
                "activity" => %{
                  "state" => "active",
                  "status" => "canonical session activity"
                },
                "presentation_activity" => %{
                  "summary" => "first participant only",
                  "status" => "running"
                },
                "draft" => %{"text" => "first participant draft"}
              }
            }} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               first_conversation_id,
               first_participant_id,
               self()
             )

    assert {:ok,
            %{
              "status" => %{
                "activity" => %{
                  "state" => "active",
                  "status" => "canonical session activity"
                }
              }
            }} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               second_conversation_id,
               second_participant_id,
               self()
             )

    second_snapshot =
      ConversationParticipantActivity.session_snapshot(
        canonical,
        %{
          "agent_group_id" => group_id,
          "conversation_id" => second_conversation_id,
          "participant_id" => second_participant_id,
          "phase" => "execution",
          "status" => "running",
          "summary" => "second participant now",
          "summary_class" => "public",
          "producer_epoch" => "participant-test-epoch",
          "response_key" => response_key,
          "sequence" => 2,
          "source_message_ids" => ["second-participant-source"],
          "updated_at" => now + 1
        },
        nil
      )

    assert :ok = RealtimeSessionActivity.publish(second_snapshot)

    assert_receive {:conversation_participant_status_changed, ^group_id, ^first_conversation_id,
                    ^first_participant_id}

    assert_receive {:conversation_participant_status_changed, ^group_id, ^second_conversation_id,
                    ^second_participant_id}

    assert {:ok,
            %{"activity" => %{"state" => "active", "status" => "canonical session activity"}}} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               first_conversation_id,
               first_participant_id
             )

    assert {:ok,
            %{
              "activity" => %{
                "state" => "active",
                "status" => "canonical session activity"
              },
              "presentation_activity" => %{
                "phase" => "execution",
                "status" => "running",
                "summary" => "second participant now"
              }
            }} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               second_conversation_id,
               second_participant_id
             )
  end

  test "participant subscriptions follow an agent target rebind", %{
    group_id: group_id,
    router_id: router_id,
    router_session_id: first_session_id
  } do
    now = System.system_time(:millisecond)

    participant =
      router_id
      |> agent_participant("router", now)
      |> Map.put("payload", %{"session_id" => first_session_id})

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant target rebind",
               "participants" => [participant]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    first_snapshot = %{
      "state" => "active",
      "status" => "first session",
      "updated_at" => now
    }

    previous_session_activity = Application.get_env(:salix_im, :session_activity_mod)

    RealtimeSessionActivity.configure(self(), router_id, first_session_id, first_snapshot)

    Application.put_env(:salix_im, :session_activity_mod, RealtimeSessionActivity)

    on_exit(fn ->
      RealtimeSessionActivity.clear()
      restore(:salix_im, :session_activity_mod, previous_session_activity)
    end)

    assert {:ok,
            %{
              "owner_pid" => participant_owner,
              "status" => %{"activity" => %{"status" => "first session"}}
            }} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id,
               self()
             )

    assert_receive {:participant_session_subscription, ^participant_owner, ^router_id,
                    ^first_session_id}

    assert {:ok, %{"participant_id" => ^participant_id}} =
             ConversationServer.deactivate_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id
             )

    assert_receive {:participant_session_unsubscription, ^participant_owner, ^router_id,
                    ^first_session_id}

    assert_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id}

    assert {:ok,
            %{
              "participant_id" => ^participant_id,
              "payload" => %{"session_id" => rebound_session_id}
            }} =
             SalixIM.ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{
                 "agent_id" => router_id,
                 "role_label" => "router",
                 "updated_at" => now + 1
               }
             )

    assert Ids.valid_session_id?(rebound_session_id)

    assert_receive {:participant_session_subscription, ^participant_owner, ^router_id,
                    ^rebound_session_id}

    assert_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id}

    second_snapshot = %{
      "state" => "active",
      "status" => "second session",
      "updated_at" => now + 1
    }

    assert :ok =
             RealtimeSessionActivity.publish(
               router_id,
               rebound_session_id,
               second_snapshot
             )

    assert_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^participant_id}

    assert {:ok, %{"activity" => %{"status" => "second session"}}} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             )
  end

  test "group conversation lifecycle admits addressed messages into participant Sessions", %{
    group_id: group_id,
    router_id: router_id,
    router_session_id: router_session_id,
    worker_id: worker_id
  } do
    now = System.system_time(:millisecond)

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

    assert listed = Enum.find(listed_conversations, &(&1["conversation_id"] == conversation_id))
    assert listed["conversation_id"] == conversation_id

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

  test "conversation search snippets preserve UTF-8 boundaries", %{group_id: group_id} do
    now = System.system_time(:millisecond)

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Unicode search",
               "participants" => [user_participant(now)],
               "created_at" => now,
               "updated_at" => now
             })

    content = String.duplicate("汉", 27) <> "needle" <> String.duplicate("字", 27)

    assert {:ok, _result} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               %{
                 "content" => content,
                 "client_request_id" => "unicode-search-snippet"
               }
             )

    assert snippet =
             eventually_value(fn ->
               case Conversations.search_group_conversations(group_id, "needle", limit: 10) do
                 {:ok, [%{"snippet" => snippet}]} -> snippet
                 {:ok, []} -> nil
               end
             end)

    assert String.valid?(snippet)
    assert snippet =~ "«needle»"
    assert is_binary(Jason.encode!(%{"snippet" => snippet}))
  end

  test "message metadata rejects delivery billing context", %{group_id: group_id} do
    now = System.system_time(:millisecond)

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
    Application.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)
    Application.put_env(:salix_im, :capture_agent_delivery_test_pid, self())
    on_exit(fn -> Application.delete_env(:salix_im, :capture_agent_delivery_test_pid) end)

    now = System.system_time(:millisecond)

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

    assert_receive {:captured_agent_delivery, ^worker_id, first_payload, first_opts}, 2_000
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

    assert_receive {:captured_agent_delivery, ^worker_id, second_payload, second_opts}, 2_000

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

    refute_receive {:captured_agent_delivery, ^worker_id, _payload, _opts}, 200
  end

  test "append coerces type-less text blocks and names the fix for shapeless ones", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    {:ok, conversation} =
      SalixIM.ConversationInput.create_group_conversation(group_id, %{
        "title" => "Coercion",
        "participants" => [
          Map.put(
            user_participant(now),
            "notification_filter",
            %{"messages" => "none", "statuses" => "none"}
          )
        ],
        "created_at" => now,
        "updated_at" => now
      })

    conversation_id = conversation["conversation_id"]

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(group_id, conversation_id)

    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))

    # {"text": …} without "type" is unambiguous — coerced, not rejected
    # (models habitually omit the type on text blocks).
    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "participant_id" => user_participant["participant_id"],
               "content" => [%{"text" => "bare text block"}],
               "client_request_id" => "msg-bare",
               "created_at" => now + 1
             })

    assert {:ok, [message]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert message["content"] == [%{"type" => "text", "text" => "bare text block"}]

    # A block that is neither typed nor coercible still fails, and the error
    # names the fix instead of a generic bad-request.
    assert {:error, {:bad_request, reason}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "participant_id" => user_participant["participant_id"],
               "content" => [%{"foo" => "bar"}],
               "client_request_id" => "msg-bad",
               "created_at" => now + 2
             })

    assert reason =~ ~s(content block must carry a "type")
  end

  test "generic create persists canonical notification filters for every participant", %{
    group_id: group_id,
    router_id: router_id
  } do
    now = System.system_time(:millisecond)

    {:ok, conversation} =
      SalixIM.ConversationInput.create_group_conversation(group_id, %{
        "title" => "Canonical participant filters",
        "participants" => [
          %{
            "actor_type" => "provider",
            "provider" => "slack",
            "role_label" => "slack_thread",
            "payload" => %{
              "connect_id" => "slack-filter-default",
              "channel_id" => "C1",
              "thread_ts" => "100.000"
            }
          },
          %{
            "actor_type" => "agent",
            "agent_id" => router_id,
            "role_label" => "worker"
          }
        ],
        "created_at" => now,
        "updated_at" => now
      })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation["conversation_id"]
             )

    provider = Enum.find(participants, &(&1["actor_type"] == "provider"))
    agent = Enum.find(participants, &(&1["actor_type"] == "agent"))

    assert provider["notification_filter"] == %{"messages" => "none", "statuses" => "none"}
    assert agent["notification_filter"] == %{"messages" => "all", "statuses" => "none"}
  end

  test "provider users share one actor-owned participant across recovery pages", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    participants =
      for index <- 1..101 do
        user_participant(now)
        |> Map.put("user_id", "existing-user-#{index}")
        |> Map.put("notification_filter", %{"messages" => "none", "statuses" => "none"})
      end

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Shared provider participant",
               "participants" => participants
             })

    assert {:error, {:bad_request, _reason}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "provider_user",
                 "provider" => "bft",
                 "user_id" => "not-joined",
                 "content" => "participant must be created separately",
                 "client_request_id" => "provider-not-joined"
               }
             )

    refute Enum.any?(all_test_participants(group_id, conversation_id), &(&1["provider"] == "bft"))

    assert {:ok, bft_participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               bft_participant()
             )

    participant_id = bft_participant["participant_id"]

    assert {:ok, %{"participant_id" => ^participant_id}} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               Map.put(bft_participant(), "payload", %{"surface" => "dashboard-v2"})
             )

    assert {:ok, %{"inserted" => true}} =
             append_bft_provider_user_message(
               group_id,
               conversation_id,
               participant_id,
               "bft-user-a",
               "bft-a"
             )

    assert {:ok, %{"inserted" => true}} =
             append_bft_provider_user_message(
               group_id,
               conversation_id,
               participant_id,
               "bft-user-b",
               "bft-b"
             )

    assert [%{"participant_id" => ^participant_id}] =
             group_id
             |> all_test_participants(conversation_id)
             |> Enum.filter(&(&1["provider"] == "bft"))

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert Enum.map(messages, &{&1["participant_id"], &1["user_id"]}) == [
             {participant_id, "bft-user-a"},
             {participant_id, "bft-user-b"}
           ]

    durable_meta =
      read_json_record!(Keys.ctl_group_conversation(group_id, conversation_id))

    refute Map.has_key?(durable_meta, "participant_count")
    refute Map.has_key?(durable_meta, "provider_participant_ids")

    assert length(all_test_participants(group_id, conversation_id)) == 102

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:ok, %{"participant_id" => ^participant_id}} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               bft_participant()
             )

    assert length(all_test_participants(group_id, conversation_id)) == 102
  end

  test "concurrent provider participant commands are serialized by the owner", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Serialized provider participant",
               "participants" => [user_participant(now)]
             })

    results =
      1..10
      |> Task.async_stream(
        fn _ ->
          ConversationServer.ensure_group_conversation_provider_participant(
            group_id,
            conversation_id,
            bft_participant()
          )
        end,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, participant}} -> participant["participant_id"] end)

    assert [_participant_id] = Enum.uniq(results)

    assert [_bft_participant] =
             group_id
             |> all_test_participants(conversation_id)
             |> Enum.filter(&(&1["provider"] == "bft"))

    assert length(all_test_participants(group_id, conversation_id)) == 2
  end

  test "participant collection accepts the bounded maximum and rejects the next membership", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    participants =
      for index <- 1..SalixIM.ConversationLimits.participant_limit() do
        now
        |> user_participant()
        |> Map.put("user_id", "bounded-user-#{index}")
      end

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Bounded participant collection",
               "participants" => participants
             })

    assert {:ok, current} =
             SalixIM.ConversationParticipantProjection.list_bounded(
               group_id,
               conversation_id
             )

    assert length(current) == SalixIM.ConversationLimits.participant_limit()

    assert {:error, {:participant_collection_over_limit, 200}} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               %{"user_id" => "one-user-too-many"}
             )
  end

  test "inactive participant history cannot grow beyond the bounded collection", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Bounded participant identity history"
             })

    for index <- 1..SalixIM.ConversationLimits.participant_limit() do
      assert {:ok, participant} =
               ConversationServer.ensure_group_conversation_user_participant(
                 group_id,
                 conversation_id,
                 %{"user_id" => "historical-user-#{index}"}
               )

      assert {:ok, %{"state" => "inactive"}} =
               ConversationServer.deactivate_group_conversation_participant(
                 group_id,
                 conversation_id,
                 participant["participant_id"]
               )
    end

    assert {:ok, history} =
             SalixIM.ConversationParticipantProjection.list_bounded(
               group_id,
               conversation_id
             )

    assert length(history) == SalixIM.ConversationLimits.participant_limit()

    assert {:error, {:participant_collection_over_limit, 200}} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               %{"user_id" => "one-historical-identity-too-many"}
             )
  end

  test "ensure reuses the canonical user identity over inactive duplicate history", %{
    group_id: group_id
  } do
    user_id = "duplicate-history-user"

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Duplicate participant identity history"
             })

    assert {:ok, original} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               %{"user_id" => user_id}
             )

    assert {:ok, %{"state" => "inactive"}} =
             ConversationServer.deactivate_group_conversation_participant(
               group_id,
               conversation_id,
               original["participant_id"]
             )

    canonical_id = Ids.new_participant_id()
    timestamp = System.system_time(:millisecond)

    canonical =
      original
      |> Map.put("participant_id", canonical_id)
      |> Map.put("state", "active")
      |> Map.put("notification_filter", %{"messages" => "none", "statuses" => "none"})
      |> Map.put("created_at", timestamp)
      |> Map.put("updated_at", timestamp)

    assert {:ok, _result} =
             SalixStore.S3.put(
               Keys.ctl_group_conversation_participant_state(
                 group_id,
                 conversation_id,
                 canonical_id
               ),
               Jason.encode!(canonical),
               if_none_match: "*"
             )

    identity_key = Jason.encode!(["user", user_id])

    assert {:ok, _aggregate} =
             SalixStore.CasRecord.update(
               Keys.ctl_group_conversation(group_id, conversation_id),
               fn aggregate ->
                 put_in(
                   aggregate,
                   [@participant_identity_slots_field, identity_key],
                   canonical_id
                 )
               end
             )

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:ok, %{"participant_id" => ^canonical_id}} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               %{"user_id" => user_id}
             )

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => user_id,
                 "content" => "canonical duplicate history recovered",
                 "client_request_id" => "canonical-duplicate-history"
               }
             )

    assert {:ok, [%{"participant_id" => ^canonical_id}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert {:ok, original_owner} =
             SalixIM.ConversationFleet.ensure_participant_started(
               group_id,
               conversation_id,
               original["participant_id"]
             )

    assert {:ok, %{"state" => "active"}} =
             SalixIM.ConversationParticipantActor.activate(
               original_owner,
               %{"notification_filter" => %{"messages" => "none", "statuses" => "none"}}
             )

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:error, {:bad_request, "user participant target is ambiguous"}} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               %{"user_id" => user_id}
             )

    assert {:ok, %{"state" => "inactive"}} =
             ConversationServer.deactivate_group_conversation_participant(
               group_id,
               conversation_id,
               canonical_id
             )

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    for attrs <- [
          %{
            "actor_type" => "user",
            "user_id" => user_id,
            "content" => "noncanonical user selector must fail closed",
            "client_request_id" => "noncanonical-user-selector"
          },
          %{
            "actor_type" => "user",
            "user_id" => user_id,
            "participant_id" => original["participant_id"],
            "content" => "noncanonical participant selector must fail closed",
            "client_request_id" => "noncanonical-participant-selector"
          }
        ] do
      assert {:error, {:bad_request, _message}} =
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 attrs
               )
    end

    assert {:ok, [%{"participant_id" => ^canonical_id}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert {:ok, %{"state" => "inactive"}} =
             ConversationServer.deactivate_group_conversation_participant(
               group_id,
               conversation_id,
               original["participant_id"]
             )

    assert {:ok, canonical_owner} =
             SalixIM.ConversationFleet.ensure_participant_started(
               group_id,
               conversation_id,
               canonical_id
             )

    assert {:ok, %{"state" => "active"}} =
             SalixIM.ConversationParticipantActor.activate(
               canonical_owner,
               %{"notification_filter" => %{"messages" => "none", "statuses" => "none"}}
             )

    assert {:ok, _aggregate} =
             SalixStore.CasRecord.update(
               Keys.ctl_group_conversation(group_id, conversation_id),
               fn aggregate ->
                 update_in(
                   aggregate,
                   [@participant_identity_slots_field],
                   &Map.delete(&1, identity_key)
                 )
               end
             )

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:error, {:bad_request, _message}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => user_id,
                 "content" => "missing canonical reservation must fail closed",
                 "client_request_id" => "missing-canonical-reservation"
               }
             )

    assert {:ok, _aggregate} =
             SalixStore.CasRecord.update(
               Keys.ctl_group_conversation(group_id, conversation_id),
               fn aggregate ->
                 put_in(
                   aggregate,
                   [@participant_identity_slots_field, identity_key],
                   original["participant_id"]
                 )
               end
             )

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:error, {:bad_request, _message}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => user_id,
                 "content" => "conflicting reservation must fail closed",
                 "client_request_id" => "conflicting-canonical-reservation"
               }
             )

    assert {:ok, [%{"participant_id" => ^canonical_id}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )
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

  test "agent participant ensure and delivery_filter share the generic owner path", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Generic targeted conversation",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"participants" => [user]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert {:ok, %{"seq" => 1, "delivery_status" => "recorded"}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "participant_id" => user["participant_id"],
               "content" => "before agent membership",
               "client_request_id" => "before-agent-membership"
             })

    assert {:ok, worker_participant} =
             SalixIM.ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{
                 "agent_id" => worker_id,
                 "role_label" => "researcher",
                 "notification_filter" => %{"messages" => "all", "statuses" => "none"}
               }
             )

    assert worker_participant["delivery_cursor_seq"] == 1
    assert worker_participant["actor_type"] == "agent"

    assert {:ok, %{"participant_id" => worker_participant_id}} =
             SalixIM.ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{"agent_id" => worker_id, "role_label" => "anything"}
             )

    assert worker_participant_id == worker_participant["participant_id"]

    assert {:ok, router_participant} =
             SalixIM.ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{"agent_id" => router_id, "role_label" => "router"}
             )

    filter = %{"participant_ids" => [worker_participant_id]}

    assert {:ok, %{"delivery_status" => "queued", "message_id" => filtered_message_id}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "participant_id" => user["participant_id"],
               "content" => "worker only",
               "delivery_filter" => filter,
               "client_request_id" => "filtered-message"
             })

    assert eventually_value(fn ->
             admitted?(group_id, conversation_id, filtered_message_id, worker_id)
           end)

    refute admitted?(group_id, conversation_id, filtered_message_id, router_id)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert List.last(messages)["delivery_filter"] == filter

    assert {:error, {:conflict, _reason}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "participant_id" => user["participant_id"],
               "content" => "worker only",
               "delivery_filter" => %{
                 "participant_ids" => [router_participant["participant_id"]]
               },
               "client_request_id" => "filtered-message"
             })

    assert {:ok, %{"delivery_status" => "recorded"} = timeline_only} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "participant_id" => user["participant_id"],
               "content" => "timeline only",
               "delivery_filter" => %{"participant_ids" => []},
               "client_request_id" => "timeline-only"
             })

    refute Map.has_key?(timeline_only, "wakeup_participant_ids")

    assert {:error, {:bad_request, _reason}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "participant_id" => user["participant_id"],
               "content" => "not a member",
               "delivery_filter" => %{"participant_ids" => [Ids.new_participant_id()]}
             })

    assert {:error, {:bad_request, _reason}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "participant_id" => user["participant_id"],
               "content" => "oversized filter",
               "delivery_filter" => %{
                 "participant_ids" => List.duplicate(worker_participant_id, 101)
               }
             })

    assert {:ok, %{"delivery_status" => "queued", "message_id" => broadcast_message_id}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "participant_id" => user["participant_id"],
               "content" => "default broadcast",
               "client_request_id" => "default-broadcast"
             })

    assert eventually_value(fn ->
             admitted?(group_id, conversation_id, broadcast_message_id, worker_id) &&
               admitted?(group_id, conversation_id, broadcast_message_id, router_id)
           end)
  end

  test "ordinary Message mentions address explicit participants while participant policy can block",
       %{
         group_id: group_id,
         router_id: router_id,
         worker_id: worker_id
       } do
    now = System.system_time(:millisecond)

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

  test "owner rejects more than 100 distinct canonical delivery_filter participant IDs", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    participants =
      for index <- 0..101 do
        user_participant(now)
        |> Map.put("user_id", "delivery-filter-limit-user-#{index}")
        |> Map.put("notification_filter", %{"messages" => "none", "statuses" => "none"})
      end

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Delivery filter contract limit",
               "participants" => participants
             })

    participants_by_user_id =
      group_id
      |> all_test_participants(conversation_id)
      |> Map.new(&{&1["user_id"], &1})

    sender = participants_by_user_id["delivery-filter-limit-user-0"]

    target_participant_ids =
      for index <- 1..101 do
        participants_by_user_id["delivery-filter-limit-user-#{index}"]["participant_id"]
      end

    assert length(Enum.uniq(target_participant_ids)) == 101

    append_result =
      ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
        "participant_id" => sender["participant_id"],
        "content" => "must not be appended",
        "delivery_filter" => %{"participant_ids" => target_participant_ids},
        "client_request_id" => "delivery-filter-over-contract-limit"
      })

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert match?({{:error, {:bad_request, _reason}}, []}, {append_result, messages})
  end

  test "owner serialization assigns distinct sequences and one idempotent append", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

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
      Task.async(fn ->
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

    assert {:ok, %{"inserted" => true}} = Task.await(first, 5_000)
    assert {:ok, %{"inserted" => true}} = Task.await(second, 5_000)

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

    duplicate_results = [Task.await(duplicate_a, 5_000), Task.await(duplicate_b, 5_000)]

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
    now = System.system_time(:millisecond)

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
      Task.async(fn ->
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

    assert {:ok, small_result} = Task.await(small, 5_000)
    assert {:ok, large_result} = Task.await(large, 5_000)
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

  test "provider participant creation retries an owner-assigned id collision", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Provider participant collision",
               "participants" => [user_participant(now)]
             })

    Application.put_env(:salix_store, :s3_backend, ConversationWriteFaultOnceS3)
    Application.put_env(:salix_im, :inject_participant_collision, true)

    on_exit(fn ->
      Application.delete_env(:salix_im, :inject_participant_collision)
      Application.delete_env(:salix_im, :participant_collision_key)
    end)

    assert {:ok, %{"participant_id" => participant_id}} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               bft_participant()
             )

    assert Ids.valid_participant_id?(participant_id)
    collision_key = Application.fetch_env!(:salix_im, :participant_collision_key)
    collided_id = collision_key |> Path.basename() |> String.trim_trailing(".json")
    assert participant_id != collided_id

    assert {:ok, %{body: aggregate_body}} =
             SalixStore.S3.get(Keys.ctl_group_conversation(group_id, conversation_id))

    assert Jason.decode!(aggregate_body)[@participant_identity_slots_field][
             Jason.encode!(["provider", "bft", "bft"])
           ] ==
             participant_id

    assert [%{"participant_id" => ^participant_id}] =
             group_id
             |> all_test_participants(conversation_id)
             |> Enum.filter(&(&1["provider"] == "bft"))

    assert length(all_test_participants(group_id, conversation_id)) == 2
  end

  test "a reserved participant identity materializes with the same id after owner restart", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant reservation recovery"
             })

    Application.put_env(:salix_store, :s3_backend, ConversationWriteFaultOnceS3)
    Application.put_env(:salix_im, :fail_participant_state_once, true)
    attrs = %{"user_id" => "reservation-recovery-user"}

    assert {:error, {:http, 503}} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               attrs
             )

    participant_state_key = Application.fetch_env!(:salix_im, :failed_participant_state_key)
    assert {:error, :not_found} = SalixStore.S3.get(participant_state_key)

    assert {:ok, %{body: aggregate_body}} =
             SalixStore.S3.get(Keys.ctl_group_conversation(group_id, conversation_id))

    identity_key = Jason.encode!(["user", attrs["user_id"]])
    reserved_id = Jason.decode!(aggregate_body)[@participant_identity_slots_field][identity_key]
    assert Ids.valid_participant_id?(reserved_id)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert {:ok, %{"participant_id" => ^reserved_id}} =
             ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, participants} =
             SalixIM.ConversationParticipantProjection.list_bounded(group_id, conversation_id)

    assert [%{"participant_id" => ^reserved_id, "state" => "active"}] = participants
  end

  test "generic append cannot forge recipient identity through a real Slack participant", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    Application.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)
    Application.put_env(:salix_im, :capture_agent_delivery_test_pid, self())
    on_exit(fn -> Application.delete_env(:salix_im, :capture_agent_delivery_test_pid) end)

    now = System.system_time(:millisecond)

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
        assert_receive {:captured_agent_delivery, agent_id, payload, _opts}, 2_000
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

    first_ensure = Task.async(fn -> reconcile.(first_desired) end)
    second_ensure = Task.async(fn -> reconcile.(second_desired) end)

    assert {:ok, _first_result} = Task.await(first_ensure, 2_000)
    assert {:ok, _second_result} = Task.await(second_ensure, 2_000)

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

  test "conversation Router reconciliation fails closed when Group authority is missing", %{
    group_id: group_id,
    router_id: router_id
  } do
    assert {:ok, initial} = SalixIM.RouterConversationInput.ensure(group_id)
    conversation_id = initial["conversation_id"]

    assert {:ok, _group} =
             SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
               Map.put(group, "router_agent_id", nil)
             end)

    assert {:error, :router_not_configured} =
             SalixIM.ConversationInput.reconcile_group_conversation_router_participant(
               group_id,
               conversation_id
             )

    router_participants =
      group_id
      |> all_test_participants(conversation_id)
      |> Enum.filter(&(&1["actor_type"] == "agent"))

    assert [preserved] = router_participants
    assert preserved["agent_id"] == router_id
    assert preserved["state"] == "active"
  end

  test "conversation Router reconciliation fails closed when current Router is archived", %{
    group_id: group_id,
    router_id: router_id
  } do
    assert {:ok, initial} = RouterConversationInput.ensure(group_id)
    conversation_id = initial["conversation_id"]

    assert {:ok, spec} = RouterConversationInput.desired_spec(group_id)
    desired = Enum.find(spec["participants"], &(&1["agent_id"] == router_id))

    assert {:ok, prepared_router} =
             SalixIM.ConversationInput.prepare_agent(group_id, conversation_id, desired)

    assert {:ok, archived_router} = SalixAgent.Control.delete(router_id)
    assert is_integer(archived_router["archived_at"])
    assert {:error, :not_found} = SalixIM.GroupDirectory.get_agent(router_id)

    assert {:error, :not_found} =
             SalixIM.ConversationInput.reconcile_group_conversation_router_participant(
               group_id,
               conversation_id
             )

    assert {:error, :stale_group_router_authority} =
             ConversationServer.reconcile_group_conversation_agent_participants(
               group_id,
               conversation_id,
               %{
                 "desired" => prepared_router,
                 "selector" => %{
                   "actor_type" => "agent",
                   "role_label" => ["agent", "router"]
                 },
                 "authority_guard" => %{
                   "type" => "group_router",
                   "router_agent_id" => router_id
                 }
               }
             )

    router_participants =
      group_id
      |> all_test_participants(conversation_id)
      |> Enum.filter(&(&1["actor_type"] == "agent"))

    assert [preserved] = router_participants
    assert preserved["agent_id"] == router_id
    assert preserved["state"] == "active"
  end

  test "participant recovery fails closed when a later page cannot be read", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    participants =
      for index <- 1..101 do
        user_participant(now)
        |> Map.put("user_id", "recovery-user-#{index}")
        |> Map.put("notification_filter", %{"messages" => "none", "statuses" => "none"})
      end

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Fail closed recovery",
               "participants" => participants
             })

    assert {:ok, bft_participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               bft_participant()
             )

    participant_id = bft_participant["participant_id"]
    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    Application.put_env(:salix_store, :s3_backend, ParticipantSecondPageFailureS3)

    assert {:error, {:participant_state_unavailable, {:http, 503}}} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               bft_participant()
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, %{"has_more" => true, "next_cursor" => cursor}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert {:error, {:http, 503}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id,
               cursor: cursor
             )

    assert {:ok, failed_owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(failed_owner, :normal)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    assert [%{"participant_id" => ^participant_id}] =
             group_id
             |> all_test_participants(conversation_id)
             |> Enum.filter(&(&1["provider"] == "bft"))
  end

  test "participant command preserves a participant-state read outage after owner recovery", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant state outage",
               "participants" => [
                 slack_thread_participant("sl-outage", "T-outage", "C-outage", "336.000")
               ]
             })

    assert {:ok, %{"participants" => [provider_participant]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant_id = provider_participant["participant_id"]

    participant_state_key =
      Keys.ctl_group_conversation_participant_state(
        group_id,
        conversation_id,
        participant_id
      )

    assert :ok = SalixIM.ConversationFleet.stop_participants(group_id, conversation_id)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :get, participant_state_key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    assert {:error, {:participant_state_unavailable, {:http, 503}}} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "participant-read-outage",
                 "content" => [%{"type" => "text", "text" => "do not treat outage as missing"}]
               }
             )
  end

  test "group conversation creates a snowflake conversation id when omitted", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Generated ID",
               "participants" => [user_participant(now)]
             })

    assert Ids.valid_conversation_id?(conversation["conversation_id"])
    refute Map.has_key?(conversation, "created_by_agent_id")

    assert {:ok, %{"participants" => [participant]}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation["conversation_id"]
             )

    assert Ids.valid_participant_id?(participant["participant_id"])
    assert participant["actor_type"] == "user"

    assert {:ok, %{"delivery_status" => "recorded"}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               %{"content" => "record without an implicit runtime target"}
             )
  end

  test "conversation owner completes create when the storage acknowledgement is lost", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, :any})
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, :any})

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Recovered create",
               "participants" => [user_participant(now)],
               "created_at" => now,
               "updated_at" => now
             })

    conversation_id = conversation["conversation_id"]
    assert Ids.valid_conversation_id?(conversation_id)

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.any?(listed, &(&1["conversation_id"] == conversation_id))

    assert {:ok, %{"participants" => [participant]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert Ids.valid_participant_id?(participant["participant_id"])
    assert participant["actor_type"] == "user"
  end

  test "conversation owner completes one idempotent append across ambiguous segment and meta writes",
       %{
         group_id: group_id
       } do
    now = System.system_time(:millisecond)

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

  test "append retry preserves the landed sequence when the sequence index write fails", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Recover failed sequence index",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    sequence_key =
      Keys.ctl_group_conversation_message_seq_index(group_id, conversation_id, 1)

    attrs = %{
      "content" => "keep the landed sequence",
      "client_request_id" => "sequence-index-fail-before-write"
    }

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, sequence_key})

    assert {:error, {:http, 503}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, %{"inserted" => false, "seq" => 1, "message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, [%{"message_id" => ^message_id, "seq" => 1}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )
  end

  test "message list fails closed when a segment continuation index is missing", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Missing segment continuation",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "content" => String.duplicate("a", 850_000),
                 "client_request_id" => "missing-segment-index-first"
               }
             )

    assert {:ok, %{"seq" => 2}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "content" => String.duplicate("b", 200_000),
                 "client_request_id" => "missing-segment-index-second"
               }
             )

    first_segment_index_key =
      Keys.ctl_group_conversation_message_segment_index(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    assert :ok = SalixStore.S3.delete(first_segment_index_key)

    assert {:error, :message_segment_index_missing} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )
  end

  test "append reuses its bounded segment read and derives the segment index from the landed write",
       %{
         group_id: group_id
       } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Segment index without read-back",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    :ok = SalixStore.S3.Fake.reset_read_log()

    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "first", "client_request_id" => "no-read-back-first"}
             )

    # One prefetched read supplies append planning, dedupe, and the CAS base.
    # The committed Message and segment index reuse that bounded snapshot.
    assert Enum.count(SalixStore.S3.Fake.read_log(), &(&1 == {:get, segment_key})) <= 2

    segment_index_key =
      Keys.ctl_group_conversation_message_segment_index(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    assert {:ok, %{body: index_body}} = SalixStore.S3.get(segment_index_key)

    assert %{
             "segment_id" => "000000000000000001",
             "start_seq" => 1,
             "end_seq" => 1,
             "message_count" => 1,
             "status" => "open"
           } = Jason.decode!(index_body)

    assert {:ok, [%{"seq" => 1}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )
  end

  test "append rejects a segment row that is not a complete canonical message record", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Malformed canonical message row",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    malformed_body =
      Jason.encode!(%{"message_id" => Ids.new_message_id(), "seq" => 1}) <> "\n"

    segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    assert {:ok, _etag} =
             SalixStore.S3.put(segment_key, malformed_body, if_none_match: "*")

    assert {:error, :invalid_message_segment} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{"content" => "real", "client_request_id" => "malformed-row-real"}
             )

    assert {:ok, %{body: ^malformed_body}} = SalixStore.S3.get(segment_key)

    assert {:ok, []} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )
  end

  test "an append retry resumes a durable request reservation after the segment write fails", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Resume reserved sequence",
               "participants" => [user_participant(now)]
             })

    segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    request_key =
      Keys.ctl_group_conversation_message_idempotency(
        group_id,
        conversation_id,
        SalixStore.Crypto.hex("client_request:resume-sequence-reservation")
      )

    attrs = %{
      "content" => "resume me",
      "client_request_id" => "resume-sequence-reservation"
    }

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, segment_key})

    assert {:error, {:http, 503}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, %{body: reservation_body}} = SalixStore.S3.get(request_key)

    assert %{"status" => "reserved", "message_id" => message_id} =
             Jason.decode!(reservation_body)

    assert Ids.valid_message_id?(message_id)

    assert {:ok, %{"inserted" => true, "message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, [%{"message_id" => ^message_id, "seq" => 1}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )
  end

  test "an append retry restores the segment chain after a rollover index write fails", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Resume rollover segment chain",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "content" => String.duplicate("s", 850_000),
                 "client_request_id" => "rollover-seed"
               }
             )

    first_segment_id = "000000000000000001"
    second_segment_id = "000000000000000002"

    second_segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        second_segment_id
      )

    second_segment_index_key =
      Keys.ctl_group_conversation_message_segment_index(
        group_id,
        conversation_id,
        second_segment_id
      )

    first_segment_index_key =
      Keys.ctl_group_conversation_message_segment_index(
        group_id,
        conversation_id,
        first_segment_id
      )

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, second_segment_index_key})

    attrs = %{
      "content" => String.duplicate("r", 200_000),
      "client_request_id" => "rollover-recovery"
    }

    assert {:error, {:http, 503}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    # The message fact landed in the new segment before its index write failed.
    assert {:ok, %{body: second_segment_body}} = SalixStore.S3.get(second_segment_key)

    assert [%{"seq" => 2}] =
             second_segment_body
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)

    # A retry must recreate a missing new-segment index from the reservation.
    # Stop immediately after that repair so we can also model an orphan index
    # left by an older retry implementation.
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, first_segment_index_key})

    assert {:error, {:http, 503}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, %{body: repaired_index_body}} = SalixStore.S3.get(second_segment_index_key)

    assert %{"previous_segment_id" => ^first_segment_id} =
             repaired_index = Jason.decode!(repaired_index_body)

    orphan_index = Map.delete(repaired_index, "previous_segment_id")
    assert {:ok, _} = SalixStore.S3.put(second_segment_index_key, Jason.encode!(orphan_index))

    assert {:ok, %{"inserted" => false, "message_id" => recovered_message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               attrs
             )

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 20
             )

    assert Enum.map(messages, & &1["seq"]) == [1, 2]
    assert List.last(messages)["message_id"] == recovered_message_id

    assert {:ok, %{body: first_index_body}} = SalixStore.S3.get(first_segment_index_key)
    assert {:ok, %{body: second_index_body}} = SalixStore.S3.get(second_segment_index_key)

    assert %{"next_segment_id" => ^second_segment_id} = Jason.decode!(first_index_body)
    assert %{"previous_segment_id" => ^first_segment_id} = Jason.decode!(second_index_body)
  end

  test "conversation list hydrates entries concurrently within the configured bound", %{
    group_id: group_id
  } do
    created =
      for index <- 1..8 do
        assert {:ok, conversation} =
                 SalixIM.ConversationInput.create_group_conversation(group_id, %{
                   "title" => "Conversation #{index}",
                   "updated_at" => index
                 })

        {index, conversation["conversation_id"]}
      end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_concurrency = Application.get_env(:salix_im, :conversation_list_read_concurrency)
    start_supervised!(ReadProbe)
    Application.put_env(:salix_store, :s3_backend, InstrumentedS3)
    Application.put_env(:salix_im, :conversation_list_read_concurrency, 3)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous_backend)
      restore(:salix_im, :conversation_list_read_concurrency, previous_concurrency)
    end)

    ReadProbe.reset(nil, Keys.ctl_group_conversations_prefix(group_id))

    assert {:ok, %{"data" => conversations}} =
             Conversations.list_group_conversations(group_id, limit: 9)

    created_ids = created |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    listed_ids =
      conversations
      |> Enum.map(& &1["conversation_id"])
      |> Enum.filter(&MapSet.member?(created_ids, &1))

    assert listed_ids == created |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))

    snapshot = ReadProbe.snapshot()
    assert snapshot.max_active == 3

    assert Enum.all?(created, fn {_index, conversation_id} ->
             snapshot.gets[Keys.ctl_group_conversation(group_id, conversation_id)] == 1
           end)

    handler_id = "conversation-list-cap-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix_im, :conversations, :list_hydration],
        &ReadProbe.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    Application.put_env(:salix_im, :conversation_list_read_concurrency, 1_000)

    assert {:ok, _page} = Conversations.list_group_conversations(group_id, limit: 1_000)

    assert_receive {[:salix_im, :conversations, :list_hydration], %{concurrency: 64}}
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

  test "conversation list stops canonical hydration once the requested window is full", %{
    group_id: group_id
  } do
    for index <- 1..40 do
      assert {:ok, _conversation} =
               SalixIM.ConversationInput.create_group_conversation(group_id, %{
                 "title" => "Conversation #{index}",
                 "updated_at" => index
               })
    end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    start_supervised!(ReadProbe)
    Application.put_env(:salix_store, :s3_backend, InstrumentedS3)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous_backend)
    end)

    ReadProbe.reset(nil, Keys.ctl_group_conversations_prefix(group_id))

    assert {:ok, %{"data" => conversations, "has_more" => true}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert length(conversations) == 20

    assert ReadProbe.snapshot().gets
           |> Map.values()
           |> Enum.sum() == 21
  end

  test "conversation list does not hydrate lower-ranked records after filling a small window", %{
    group_id: group_id
  } do
    records = [
      {"cnv1_0000000000000000001", 30},
      {"cnv1_0000000000000000002", 20},
      {"cnv1_0000000000000000003", 10}
    ]

    for {conversation_id, updated_at} <- records do
      conversation = %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "title" => "Conversation #{updated_at}",
        "status" => "active",
        "message_count" => 0,
        "created_at" => updated_at,
        "updated_at" => updated_at
      }

      assert {:ok, _etag} =
               SalixStore.S3.put(
                 Keys.ctl_group_conversation(group_id, conversation_id),
                 Jason.encode!(conversation)
               )

      assert {:ok, _etag} =
               SalixStore.S3.put(
                 conversation_list_index_key(group_id, conversation),
                 Jason.encode!(
                   Map.take(conversation, ~w(agent_group_id conversation_id updated_at))
                 )
               )
    end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, ConversationHydrationErrorS3)
    on_exit(fn -> restore(:salix_store, :s3_backend, previous_backend) end)

    assert {:ok,
            %{
              "data" => [%{"conversation_id" => "cnv1_0000000000000000001"}],
              "has_more" => true,
              "next_cursor" => next_cursor
            }} = Conversations.list_group_conversations(group_id, limit: 1)

    assert is_binary(next_cursor)
  end

  test "conversation list performs one bounded durable read per projected record", %{
    group_id: group_id
  } do
    start_supervised!(ReadProbe)

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Slow hydration"
             })

    ReadProbe.reset(nil, Keys.ctl_group_conversation(group_id, conversation["conversation_id"]))

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, InstrumentedS3)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous_backend)
    end)

    assert {:ok, %{"data" => [%{"conversation_id" => conversation_id}]}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert conversation_id == conversation["conversation_id"]

    assert ReadProbe.snapshot().gets == %{
             Keys.ctl_group_conversation(group_id, conversation_id) => 1
           }
  end

  test "conversation list returns an error when parallel hydration times out", %{
    group_id: group_id
  } do
    start_supervised!(ReadProbe)

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Slow hydration"
             })

    ReadProbe.reset(nil, Keys.ctl_group_conversation(group_id, conversation["conversation_id"]))

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_timeout = Application.get_env(:salix_im, :conversation_list_read_timeout)
    Application.put_env(:salix_store, :s3_backend, InstrumentedS3)
    Application.put_env(:salix_im, :conversation_list_read_timeout, 10)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous_backend)
      restore(:salix_im, :conversation_list_read_timeout, previous_timeout)
    end)

    assert {:error, {:conversation_list_hydration_failed, :timeout}} =
             Conversations.list_group_conversations(group_id, limit: 20)
  end

  test "conversation list skips missing stale entries but returns hydration backend errors", %{
    group_id: group_id
  } do
    valid_id = "cnv1_0000000000000000001"
    stale_id = "cnv1_0000000000000000002"
    backend_error_id = "cnv1_0000000000000000003"

    valid_conversation = %{
      "agent_group_id" => group_id,
      "conversation_id" => valid_id,
      "title" => "Valid hydration",
      "status" => "active",
      "message_count" => 0,
      "created_at" => 2,
      "updated_at" => 2
    }

    assert {:ok, _etag} =
             SalixStore.S3.put(
               Keys.ctl_group_conversation(group_id, valid_conversation["conversation_id"]),
               Jason.encode!(valid_conversation)
             )

    for {conversation_id, updated_at} <- [
          {valid_id, 2},
          {stale_id, 1}
        ] do
      index = %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "updated_at" => updated_at
      }

      assert {:ok, _etag} =
               SalixStore.S3.put(
                 conversation_list_index_key(group_id, index),
                 Jason.encode!(index)
               )
    end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, ConversationHydrationErrorS3)
    on_exit(fn -> restore(:salix_store, :s3_backend, previous_backend) end)

    assert {:ok, %{"data" => listed}} =
             Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.any?(listed, &(&1["conversation_id"] == valid_id))
    refute Enum.any?(listed, &(&1["conversation_id"] == stale_id))

    backend_error_index = %{
      "agent_group_id" => group_id,
      "conversation_id" => backend_error_id,
      "updated_at" => 3
    }

    assert {:ok, _etag} =
             SalixStore.S3.put(
               conversation_list_index_key(group_id, backend_error_index),
               Jason.encode!(backend_error_index)
             )

    assert {:error, _reason} = Conversations.list_group_conversations(group_id, limit: 20)
  end

  test "conversation list continues across S3 pages after dropping stale entries", %{
    group_id: group_id
  } do
    valid_ids =
      for index <- 1..105, reduce: [] do
        acc ->
          conversation_id = Ids.new_conversation_id()
          updated_at = 1_000 - index

          conversation = %{
            "agent_group_id" => group_id,
            "conversation_id" => conversation_id,
            "title" => "Page #{index}",
            "status" => "active",
            "message_count" => 0,
            "created_at" => updated_at,
            "updated_at" => updated_at
          }

          index_key = conversation_list_index_key(group_id, conversation)

          assert {:ok, _etag} =
                   SalixStore.S3.put(
                     index_key,
                     Jason.encode!(%{
                       "agent_group_id" => group_id,
                       "conversation_id" => conversation_id,
                       "updated_at" => updated_at
                     })
                   )

          if index <= 5 or index > 100 do
            assert {:ok, _etag} =
                     SalixStore.S3.put(
                       Keys.ctl_group_conversation(group_id, conversation_id),
                       Jason.encode!(conversation)
                     )

            [conversation_id | acc]
          else
            acc
          end
      end
      |> Enum.reverse()

    assert {:ok,
            %{
              "data" => first_page,
              "has_more" => true,
              "next_cursor" => next_cursor
            }} = Conversations.list_group_conversations(group_id, limit: 8)

    assert length(first_page) == 8

    assert {:ok, %{"data" => second_page, "has_more" => false}} =
             Conversations.list_group_conversations(group_id, limit: 8, cursor: next_cursor)

    first_ids = MapSet.new(Enum.map(first_page, & &1["conversation_id"]))
    second_ids = MapSet.new(Enum.map(second_page, & &1["conversation_id"]))

    assert MapSet.disjoint?(first_ids, second_ids)

    assert MapSet.subset?(
             MapSet.new(valid_ids),
             MapSet.union(first_ids, second_ids)
           )
  end

  test "conversation list bounds stale index hydration and returns an explicit scan error", %{
    group_id: group_id
  } do
    for index <- 1..401 do
      conversation_id = Ids.new_conversation_id()

      stale_index = %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "updated_at" => index
      }

      assert {:ok, _etag} =
               SalixStore.S3.put(
                 conversation_list_index_key(group_id, stale_index),
                 Jason.encode!(stale_index)
               )
    end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    start_supervised!(ConversationListScanProbe)
    ConversationListScanProbe.reset()
    Application.put_env(:salix_store, :s3_backend, CountingConversationListS3)
    on_exit(fn -> restore(:salix_store, :s3_backend, previous_backend) end)

    assert {:error, :conversation_list_scan_limit_exceeded} =
             Conversations.list_group_conversations(group_id, limit: 1)

    # limit=1 uses 100-key raw pages. The request stops after two pages
    # instead of traversing every stale index in the tenant prefix.
    assert %{lists: 2, gets: 401} = ConversationListScanProbe.snapshot()
  end

  test "message and snapshot reads load canonical conversation metadata once", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Read count",
               "participants" => [user_participant(now)]
             })

    assert {:ok, append_result} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "content" => "hello",
               "client_request_id" => "msg-read-count"
             })

    message_id = append_result["message_id"]

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    start_supervised!(ReadProbe)
    Application.put_env(:salix_store, :s3_backend, InstrumentedS3)
    on_exit(fn -> restore(:salix_store, :s3_backend, previous_backend) end)

    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)

    participant_prefix =
      Keys.ctl_group_conversation_participants_prefix(group_id, conversation_id)

    ReadProbe.reset(self())

    assert {:ok, [%{"message_id" => ^message_id}]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    message_reads = ReadProbe.snapshot().gets
    assert message_reads[meta_key] == 1

    refute Enum.any?(message_reads, fn {key, _count} ->
             String.starts_with?(key, participant_prefix)
           end)

    ReadProbe.reset(self())

    assert {:ok,
            %{
              "conversation" => %{"conversation_id" => ^conversation_id},
              "messages" => [%{"message_id" => ^message_id}]
            }} =
             Conversations.get_group_conversation_with_messages(group_id, conversation_id,
               limit: 10
             )

    snapshot_reads = ReadProbe.snapshot().gets
    assert snapshot_reads[meta_key] == 1

    refute Enum.any?(snapshot_reads, fn {key, _count} ->
             String.starts_with?(key, participant_prefix)
           end)
  end

  test "conversation and participant reads stay within their resource boundaries", %{
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    participants =
      for id <- ["user-a", "user-b"], do: user_participant(now) |> Map.put("user_id", id)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant read budget",
               "participants" => participants
             })

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    start_supervised!(ConversationListScanProbe)
    Application.put_env(:salix_store, :s3_backend, CountingConversationListS3)
    on_exit(fn -> restore(:salix_store, :s3_backend, previous_backend) end)

    ConversationListScanProbe.reset()

    assert {:ok, conversation} =
             Conversations.get_group_conversation(group_id, conversation_id)

    refute Map.has_key?(conversation, "participants")
    assert %{gets: 2, lists: 0} = ConversationListScanProbe.snapshot()

    ConversationListScanProbe.reset()

    assert {:ok, %{"participants" => listed}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert Enum.all?(listed, &Ids.valid_participant_id?(&1["participant_id"]))
    assert Enum.map(listed, & &1["user_id"]) |> Enum.sort() == ["user-a", "user-b"]
    assert %{gets: 3, lists: 1} = ConversationListScanProbe.snapshot()

    ConversationListScanProbe.reset()

    user_b_participant = Enum.find(listed, &(&1["user_id"] == "user-b"))

    assert {:ok, %{"participant_id" => participant_id}} =
             Conversations.get_group_conversation_participant(
               group_id,
               conversation_id,
               user_b_participant["participant_id"]
             )

    assert participant_id == user_b_participant["participant_id"]

    assert %{gets: 2, lists: 0} = ConversationListScanProbe.snapshot()
  end

  test "participant status snapshot does not list participants again", %{group_id: group_id} do
    conversation_id = Ids.new_conversation_id()
    participant_id = Ids.new_participant_id()
    participants = [%{"participant_id" => participant_id, "actor_type" => "user"}]

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    start_supervised!(ConversationListScanProbe)
    Application.put_env(:salix_store, :s3_backend, CountingConversationListS3)

    on_exit(fn -> restore(:salix_store, :s3_backend, previous_backend) end)

    ConversationListScanProbe.reset()

    assert {:ok, statuses} =
             Conversations.group_conversation_participant_statuses(
               group_id,
               conversation_id,
               participants
             )

    refute Map.has_key?(statuses, participant_id)
    assert %{gets: 0, lists: 0} = ConversationListScanProbe.snapshot()
  end

  test "participant pages scan only the bounded flat state projection", %{group_id: group_id} do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Bounded participant state page",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant_dir =
      Keys.ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id)

    for index <- 1..250 do
      key = participant_dir <> "deliveries/history-#{String.pad_leading("#{index}", 4, "0")}.json"
      assert {:ok, _} = SalixStore.S3.put(key, "{}")
    end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    start_supervised!(ParticipantStateScanProbe)
    ParticipantStateScanProbe.reset()
    Application.put_env(:salix_store, :s3_backend, CountingParticipantStateS3)
    on_exit(fn -> restore(:salix_store, :s3_backend, previous_backend) end)

    assert {:ok, %{"participants" => [%{"participant_id" => ^participant_id}]}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation_id,
               limit: 1
             )

    assert %{lists: 1, max_requested: 2, max_returned: 1} =
             ParticipantStateScanProbe.snapshot()
  end

  test "conversation cleanup tolerates participant state disappearing between list and get", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Participant cleanup list race",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert {:ok, _pin} =
             ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)

    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)

    participant_states_prefix =
      Keys.ctl_group_conversation_participant_states_prefix(group_id, conversation_id)

    participant_state_key =
      Keys.ctl_group_conversation_participant_state(
        group_id,
        conversation_id,
        participant_id
      )

    Application.put_env(:salix_store, :s3_backend, ConversationDeleteRaceS3)
    Application.put_env(:salix_im, :conversation_delete_race_test_pid, self())

    Application.put_env(
      :salix_im,
      :delete_race_participant_states_prefix,
      participant_states_prefix
    )

    Application.put_env(:salix_im, :drop_participant_state_after_list_once, true)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    owner_ref = Process.monitor(owner)

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert_receive {:participant_state_deleted_after_list, deleted_key}, 1_000
    assert deleted_key == participant_state_key
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 2_000

    assert {:error, :not_found} = SalixStore.S3.get(meta_key)
    assert {:ok, %{"data" => []}} = Conversations.list_conversation_pins(group_id, tenant_id)
  end

  test "conversation cleanup retries a later stage not_found instead of completing early", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Retry cleanup stage not found",
               "participants" => []
             })

    assert {:ok, _pin} =
             ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)

    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)

    participant_objects_prefix =
      Keys.ctl_group_conversation_participants_prefix(group_id, conversation_id)

    Application.put_env(:salix_store, :s3_backend, ConversationDeleteRaceS3)
    Application.put_env(:salix_im, :conversation_delete_race_test_pid, self())
    Application.put_env(:salix_im, :delete_cleanup_stage_prefix, participant_objects_prefix)
    Application.put_env(:salix_im, :fail_delete_cleanup_stage_not_found_once, true)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    owner_ref = Process.monitor(owner)

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert_receive :conversation_cleanup_stage_not_found, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 2_000

    assert {:error, :not_found} = SalixStore.S3.get(meta_key)
    assert {:ok, %{"data" => []}} = Conversations.list_conversation_pins(group_id, tenant_id)
  end

  test "deleting a conversation retires its participants and pin after admission", %{
    tenant_id: tenant_id,
    group_id: group_id,
    worker_id: worker_id
  } do
    now = System.system_time(:millisecond)

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

  test "explicit tombstone removes a formerly projected Task after a kind-flip relay loss", %{
    group_id: group_id
  } do
    reset_search_projection!()

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Private stale task",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert eventually_value(fn ->
             if SalixIM.ConversationSearchEnqueuer.pending_count() == 0 and
                  search_job_count(group_id, conversation_id) == 1,
                do: true
           end)

    assert {:ok, task_claim} = ConversationSearch.claim_one("task-projector", 30_000)
    assert task_claim.conversation_id == conversation_id
    assert :ok = ConversationSearchProjection.process_claim(task_claim)
    assert :ok = ConversationSearch.complete(task_claim)

    assert {:ok, [%{"conversation_id" => ^conversation_id}]} =
             Conversations.search_group_tasks(group_id, "Private")

    assert {:ok, %{"kind" => "user_chat"}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "kind" => "user_chat"
             })

    assert eventually_value(fn ->
             if SalixIM.ConversationSearchEnqueuer.pending_count() == 0, do: true
           end)

    # Simulate loss of the best-effort kind-flip relay. The explicit tombstone
    # remains the authority that must durably admit a projection delete.
    Repo.query!(
      "DELETE FROM conversation_search_jobs " <>
        "WHERE agent_group_id = $1 AND conversation_id = $2",
      [group_id, conversation_id]
    )

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert eventually_value(fn ->
             case search_job(group_id, conversation_id) do
               %{"operation" => "delete"} -> true
               _other -> nil
             end
           end)

    assert {:ok, delete_claim} = ConversationSearch.claim_one("delete-projector", 30_000)
    assert delete_claim.operation == :delete
    assert delete_claim.conversation_id == conversation_id
    assert :ok = ConversationSearchProjection.process_claim(delete_claim)
    assert :ok = ConversationSearch.complete(delete_claim)

    assert {:ok, []} = Conversations.search_group_tasks(group_id, "Private")

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM conversation_search_states " <>
                 "WHERE writer_generation = 'test-search-generation' " <>
                 "AND agent_group_id = $1 AND conversation_id = $2",
               [group_id, conversation_id]
             )

    assert {:ok, %{"conversation_id" => chat_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Never projected chat",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    assert :ok = ConversationServer.delete_group_conversation(group_id, chat_id)

    assert eventually_value(fn ->
             case search_job(group_id, chat_id) do
               %{"operation" => "delete"} -> true
               _other -> nil
             end
           end)

    assert {:ok, chat_delete_claim} =
             ConversationSearch.claim_one("chat-delete-projector", 30_000)

    assert chat_delete_claim.operation == :delete
    assert chat_delete_claim.conversation_id == chat_id
    assert :ok = ConversationSearchProjection.process_claim(chat_delete_claim)
    assert :ok = ConversationSearch.complete(chat_delete_claim)
    assert search_job_count(group_id, chat_id) == 0
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
               "participants" => [user_participant(System.system_time(:millisecond))]
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

  test "one-Group repair queues one bounded page and exposes its resume cursor", %{
    group_id: group_id
  } do
    reset_search_projection!()

    conversation_ids =
      Enum.map(1..3, fn index ->
        assert {:ok, %{"conversation_id" => conversation_id}} =
                 SalixIM.ConversationInput.create_group_conversation(group_id, %{
                   "kind" => "agent_task",
                   "title" => "Paged repair #{index}",
                   "participants" => [
                     user_participant(System.system_time(:millisecond) + index)
                   ]
                 })

        conversation_id
      end)

    assert eventually_value(fn ->
             if SalixIM.ConversationSearchEnqueuer.pending_count() == 0 and
                  Enum.all?(conversation_ids, &(search_job_count(group_id, &1) == 1)),
                do: true
           end)

    reset_search_projection!()

    first_output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Salix.ConversationSearch.Rebuild.run([
          "--group",
          group_id,
          "--limit",
          "2"
        ])
      end)

    assert first_output =~ "queued 2 Conversation search rebuild jobs"
    assert first_output =~ "has_more=true"
    assert [_, cursor] = Regex.run(~r/next_cursor=([^\s]+)/, first_output)
    refute cursor == "none"
    assert group_search_job_count(group_id) == 2

    second_output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Salix.ConversationSearch.Rebuild.run([
          "--group",
          group_id,
          "--limit",
          "2",
          "--cursor",
          cursor
        ])
      end)

    assert second_output =~ "queued 1 Conversation search rebuild jobs"
    assert second_output =~ "has_more=false"
    assert second_output =~ "next_cursor=none"
    assert group_search_job_count(group_id) == 3
  end

  test "configured search holds tombstones with bounded retry while disabled search does not", %{
    group_id: group_id
  } do
    reset_search_projection!()

    assert {:ok, %{"conversation_id" => configured_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Configured delete admission",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    configured_meta = Keys.ctl_group_conversation(group_id, configured_id)
    assert {:ok, configured_owner} = ConversationPlacement.ensure_started(group_id, configured_id)

    # Removing the active rollout cursor makes durable admission fail without
    # making canonical S3 unavailable.
    Repo.query!("DELETE FROM conversation_search_discovery_cursors WHERE id = 'main'")
    assert :ok = ConversationServer.delete_group_conversation(group_id, configured_id)

    assert 1 ==
             eventually_value(
               fn ->
                 if Process.alive?(configured_owner) do
                   state = :sys.get_state(configured_owner)
                   if state.deleted? and state.search_delete_retry_attempt == 1, do: 1
                 end
               end,
               150
             )

    Process.sleep(250)
    assert Process.alive?(configured_owner)
    assert :sys.get_state(configured_owner).search_delete_retry_attempt == 1

    assert {:ok, %{body: tombstone_body}} = SalixStore.S3.get(configured_meta)
    assert not is_nil(Jason.decode!(tombstone_body)["deleted_at"])

    Repo.query!("""
    INSERT INTO conversation_search_discovery_cursors
      (id, writer_generation, completed_cycles, cycle_started_at,
       last_cycle_completed_at, inserted_at, updated_at)
    VALUES ('main', 'test-search-generation', 1, now(), now(), now(), now())
    """)

    assert eventually_value(
             fn ->
               if search_job_count(group_id, configured_id) == 1 and
                    SalixStore.S3.get(configured_meta) == {:error, :not_found},
                  do: true
             end,
             200
           )

    previous_generation =
      Application.get_env(:salix_store, :conversation_search_writer_generation)

    Application.delete_env(:salix_store, :conversation_search_writer_generation)

    on_exit(fn ->
      Application.put_env(
        :salix_store,
        :conversation_search_writer_generation,
        previous_generation
      )
    end)

    assert {:ok, %{"conversation_id" => disabled_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Disabled projection delete",
               "participants" => [user_participant(System.system_time(:millisecond))]
             })

    disabled_meta = Keys.ctl_group_conversation(group_id, disabled_id)
    assert :ok = ConversationServer.delete_group_conversation(group_id, disabled_id)

    assert eventually_value(fn ->
             if SalixStore.S3.get(disabled_meta) == {:error, :not_found}, do: true
           end)
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

  test "Task search reads only the latest 64 slots and enforces text budgets", %{
    group_id: group_id
  } do
    conversation_id = Ids.new_conversation_id()

    rows =
      Enum.map(1..65, fn
        1 -> task_search_row(1, "old sentinel outside the recent window")
        2 -> task_search_row(2, nil)
        65 -> task_search_row(65, String.duplicate("z", 40_000))
        seq -> task_search_row(seq, String.duplicate(Integer.to_string(rem(seq, 10)), 8_000))
      end)

    segment_id = task_search_segment_id(1)
    put_task_search_segment(group_id, conversation_id, segment_id, rows, nil)
    put_task_search_pointer(group_id, conversation_id, Enum.at(rows, 1), segment_id)
    :ok = S3.Fake.reset_read_log()

    assert {:ok, window} =
             Conversations.task_search_content_window(
               task_search_conversation(group_id, conversation_id, 65)
             )

    assert window.segment_count == 1
    assert window.source_bytes <= 1_000_000
    assert window.indexed_bytes <= 262_144

    assert Enum.any?(
             window.messages,
             &(&1.seq == 65 and String.ends_with?(&1.envelope.content, "…"))
           )

    refute Enum.any?(window.messages, &(&1.seq in [1, 2]))

    refute Enum.any?(
             window.messages,
             &String.contains?(&1.envelope.content, "old sentinel")
           )

    assert Enum.all?(window.messages, fn message ->
             SearchDocumentEnvelope.valid?(message.envelope, :message) and
               Enum.sort(Map.keys(message)) == [:created_at, :envelope, :id, :seq]
           end)

    assert window.indexed_bytes ==
             Enum.sum(
               Enum.map(window.messages, fn message ->
                 message.envelope.weight_bytes
               end)
             )

    segment_key =
      Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    segment_index_key =
      Keys.ctl_group_conversation_message_segment_index(group_id, conversation_id, segment_id)

    reads = S3.Fake.read_log()
    assert Enum.count(reads, &(&1 == {:get, segment_key})) == 1
    assert Enum.count(reads, &(&1 == {:get, segment_index_key})) == 1
  end

  test "Task search caps a 65-segment canonical history at 64 segment reads", %{
    group_id: group_id
  } do
    conversation_id = Ids.new_conversation_id()

    rows =
      Enum.map(1..65, fn
        1 ->
          task_search_row(1, "old segment must not be read")

        2 ->
          task_search_row(2, nil)

        65 ->
          task_search_row(65, "newest")
          |> Map.put("role_label", String.duplicate("unused-role", 80_000))

        seq ->
          task_search_row(seq, "slot #{seq}")
      end)

    Enum.each(rows, fn row ->
      segment_id = task_search_segment_id(row["seq"])

      next_segment_id =
        if row["seq"] < 65, do: task_search_segment_id(row["seq"] + 1)

      put_task_search_segment(
        group_id,
        conversation_id,
        segment_id,
        [row],
        next_segment_id
      )
    end)

    put_task_search_pointer(
      group_id,
      conversation_id,
      Enum.at(rows, 1),
      task_search_segment_id(2)
    )

    :ok = S3.Fake.reset_read_log()

    assert {:ok, %{segment_count: 64, messages: messages}} =
             Conversations.task_search_content_window(
               task_search_conversation(group_id, conversation_id, 65)
             )

    assert length(messages) == 63
    assert Enum.map(messages, & &1.seq) == Enum.to_list(3..65)

    assert Enum.all?(
             messages,
             &(Enum.sort(Map.keys(&1)) == [:created_at, :envelope, :id, :seq])
           )

    segment_prefix =
      Keys.ctl_group_conversation_messages_segments_prefix(group_id, conversation_id)

    index_prefix =
      Keys.ctl_group_conversation_message_segment_index_prefix(group_id, conversation_id)

    reads = S3.Fake.read_log()

    assert Enum.count(reads, fn
             {:get, key} -> String.starts_with?(key, segment_prefix)
             _other -> false
           end) == 64

    assert Enum.count(reads, fn
             {:get, key} -> String.starts_with?(key, index_prefix)
             _other -> false
           end) == 64

    refute {:get,
            Keys.ctl_group_conversation_message_segment(
              group_id,
              conversation_id,
              task_search_segment_id(1)
            )} in reads
  end

  test "Task search fails closed before decoding an oversized canonical segment", %{
    group_id: group_id
  } do
    conversation_id = Ids.new_conversation_id()
    row = task_search_row(1, "small")
    segment_id = task_search_segment_id(1)
    put_task_search_segment(group_id, conversation_id, segment_id, [row], nil)
    put_task_search_pointer(group_id, conversation_id, row, segment_id)

    segment_key =
      Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    assert {:ok, _result} = S3.put(segment_key, String.duplicate("x", 1_000_001))

    assert {:error, :task_search_segment_too_large} =
             Conversations.task_search_content_window(
               task_search_conversation(group_id, conversation_id, 1)
             )
  end

  test "delete tombstone hides the aggregate before bounded cleanup and resumes after owner restart",
       %{
         tenant_id: tenant_id,
         group_id: group_id
       } do
    now = System.system_time(:millisecond)

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
    Application.put_env(:salix_store, :s3_backend, ConversationDeleteFaultOnceS3)
    Application.put_env(:salix_im, :delete_fault_conversation_prefix, prefix)
    Application.put_env(:salix_im, :fail_conversation_child_delete_once, true)
    Application.put_env(:salix_im, :conversation_delete_fault_test_pid, self())

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)
    assert_receive {:conversation_child_delete_failed, failed_key}, 1_000
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

  test "delete changes nothing before the durable tombstone and stops participant IO before ack",
       %{
         group_id: group_id,
         worker_id: worker_id
       } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Tombstone ordering",
               "participants" => [
                 user_participant(now),
                 agent_participant(worker_id, "worker", now)
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    worker_participant = Enum.find(participants, &(&1["agent_id"] == worker_id))

    assert {:ok, participant_owner} =
             SalixIM.ConversationFleet.ensure_participant_started(
               group_id,
               conversation_id,
               worker_participant["participant_id"]
             )

    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)
    Application.put_env(:salix_store, :s3_backend, ConversationWriteFaultOnceS3)
    Application.put_env(:salix_im, :conversation_tombstone_fault_key, meta_key)
    Application.put_env(:salix_im, :fail_conversation_tombstone_once, true)

    assert {:error, {:http, 503}} =
             ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert Process.alive?(participant_owner)

    assert {:ok, %{"status" => "active"}} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => "current",
                 "content" => "still usable",
                 "client_request_id" => "after-failed-tombstone"
               }
             )

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)
    refute Process.alive?(participant_owner)
    assert {:error, :not_found} = Conversations.get_group_conversation(group_id, conversation_id)
  end

  test "delete retry after a tombstone owner crash acknowledges only after participant IO stops",
       %{
         group_id: group_id,
         worker_id: worker_id
       } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Crash after tombstone",
               "participants" => [
                 user_participant(now),
                 blocking_provider_participant(group_id, worker_id, now)
               ]
             })

    Application.put_env(:salix_im, :slack_conversation_delivery_mod, BlockingProviderDelivery)
    Application.put_env(:salix_im, :blocking_agent_delivery_test_pid, self())

    assert {:ok, %{"delivery_status" => "queued"}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "content" => "keep participant IO active",
               "client_request_id" => "delete-crash-active-delivery"
             })

    assert_receive {:agent_delivery_blocked, delivery_worker}, 2_000

    assert [%{"participant_id" => participant_id}] =
             group_id
             |> all_test_participants(conversation_id)
             |> Enum.filter(&(&1["actor_type"] == "provider"))

    assert {:ok, participant_owner} =
             SalixIM.ConversationFleet.ensure_participant_started(
               group_id,
               conversation_id,
               participant_id
             )

    assert {:ok, conversation_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    participant_ref = Process.monitor(participant_owner)
    delivery_ref = Process.monitor(delivery_worker)
    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)

    Application.put_env(:salix_store, :s3_backend, ConversationTombstoneOwnerCrashS3)
    Application.put_env(:salix_im, :crash_tombstone_owner_once, true)
    Application.put_env(:salix_im, :crash_tombstone_key, meta_key)
    Application.put_env(:salix_im, :crash_tombstone_test_pid, self())

    Application.put_env(
      :salix_im,
      :crash_participant_states_prefix,
      Keys.ctl_group_conversation_participant_states_prefix(group_id, conversation_id)
    )

    Application.put_env(:salix_im, :block_deleted_participant_cleanup, true)

    assert {:error, {:owner_unreachable, _owner_key, _reason}} =
             ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert_receive :tombstone_committed, 1_000

    assert {:ok, restarted_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    refute restarted_owner == conversation_owner

    retry =
      Task.async(fn ->
        ConversationServer.delete_group_conversation(group_id, conversation_id)
      end)

    assert_receive :deleted_participant_cleanup_blocked, 2_000

    assert :ok = Task.await(retry)
    assert_receive {:DOWN, ^participant_ref, :process, ^participant_owner, _reason}, 1_000
    assert_receive {:DOWN, ^delivery_ref, :process, ^delivery_worker, _reason}, 1_000
    refute Process.alive?(participant_owner)
    refute Process.alive?(delivery_worker)

    Application.put_env(:salix_im, :block_deleted_participant_cleanup, false)
  end

  test "tombstone recovery retries an initial meta read failure without another delete", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Retry tombstone recovery classification",
               "participants" => [user_participant(now)]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert {:ok, participant_owner} =
             SalixIM.ConversationFleet.ensure_participant_started(
               group_id,
               conversation_id,
               participant_id
             )

    participant_ref = Process.monitor(participant_owner)

    assert {:ok, _pin} =
             ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)

    assert {:ok, conversation_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    conversation_ref = Process.monitor(conversation_owner)
    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)
    pin_aggregate_key = Keys.ctl_conversation_pins_aggregate(group_id)

    assert {:ok, %{body: pin_aggregate_body}} = SalixStore.S3.get(pin_aggregate_key)

    assert %{"pins" => pins} = Jason.decode!(pin_aggregate_body)
    assert Enum.any?(pins, &(&1["conversation_id"] == conversation_id))

    Application.put_env(:salix_store, :s3_backend, ConversationTombstoneOwnerCrashS3)
    Application.put_env(:salix_im, :crash_tombstone_owner_once, true)
    Application.put_env(:salix_im, :crash_tombstone_key, meta_key)
    Application.put_env(:salix_im, :crash_tombstone_test_pid, self())

    Application.put_env(
      :salix_im,
      :fail_recovery_meta_get_after_tombstone_crash_once,
      true
    )

    assert {:error, {:owner_unreachable, _owner_key, _reason}} =
             ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert_receive :tombstone_committed, 1_000
    assert_receive {:DOWN, ^conversation_ref, :process, ^conversation_owner, _reason}, 1_000

    assert eventually_value(fn ->
             case ConversationPlacement.ensure_started(group_id, conversation_id) do
               {:ok, restarted_owner} when restarted_owner != conversation_owner ->
                 restarted_owner

               _ ->
                 nil
             end
           end)

    assert_receive :recovery_meta_get_failed, 1_000

    assert_receive {:DOWN, ^participant_ref, :process, ^participant_owner, _reason}, 2_000

    assert eventually_value(fn ->
             with {:error, :not_found} <- SalixStore.S3.get(meta_key),
                  {:ok, %{body: pin_aggregate_body}} <-
                    SalixStore.S3.get(pin_aggregate_key),
                  {:ok, %{"pins" => pins}} <- Jason.decode(pin_aggregate_body) do
               not Enum.any?(pins, &(&1["conversation_id"] == conversation_id))
             else
               _ -> nil
             end
           end)
  end

  test "fleet quiescence removes participant owners created after a teardown snapshot", %{
    group_id: group_id,
    worker_id: worker_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Recovery retry teardown race",
               "participants" => [agent_participant(worker_id, "worker", now)]
             })

    assert {:ok, %{"participants" => [%{"participant_id" => participant_id}]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert :ok = SalixIM.TestSupport.Fleet.stop_all!()

    participant_key =
      SalixIM.ConversationParticipantActor.key(group_id, conversation_id, participant_id)

    assert [] == Registry.lookup(SalixIM.ConversationRegistry, participant_key)

    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)

    participant_state_key =
      Keys.ctl_group_conversation_participant_state(
        group_id,
        conversation_id,
        participant_id
      )

    Application.put_env(:salix_store, :s3_backend, ConversationTombstoneOwnerCrashS3)
    Application.put_env(:salix_im, :crash_tombstone_key, meta_key)
    Application.put_env(:salix_im, :crash_tombstone_test_pid, self())
    Application.put_env(:salix_im, :fail_recovery_meta_get_once, true)
    Application.put_env(:salix_im, :block_recovery_meta_get_once, true)

    assert {:ok, _recovering_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    assert_receive :recovery_meta_get_failed, 1_000
    assert_receive {:recovery_meta_get_blocked, blocked_store}, 1_000

    teardown_snapshot = DynamicSupervisor.which_children(SalixIM.ConversationFleetSup)
    assert [] == Registry.lookup(SalixIM.ConversationRegistry, participant_key)

    send(blocked_store, :release_recovery_meta_get)

    late_participant_owner =
      eventually_value(fn ->
        case Registry.lookup(SalixIM.ConversationRegistry, participant_key) do
          [{pid, _value}] -> pid
          [] -> nil
        end
      end)

    assert is_pid(late_participant_owner)

    late_participant_store = :sys.get_state(late_participant_owner).store_pid

    Enum.each(teardown_snapshot, fn {_id, pid, _type, _modules} ->
      DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid)
    end)

    assert Process.alive?(late_participant_owner)

    SalixStore.S3.Fake.reset()

    assert :ok =
             SalixIM.ConversationParticipantActor.wake(group_id, conversation_id, participant_id)

    assert eventually_value(fn ->
             if {:get, participant_state_key} in SalixStore.S3.Fake.read_log(), do: true
           end)

    assert :ok = SalixIM.TestSupport.Fleet.stop_all!()
    refute Process.alive?(late_participant_owner)
    assert [] == Registry.lookup(SalixIM.ConversationRegistry, participant_key)

    SalixStore.S3.Fake.reset_read_log()

    # Observe past one full retry_drain cadence after the fleet is quiescent.
    Process.sleep(1_100)
    assert [] == SalixStore.S3.Fake.read_log(late_participant_store)
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

  for preconverted <- [false, true] do
    @preconverted preconverted
    @tag :task_graph_retirement
    test "graph retirement retains one directed handoff across retries, partial conversion=#{preconverted}",
         %{
           group_id: group_id,
           router_id: router_id,
           worker_id: worker_id,
           tenant_id: tenant_id
         } do
      assert {:ok, %{"conversation_id" => id}} =
               create_task_conversation(
                 group_id,
                 router_id,
                 worker_id,
                 %{"title" => "Retained Task", "content" => "Original request"}
               )

      extra =
        SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
          "name" => "Former reviewer",
          "role" => "worker"
        })

      assert {:ok, reviewer} =
               SalixIM.ConversationInput.ensure_group_conversation_agent_participant(
                 group_id,
                 id,
                 %{"agent_id" => extra["agent_id"], "role_label" => "reviewer"}
               )

      assert {:ok, %{"participants" => participants}} =
               Conversations.list_group_conversation_participants(group_id, id)

      worker = Enum.find(participants, &(&1["agent_id"] == worker_id))

      graph = %{
        "schema" => "task-workflow/v1",
        "participants" => %{
          "worker" => %{"participant_id" => worker["participant_id"]},
          "reviewer" => %{"participant_id" => reviewer["participant_id"]}
        }
      }

      runtime = %{"progresses" => %{"review" => %{"state" => "active"}}}
      SalixIM.ConversationFleet.stop(group_id, id)

      assert {:ok, _} =
               CasRecord.update(Keys.ctl_group_conversation(group_id, id), fn current ->
                 legacy =
                   current |> Map.put("workflow", graph) |> Map.put("workflow_runtime", runtime)

                 if @preconverted do
                   {:ok, converted} =
                     SalixIM.Migrations.RetireTaskGraph.convert(legacy, participants)

                   converted
                 else
                   legacy
                 end
               end)

      assert {:ok, _pid} =
               SalixIM.ConversationFleet.ensure_started(group_id, id, wake_on_recovery: false)

      assert {:ok, first} = ConversationServer.retire_task_graph(group_id, id)
      assert first["inserted"]
      :ok = SalixIM.ConversationFleet.stop(group_id, id)

      assert {:ok, _pid} =
               SalixIM.ConversationFleet.ensure_started(group_id, id, wake_on_recovery: false)

      assert {:ok, second} = ConversationServer.retire_task_graph(group_id, id)
      refute second["inserted"]
      assert first["message_id"] == second["message_id"]
      assert {:ok, task} = Conversations.get_group_conversation(group_id, id)
      assert task["task_worker_agent_id"] == worker_id
      assert task["status"] == "active"
      assert task["metadata"]["retired_task_graph"]["runtime"] == runtime

      assert {:ok, messages} =
               Conversations.list_group_conversation_messages(group_id, id, limit: 20)

      assert length(messages) == 2
      handoff = Enum.find(messages, &(&1["message_id"] == first["message_id"]))
      assert handoff["delivery_filter"] == %{"participant_ids" => [worker["participant_id"]]}

      assert {:ok, retired} =
               Conversations.get_group_conversation_participant(
                 group_id,
                 id,
                 reviewer["participant_id"]
               )

      assert retired["state"] == "inactive"
    end
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

  test "legacy Agent attachment does not make its result Message unreadable when the source path is gone",
       %{group_id: group_id, router_id: router_id, worker_id: worker_id} do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             create_task_conversation(group_id, router_id, worker_id, %{
               "title" => "Legacy attachment compatibility",
               "content" => "Review a pre-upgrade result Message.",
               "client_request_id" => "legacy-missing-agent-attachment"
             })

    missing_path = "/artifacts/pre-upgrade-result.md"

    assert {:ok, %{"message_id" => result_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "content" => [
                   %{"type" => "text", "text" => "The legacy result is still reviewable."},
                   %{
                     "type" => "file",
                     "path" => missing_path,
                     "file_name" => "pre-upgrade-result.md"
                   }
                 ],
                 "client_request_id" => "persisted-before-attachment-binding",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:error, :not_found} = SalixAgent.Workspace.read(worker_id, missing_path)

    assert {:ok, result} =
             SalixIM.Provider.call_api(
               router_id,
               "internal",
               "internal.read_conversation",
               %{
                 "connect_id" => "internal",
                 "params" => %{
                   "conversation_id" => conversation_id,
                   "message_id" => result_message_id,
                   "query" => "read the referenced legacy result"
                 }
               }
             )

    assert [%{"message_id" => ^result_message_id} = message] = result["messages"]
    assert Jason.encode!(message) =~ "The legacy result is still reviewable."
  end

  test "TaskWorkerWatch reminds a silent stopped Worker once, then tells the Router", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-nudge")

    stopped_at = System.system_time(:millisecond)
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    send(watch, {:task_worker_stopped_timeout, {worker_id, session_id}, version, token})

    assert_receive {:captured_agent_delivery, ^worker_id, nudge, _opts}, 2_000
    assert nudge.content =~ "publish exactly one result Message"
    refute_receive {:captured_agent_delivery, ^router_id, _, _}, 100
    assert {:acted, ^version, :stopped, nil, nil, nil} = :sys.get_state(watch).stop

    # A replayed timer for the same stop is ignored.
    send(watch, {:task_worker_stopped_timeout, {worker_id, session_id}, version, token})
    refute_receive {:captured_agent_delivery, _, _, _}, 100

    # The reminder woke the Worker; it stops again without publishing.
    TaskSessionActivity.set(worker_id, session_id, "active", stopped_at + 500)
    TaskSessionActivity.notify(worker_id, session_id)
    assert eventually_value(fn -> :sys.get_state(watch).stop == nil end)

    stopped_again = stopped_at + 1_000
    version_again = Integer.to_string(stopped_again)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_again)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version_again, :stopped, nil, _timer, token_again} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version_again, token_again}
    )

    assert_receive {:captured_agent_delivery, ^router_id, notice, _opts}, 2_000
    assert notice.content =~ "stopped without publishing a result (stopped_after_reminder)"
    refute_receive {:captured_agent_delivery, ^worker_id, _, _}, 100

    # A third silent stop in the same delegation sends nothing more.
    stopped_third = stopped_at + 2_000
    version_third = Integer.to_string(stopped_third)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_third)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version_third, :stopped, nil, _timer, token_third} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    send(
      watch,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version_third, token_third}
    )

    assert eventually_value(fn -> match?({:acted, _, _, _, _, _}, :sys.get_state(watch).stop) end)
    refute_receive {:captured_agent_delivery, _, _, _}, 100

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

  test "TaskWorkerWatch stays quiet when the Worker has published a result", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-quiet")

    assert {:ok, _message} =
             append_task_result_message(
               group_id,
               conversation_id,
               worker_id,
               "task-worker-watch-result",
               "Here is the summary."
             )

    stopped_at = System.system_time(:millisecond)
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    send(watch, {:task_worker_stopped_timeout, {worker_id, session_id}, version, token})

    assert eventually_value(fn ->
             match?({:acted, ^version, _, _, _, _}, :sys.get_state(watch).stop)
           end)

    refute_receive {:captured_agent_delivery, _, _, _}, 200

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    refute Enum.any?(
             messages,
             &(get_in(&1, ["metadata", "message_type"]) in [
                 "task_worker_nudge",
                 "task_worker_stopped"
               ])
           )
  end

  test "TaskWorkerWatch keeps the grace period for second-based session timestamps", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {_conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-seconds")

    stopped_at = System.system_time(:second)
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, timer, _token} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    assert Process.read_timer(timer) > div(SalixIM.TaskWorkerWatch.grace_ms(), 2)
    refute_receive {:captured_agent_delivery, _, _, _}, 100
  end

  test "TaskWorkerWatch tells the Router at once when the Worker's runtime cannot run", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-blocked")

    failed_at = System.system_time(:millisecond)
    version = Integer.to_string(failed_at)

    TaskSessionActivity.set(
      worker_id,
      session_id,
      "error",
      failed_at,
      "quota_exhausted",
      nil,
      "error: Claude account usage quota is exhausted. Provider reset time: 2026-09-15T13:50:00Z."
    )

    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :error, "quota_exhausted", _timer, token} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    send(watch, {:task_worker_stopped_timeout, {worker_id, session_id}, version, token})

    assert_receive {:captured_agent_delivery, ^router_id, notice, _opts}, 2_000
    assert notice.content =~ "(quota_exhausted)"
    assert notice.content =~ "2026-09-15T13:50:00Z"
    assert notice.content =~ "Tell the requester"
    assert notice.content =~ "do not promise automatic recovery"
    refute_receive {:captured_agent_delivery, ^worker_id, _, _}, 100

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert [notice_message] =
             Enum.filter(
               messages,
               &(get_in(&1, ["metadata", "message_type"]) == "task_worker_stopped")
             )

    assert get_in(notice_message, ["metadata", "task_worker_watch", "issue"]) == "quota_exhausted"
  end

  test "TaskWorkerWatch does not escalate the stop it already reminded for after a restart", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-restart")

    stopped_at = System.system_time(:millisecond)
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    send(watch, {:task_worker_stopped_timeout, {worker_id, session_id}, version, token})
    assert_receive {:captured_agent_delivery, ^worker_id, _nudge, _opts}, 2_000

    # The owner restarts; the new watch finds the Worker still in the same
    # stop, with the reminder already in the Task.
    :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)
    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    assert {:ok, restarted} = SalixIM.ConversationActor.task_worker_watch(owner)
    refute restarted == watch

    assert {:scheduled, ^version, :stopped, nil, _timer, token_again} =
             eventually_value(fn -> :sys.get_state(restarted).stop end)

    send(restarted, {:task_worker_stopped_timeout, {worker_id, session_id}, version, token_again})

    assert eventually_value(fn ->
             match?({:acted, ^version, _, _, _, _}, :sys.get_state(restarted).stop)
           end)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert Enum.map(
             Enum.filter(
               messages,
               &(get_in(&1, ["metadata", "message_type"]) in [
                   "task_worker_nudge",
                   "task_worker_stopped"
                 ])
             ),
             &get_in(&1, ["metadata", "message_type"])
           ) == ["task_worker_nudge"]

    # A genuinely new stop after the reminder still escalates.
    stopped_again = stopped_at + 1_000
    version_again = Integer.to_string(stopped_again)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_again)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version_again, :stopped, nil, _timer, token_new} =
             eventually_value(fn -> :sys.get_state(restarted).stop end)

    send(
      restarted,
      {:task_worker_stopped_timeout, {worker_id, session_id}, version_again, token_new}
    )

    assert eventually_value(fn ->
             match?(
               {:ok, messages} when is_list(messages),
               Conversations.list_group_conversation_messages(group_id, conversation_id,
                 limit: 20
               )
             ) and
               Enum.any?(
                 elem(
                   Conversations.list_group_conversation_messages(group_id, conversation_id,
                     limit: 20
                   ),
                   1
                 ),
                 &(get_in(&1, ["metadata", "message_type"]) == "task_worker_stopped")
               )
           end)
  end

  test "TaskWorkerWatch retries a reminder whose append failed", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, session_id, watch} =
      start_watched_plain_task(group_id, router_id, worker_id, "task-worker-watch-retry")

    Application.put_env(:salix_im, :task_worker_watch_fail_next_append, true)

    stopped_at = System.system_time(:millisecond)
    version = Integer.to_string(stopped_at)
    TaskSessionActivity.set(worker_id, session_id, "stopped", stopped_at)
    TaskSessionActivity.notify(worker_id, session_id)

    assert {:scheduled, ^version, :stopped, nil, _timer, token} =
             eventually_value(fn -> :sys.get_state(watch).stop end)

    send(watch, {:task_worker_stopped_timeout, {worker_id, session_id}, version, token})

    # The append failed: nothing was delivered and the stage stays open on a
    # retry timer with a fresh token.
    assert {:retry, ^version, :stopped, nil, retry_timer, retry_token} =
             eventually_value(fn ->
               case :sys.get_state(watch).stop do
                 {:retry, _, _, _, _, _} = stop -> stop
                 _ -> nil
               end
             end)

    assert is_reference(retry_timer)
    assert :sys.get_state(watch).attempts == 1
    refute_receive {:captured_agent_delivery, ^worker_id, _, _}, 200
    refute Application.get_env(:salix_im, :task_worker_watch_fail_next_append)

    send(watch, {:task_worker_stopped_timeout, {worker_id, session_id}, version, retry_token})
    assert_receive {:captured_agent_delivery, ^worker_id, nudge, _opts}, 2_000
    assert nudge.content =~ "publish exactly one result Message"
    assert {:acted, ^version, :stopped, nil, nil, nil} = :sys.get_state(watch).stop
    assert :sys.get_state(watch).attempts == 0

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert [_nudge] =
             Enum.filter(
               messages,
               &(get_in(&1, ["metadata", "message_type"]) == "task_worker_nudge")
             )
  end

  @tag :task_archive
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

  @tag :task_archive
  test "archived Task remains in list after late agent result with archive-time ordering", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    assert {:ok, %{"conversation_id" => id}} =
             create_task_conversation(group_id, router_id, worker_id, %{
               "title" => "Late result",
               "content" => "work",
               "client_request_id" => "archive-late"
             })

    assert {:ok, ready} =
             ConversationServer.update_group_conversation(group_id, id, %{"status" => "failed"})

    assert {:ok, archived} =
             ConversationServer.set_task_archived(group_id, id, :archive, ready["updated_at"])

    assert {:ok, _} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               id,
               worker_id,
               %{
                 "content" => "late result",
                 "client_request_id" => "late-result",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, %{"data" => data}} =
             Conversations.list_group_conversations(group_id, kind: "agent_task", limit: 50)

    current = Enum.find(data, &(&1["conversation_id"] == id))
    assert current["status"] == "archived"
    assert current["archived_at"] == archived["archived_at"]
    assert current["updated_at"] > archived["updated_at"]
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
             ConversationServer.subscribe_group_conversation(group_id, conversation_id, self())

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert_receive {:conversation_status_changed, ^group_id, ^conversation_id, "completed"}

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    refute_receive {:conversation_status_changed, ^group_id, ^conversation_id, "completed"}, 100

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

  test "Task review acceptance repairs its list projection after the canonical CAS lands", %{
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
                 "title" => "Review index repair",
                 "content" => "build the requested artifact",
                 "client_request_id" => "review-index-repair-task"
               }
             )

    assert {:ok, %{"seq" => 2}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "content" => "The artifact is ready.",
                 "client_request_id" => "review-index-repair-result",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, %{"updated_at" => review_version}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "status" => "ready_for_review"
             })

    assert {:ok, %{"status" => "ready_for_review"} = reviewable} =
             Conversations.get_group_conversation(group_id, conversation_id)

    previous_index_key = conversation_list_index_key(group_id, reviewable)
    assert Map.has_key?(SalixStore.S3.Fake.dump(), previous_index_key)

    assert {:ok, %{"tail_seq" => 2}} =
             ConversationServer.subscribe_group_conversation(group_id, conversation_id, self())

    assert :ok =
             SalixStore.S3.Fake.blackhole({:fail, 503, :delete, previous_index_key})

    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    reply = ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert {:ok, canonical} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, %{"data" => visible_conversations}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert Enum.any?(visible_conversations, fn conversation ->
             conversation["conversation_id"] == conversation_id and
               conversation["status"] == "completed"
           end)

    status_notified? =
      receive do
        {:conversation_status_changed, ^group_id, ^conversation_id, "completed"} -> true
      after
        100 -> false
      end

    assert :ok = SalixStore.S3.Fake.clear_blackhole()

    stale_index_repaired? =
      eventually_value(fn ->
        not Map.has_key?(SalixStore.S3.Fake.dump(), previous_index_key)
      end)

    assert %{
             api_success?: true,
             canonical_status: "completed",
             stale_index_repaired?: true,
             status_notified?: true
           } == %{
             api_success?: match?({:ok, %{"status" => "completed"}}, reply),
             canonical_status: canonical["status"],
             stale_index_repaired?: stale_index_repaired?,
             status_notified?: status_notified?
           }
  end

  test "Task list repair survives conversation owner restart", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, review_version} =
      create_reviewable_task!(group_id, router_id, worker_id, "restart-index-repair")

    assert {:ok, reviewable} = Conversations.get_group_conversation(group_id, conversation_id)
    stale_key = conversation_list_index_key(group_id, reviewable)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :delete, stale_key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert [_current, _stale] =
             conversation_list_index_records(group_id, conversation_id)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    store_pid = :sys.get_state(owner).store_pid
    store_ref = Process.monitor(store_pid)
    assert :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)
    assert_receive {:DOWN, ^store_ref, :process, ^store_pid, _reason}, 1_000
    assert :ok = SalixStore.S3.Fake.clear_blackhole()

    assert {:ok, _restarted_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    assert eventually_value(fn ->
             with {:ok, canonical} <-
                    Conversations.get_group_conversation(group_id, conversation_id),
                  [{only_key, only_record}] <-
                    conversation_list_index_records(group_id, conversation_id) do
               only_key == conversation_list_index_key(group_id, canonical) and
                 only_record["updated_at"] == canonical["updated_at"]
             else
               _ -> false
             end
           end)
  end

  test "Task acceptance does not commit when its current list index cannot be written", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, review_version} =
      create_reviewable_task!(group_id, router_id, worker_id, "index-first-accept")

    assert {:ok, before_accept} =
             Conversations.get_group_conversation(group_id, conversation_id)

    before_key = conversation_list_index_key(group_id, before_accept)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, :any})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    assert {:error, _reason} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert :ok = SalixStore.S3.Fake.clear_blackhole()

    assert {:ok, after_failure} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert after_failure["status"] == "ready_for_review"
    assert after_failure["updated_at"] == before_accept["updated_at"]
    assert [{^before_key, _record}] = conversation_list_index_records(group_id, conversation_id)
  end

  test "Task acceptance writes the current list locator before canonical meta", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, review_version} =
      create_reviewable_task!(group_id, router_id, worker_id, "index-before-meta")

    assert :ok = SalixStore.S3.Fake.reset_put_log()

    assert {:ok, %{"status" => "completed"} = completed} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    current_key = conversation_list_index_key(group_id, completed)
    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)
    writes = SalixStore.S3.Fake.put_log()

    assert current_index = Enum.find_index(writes, &(&1 == current_key))
    assert meta_index = Enum.find_index(writes, &(&1 == meta_key))
    assert current_index < meta_index
  end

  test "message append list repair survives conversation owner restart", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, _review_version} =
      create_reviewable_task!(group_id, router_id, worker_id, "append-restart-index-repair")

    assert {:ok, before_append} =
             Conversations.get_group_conversation(group_id, conversation_id)

    stale_key = conversation_list_index_key(group_id, before_append)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :delete, stale_key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    assert {:ok, %{"inserted" => true}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               router_id,
               %{
                 "content" => "Please add keyboard controls.",
                 "client_request_id" => "append-restart-index-repair-command",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert [_current, _stale] = conversation_list_index_records(group_id, conversation_id)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    store_pid = :sys.get_state(owner).store_pid
    store_ref = Process.monitor(store_pid)
    assert :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)
    assert_receive {:DOWN, ^store_ref, :process, ^store_pid, _reason}, 1_000
    assert :ok = SalixStore.S3.Fake.clear_blackhole()

    assert {:ok, _restarted_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    assert eventually_value(fn ->
             with {:ok, canonical} <-
                    Conversations.get_group_conversation(group_id, conversation_id),
                  [{only_key, only_record}] <-
                    conversation_list_index_records(group_id, conversation_id) do
               only_key == conversation_list_index_key(group_id, canonical) and
                 only_record["updated_at"] == canonical["updated_at"] and
                 canonical["status"] == "ready_for_review"
             else
               _ -> false
             end
           end)
  end

  test "overlapping failed list-index updates converge to the latest canonical Task", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, review_version} =
      create_reviewable_task!(group_id, router_id, worker_id, "overlapping-index-repair")

    assert {:ok, reviewable} = Conversations.get_group_conversation(group_id, conversation_id)
    first_stale_key = conversation_list_index_key(group_id, reviewable)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :delete, first_stale_key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert {:ok, completed} = Conversations.get_group_conversation(group_id, conversation_id)
    second_stale_key = conversation_list_index_key(group_id, completed)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :delete, second_stale_key})

    assert {:ok, %{"title" => "Reviewed artifact"}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "title" => "Reviewed artifact"
             })

    assert :ok = SalixStore.S3.Fake.clear_blackhole()

    assert eventually_value(fn ->
             case conversation_list_index_records(group_id, conversation_id) do
               [{_key, %{"updated_at" => updated_at}}] ->
                 {:ok, canonical} =
                   Conversations.get_group_conversation(group_id, conversation_id)

                 updated_at == canonical["updated_at"]

               _records ->
                 false
             end
           end)
  end

  test "a pending Task list repair cannot recreate an index after deletion", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, review_version} =
      create_reviewable_task!(group_id, router_id, worker_id, "delete-index-repair")

    assert {:ok, reviewable} = Conversations.get_group_conversation(group_id, conversation_id)
    stale_key = conversation_list_index_key(group_id, reviewable)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :delete, stale_key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)
    assert :ok = SalixStore.S3.Fake.clear_blackhole()

    assert eventually_value(fn ->
             Conversations.get_group_conversation(group_id, conversation_id) ==
               {:error, :not_found} and
               conversation_list_index_records(group_id, conversation_id) == []
           end)
  end

  test "delete cleanup removes the previous Task list locator after an owner restart", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    {conversation_id, review_version} =
      create_reviewable_task!(group_id, router_id, worker_id, "delete-restart-index-repair")

    assert {:ok, reviewable} = Conversations.get_group_conversation(group_id, conversation_id)
    stale_key = conversation_list_index_key(group_id, reviewable)
    assert :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :delete, stale_key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    assert {:ok, %{"status" => "completed"}} =
             ConversationServer.accept_task_review(group_id, conversation_id, review_version)

    assert :ok = ConversationServer.delete_group_conversation(group_id, conversation_id)

    assert eventually_value(fn ->
             case conversation_list_index_records(group_id, conversation_id) do
               [{^stale_key, _record}] -> true
               _records -> false
             end
           end)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    store_pid = :sys.get_state(owner).store_pid
    store_ref = Process.monitor(store_pid)
    assert :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)
    assert_receive {:DOWN, ^store_ref, :process, ^store_pid, _reason}, 1_000
    assert :ok = SalixStore.S3.Fake.clear_blackhole()

    assert {:ok, _restarted_owner} =
             ConversationPlacement.ensure_started(group_id, conversation_id)

    assert eventually_value(fn ->
             Conversations.get_group_conversation(group_id, conversation_id) ==
               {:error, :not_found} and
               conversation_list_index_records(group_id, conversation_id) == []
           end)
  end

  test "task create leaves no Task after initial append fails and a retry creates it", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    attrs = %{
      "title" => "Repair prepared task",
      "content" => "deliver exactly once after retry",
      "client_request_id" => "task-create-partial-repair"
    }

    Application.put_env(:salix_store, :s3_backend, ConversationWriteFaultOnceS3)
    Application.put_env(:salix_im, :fail_message_segment_once, true)

    on_exit(fn -> Application.delete_env(:salix_im, :fail_message_segment_once) end)

    assert {:error, _reason} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               attrs
             )

    assert {:ok, %{"data" => conversations}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert [] == Enum.filter(conversations, &(&1["title"] == attrs["title"]))

    assert {:ok, %{"conversation_id" => prepared_conversation_id}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               attrs
             )

    assert {:ok, [message]} =
             Conversations.list_group_conversation_messages(
               group_id,
               prepared_conversation_id,
               limit: 10
             )

    assert message["content"] == [%{"type" => "text", "text" => attrs["content"]}]

    assert {:error, {:conflict, _reason}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               Map.put(attrs, "content", "conflicting retry")
             )
  end

  test "trusted ingress task retry rejects different content", %{
    group_id: group_id,
    worker_id: worker_id
  } do
    conversation_id = Ids.new_conversation_id()
    created_at = System.system_time(:millisecond)

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
    created_at = System.system_time(:millisecond)

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

  test "trusted ingress target conflict does not install a materialization fence", %{
    tenant_id: tenant_id,
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    other_worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Other Worker",
        "role" => "worker"
      })

    assert {:ok, %{"conversation_id" => conversation_id}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               %{
                 "title" => "Existing ordinary task",
                 "content" => "Keep the existing task untouched",
                 "client_request_id" => "existing-task-before-external-collision"
               }
             )

    assert {:ok, existing} =
             Conversations.get_group_conversation(group_id, conversation_id)

    refute Map.has_key?(existing, "task_materialization")

    assert {:error, {:conflict, _reason}} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               conversation_id,
               other_worker["agent_id"],
               %{
                 "title" => existing["title"],
                 "command" => get_in(existing, ["schedule", "command"]),
                 "created_at" => existing["created_at"]
               }
             )

    assert {:ok, unchanged} =
             Conversations.get_group_conversation(group_id, conversation_id)

    refute Map.has_key?(unchanged, "task_materialization")
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
        "title" => "Bridge chat",
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

  test "seeded BFT target remains the single provider participant after owner recovery", %{
    group_id: group_id
  } do
    conversation_id = Ids.new_conversation_id()

    seed = %{
      "conversation" => %{
        "kind" => "user_chat",
        "title" => "Imported BFT chat",
        "participants" => [bft_participant()]
      },
      "messages" => [
        %{
          "client_request_id" => "workspace-import-user-1",
          "actor_type" => "provider_user",
          "provider" => "bft",
          "user_id" => "imported-user",
          "content" => "imported message"
        }
      ]
    }

    assert {:ok, %{"message_count" => 1}} =
             seed_group_conversation_transcript(
               group_id,
               conversation_id,
               seed
             )

    assert [%{"participant_id" => participant_id, "target_key" => "bft"}] =
             all_test_participants(group_id, conversation_id)

    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    :ok = GenServer.stop(owner, :normal)

    assert length(all_test_participants(group_id, conversation_id)) == 1

    assert {:ok, %{"participant_id" => ^participant_id}} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               bft_participant()
             )

    assert length(all_test_participants(group_id, conversation_id)) == 1
  end

  test "agent messages are stored through group conversations", %{
    group_id: group_id,
    worker_id: worker_id
  } do
    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Group owned",
               "participants" => [
                 %{
                   "actor_type" => "agent",
                   "agent_id" => worker_id,
                   "state" => "active",
                   "notification_filter" => %{"messages" => "all", "statuses" => "none"}
                 }
               ]
             })

    conversation_id = conversation["conversation_id"]
    assert Ids.valid_conversation_id?(conversation_id)

    assert {:ok, result} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "kind" => "message",
               "actor_type" => "agent",
               "agent_id" => worker_id,
               "content" => "agent note",
               "client_request_id" => "agent-msg-1"
             })

    message_id = result["message_id"]
    assert Ids.valid_message_id?(message_id)

    assert {:ok, [%{"message_id" => ^message_id}]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)
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
    now = System.system_time(:millisecond)

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

  test "slack worker ingress dedupes recipient identity rollout rollback and name refresh", %{
    tenant_id: tenant_id,
    group_id: group_id,
    worker_id: worker_id
  } do
    connect = slack_connect(tenant_id, group_id, worker_id)
    now = System.system_time(:millisecond)

    base_metadata = %{
      "provider" => "slack",
      "connect_id" => connect["connect_id"],
      "workspace_id" => connect["workspace_id"]
    }

    identity_v1 = %{
      "provider" => "slack",
      "display_name" => "comma-old",
      "username" => "comma_old",
      "user_id" => connect["bot_user_id"],
      "app_id" => connect["app_id"]
    }

    identity_v2 = %{
      "provider" => "slack",
      "display_name" => "comma-new",
      "username" => "comma_new",
      "user_id" => connect["bot_user_id"],
      "app_id" => connect["app_id"]
    }

    old_first = %{
      "channel_id" => "C-worker-identity-old",
      "thread_ts" => "401.001",
      "message_ts" => "401.001",
      "source_message_id" => "slack-worker-identity-old-first",
      "user_id" => "U-worker-human",
      "content" => [%{"type" => "text", "text" => "old worker event"}],
      "metadata" => base_metadata,
      "created_at" => now
    }

    assert {:ok,
            %{
              "inserted" => true,
              "message_id" => old_first_message_id,
              "conversation_id" => old_first_conversation_id
            }} =
             SlackConversationIngress.append_worker_thread_message(
               connect,
               worker_id,
               old_first
             )

    for identity <- [identity_v1, identity_v2] do
      replay = put_in(old_first, ["metadata", "recipient_im_identity"], identity)

      assert {:ok, %{"inserted" => false, "message_id" => ^old_first_message_id}} =
               SlackConversationIngress.append_worker_thread_message(
                 connect,
                 worker_id,
                 replay
               )
    end

    assert {:ok, old_first_message} =
             Conversations.get_group_conversation_message(
               group_id,
               old_first_conversation_id,
               old_first_message_id
             )

    refute Map.has_key?(old_first_message["metadata"], "recipient_im_identity")
    refute Map.has_key?(old_first_message, "owner_recipient_im_identity_v1")

    assert {:error, {:conflict, "idempotency identity was already used for different content"}} =
             SlackConversationIngress.append_worker_thread_message(
               connect,
               worker_id,
               Map.put(old_first, "content", [
                 %{"type" => "text", "text" => "different old worker event"}
               ])
             )

    new_first = %{
      "channel_id" => "C-worker-identity-new",
      "thread_ts" => "402.001",
      "message_ts" => "402.001",
      "source_message_id" => "slack-worker-identity-new-first",
      "user_id" => "U-worker-human",
      "content" => [%{"type" => "text", "text" => "new worker event"}],
      "metadata" => Map.put(base_metadata, "recipient_im_identity", identity_v1),
      "created_at" => now + 1
    }

    assert {:ok,
            %{
              "inserted" => true,
              "message_id" => new_first_message_id,
              "conversation_id" => new_first_conversation_id
            }} =
             SlackConversationIngress.append_worker_thread_message(
               connect,
               worker_id,
               new_first
             )

    for metadata <- [base_metadata, Map.put(base_metadata, "recipient_im_identity", identity_v2)] do
      replay = Map.put(new_first, "metadata", metadata)

      assert {:ok, %{"inserted" => false, "message_id" => ^new_first_message_id}} =
               SlackConversationIngress.append_worker_thread_message(
                 connect,
                 worker_id,
                 replay
               )
    end

    assert {:ok, new_first_message} =
             Conversations.get_group_conversation_message(
               group_id,
               new_first_conversation_id,
               new_first_message_id
             )

    refute Map.has_key?(new_first_message["metadata"], "recipient_im_identity")
    assert new_first_message["owner_recipient_im_identity_v1"] == identity_v1

    assert {:error, {:conflict, "idempotency identity was already used for different content"}} =
             SlackConversationIngress.append_worker_thread_message(
               connect,
               worker_id,
               Map.put(new_first, "content", [
                 %{"type" => "text", "text" => "different new worker event"}
               ])
             )
  end

  test "concurrent messages recover one version 1 orphan binding into one task", %{
    tenant_id: tenant_id,
    group_id: group_id,
    worker_id: worker_id
  } do
    connect = slack_connect(tenant_id, group_id, worker_id)
    conversation_id = Ids.new_conversation_id()
    now = System.system_time(:millisecond)

    binding_key =
      Keys.ctl_im_slack_thread_binding(
        group_id,
        connect["connect_id"],
        "C-legacy-orphan",
        "legacy-thread"
      )

    assert {:ok, %{"version" => 1}} =
             CasRecord.create(binding_key, %{
               "version" => 1,
               "provider" => "slack",
               "group_id" => group_id,
               "connect_id" => connect["connect_id"],
               "channel_id" => "C-legacy-orphan",
               "thread_ts" => "legacy-thread",
               "worker_agent_id" => worker_id,
               "conversation_id" => conversation_id,
               "created_at" => now,
               "updated_at" => now
             })

    start_supervised!(LegacyOrphanReadBarrier)

    conversation_key = Keys.ctl_group_conversation(group_id, conversation_id)
    LegacyOrphanReadBarrier.arm(conversation_key, self())
    Application.put_env(:salix_store, :s3_backend, LegacyOrphanBarrierS3)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake) end)

    append = fn suffix ->
      SlackConversationIngress.append_worker_thread_message(connect, worker_id, %{
        "channel_id" => "C-legacy-orphan",
        "thread_ts" => "legacy-thread",
        "message_ts" => "legacy-#{suffix}",
        "source_message_id" => "legacy-source-#{suffix}",
        "user_id" => "U-legacy",
        "content" => [%{"type" => "text", "text" => "legacy message #{suffix}"}],
        "created_at" => now + suffix
      })
    end

    first = Task.async(fn -> append.(1) end)
    second = Task.async(fn -> append.(2) end)

    waiters =
      for _ <- 1..2 do
        assert_receive {:legacy_orphan_read_waiting, pid, ^conversation_key}, 1_000
        pid
      end

    Enum.each(waiters, &send(&1, {:release_legacy_orphan_read, conversation_key}))

    assert [
             {:ok, %{"conversation_id" => ^conversation_id}},
             {:ok, %{"conversation_id" => ^conversation_id}}
           ] = [Task.await(first, 5_000), Task.await(second, 5_000)]

    assert {:ok,
            %{
              "version" => 2,
              "conversation_id" => ^conversation_id,
              "task_materialization" => materialization
            }} = CasRecord.get(binding_key)

    assert materialization["command"] in ["legacy message 1", "legacy message 2"]

    assert {:ok, %{"task_materialization" => ^materialization}} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert length(messages) == 2

    assert {:ok, _corrupt_binding} =
             CasRecord.update(binding_key, fn binding ->
               put_in(binding, ["task_materialization", "unexpected"], true)
             end)

    assert {:error, :invalid_slack_thread_binding} =
             SlackConversationIngress.get_thread_binding(
               group_id,
               connect["connect_id"],
               "C-legacy-orphan",
               "legacy-thread"
             )
  end

  test "concurrent first messages share one version 2 binding snapshot", %{
    tenant_id: tenant_id,
    group_id: group_id,
    worker_id: worker_id
  } do
    connect = slack_connect(tenant_id, group_id, worker_id)
    now = System.system_time(:millisecond)

    binding_key =
      Keys.ctl_im_slack_thread_binding(
        group_id,
        connect["connect_id"],
        "C-concurrent-first",
        "concurrent-thread"
      )

    start_supervised!(LegacyOrphanReadBarrier)
    LegacyOrphanReadBarrier.arm(binding_key, self())
    Application.put_env(:salix_store, :s3_backend, LegacyOrphanBarrierS3)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake) end)

    append = fn suffix ->
      SlackConversationIngress.append_worker_thread_message(connect, worker_id, %{
        "channel_id" => "C-concurrent-first",
        "thread_ts" => "concurrent-thread",
        "message_ts" => "concurrent-#{suffix}",
        "source_message_id" => "concurrent-source-#{suffix}",
        "user_id" => "U-concurrent",
        "content" => [%{"type" => "text", "text" => "concurrent message #{suffix}"}],
        "created_at" => now + suffix
      })
    end

    first = Task.async(fn -> append.(1) end)
    second = Task.async(fn -> append.(2) end)

    waiters =
      for _ <- 1..2 do
        assert_receive {:legacy_orphan_read_waiting, pid, ^binding_key}, 1_000
        pid
      end

    Enum.each(waiters, &send(&1, {:release_legacy_orphan_read, binding_key}))

    assert [
             {:ok, %{"conversation_id" => conversation_id}},
             {:ok, %{"conversation_id" => conversation_id}}
           ] = [Task.await(first, 5_000), Task.await(second, 5_000)]

    assert {:ok,
            %{
              "version" => 2,
              "conversation_id" => ^conversation_id,
              "task_materialization" => materialization
            }} = CasRecord.get(binding_key)

    assert materialization["command"] in ["concurrent message 1", "concurrent message 2"]

    assert {:ok, %{"task_materialization" => ^materialization}} =
             Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 10
             )

    assert length(messages) == 2
  end

  test "a true binding conversation id collision rebinds without mutating the existing task", %{
    tenant_id: tenant_id,
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    other_worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Collision Worker",
        "role" => "worker"
      })

    assert {:ok, %{"conversation_id" => occupied_conversation_id}} =
             create_task_conversation(
               group_id,
               router_id,
               other_worker["agent_id"],
               %{
                 "title" => "Occupied task",
                 "content" => "Do not mutate this task",
                 "client_request_id" => "occupied-before-slack-binding"
               }
             )

    connect = slack_connect(tenant_id, group_id, worker_id)
    now = System.system_time(:millisecond)

    binding_key =
      Keys.ctl_im_slack_thread_binding(
        group_id,
        connect["connect_id"],
        "C-id-collision",
        "collision-thread"
      )

    assert {:ok, _binding} =
             CasRecord.create(binding_key, %{
               "version" => 2,
               "provider" => "slack",
               "group_id" => group_id,
               "connect_id" => connect["connect_id"],
               "channel_id" => "C-id-collision",
               "thread_ts" => "collision-thread",
               "worker_agent_id" => worker_id,
               "conversation_id" => occupied_conversation_id,
               "task_materialization" => %{
                 "title" => "Slack task: collision message",
                 "command" => "collision message",
                 "created_at" => now
               },
               "created_at" => now,
               "updated_at" => now
             })

    assert {:ok, %{"conversation_id" => replacement_conversation_id}} =
             SlackConversationIngress.append_worker_thread_message(connect, worker_id, %{
               "channel_id" => "C-id-collision",
               "thread_ts" => "collision-thread",
               "message_ts" => "collision-message",
               "source_message_id" => "collision-source",
               "user_id" => "U-collision",
               "content" => [%{"type" => "text", "text" => "collision message"}],
               "created_at" => now
             })

    refute replacement_conversation_id == occupied_conversation_id

    assert {:ok, occupied} =
             Conversations.get_group_conversation(group_id, occupied_conversation_id)

    refute Map.has_key?(occupied, "task_materialization")

    assert {:ok, %{"conversation_id" => ^replacement_conversation_id}} =
             CasRecord.get(binding_key)
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

  test "provider participant message mentions are immutable per-delivery metadata", %{
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Provider message mentions",
               "participants" => [
                 slack_thread_participant("sl-mentions", "T-mentions", "C-mentions", "334.000")
               ]
             })

    assert {:ok, %{"participants" => [provider_participant]}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant_id = provider_participant["participant_id"]
    mentions = %{"mode" => "users", "users" => [%{"user_id" => "ou_alice", "name" => "Alice"}]}

    assert {:ok, first} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "provider-command-with-mentions",
                 "content" => [%{"type" => "text", "text" => "Summary"}],
                 "mentions" => mentions
               }
             )

    assert {:ok, second} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "provider-command-without-mentions",
                 "content" => [%{"type" => "text", "text" => "Transcript ready"}],
                 "mentions" => %{"mode" => "none", "users" => []}
               }
             )

    deliveries =
      eventually_value(fn ->
        values = delivery_records(group_id, conversation_id) |> Map.values()
        if length(values) == 2, do: values
      end)

    first_delivery = Enum.find(deliveries, &(&1["message_id"] == first["message_id"]))
    second_delivery = Enum.find(deliveries, &(&1["message_id"] == second["message_id"]))

    assert get_in(first_delivery, ["message_metadata", "delivery_mentions"]) == mentions

    assert get_in(second_delivery, ["message_metadata", "delivery_mentions"]) == %{
             "mode" => "none",
             "users" => []
           }

    refute Map.has_key?(first_delivery["participant_payload"], "mentions")
    refute Map.has_key?(second_delivery["participant_payload"], "mentions")

    assert {:error, {:conflict, "idempotency identity was already used for different content"}} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "provider-command-with-mentions",
                 "content" => [%{"type" => "text", "text" => "Summary"}],
                 "mentions" => %{"mode" => "none", "users" => []}
               }
             )

    assert {:error, {:bad_request, "message metadata contains reserved delivery_mentions"}} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "provider-command-spoofed-mentions",
                 "content" => [%{"type" => "text", "text" => "Spoofed"}],
                 "metadata" => %{delivery_mentions: mentions}
               }
             )

    assert {:error, {:bad_request, "invalid message mentions"}} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "provider-command-mention-all",
                 "content" => [%{"type" => "text", "text" => "Unsafe"}],
                 "mentions" => %{"mode" => "all", "users" => []}
               }
             )

    assert {:error, {:bad_request, "invalid or duplicate message mentions"}} =
             ConversationServer.send_provider_participant_message(
               group_id,
               conversation_id,
               participant_id,
               %{
                 "idempotency_key" => "provider-command-duplicate-mentions",
                 "content" => [%{"type" => "text", "text" => "Duplicate"}],
                 "mentions" => %{
                   "mode" => "users",
                   "users" => [
                     %{"user_id" => "ou_alice", "name" => "Alice"},
                     %{"user_id" => "ou_alice", "name" => "Forged Alice"}
                   ]
                 }
               }
             )
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

  test "pin listing propagates canonical conversation read outages", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "Pinned during outage"
             })

    assert {:ok, _pin} =
             ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)

    assert :ok =
             SalixStore.S3.Fake.set_fault(
               {:fail, 503, :get, Keys.ctl_group_conversation(group_id, conversation_id)}
             )

    assert {:error, {:http, 503}} =
             Conversations.list_conversation_pins(group_id, tenant_id)
  end

  test "pin reads are bounded and expose an opaque continuation cursor", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    conversation_ids =
      for index <- 1..3 do
        assert {:ok, %{"conversation_id" => conversation_id}} =
                 SalixIM.ConversationInput.create_group_conversation(group_id, %{
                   "kind" => "agent_task",
                   "title" => "Paged pin #{index}"
                 })

        assert {:ok, _pin} =
                 ConversationServer.pin_conversation(group_id, conversation_id, tenant_id)

        Process.sleep(2)
        conversation_id
      end

    assert {:ok,
            %{
              "data" => first_page,
              "has_more" => true,
              "next_cursor" => next_cursor
            }} =
             Conversations.list_conversation_pins(group_id, tenant_id, limit: 2)

    assert length(first_page) == 2
    assert is_binary(next_cursor)

    assert Enum.map(first_page, & &1["conversation_id"]) ==
             conversation_ids |> Enum.reverse() |> Enum.take(2)

    assert {:ok, %{"data" => second_page, "has_more" => false}} =
             Conversations.list_conversation_pins(group_id, tenant_id,
               limit: 2,
               cursor: next_cursor
             )

    assert length(second_page) == 1

    assert Enum.sort(Enum.map(first_page ++ second_page, & &1["conversation_id"])) ==
             Enum.sort(conversation_ids)

    oldest = List.first(conversation_ids)
    Process.sleep(2)
    assert {:ok, _pin} = ConversationServer.pin_conversation(group_id, oldest, tenant_id)

    assert {:ok, %{"data" => [%{"conversation_id" => ^oldest}]}} =
             Conversations.list_conversation_pins(group_id, tenant_id, limit: 1)

    assert {:error, {:bad_request, "limit must be <= 200"}} =
             Conversations.list_conversation_pins(group_id, tenant_id, limit: 201)

    assert {:error, {:bad_request, "invalid cursor"}} =
             Conversations.list_conversation_pins(group_id, tenant_id, cursor: "not-a-cursor")
  end

  test "conversation server serializes duplicate appends by client request id", %{
    group_id: group_id,
    router_id: router_id,
    worker_id: worker_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Owner duplicate",
               "participants" => [
                 user_participant(now),
                 agent_participant(router_id, "router", now),
                 agent_participant(worker_id, "worker", now)
               ],
               "created_at" => now,
               "updated_at" => now
             })

    tasks =
      for _ <- 1..10 do
        Task.async(fn ->
          ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
            "kind" => "message",
            "content" => "same message",
            "client_request_id" => "same-request",
            "created_at" => now + 1
          })
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, %{"inserted" => true}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{"inserted" => false}}, &1)) == 9

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    [message] = messages
    message_id = message["message_id"]
    assert Ids.valid_message_id?(message_id)

    for agent <- [router_id, worker_id] do
      assert eventually_value(fn -> admitted?(group_id, conversation_id, message_id, agent) end)
    end
  end

  test "concurrent creates share one client request identity across owner restart", %{
    group_id: group_id
  } do
    attrs = %{
      "title" => "One logical create",
      "client_request_id" => "concurrent-create-request",
      "participants" => [user_participant(System.system_time(:millisecond))]
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
               "participants" => [user_participant(System.system_time(:millisecond))]
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
    Application.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)
    Application.put_env(:salix_im, :capture_agent_delivery_test_pid, self())
    on_exit(fn -> Application.delete_env(:salix_im, :capture_agent_delivery_test_pid) end)

    now = System.system_time(:millisecond)

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

    assert_receive {:captured_agent_delivery, ^worker_id, _payload, _opts}, 2_000
    refute_receive {:captured_agent_delivery, ^router_id, _payload, _opts}, 200

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

    refute_receive {:captured_agent_delivery, _agent_id, _payload, _opts}, 300

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
    now = System.system_time(:millisecond)

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

  test "participant state commands remain responsive while external delivery is blocked", %{
    group_id: group_id,
    worker_id: worker_id
  } do
    now = System.system_time(:millisecond)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Non-blocking participant owner",
               "participants" => [
                 user_participant(now),
                 blocking_provider_participant(group_id, worker_id, now)
               ]
             })

    Application.put_env(:salix_im, :slack_conversation_delivery_mod, BlockingProviderDelivery)
    Application.put_env(:salix_im, :blocking_agent_delivery_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:salix_im, :blocking_agent_delivery_test_pid)
    end)

    assert [%{"participant_id" => participant_id}] =
             group_id
             |> all_test_participants(conversation_id)
             |> Enum.filter(&(&1["actor_type"] == "provider"))

    assert {:ok, participant_actor} =
             SalixIM.ConversationFleet.ensure_participant_started(
               group_id,
               conversation_id,
               participant_id
             )

    assert {:ok, %{"delivery_status" => "queued"}} =
             ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
               "actor_type" => "user",
               "user_id" => "current",
               "content" => "block external delivery only",
               "client_request_id" => "blocked-external-delivery"
             })

    assert_receive {:agent_delivery_blocked, delivery_worker}, 2_000
    worker_ref = Process.monitor(delivery_worker)

    cursor_update =
      Task.async(fn ->
        SalixIM.ConversationParticipantActor.advance_delivery_cursor(participant_actor, 10_000)
      end)

    assert {:ok, %{"delivery_cursor_seq" => 10_000}} = Task.await(cursor_update, 1_000)

    # Monitor requests are asynchronous; synchronize with the live worker before
    # the owner's exit can overtake the monitor signal from this process.
    assert {:monitored_by, monitors} = Process.info(delivery_worker, :monitored_by)
    assert self() in monitors

    Process.exit(participant_actor, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^delivery_worker, :killed}, 1_000
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp drain_task_list_invalidations(group_id, conversation_id, acc \\ []) do
    receive do
      {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conversation_id, version} ->
        drain_task_list_invalidations(group_id, conversation_id, [version | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp blocking_provider_participant(group, worker, now) do
    previous = Application.get_env(:salix_im, :slack_conversation_delivery_mod)
    on_exit(fn -> restore(:salix_im, :slack_conversation_delivery_mod, previous) end)
    connect = Ids.new_connect_id()

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(group, connect), %{
        "group_id" => group,
        "provider" => "slack",
        "inbound_agent_id" => worker
      })

    %{
      "actor_type" => "provider",
      "provider" => "slack",
      "target_key" => connect,
      "payload" => %{"connect_id" => connect, "channel_id" => "C-blocked"},
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"},
      "created_at" => now,
      "updated_at" => now
    }
  end

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

  defp append_bft_provider_user_message(
         group_id,
         conversation_id,
         participant_id,
         user_id,
         request_id
       ) do
    ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
      "actor_type" => "provider_user",
      "provider" => "bft",
      "participant_id" => participant_id,
      "user_id" => user_id,
      "display_name" => user_id,
      "content" => user_id,
      "client_request_id" => request_id
    })
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

  # A plain Task whose Worker session the TaskWorkerWatch is
  # already subscribed to; returns the ids the watch tests key on.
  defp start_watched_plain_task(group_id, router_id, worker_id, request_id, configure \\ true) do
    if configure do
      start_supervised!(TaskSessionActivity)
      start_supervised!(SalixIM.TestSupport.Fleet.Cleanup)
      Application.put_env(:salix_im, :session_activity_mod, TaskSessionActivity)
      Application.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)
      Application.put_env(:salix_im, :capture_agent_delivery_test_pid, self())

      on_exit(fn ->
        SalixIM.TestSupport.Fleet.stop_all!()
        Application.delete_env(:salix_im, :capture_agent_delivery_test_pid)
        Application.delete_env(:salix_im, :task_worker_watch_fail_next_append)
      end)
    end

    assert {:ok, %{"conversation_id" => conversation_id}} =
             create_task_conversation(group_id, router_id, worker_id, %{
               "content" => "Summarize the thread and report back.",
               "client_request_id" => request_id
             })

    assert_receive {:captured_agent_delivery, ^worker_id, _command, _opts}, 2_000

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    worker = Enum.find(participants, &(&1["agent_id"] == worker_id))
    session_id = get_in(worker, ["payload", "session_id"])
    assert {:ok, owner} = ConversationPlacement.ensure_started(group_id, conversation_id)
    assert {:ok, watch} = SalixIM.ConversationActor.task_worker_watch(owner)

    assert eventually_value(fn ->
             TaskSessionActivity.subscribed?(worker_id, session_id, watch)
           end)

    {conversation_id, session_id, watch}
  end

  defp create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs) do
    command = String.trim(attrs["content"])
    created_at = attrs["created_at"] || System.system_time(:millisecond)

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
    app_id = "A-supervision-#{System.unique_integer([:positive])}"

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
               "updated_at" => System.system_time(:second)
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

  defp conversation_list_index_key(group_id, conversation) do
    timestamp =
      case conversation["updated_at"] || conversation["created_at"] || 0 do
        value when is_integer(value) and value >= 0 -> value
        value -> String.to_integer(to_string(value))
      end
      |> min(9_999_999_999_999_999_999)

    sort_key =
      (9_999_999_999_999_999_999 - timestamp)
      |> Integer.to_string()
      |> String.pad_leading(19, "0")

    Keys.ctl_group_conversation_list_entry(
      group_id,
      sort_key,
      conversation["conversation_id"] || ""
    )
  end

  defp conversation_list_index_records(group_id, conversation_id) do
    prefix = Keys.ctl_group_conversation_list_prefix(group_id)

    SalixStore.S3.Fake.dump()
    |> Enum.flat_map(fn
      {key, %{body: body}} ->
        with true <- String.starts_with?(key, prefix),
             {:ok, %{"conversation_id" => ^conversation_id} = record} <- Jason.decode(body) do
          [{key, record}]
        else
          _ -> []
        end

      _entry ->
        []
    end)
  end

  defp create_reviewable_task!(group_id, router_id, worker_id, request_suffix) do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             create_task_conversation(
               group_id,
               router_id,
               worker_id,
               %{
                 "title" => "Review index repair",
                 "content" => "build the requested artifact",
                 "client_request_id" => "#{request_suffix}-task"
               }
             )

    assert {:ok, %{"seq" => 2}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               worker_id,
               %{
                 "content" => "The artifact is ready.",
                 "client_request_id" => "#{request_suffix}-result",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, %{"status" => "ready_for_review", "updated_at" => review_version}} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "status" => "ready_for_review"
             })

    {conversation_id, review_version}
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

  defp group_search_job_count(group_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM conversation_search_jobs " <>
          "WHERE writer_generation = 'test-search-generation' " <>
          "AND agent_group_id = $1",
        [group_id]
      )

    count
  end

  defp search_job(group_id, conversation_id) do
    case Repo.query!(
           "SELECT operation FROM conversation_search_jobs " <>
             "WHERE writer_generation = 'test-search-generation' " <>
             "AND agent_group_id = $1 AND conversation_id = $2",
           [group_id, conversation_id]
         ).rows do
      [[operation]] -> %{"operation" => operation}
      [] -> nil
    end
  end

  defp eventually_value(fun, retries \\ 100)
  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, retries) do
    case fun.() do
      nil ->
        Process.sleep(20)
        eventually_value(fun, retries - 1)

      false ->
        Process.sleep(20)
        eventually_value(fun, retries - 1)

      value ->
        value
    end
  end
end
