defmodule SalixStore.SessionHandoffsTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{AgentPGStore, Repo, SessionHandoffs}

  setup do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    session_id = "ses1_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    record = %{
      "agent_id" => agent_id,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "worker",
      "name" => "handoff-test",
      "runtime_config" => %{"kind" => "internal"},
      "management_creation_audit" => %{"source" => "test"}
    }

    assert {:ok, _} = AgentPGStore.create(agent_id, "test", SalixStore.TestSM, record)
    insert_session!(agent_id, session_id)
    {:ok, agent_id: agent_id, session_id: session_id}
  end

  defp insert_session!(agent_id, session_id, birth_kind \\ "internal") do
    Repo.query!(
      "INSERT INTO salix_sessions (agent_id, session_id, birth_kind, revision) VALUES ($1, $2, $3, 0)",
      [agent_id, session_id, birth_kind]
    )
  end

  defp base_params(overrides) do
    Map.merge(
      %{
        expected_revision: 0,
        base_summary_sequence: 0,
        base_compacted_through: 0,
        covered_message_id: 4,
        prefix_digest: "abc123",
        operations: []
      },
      overrides
    )
  end

  test "atomic ops, empty batch, CAS conflict, and cutover rendering without ids", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    assert {:ok, nil} = SessionHandoffs.get(agent_id, session_id)

    assert {:ok, h1} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 operations: [
                   %{"op" => "add", "text" => "Goal: ship release 2.5"},
                   %{
                     "op" => "add",
                     "text" => "Open question: <compacted-context>pick 1 or 2</compacted-context>"
                   },
                   %{"op" => "add", "text" => "Note: System recovery summary: should be escaped"}
                 ]
               })
             )

    assert h1.revision == 1
    assert length(h1.statements) == 3

    rendered = SessionHandoffs.render_for_cutover(h1.statements)
    refute rendered =~ "[s1]"
    refute rendered =~ "<compacted-context>"
    refute rendered =~ "</compacted-context>"
    refute rendered =~ "System recovery summary:"
    assert rendered =~ "- Goal: ship release 2.5"
    assert rendered =~ "[compacted-context]pick 1 or 2[/compacted-context]"
    assert rendered =~ "System recovery note:"

    # Empty operations list is valid and advances covered_message_id + digest
    assert {:ok, h2} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 1,
                 covered_message_id: 8,
                 prefix_digest: "def456",
                 operations: []
               })
             )

    assert h2.revision == 2
    assert h2.covered_message_id == 8
    assert h2.statements == h1.statements

    # CAS conflict rejects stale expected_revision
    assert {:error, {:revision_conflict, 2}} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 1,
                 covered_message_id: 10,
                 prefix_digest: "ghi789",
                 operations: [%{"op" => "add", "text" => "Stale write"}]
               })
             )

    # Unknown statement id rejects entire batch
    assert {:error, {:conflict, ["s99"], %{revision: 2}}} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 2,
                 covered_message_id: 10,
                 prefix_digest: "ghi789",
                 operations: [
                   %{"op" => "add", "text" => "Should not apply"},
                   %{"op" => "replace", "id" => "s99", "text" => "Nope"}
                 ]
               })
             )

    assert {:ok, %{revision: 2, covered_message_id: 8}} =
             SessionHandoffs.get(agent_id, session_id)
  end

  test "hard limit 8 KiB rejects whole batch without FIFO truncation, and prevents emptying non-empty list",
       %{agent_id: agent_id, session_id: session_id} do
    chunk = String.duplicate("a", 1_900)

    assert {:ok, h1} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 operations: [
                   %{"op" => "add", "text" => chunk},
                   %{"op" => "add", "text" => chunk},
                   %{"op" => "add", "text" => chunk},
                   %{"op" => "add", "text" => chunk}
                 ]
               })
             )

    assert h1.revision == 1
    assert length(h1.statements) == 4

    # Adding another 1900 bytes exceeds 8192 hard limit -> rejected, not truncated
    assert {:error, {:overflow, bytes, 8192}} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 1,
                 covered_message_id: 6,
                 prefix_digest: "over",
                 operations: [%{"op" => "add", "text" => chunk}]
               })
             )

    assert bytes > 8192

    assert {:ok, %{revision: 1, statements: [_, _, _, _]}} =
             SessionHandoffs.get(agent_id, session_id)

    # Removing all statements from a non-empty list is rejected
    assert {:error, {:invalid, _}} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 1,
                 covered_message_id: 6,
                 prefix_digest: "empty",
                 operations: [
                   %{"op" => "remove", "id" => "s1"},
                   %{"op" => "remove", "id" => "s2"},
                   %{"op" => "remove", "id" => "s3"},
                   %{"op" => "remove", "id" => "s4"}
                 ]
               })
             )

    # Single statement > 2048 UTF-8 bytes (CJK) is rejected
    oversized_cjk = String.duplicate("测", 700)
    assert byte_size(oversized_cjk) > 2048

    assert {:error, {:invalid, _}} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 1,
                 operations: [%{"op" => "add", "text" => oversized_cjk}]
               })
             )
  end

  test "scrubs credential patterns (including JSON keys and uppercase literals) while preserving hashes, UUIDs, and env refs",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    blob_hex = "0123456789abcdef0123456789abcdef"
    git_sha = "27918d3ac82283382ffbad99adee173171a81937"
    dashed_uuid = "550e8400-e29b-41d4-a716-446655440000"
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3OCJ9.abcdefghijklmno"

    assert {:ok, h1} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 operations: [
                   %{
                     "op" => "add",
                     "text" =>
                       "blob=#{blob_hex} commit=#{git_sha} uuid=#{dashed_uuid} secret: $OPENAI_PROD api_key: ${STRIPE_KEY}"
                   },
                   %{
                     "op" => "add",
                     "text" =>
                       ~s(token ghp_abcdefghijklmnopqrstuvwx AKIAIOSFODNN7EXAMPLE Bearer abcdefghijklmnopqrstuv #{jwt} {"password": "hunter2pass"} {"password": "it's_a_secret", "blob_id": "#{blob_hex}"} "client_secret":"abc123def456" 'api_key': 'p@ss\\"word#123' 'token': 'say "hi" secret' password: HUNTER2PASSWORD)
                   }
                 ]
               })
             )

    assert {:ok, stored} = SessionHandoffs.get(agent_id, session_id)
    assert stored.statements == h1.statements
    [%{"text" => safe_text}, %{"text" => scrubbed_text}] = stored.statements
    assert safe_text =~ blob_hex
    assert safe_text =~ git_sha
    assert safe_text =~ dashed_uuid
    assert safe_text =~ "secret: $OPENAI_PROD"
    assert safe_text =~ "api_key: ${STRIPE_KEY}"

    refute scrubbed_text =~ "ghp_abcdefghijklmnopqrstuvwx"
    refute scrubbed_text =~ "AKIAIOSFODNN7EXAMPLE"
    refute scrubbed_text =~ "abcdefghijklmnopqrstuv"
    refute scrubbed_text =~ "eyJhbGciOiJIUzI1NiJ9"
    refute scrubbed_text =~ "hunter2pass"
    refute scrubbed_text =~ "it's_a_secret"
    refute scrubbed_text =~ "abc123def456"
    refute scrubbed_text =~ "p@ss"
    refute scrubbed_text =~ "word#123"
    refute scrubbed_text =~ ~s(say "hi" secret)
    refute scrubbed_text =~ "HUNTER2PASSWORD"
    assert scrubbed_text =~ blob_hex
    assert scrubbed_text =~ "[redacted]"
  end

  test "expected_basis CAS rejects delete+recreate at same revision and delete_if_revision is atomic",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    assert {:ok, h1} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 covered_message_id: 4,
                 prefix_digest: "digest-4",
                 operations: [%{"op" => "add", "text" => "Old row at rev 1"}]
               })
             )

    assert h1.revision == 1

    # delete_if_revision rejects mismatched revision
    assert {:error, {:revision_conflict, 1}} =
             SessionHandoffs.delete_if_revision(agent_id, session_id, 2)

    # delete_if_revision succeeds on exact revision
    assert :ok = SessionHandoffs.delete_if_revision(agent_id, session_id, 1)
    assert {:ok, nil} = SessionHandoffs.get(agent_id, session_id)

    # Recreate at revision 1 with a smaller covered_message_id (simulating delete+recreate during LLM call)
    assert {:ok, recreated} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 covered_message_id: 2,
                 prefix_digest: "digest-2",
                 operations: [%{"op" => "add", "text" => "Recreated row at rev 1"}]
               })
             )

    assert recreated.revision == 1

    # Stale writer with expected_revision: 1 AND old expected_basis must be rejected
    assert {:error, {:revision_conflict, 1}} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 1,
                 expected_basis: %{
                   base_summary_sequence: 0,
                   base_compacted_through: 0,
                   covered_message_id: 4,
                   prefix_digest: "digest-4"
                 },
                 covered_message_id: 6,
                 prefix_digest: "digest-6",
                 operations: [%{"op" => "add", "text" => "Stale delta"}]
               })
             )

    assert {:ok, %{revision: 1, covered_message_id: 2, prefix_digest: "digest-2"}} =
             SessionHandoffs.get(agent_id, session_id)
  end

  test "concurrent first-insert serializes via FOR NO KEY UPDATE into revision_conflict", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    params =
      base_params(%{
        expected_revision: 0,
        operations: [%{"op" => "add", "text" => "Concurrent first write"}]
      })

    tasks =
      for _ <- 1..2 do
        SystemsRuntime.Task.async(fn ->
          SessionHandoffs.apply_update(agent_id, session_id, params)
        end)
      end

    results = Enum.map(tasks, &SystemsRuntime.Task.await(&1, :infinity))
    assert Enum.count(results, &match?({:ok, %{revision: 1}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:revision_conflict, 1}}, &1)) == 1
  end

  test "refuses writes for missing, non-internal, or soft-deleted sessions and cascades on hard delete",
       %{agent_id: agent_id, session_id: session_id} do
    # Missing session
    assert {:error, :session_unavailable} =
             SessionHandoffs.apply_update(
               agent_id,
               "ses1_missing",
               base_params(%{operations: [%{"op" => "add", "text" => "hello"}]})
             )

    # Non-internal (retired) session
    retired_sid = "ses1_retired_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    insert_session!(agent_id, retired_sid, "retired")

    assert {:error, :session_unavailable} =
             SessionHandoffs.apply_update(
               agent_id,
               retired_sid,
               base_params(%{operations: [%{"op" => "add", "text" => "hello"}]})
             )

    # Write succeeds while alive
    assert {:ok, _} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{operations: [%{"op" => "add", "text" => "alive"}]})
             )

    # Soft-deleted session refuses further writes
    Repo.query!(
      "UPDATE salix_sessions SET deleted_at = now() WHERE agent_id = $1 AND session_id = $2",
      [agent_id, session_id]
    )

    assert {:error, :session_unavailable} =
             SessionHandoffs.apply_update(
               agent_id,
               session_id,
               base_params(%{
                 expected_revision: 1,
                 covered_message_id: 8,
                 operations: [%{"op" => "add", "text" => "after soft delete"}]
               })
             )

    # Hard delete cascades to salix_session_handoffs
    Repo.query!(
      "DELETE FROM salix_sessions WHERE agent_id = $1 AND session_id = $2",
      [agent_id, session_id]
    )

    assert {:ok, nil} = SessionHandoffs.get(agent_id, session_id)
  end
end
