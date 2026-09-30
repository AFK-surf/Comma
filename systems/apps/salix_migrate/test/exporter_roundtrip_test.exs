defmodule SalixMigrate.ExporterRoundtripTest do
  @moduledoc """
  End-to-end roundtrip for the Go-side migration exporter:

      Go agent DB (real schema) → cmd/willow-salix-export → import JSON
        → SalixMigrate.Import → SalixStore.Agent.claim + InternalSessionStore

  Builds the exporter from a matching Willow source layout after staging
  scripts/build_exporter.sh at `systems/scripts/` in that checkout,
  creates a fixture agent DB with the REAL `sessions`/`messages`/`tool_calls`
  CREATE TABLE statements (same script, `--fixture` mode), runs the exporter,
  and asserts the imported internal runtime sessions reconstruct the conversation EXACTLY:
  message order, roles, contents, tool linkage, watermarks, dedupe index, and
  per-session `next_message_id`.

  Tagged `:go_exporter` and excluded by default (requires go + sqlite3 + bash);
  run with: mix test --include go_exporter
  """
  use ExUnit.Case, async: false

  @moduletag :go_exporter

  alias SalixMigrate.Import
  alias SalixAgent.InternalSessionStore
  alias SalixStore.Agent
  alias SalixAgent.State

  @script Path.expand("../../../scripts/build_exporter.sh", __DIR__)

  setup_all do
    for {exe, hint} <- [
          {"go", "the Go toolchain is required to build cmd/willow-salix-export"},
          {"sqlite3", "the sqlite3 CLI is required to create the fixture agent DB"},
          {"bash", "bash is required to run scripts/build_exporter.sh"}
        ] do
      System.find_executable(exe) ||
        raise "exporter roundtrip test: `#{exe}` not found in PATH — #{hint}. " <>
                "Exclude with `mix test --exclude go_exporter` (the default) if unavailable."
    end

    exporter = Path.join(System.tmp_dir!(), "willow-salix-export-test")

    db =
      Path.join(
        System.tmp_dir!(),
        "willow-salix-fixture-#{System.unique_integer([:positive])}.db"
      )

    {out, status} = System.cmd("bash", [@script, exporter], stderr_to_stdout: true)
    status == 0 || raise "go build of willow-salix-export failed:\n#{out}"

    {out, status} = System.cmd("bash", [@script, "--fixture", db], stderr_to_stdout: true)
    status == 0 || raise "fixture DB creation failed:\n#{out}"

    on_exit(fn -> File.rm(db) end)

    # Run the exporter once; stdout is the pure import JSON document.
    {json, 0} = System.cmd(exporter, ["-db", db, "-tenant", "acme", "-template", "assistant"])
    {:ok, export: Jason.decode!(json)}
  end

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: "agent-#{System.unique_integer([:positive])}"}
  end

  test "exporter emits the documented import shape", %{export: export} do
    assert export["tenant"] == "acme"
    assert export["template"] == "assistant"
    assert is_integer(export["migrated_at"])

    # 2 live sessions; the soft-deleted fixture session (s-gone) is not exported.
    assert Enum.map(export["sessions"], & &1["id"]) == ["s-main", "s-side"]

    # The compaction-summary message row is folded into the session record and
    # NOT re-exported as a message (Salix would inject the summary twice).
    [main, side] = export["sessions"]
    assert main["status"] == "idle"
    refute Map.has_key?(main, "wake_sequence")
    assert main["last_ack_message_id"] == 5
    assert main["summary_sequence"] == 1
    assert main["compacted_through"] == 4
    assert main["summary"] == "summary: greeted and read /notes.txt"
    assert side["status"] == "queued"
    refute Map.has_key?(side, "wake_sequence")

    # message ids/order verbatim; compaction row (id 6) and the deleted
    # session's message (id 7) are excluded...
    assert Enum.map(export["messages"], & &1["id"]) == [1, 2, 3, 4, 5]
    # ...but BOTH still count for the id high-water mark (AUTOINCREMENT).
    assert export["next_message_id"] == 8
  end

  test "claim after import reconstructs the conversation exactly", %{export: export, agent: a} do
    assert :ok = Import.import_agent(a, export)
    {:ok, owned} = Agent.claim(a, "node-1", State, steal: true)
    refute Map.has_key?(owned.state, :sessions)

    # -- s-main: order, roles, contents
    assert {:ok, s} = InternalSessionStore.read(a, "s-main")
    assert Enum.map(s.messages, & &1.id) == [1, 2, 3, 4]
    assert Enum.map(s.messages, & &1.role) == ["user", "assistant", "tool", "assistant"]

    assert Enum.map(s.messages, & &1.content) == [
             "hello",
             "let me check that file",
             ~s({"ok":true,"bytes":5}),
             "done — the file says hi"
           ]

    # tool linkage: the assistant turn carries the folded tool_call in the
    # Salix %{id, name, args} shape; the tool result references it back.
    [_, assistant, tool_result, plain_assistant] = s.messages

    assert assistant.tool_calls == [
             %{"id" => "call-1", "name" => "vfs_read", "args" => %{"path" => "/notes.txt"}}
           ]

    assert tool_result.tool_call_id == "call-1"
    refute Map.has_key?(plain_assistant, :tool_calls)

    # watermarks + compaction facts
    assert s.status == :idle
    assert s.last_ack_message_id == 5
    assert s.summary_sequence == 1
    assert s.compacted_through == 4
    assert s.summary == "summary: greeted and read /notes.txt"

    # -- s-side
    assert {:ok, side} = InternalSessionStore.read(a, "s-side")
    assert side.status == :queued
    assert Enum.map(side.messages, &{&1.id, &1.role, &1.content}) == [{5, "user", "ping"}]

    # -- deleted session and its message did not cross over
    assert {:error, :not_found} = InternalSessionStore.read(a, "s-gone")

    # -- dedupe index + id high-water mark are session-local
    assert MapSet.member?(s.input_dedupe, "src-1")
    assert MapSet.member?(side.input_dedupe, "src-2")
    assert s.next_message_id == 8
    assert side.next_message_id == 8
  end

  test "migrated agent continues correctly: dedupe drops re-deliveries, new ids append after the hwm",
       %{export: export, agent: a} do
    :ok = Import.import_agent(a, export)
    {:ok, owned} = Agent.claim(a, "node-1", State, steal: true)
    refute Map.has_key?(owned.state, :sessions)

    {:ok, main} = InternalSessionStore.read(a, "s-main")
    next = main.next_message_id

    {:ok, main} =
      InternalSessionStore.prepare_commit(
        a,
        "s-main",
        [
          # re-delivery of an already-imported source id → dropped (inv #12)
          %{
            "type" => "delivery",
            "session_id" => "s-main",
            "message_id" => next,
            "source_message_id" => "src-1",
            "content" => "duplicate of hello"
          }
        ],
        hwm: next
      )

    {:ok, side} =
      InternalSessionStore.prepare_commit(
        a,
        "s-side",
        [
          # genuinely new delivery → appends with the post-migration id
          %{
            "type" => "delivery",
            "session_id" => "s-side",
            "message_id" => next,
            "source_message_id" => "src-3",
            "content" => "after migration"
          }
        ],
        hwm: next
      )

    assert length(main.messages) == 4
    assert length(side.messages) == 2
    assert List.last(side.messages).id == 8
    assert List.last(side.messages).content == "after migration"
  end
end
