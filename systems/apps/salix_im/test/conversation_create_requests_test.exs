defmodule SalixIM.ConversationCreateRequestsTest do
  use SystemsClock.Case, async: false
  alias SalixIM.{ConversationCreateRequests, ConversationPGStore, ConversationServer}
  alias SalixStore.{Ids, Repo, S3}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    group = Ids.new_group_id(Ids.new_tenant_id())
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Create requests"})

    on_exit(fn ->
      Repo.query!("DELETE FROM salix_conversation_create_requests WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM conversation_log_recovery WHERE group_id = $1", [group])
      Repo.query!("DELETE FROM salix_conversations WHERE group_id = $1", [group])

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    {:ok, group: group}
  end

  test "the exact request returns the winning Task id and automatic placement", %{group: group} do
    first = %{
      "client_request_id" => "request",
      "title" => "Task",
      "automatic_task_place" => true,
      "runs_on" => %{"station_id" => "first"},
      "session_model" => "model"
    }

    assert {:ok, id, pinned} =
             ConversationServer.reserve_task_conversation(group, "delegator", "worker", first)

    assert pinned["runs_on"] == first["runs_on"]
    retry = Map.put(first, "runs_on", %{"station_id" => "second"})

    assert {:ok, ^id, retried} =
             ConversationServer.reserve_task_conversation(group, "delegator", "worker", retry)

    assert retried["runs_on"] == first["runs_on"]

    assert {:ok, %{"runs_on" => %{"station_id" => "first"}, "session_model" => "model"}} =
             ConversationServer.task_request_placement(group, "request")

    assert {:ok, %{"disposition" => "reserved_task_unavailable"}} =
             ConversationServer.lookup_task_create_request(group, "request")

    assert {:error, {:conflict, _}} =
             ConversationServer.reserve_task_conversation(
               group,
               "delegator",
               "worker",
               Map.put(first, "title", "Different")
             )
  end

  test "concurrent retries share one binding which survives canonical Conversation deletion", %{
    group: group
  } do
    candidate = candidate(group)

    results =
      1..4
      |> Task.async_stream(
        fn _ ->
          ConversationCreateRequests.reserve(
            Map.put(candidate, "conversation_id", Ids.new_conversation_id())
          )
        end,
        max_concurrency: 4
      )
      |> Enum.map(fn {:ok, {:ok, binding}} -> binding end)

    assert length(Enum.uniq(results)) == 1
    [binding | _] = results
    scope = ConversationPGStore.new(group, binding["conversation_id"])
    assert {:ok, :inserted, _, 1} = ConversationPGStore.create(scope, %{"kind" => "agent_task"})

    Repo.query!(
      "DELETE FROM salix_conversations WHERE group_id = $1 AND conversation_id = $2",
      [group, binding["conversation_id"]]
    )

    assert {:ok, ^binding} = ConversationCreateRequests.read(group, candidate["request_identity"])
    assert {:ok, ^binding} = ConversationCreateRequests.reserve(candidate)
    other_group = Ids.new_group_id(Ids.new_tenant_id())

    on_exit(fn ->
      Repo.query!("DELETE FROM salix_conversation_create_requests WHERE group_id = $1", [
        other_group
      ])
    end)

    assert {:ok, other} =
             ConversationCreateRequests.reserve(Map.put(candidate, "group_id", other_group))

    assert other["group_id"] == other_group
    assert {:ok, ^binding} = ConversationCreateRequests.read(group, candidate["request_identity"])
  end

  test "a disconnected insert stays unknown and a retry preserves the frozen identity and time",
       %{group: group} do
    candidate = candidate(group)

    Repo.query!("""
    CREATE FUNCTION conversation_create_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.group_id = '#{group}' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER conversation_create_disconnect BEFORE INSERT ON salix_conversation_create_requests FOR EACH ROW EXECUTE FUNCTION conversation_create_disconnect()"
    )

    on_exit(fn ->
      Repo.query!(
        "DROP TRIGGER IF EXISTS conversation_create_disconnect ON salix_conversation_create_requests"
      )

      Repo.query!("DROP FUNCTION IF EXISTS conversation_create_disconnect()")
    end)

    assert {:error, :commit_indeterminate} = ConversationCreateRequests.reserve(candidate)

    Repo.query!(
      "DROP TRIGGER conversation_create_disconnect ON salix_conversation_create_requests"
    )

    Repo.query!("DROP FUNCTION conversation_create_disconnect()")
    assert {:ok, binding} = ConversationCreateRequests.reserve(candidate)
    assert binding["conversation_id"] == candidate["conversation_id"]
    assert binding["created_at"] == candidate["created_at"]

    assert {:ok, ^binding} =
             ConversationCreateRequests.reserve(
               Map.put(candidate, "conversation_id", Ids.new_conversation_id())
             )

    assert {:error, {:conflict, _}} =
             ConversationCreateRequests.reserve(
               Map.put(candidate, "request_fingerprint", "changed")
             )
  end

  test "a failed binding read cannot appear to be an unreserved request", %{group: group} do
    Repo.query!(
      "ALTER TABLE salix_conversation_create_requests RENAME TO conversation_create_requests_unavailable"
    )

    on_exit(fn ->
      Repo.query!(
        "ALTER TABLE IF EXISTS conversation_create_requests_unavailable RENAME TO salix_conversation_create_requests"
      )
    end)

    assert {:error, :unavailable} = ConversationServer.task_request_placement(group, "missing")

    assert {:error, :unavailable} =
             ConversationServer.lookup_task_create_request(group, "missing")

    Repo.query!(
      "ALTER TABLE conversation_create_requests_unavailable RENAME TO salix_conversation_create_requests"
    )
  end

  defp candidate(group) do
    %{
      "group_id" => group,
      "request_identity" => "create",
      "conversation_id" => Ids.new_conversation_id(),
      "request_fingerprint" => "original fingerprint",
      "created_at" => 1_234,
      "task_placement" => %{"runs_on" => %{"station_id" => "original"}}
    }
  end
end
