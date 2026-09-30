defmodule SalixMeet.RuntimeTest do
  use ExUnit.Case, async: false

  alias SalixMeet.{Runtime, RuntimeEvents, Store}
  alias SalixAgent.AgentWorkspace
  alias SalixAgent.InternalSessionActor
  alias SalixAgent.InternalSessionStore
  alias SalixStore.{Ids, Keys, S3}
  alias __MODULE__.FakeMeetingProvider

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_provider = Application.get_env(:salix_meet, :provider_mod)
    prev_agent_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    prev_dispatch = Application.get_env(:salix_meet, :meeting_dispatch_mod)
    prev_dispatch_test_pid = Application.get_env(:salix_meet, :meeting_dispatch_test_pid)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    Application.put_env(:salix_meet, :provider_mod, __MODULE__.FakeMeetingProvider)
    Application.put_env(:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime)

    ensure_fake_s3_started!()
    SalixStore.S3.Fake.reset()
    ensure_mock_llm_started!()
    ensure_fake_provider_started!()
    FakeMeetingProvider.reset()
    stop_all_agents()

    on_exit(fn ->
      stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_s3)
      restore_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_meet, :provider_mod, prev_provider)
      restore_env(:salix_meet, :agent_runtime_mod, prev_agent_runtime)
      restore_env(:salix_meet, :meeting_dispatch_mod, prev_dispatch)
      restore_env(:salix_meet, :meeting_dispatch_test_pid, prev_dispatch_test_pid)
    end)

    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    put_group!(tenant_id, group_id)

    {:ok, tenant_id: tenant_id, group_id: group_id}
  end

  defmodule FakeMeetingProvider do
    use Agent

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def publish(payload) do
      Agent.update(__MODULE__, &[payload | &1])
      {:ok, %{"published" => true}}
    end

    def published, do: Agent.get(__MODULE__, &Enum.reverse/1)
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
  end

  defmodule CaptureMeetingDispatch do
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(_payload), do: {:ok, %{"accepted" => true}}

    @impl true
    def send_chat(payload) do
      send(Application.fetch_env!(:salix_meet, :meeting_dispatch_test_pid), payload)
      {:ok, payload}
    end

    @impl true
    def session_status(_payload), do: {:ok, :unavailable}
  end

  defmodule BarrierAgentRuntime do
    @behaviour SalixMeet.Ports.AgentRuntime

    def ensure_agent(request), do: SalixMeet.TestAgentRuntime.ensure_agent(request)
    def verify_agent(request), do: SalixMeet.TestAgentRuntime.verify_agent(request)

    def prepare_workspace_write(agent_id, path, data),
      do: SalixMeet.TestAgentRuntime.prepare_workspace_write(agent_id, path, data)

    def stream_workspace_write(agent_id, env_id, path, source_path) do
      test_pid = Application.fetch_env!(:salix_meet, :runtime_barrier_test_pid)
      send(test_pid, {:artifact_prepare_waiting, self()})

      receive do
        :release_artifact_prepare ->
          SalixMeet.TestAgentRuntime.stream_workspace_write(agent_id, env_id, path, source_path)
      end
    end

    def discard_prepared_workspace_write(event),
      do: SalixAgent.AgentWorkspace.discard_prepared_write(event)

    def stat_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.stat_workspace(agent_id, path)

    def read_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.read_workspace(agent_id, path)

    def event_committed?(agent_id, session_id, source_id),
      do: SalixMeet.TestAgentRuntime.event_committed?(agent_id, session_id, source_id)

    def workspace_event_committed?(agent_id, session_id, source_id),
      do: SalixMeet.TestAgentRuntime.workspace_event_committed?(agent_id, session_id, source_id)

    def commit_event(request), do: SalixMeet.TestAgentRuntime.commit_event(request)
  end

  defmodule LateAmbiguousCommitAgentRuntime do
    @behaviour SalixMeet.Ports.AgentRuntime

    def ensure_agent(request), do: SalixMeet.TestAgentRuntime.ensure_agent(request)
    def verify_agent(request), do: SalixMeet.TestAgentRuntime.verify_agent(request)

    def prepare_workspace_write(agent_id, path, data),
      do: SalixMeet.TestAgentRuntime.prepare_workspace_write(agent_id, path, data)

    def stream_workspace_write(agent_id, env_id, path, source_path),
      do: SalixMeet.TestAgentRuntime.stream_workspace_write(agent_id, env_id, path, source_path)

    def discard_prepared_workspace_write(event),
      do: SalixMeet.TestAgentRuntime.discard_prepared_workspace_write(event)

    def stat_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.stat_workspace(agent_id, path)

    def read_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.read_workspace(agent_id, path)

    def event_committed?(agent_id, session_id, source_id),
      do: SalixMeet.TestAgentRuntime.event_committed?(agent_id, session_id, source_id)

    def workspace_event_committed?(agent_id, session_id, source_id),
      do: SalixMeet.TestAgentRuntime.workspace_event_committed?(agent_id, session_id, source_id)

    def commit_event(request) do
      send(
        Application.fetch_env!(:salix_meet, :runtime_late_commit_test_pid),
        {:late_ambiguous_commit, request}
      )

      {:error, {:ambiguous, :timeout}}
    end
  end

  test "ensure_for_group creates a hidden group-owned meeting agent", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)

    assert meeting_agent["tenant_id"] == tenant_id
    assert meeting_agent["group_id"] == group_id
    assert meeting_agent["status"] == "idle"
    assert SalixStore.Ids.valid_agent_id_for_group?(meeting_agent["meeting_agent_id"], group_id)
    assert Ids.valid_session_id?(meeting_agent["meeting_session_id"])
    assert meeting_agent["billing_owner"]["billing_account_id"] == "ba-meeting-" <> group_id

    {:ok, agent} = read_json(Keys.ctl_agent(meeting_agent["meeting_agent_id"]))
    assert agent["tenant_id"] == tenant_id
    assert agent["group_id"] == group_id
    assert agent["role"] == "meeting"
    assert agent["purpose"] == "meeting"
    assert agent["hidden"] == true
    assert agent["template_id"] == "__internal_meeting_agent"

    {:ok, template} = read_json(Keys.ctl_template(agent["template_id"]))
    assert template["hidden"] == true
    assert template["purpose"] == "meeting"
    assert template["provider"] == "internal/noop"

    {:ok, group} = read_json(Keys.ctl_group(group_id))
    refute Map.has_key?(group, "router_agent_id")

    assert {:ok, session} =
             InternalSessionStore.read(
               meeting_agent["meeting_agent_id"],
               meeting_agent["meeting_session_id"]
             )

    assert SalixAgent.InternalSession.get(session, :hidden) == true
  end

  test "default chat dispatch identity is stable across retries", %{tenant_id: tenant_id} do
    meeting_id = "meeting-chat-identity"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "attempt" => 2,
                 "copilot" => %{"caption_cursor" => 3, "chat_cursor" => 4},
                 "group_id" => "group-chat-identity",
                 "runtime_source" => "compute_workload",
                 "runtime_policy" => "compute_workload",
                 "compute_environment_id" => "environment-chat-identity",
                 "workload_id" => "workload-chat-identity",
                 "tenant_id" => tenant_id
               }
             )

    Application.put_env(:salix_meet, :meeting_dispatch_mod, CaptureMeetingDispatch)
    Application.put_env(:salix_meet, :meeting_dispatch_test_pid, self())

    assert {:ok, first} = Runtime.send_chat(meeting_id, "same answer")
    assert_receive first_payload
    assert first_payload["message_id"] == first["message_id"]
    assert first_payload["tenant_id"] == tenant_id

    assert {:ok, second} = Runtime.send_chat(meeting_id, "same answer")
    assert_receive second_payload
    assert second_payload["message_id"] == first_payload["message_id"]
    assert second["message_id"] == first["message_id"]
  end

  test "start heartbeat and stop update durable status through the meeting agent owner", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, running} = Runtime.start_for_group(tenant_id, group_id, now: 1_000)
    agent_id = running["meeting_agent_id"]

    assert running["status"] == "running"
    assert running["started_at"] == 1_000
    assert running["heartbeat_at"] == 1_000
    assert SalixAgent.Fleet.running?(agent_id)

    assert {:ok, heartbeat} = Runtime.heartbeat(tenant_id, group_id, now: 2_000)
    assert heartbeat["status"] == "running"
    assert heartbeat["heartbeat_at"] == 2_000
    assert SalixAgent.Fleet.running?(agent_id)

    assert {:ok, stopped} = Runtime.stop_for_group(tenant_id, group_id, now: 3_000)
    assert stopped["status"] == "stopped"
    assert stopped["stopped_at"] == 3_000
    assert SalixAgent.Fleet.running?(agent_id)
  end

  test "meeting inbound commits only to the meeting agent session", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    event = %{
      "provider" => "slack",
      "event_id" => "evt-1",
      "meet_url" => "https://meet.google.com/abc-defg-hij",
      "source" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
    }

    assert {:ok, delivered} = Runtime.deliver_event(tenant_id, group_id, event)
    assert delivered["status"] == "created"

    meeting_agent = delivered["meeting_agent"]
    assert meeting_session_has?(meeting_agent, "evt-1")

    assert {:ok, session} =
             SalixAgent.InternalSessionStore.read(
               meeting_agent["meeting_agent_id"],
               meeting_agent["meeting_session_id"]
             )

    assert %{
             "billing_account_id" => billing_account_id,
             "entrypoint" => "meeting_runtime",
             "actor_type" => "system",
             "salix_agent_id" => salix_agent_id
           } = SalixAgent.InternalSession.get(session, :billing_context)

    assert billing_account_id == "ba-meeting-" <> group_id
    assert salix_agent_id == meeting_agent["meeting_agent_id"]
    assert SalixAgent.Fleet.running?(meeting_agent["meeting_agent_id"])

    assert [_] =
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(
                 meeting_agent["meeting_agent_id"],
                 meeting_agent["meeting_session_id"]
               )
             )

    assert {:ok, []} = S3.list_all(Keys.ctl_group_conversations_prefix(group_id))
    assert {:ok, []} = S3.list_all("ctl/bridge_conversations/#{tenant_id}/")
    assert {:ok, []} = S3.list_all("ctl/bridge/")
  end

  test "a committed event replays Meeting Store projection exactly once after its ACK is lost", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    previous_storage_authorization =
      Application.get_env(:salix_agent, :storage_authorization_mod)

    Application.put_env(
      :salix_agent,
      :storage_authorization_mod,
      SalixAgent.StorageAuthorization.Noop
    )

    on_exit(fn ->
      restore_env(
        :salix_agent,
        :storage_authorization_mod,
        previous_storage_authorization
      )
    end)

    assert {:ok, meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-replay-#{System.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "status" => "active",
                 "artifact_root" => RuntimeEvents.artifact_root(meeting_id)
               }
             )

    source_path =
      Path.join(System.tmp_dir!(), "meeting-replay-#{System.unique_integer([:positive])}.txt")

    File.write!(source_path, "one transcript")
    on_exit(fn -> File.rm(source_path) end)

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-replay-1",
      "meeting_id" => meeting_id,
      "status" => "done",
      "captions" => [%{"speaker" => "Ann", "text" => "hello"}],
      "chats" => [%{"sender" => "Bob", "text" => "ship it"}],
      "artifacts" => [
        %{
          "kind" => "transcript",
          "filename" => "transcript.txt",
          "content_type" => "text/plain",
          "src_path" => source_path
        }
      ]
    }

    source_id = "meeting:#{tenant_id}:#{group_id}:runtime-replay-1"
    assert {:ok, prepared} = RuntimeEvents.prepare(meeting_agent, event, "env-origin")

    assert {:ok, :created} =
             SalixMeet.TestAgentRuntime.commit_event(%{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "agent_id" => meeting_agent["meeting_agent_id"],
               "session_id" => meeting_agent["meeting_session_id"],
               "source_id" => source_id,
               "event" => event,
               "billing_context" => %{},
               "vfs_events" => prepared.vfs_events,
               "now" => 1
             })

    File.rm!(source_path)

    artifact_path = RuntimeEvents.artifact_root(meeting_id) <> "/transcript.txt"

    :ok =
      SalixStore.S3.Fake.set_fault(
        {:fail, 503, :get, Keys.agent_workspace_state(meeting_agent["meeting_agent_id"])}
      )

    assert {:error, {:artifact_recovery_failed, ^artifact_path, {:http, 503}}} =
             Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

    assert {:ok, unprojected_doc, _etag} = Store.get(meeting_id)
    refute Map.has_key?(unprojected_doc["state"], "artifacts")
    refute Map.has_key?(unprojected_doc["state"], "captions")
    refute Map.has_key?(unprojected_doc["state"], "chats")

    assert {:ok, %{"status" => "duplicate"}} =
             Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

    assert {:ok, state_doc, _etag} = Store.get(meeting_id)
    assert [%{"speaker" => "Ann", "text" => "hello"}] = state_doc["state"]["captions"]
    assert [%{"sender" => "Bob", "text" => "ship it"}] = state_doc["state"]["chats"]

    assert {:ok, "one transcript"} =
             AgentWorkspace.read(
               meeting_agent["meeting_agent_id"],
               artifact_path
             )

    assert state_doc["state"]["artifacts"]["transcript"]["path"] ==
             artifact_path

    assert {:ok, %{"status" => "duplicate"}} =
             Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

    assert {:ok, replayed_doc, _etag} = Store.get(meeting_id)
    assert length(replayed_doc["state"]["captions"]) == 1
    assert length(replayed_doc["state"]["chats"]) == 1
  end

  test "a staged workspace artifact completes its source receipt after the source disappears", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    previous_storage_authorization =
      Application.get_env(:salix_agent, :storage_authorization_mod)

    Application.put_env(
      :salix_agent,
      :storage_authorization_mod,
      SalixAgent.StorageAuthorization.Noop
    )

    on_exit(fn ->
      restore_env(
        :salix_agent,
        :storage_authorization_mod,
        previous_storage_authorization
      )
    end)

    assert {:ok, meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-workspace-replay-#{System.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "status" => "active",
                 "artifact_root" => RuntimeEvents.artifact_root(meeting_id)
               }
             )

    source_path =
      Path.join(
        System.tmp_dir!(),
        "meeting-workspace-replay-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(source_path, "durable transcript")
    on_exit(fn -> File.rm(source_path) end)

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-workspace-replay-1",
      "meeting_id" => meeting_id,
      "status" => "done",
      "captions" => [%{"speaker" => "Ann", "text" => "recover me"}],
      "artifacts" => [
        %{
          "kind" => "transcript",
          "filename" => "transcript.txt",
          "content_type" => "text/plain",
          "src_path" => source_path
        }
      ]
    }

    source_id = "meeting:#{tenant_id}:#{group_id}:runtime-workspace-replay-1"
    agent_id = meeting_agent["meeting_agent_id"]
    session_id = meeting_agent["meeting_session_id"]

    :ok =
      SalixStore.S3.Fake.set_fault(
        {:fail, 503, :put, Keys.agent_internal_runtime_session(agent_id, session_id)}
      )

    assert {:error, {:http, 503}} =
             Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

    assert {:ok, false} =
             SalixAgent.MeetingRuntime.event_committed?(agent_id, session_id, source_id)

    assert {:ok, true} =
             SalixAgent.MeetingRuntime.workspace_event_committed?(
               agent_id,
               session_id,
               source_id
             )

    File.rm!(source_path)

    assert {:ok, %{"status" => "created"}} =
             Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

    assert {:ok, true} =
             SalixAgent.MeetingRuntime.event_committed?(agent_id, session_id, source_id)

    artifact_path = RuntimeEvents.artifact_root(meeting_id) <> "/transcript.txt"
    assert {:ok, "durable transcript"} = AgentWorkspace.read(agent_id, artifact_path)

    assert {:ok, state_doc, _etag} = Store.get(meeting_id)
    assert state_doc["state"]["artifacts"]["transcript"]["path"] == artifact_path

    assert [%{"speaker" => "Ann", "text" => "recover me"} = caption] =
             state_doc["state"]["captions"]

    assert is_binary(caption["runtime_event_id"])

    assert {:ok, %{"status" => "duplicate"}} =
             Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

    assert {:ok, replayed_doc, _etag} = Store.get(meeting_id)
    assert length(replayed_doc["state"]["captions"]) == 1
  end

  test "a definite workspace commit failure discards prepared artifacts before retry", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    with_noop_storage_authorization(fn ->
      assert {:ok, meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)
      agent_id = meeting_agent["meeting_agent_id"]
      meeting_id = "mtg-commit-retry-#{System.unique_integer([:positive])}"
      source_path = temp_artifact!("commit-retry", "retry bytes")

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "status" => "active",
                   "artifact_root" => RuntimeEvents.artifact_root(meeting_id)
                 }
               )

      event = artifact_event(meeting_id, "commit-retry-event", source_path)

      :ok =
        S3.Fake.set_fault({:fail, 503, :put, Keys.agent_workspace_state(agent_id)})

      assert {:error, {:http, 503}} =
               Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

      assert {:ok, %{objects: []}} = S3.list("blobs/")
      assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())

      assert {:ok, %{"status" => "created"}} =
               Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

      assert {:ok, %{objects: [_]}} = S3.list("blobs/")
      assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
    end)
  end

  test "an ambiguous workspace commit retains prepared bodies until a late commit is reconciled",
       %{
         tenant_id: tenant_id,
         group_id: group_id
       } do
    with_noop_storage_authorization(fn ->
      previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
      previous_pid = Application.get_env(:salix_meet, :runtime_late_commit_test_pid)
      Application.put_env(:salix_meet, :agent_runtime_mod, LateAmbiguousCommitAgentRuntime)
      Application.put_env(:salix_meet, :runtime_late_commit_test_pid, self())

      try do
        assert {:ok, meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)
        agent_id = meeting_agent["meeting_agent_id"]
        meeting_id = "mtg-late-commit-#{System.unique_integer([:positive])}"
        source_path = temp_artifact!("late-commit", "late durable transcript")

        assert {:ok, _doc, _etag} =
                 Store.create_once(meeting_id,
                   state: %{
                     "tenant_id" => tenant_id,
                     "group_id" => group_id,
                     "status" => "active",
                     "artifact_root" => RuntimeEvents.artifact_root(meeting_id)
                   }
                 )

        event = artifact_event(meeting_id, "late-commit-event", source_path)

        assert {:error, {:ambiguous, :timeout}} =
                 Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

        assert_receive {:late_ambiguous_commit, request}, 2_000
        assert {:ok, %{objects: [%{key: blob_key}]}} = S3.list("blobs/")
        assert {:ok, %{objects: [_intent]}} = S3.list(Keys.prepared_blob_cleanup_prefix())

        assert {:ok, :created} = SalixMeet.TestAgentRuntime.commit_event(request)
        assert {:ok, _} = S3.head(blob_key)
        assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())

        File.rm!(source_path)

        assert {:ok, %{"status" => "duplicate"}} =
                 Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")

        artifact_path = RuntimeEvents.artifact_root(meeting_id) <> "/transcript.txt"
        assert {:ok, "late durable transcript"} = AgentWorkspace.read(agent_id, artifact_path)

        assert {:ok, state_doc, _etag} = Store.get(meeting_id)
        assert state_doc["state"]["artifacts"]["transcript"]["path"] == artifact_path
      after
        restore_env(:salix_meet, :agent_runtime_mod, previous_runtime)
        restore_env(:salix_meet, :runtime_late_commit_test_pid, previous_pid)
      end
    end)
  end

  test "artifact batch path conflicts and traversal are rejected before any source read", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    with_noop_storage_authorization(fn ->
      assert {:ok, _meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)
      meeting_id = "mtg-path-admission-#{System.unique_integer([:positive])}"
      transcript_path = temp_artifact!("path-transcript", "transcript bytes")
      audio_path = temp_artifact!("path-audio", "audio bytes")

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "status" => "active",
                   "artifact_root" => RuntimeEvents.artifact_root(meeting_id)
                 }
               )

      conflicting = %{
        "type" => "meeting_runtime_update",
        "event_id" => "path-conflict",
        "meeting_id" => meeting_id,
        "status" => "done",
        "artifacts" => [
          %{
            "kind" => "transcript",
            "filename" => "recording.bin",
            "src_path" => transcript_path
          },
          %{"kind" => "audio", "filename" => "recording.bin", "src_path" => audio_path}
        ]
      }

      assert {:error, :artifact_batch_conflict} =
               Runtime.deliver_event(tenant_id, group_id, conflicting,
                 origin_env_id: "env-origin"
               )

      traversing = put_in(conflicting, ["event_id"], "path-traversal")
      traversing = put_in(traversing, ["artifacts", Access.at(1), "filename"], "../audio.mp3")

      assert {:error, :artifact_path_invalid} =
               Runtime.deliver_event(tenant_id, group_id, traversing, origin_env_id: "env-origin")

      assert {:ok, %{objects: []}} = S3.list("blobs/")
      assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
    end)
  end

  test "concurrent same-source preparations keep only the manifest-owned blob", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    with_noop_storage_authorization(fn ->
      previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
      previous_pid = Application.get_env(:salix_meet, :runtime_barrier_test_pid)
      Application.put_env(:salix_meet, :agent_runtime_mod, BarrierAgentRuntime)
      Application.put_env(:salix_meet, :runtime_barrier_test_pid, self())

      try do
        assert {:ok, _meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)
        meeting_id = "mtg-concurrent-#{System.unique_integer([:positive])}"
        source_path = temp_artifact!("concurrent", "same bytes")

        assert {:ok, _doc, _etag} =
                 Store.create_once(meeting_id,
                   state: %{
                     "tenant_id" => tenant_id,
                     "group_id" => group_id,
                     "status" => "active",
                     "artifact_root" => RuntimeEvents.artifact_root(meeting_id)
                   }
                 )

        event = artifact_event(meeting_id, "concurrent-event", source_path)

        tasks =
          for _ <- 1..2 do
            Task.async(fn ->
              Runtime.deliver_event(tenant_id, group_id, event, origin_env_id: "env-origin")
            end)
          end

        waiting =
          for _ <- 1..2 do
            assert_receive {:artifact_prepare_waiting, pid}, 2_000
            pid
          end

        Enum.each(waiting, &send(&1, :release_artifact_prepare))

        statuses =
          tasks
          |> Enum.map(&Task.await(&1, 5_000))
          |> Enum.map(fn {:ok, %{"status" => status}} -> status end)
          |> Enum.sort()

        assert statuses == ["created", "created"]
        assert {:ok, %{objects: [_]}} = S3.list("blobs/")
        assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
      after
        restore_env(:salix_meet, :agent_runtime_mod, previous_runtime)
        restore_env(:salix_meet, :runtime_barrier_test_pid, previous_pid)
      end
    end)
  end

  test "ensure_for_group rejects an existing same-id ordinary agent state", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    put_meeting_slot!(tenant_id, group_id, agent_id)
    ordinary_session_id = Ids.new_session_id()

    create_agent_state!(agent_id, [
      %{"type" => "session_created", "session_id" => ordinary_session_id, "hidden" => false}
    ])

    assert {:error, {:invalid_meeting_agent, :missing_meeting_session}} =
             Runtime.ensure_for_group(tenant_id, group_id)

    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "ensure_for_group rejects an existing same-id agent record with wrong purpose", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    session_id = Ids.new_session_id()
    put_meeting_slot!(tenant_id, group_id, agent_id, session_id)

    put_agent_record!(
      tenant_id,
      group_id,
      agent_id,
      session_id,
      %{"purpose" => "default"}
    )

    create_valid_meeting_state!(agent_id, session_id)

    assert {:error, {:invalid_meeting_agent, :agent_record_purpose_mismatch}} =
             Runtime.ensure_for_group(tenant_id, group_id)

    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "ensure_for_group rejects an existing same-id agent record from another group", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    session_id = Ids.new_session_id()
    other_group_id = SalixStore.Ids.new_group_id(tenant_id)
    put_group!(tenant_id, other_group_id)
    put_meeting_slot!(tenant_id, group_id, agent_id, session_id)

    put_agent_record!(tenant_id, other_group_id, agent_id, session_id)
    create_valid_meeting_state!(agent_id, session_id)

    assert {:error, {:invalid_meeting_agent, :agent_record_group_mismatch}} =
             Runtime.ensure_for_group(tenant_id, group_id)

    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "ensure_for_group rejects an existing same-id agent record from another tenant", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    session_id = Ids.new_session_id()
    other_tenant_id = SalixStore.Ids.new_tenant_id()
    put_meeting_slot!(tenant_id, group_id, agent_id, session_id)

    put_agent_record!(other_tenant_id, group_id, agent_id, session_id)
    create_valid_meeting_state!(agent_id, session_id)

    assert {:error, {:invalid_meeting_agent, :agent_record_tenant_mismatch}} =
             Runtime.ensure_for_group(tenant_id, group_id)

    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "meeting role has no LLM tool policy surface" do
    assert [] = SalixAgent.ToolPolicy.specs_for("meeting")
  end

  test "meeting outbound uses the provider boundary", %{tenant_id: tenant_id, group_id: group_id} do
    {:ok, meeting_agent} = Runtime.ensure_for_group(tenant_id, group_id)

    payload = %{
      "provider" => "slack",
      "connect_id" => "slack-1",
      "target" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
      "kind" => "summary",
      "text" => "Meeting summary"
    }

    assert {:ok, %{"published" => true}} = Runtime.publish(meeting_agent, payload)
    assert [^payload] = FakeMeetingProvider.published()
  end

  defp put_group!(tenant_id, group_id) do
    now = System.system_time(:second)

    rec = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => "Meeting Group",
      "router_conversation_id" => SalixStore.Ids.new_conversation_id(),
      "billing_owner" => %{
        "billing_account_id" => "ba-meeting-" <> group_id,
        "surface" => "bridge",
        "product_owner_type" => "organization",
        "product_owner_id" => "org-meeting",
        "salix_tenant_id" => tenant_id,
        "salix_group_id" => group_id
      },
      "created_at" => now,
      "updated_at" => now
    }

    {:ok, _} = S3.put(Keys.ctl_group(group_id), Jason.encode!(rec), if_none_match: "*")
    rec
  end

  defp put_agent_record!(tenant_id, group_id, agent_id, _session_id, overrides \\ %{}) do
    now = System.system_time(:second)

    rec =
      Map.merge(
        %{
          "agent_id" => agent_id,
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "role" => "meeting",
          "name" => "__internal_meeting_agent",
          "system_prompt" => "",
          "router_system_prompt" => "",
          "template_id" => "__internal_meeting_agent",
          "provider" => "internal/noop",
          "db_namespace" => "salix:" <> agent_id,
          "status" => "idle",
          "purpose" => "meeting",
          "hidden" => true,
          "created_at" => now,
          "heartbeat_schedule_id" => SalixStore.Ids.new_schedule_id(),
          "tool_router_enabled" => false,
          "vm" => %{"enabled" => false}
        },
        overrides
      )

    {:ok, _} = S3.put(Keys.ctl_agent(agent_id), Jason.encode!(rec), if_none_match: "*")
    rec
  end

  defp put_meeting_slot!(tenant_id, group_id, agent_id, session_id \\ nil) do
    session_id = session_id || Ids.new_session_id()
    now = System.system_time(:second)

    record = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_agent_id" => agent_id,
      "meeting_session_id" => session_id,
      "status" => "idle",
      "billing_owner" => %{},
      "created_at" => now,
      "updated_at" => now
    }

    {:ok, _} = S3.put(Keys.meet_agent(group_id), Jason.encode!(record), if_none_match: "*")
  end

  defp create_valid_meeting_state!(agent_id, session_id) do
    create_agent_state!(agent_id, [
      %{
        "type" => "session_created",
        "session_id" => session_id,
        "name" => "__internal_meeting_agent",
        "hidden" => true,
        "created_at" => System.system_time(:second)
      }
    ])
  end

  defp create_agent_state!(agent_id, events) do
    {:ok, owned} = SalixStore.Agent.create(agent_id, Atom.to_string(node()), SalixAgent.State)

    case SalixStore.Agent.commit(owned, events) do
      {:ok, owned} ->
        SalixStore.Agent.release(owned)

      {:error, _} = err ->
        _ = SalixStore.Agent.release(owned)
        flunk("failed to seed agent state: #{inspect(err)}")
    end
  end

  defp read_json(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      other -> other
    end
  end

  defp meeting_session_has?(meeting_agent, text) do
    case SalixAgent.InternalSessionStore.read(
           meeting_agent["meeting_agent_id"],
           meeting_agent["meeting_session_id"]
         ) do
      {:ok, session} ->
        session
        |> SalixAgent.InternalSession.get(:messages)
        |> Enum.any?(&(to_string(Map.get(&1, :content)) =~ text))

      _ ->
        false
    end
  end

  defp with_noop_storage_authorization(fun) do
    previous = Application.get_env(:salix_agent, :storage_authorization_mod)

    Application.put_env(
      :salix_agent,
      :storage_authorization_mod,
      SalixAgent.StorageAuthorization.Noop
    )

    try do
      fun.()
    after
      restore_env(:salix_agent, :storage_authorization_mod, previous)
    end
  end

  defp temp_artifact!(label, body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "meeting-#{label}-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp artifact_event(meeting_id, event_id, source_path) do
    %{
      "type" => "meeting_runtime_update",
      "event_id" => event_id,
      "meeting_id" => meeting_id,
      "status" => "done",
      "artifacts" => [
        %{
          "kind" => "transcript",
          "filename" => "transcript.txt",
          "content_type" => "text/plain",
          "src_path" => source_path
        }
      ]
    }
  end

  defp ensure_fake_s3_started! do
    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end
  end

  defp ensure_mock_llm_started! do
    case Process.whereis(SalixAgent.LLM.Mock) do
      nil -> start_supervised!(SalixAgent.LLM.Mock)
      _pid -> :ok
    end
  end

  defp ensure_fake_provider_started! do
    case Process.whereis(FakeMeetingProvider) do
      nil -> start_supervised!(FakeMeetingProvider)
      _pid -> :ok
    end
  end

  defp stop_all_agents do
    if Process.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.uniq()
      |> Enum.each(&SalixAgent.Fleet.stop/1)
    end

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
