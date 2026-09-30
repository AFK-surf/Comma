defmodule SalixAgent.SessionKernelRuntimeQueryTest do
  @moduledoc """
  Coverage for the runtime-consumer query catalog
  (`runtime/VerifiedKernel/Session/Query/Runtime.lean`).

  Each case asserts the kernel's answer for fixtures that exercise the listing
  projection over idle, failed, forked, hidden, archived and compacted
  sessions; the format-1 fact scans and their format-2/3 explicit fields;
  willow's title sourcing over binary and block content; the billing usage
  shapes; and the emergency-compact watermark on both sides of the format-2
  cutover.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session, as: Resident

  defp ask(state, name, args \\ nil), do: Resident.query(Resident.open(state), name, args)

  ## Fixtures ---------------------------------------------------------------

  defp base(attrs \\ %{}) do
    struct(State, Map.merge(%{agent_id: "agent-1", session_id: "session-1"}, attrs))
  end

  defp user_message(id, extra \\ %{}) do
    Map.merge(%{id: id, role: "user", content: "hello #{id}"}, extra)
  end

  defp assistant_message(id, extra \\ %{}) do
    Map.merge(%{id: id, role: "assistant", content: "reply #{id}", tool_calls: []}, extra)
  end

  defp fixtures do
    [
      {"idle empty", base()},
      {"named and hidden",
       base(%{
         name: "Weekly review",
         hidden: true,
         created_at: 10,
         last_activity_at: 20,
         activity_status_updated_at: 21,
         activity_revision: "rev-9",
         storage_revision: "rev-1"
       })},
      {"revision falls back to storage",
       base(%{storage_revision: "rev-1", next_message_id: 7, last_ack_message_id: 6})},
      {"failed session",
       base(%{visible_reply_repair: %{"status" => "exhausted"}, next_message_id: 3})},
      {"forked session",
       base(%{
         fork_request_id: "fork-1",
         source_agent_id: "agent-1",
         source_session_id: "session-0",
         source_schedule_id: "sched-1"
       })},
      {"forked from another agent",
       base(%{source_agent_id: "agent-2", source_session_id: "session-0"})},
      {"forked with blank source agent",
       base(%{source_agent_id: "", source_session_id: "session-0"})},
      {"compacted and archived",
       base(%{
         compacted_through: 12,
         archived_through: 8,
         summary_sequence: 3,
         next_message_id: 20,
         archive_chunks: [["a", 1, 4], ["b", 5, 4]],
         segment_catalog: [["c", 9, 2]],
         messages: [user_message(18), assistant_message(19)]
       })},
      {"recovered compaction failure",
       base(%{
         compacted_through: 5,
         summary_sequence: 2,
         compaction_failure: %{
           "category" => "provider",
           "reason" => "overloaded",
           "failed_at" => 44,
           "recovery_summary_written" => true
         }
       })},
      {"recovered compaction failure with created_at",
       base(%{
         compaction_failure: %{
           "recovery_summary_written" => true,
           "created_at" => 7,
           "failed_at" => 44
         }
       })},
      {"unrecovered compaction failure",
       base(%{compaction_failure: %{"recovery_summary_written" => false}})},
      {"explicit recovery field",
       base(%{
         last_compaction_recovery: %{"kind" => "compaction_recovery", "created_at" => 3},
         events: [%{"kind" => "compaction_recovery", "created_at" => 1}]
       })},
      {"legacy recovery fact",
       base(%{
         storage_format: 1,
         events: [
           %{"kind" => "compaction_recovery", "created_at" => 1},
           %{"kind" => "session_compact_result", "source_message_id" => "src-1"},
           %{"kind" => "compaction_recovery", "created_at" => 2}
         ]
       })},
      {"legacy compact results",
       base(%{
         storage_format: 1,
         events: [
           %{
             "kind" => "session_compact_result",
             "source_message_id" => "src-1",
             "status" => "ok"
           },
           %{"kind" => "other", "source_message_id" => "src-2"}
         ]
       })},
      {"explicit compact results",
       base(%{
         compact_results: %{"src-1" => %{"status" => "compacted"}},
         events: [
           %{
             "kind" => "session_compact_result",
             "source_message_id" => "src-1",
             "status" => "old"
           }
         ]
       })},
      {"emergency redaction",
       base(%{
         storage_format: 3,
         next_message_id: 30,
         redactions: [
           %{"kind" => "tool_messages_through", "through_id" => 3, "replacement" => "x"},
           %{
             "kind" => "non_model_messages_over_bytes_through",
             "through_id" => 17,
             "max_bytes" => 10,
             "replacement" => "y"
           }
         ]
       })},
      {"emergency redaction without watermark",
       base(%{
         storage_format: 3,
         next_message_id: 30,
         redactions: [%{"kind" => "non_model_messages_over_bytes_through", "max_bytes" => 10}]
       })},
      {"emergency legacy fallback", base(%{storage_format: 1, next_message_id: 30})},
      {"title source binary",
       base(%{
         messages: [
           %{id: 1, role: "summary", content: "context"},
           user_message(2, %{content: "  Fix the failing build  "}),
           assistant_message(3)
         ]
       })},
      {"title source blocks",
       base(%{
         messages: [
           %{
             id: 1,
             role: "user",
             content: [
               %{"type" => "text", "text" => "first"},
               %{"type" => "image", "url" => "x"},
               "raw",
               %{type: "text", text: "second"},
               %{"type" => "text"},
               7
             ]
           }
         ]
       })},
      {"title source string keys",
       base(%{messages: [%{"id" => 1, "role" => "user", "content" => "string keyed"}]})},
      {"title source missing content", base(%{messages: [%{id: 1, role: "user"}]})},
      {"title source empty blocks", base(%{messages: [%{id: 1, role: "user", content: []}]})},
      {"title no user", base(%{messages: [assistant_message(1)]})},
      {"billing rounds",
       base(%{
         messages: [
           assistant_message(1, %{
             prompt_tokens: 10,
             completion_tokens: 5,
             model: "claude-opus-5",
             tool_calls: [%{"id" => "a"}, %{"id" => "b"}],
             created_at: 100
           }),
           assistant_message(2, %{
             input_tokens: "7",
             output_tokens: 3.9,
             total_tokens: 20,
             cache_read_input_tokens: 4,
             cache_creation_input_tokens: 6,
             created_at: "101"
           }),
           %{
             "id" => 3,
             "role" => "assistant",
             "input_tokens" => 2,
             "output_tokens" => 0,
             "prompt_tokens_details" => %{"cached_tokens" => 9}
           },
           assistant_message(4, %{prompt_tokens: 0, completion_tokens: 0}),
           user_message(5, %{prompt_tokens: 3, completion_tokens: 3})
         ]
       })},
      {"input dedupe", base(%{input_dedupe: MapSet.new(["src-1", "src-2"]), last_seq: 12})},
      {"snapshot revision", base(%{storage_revision: "rev-42", last_seq: 12})},
      {"snapshot seq only", base(%{storage_revision: nil, last_seq: 12})}
    ]
  end

  defp fixture(label) do
    {^label, state} = Enum.find(fixtures(), fn {name, _} -> name == label end)
    state
  end

  ## Queries ----------------------------------------------------------------

  test "the listing projection drops nils and keeps false" do
    listing = ask(fixture("idle empty"), :session_json, "agent-1")

    assert listing["hidden"] == false
    assert listing["name"] == "Default"
    assert listing["runtime_kind"] == "internal"
    assert listing["agent_id"] == "agent-1"
    refute Map.has_key?(listing, "activity_status_updated_at")
    refute Map.has_key?(listing, "fork_request_id")
    refute Map.has_key?(listing, "issue")

    named = ask(fixture("named and hidden"), :session_json, "agent-1")
    assert named["hidden"] == true
    assert named["name"] == "Weekly review"
    assert named["activity_revision"] == "rev-9"
    assert named["last_activity_at"] == 20

    assert ask(fixture("revision falls back to storage"), :session_json, "agent-1")[
             "activity_revision"
           ] == "rev-1"

    failed = ask(fixture("failed session"), :session_json, "agent-1")
    assert failed["activity_status"] == "failed"
    assert failed["issue"] == "visible_reply_repair_exhausted"

    forked = ask(fixture("forked session"), :session_json, "agent-1")
    assert forked["fork_request_id"] == "fork-1"
    assert forked["source_schedule_id"] == "sched-1"
  end

  test "the listing counts the whole transcript and the highest id ever minted" do
    listing = ask(fixture("compacted and archived"), :session_json, "agent-1")

    assert listing["message_count"] == 12
    assert listing["last_message_id"] == 19
    assert listing["archived_through"] == 8
    assert listing["compacted_through"] == 12
    assert listing["summary_sequence"] == 3
  end

  test "the emergency watermark distinguishes a missing format-2 result from a legacy head" do
    assert ask(fixture("emergency redaction"), :emergency_compact_through_id) == 17

    assert ask(fixture("emergency redaction without watermark"), :emergency_compact_through_id) ==
             nil

    assert ask(fixture("emergency legacy fallback"), :emergency_compact_through_id) == 29
  end

  test "lineage follows a same-agent fork only" do
    assert ask(fixture("forked session"), :lineage_source_session_id) == "session-0"

    assert ask(fixture("forked with blank source agent"), :lineage_source_session_id) ==
             "session-0"

    assert ask(fixture("forked from another agent"), :lineage_source_session_id) == nil
  end

  test "the compact result prefers the explicit field over the fact scan" do
    assert ask(fixture("explicit compact results"), :compact_result_for, "src-1") ==
             %{"status" => "compacted"}

    assert ask(fixture("legacy compact results"), :compact_result_for, "src-1") ==
             %{
               "kind" => "session_compact_result",
               "source_message_id" => "src-1",
               "status" => "ok"
             }

    assert ask(fixture("legacy compact results"), :compact_result_for, "src-2") == nil
  end

  test "the recovery lookup prefers the field, then the newest fact, then the failure" do
    assert ask(fixture("explicit recovery field"), :latest_compaction_recovery) ==
             %{"kind" => "compaction_recovery", "created_at" => 3}

    assert ask(fixture("legacy recovery fact"), :latest_compaction_recovery) ==
             %{"kind" => "compaction_recovery", "created_at" => 2}

    recovered = ask(fixture("recovered compaction failure"), :latest_compaction_recovery)
    assert recovered["kind"] == "compaction_recovery"
    assert recovered["compacted_through"] == 5
    assert recovered["summary_sequence"] == 2
    assert recovered["created_at"] == 44

    assert ask(
             fixture("recovered compaction failure with created_at"),
             :latest_compaction_recovery
           )[
             "created_at"
           ] == 7

    assert ask(fixture("unrecovered compaction failure"), :latest_compaction_recovery) == nil
    assert ask(fixture("idle empty"), :latest_compaction_recovery) == nil
  end

  test "title sourcing flattens blocks and finds the first user message" do
    assert ask(fixture("title source binary"), :title_source_content) == "Fix the failing build"
    assert ask(fixture("title source binary"), :title_has_assistant?) == true
    assert ask(fixture("title source blocks"), :title_source_content) == "first\nraw\nsecond"
    assert ask(fixture("title source blocks"), :title_has_assistant?) == false
    assert ask(fixture("title source string keys"), :title_source_content) == "string keyed"
    assert ask(fixture("title source missing content"), :title_source_content) == ""
    assert ask(fixture("title source empty blocks"), :title_source_content) == ""
    assert ask(fixture("title no user"), :title_source_content) == ""
  end

  test "billing counts assistant rounds only and carries every usage shape" do
    entries =
      ask(fixture("billing rounds"), :internal_session_billing_entries, {"fallback", "anthropic"})

    assert length(entries) == 3
    [first, second, third] = entries

    assert first["message_id"] == 1
    assert first["input_tokens"] == 10
    assert first["output_tokens"] == 5
    assert first["total_tokens"] == 15
    assert first["step_count"] == 2
    assert first["model"] == "claude-opus-5"
    assert first["provider_type"] == "anthropic"
    assert first["call_kind"] == "agent"
    assert first["cost_micros"] == 0
    assert first["created_at"] == 100

    assert second["input_tokens"] == 7
    assert second["output_tokens"] == 3
    assert second["total_tokens"] == 20
    assert second["cache_read_input_tokens"] == 4
    assert second["cache_write_input_tokens"] == 6
    assert second["model"] == "fallback"
    assert second["created_at"] == 101

    assert third["cache_read_input_tokens"] == 9
    assert third["session_id"] == "session-1"
  end

  test "the durable ledger and the snapshot identity read the state, not the host" do
    assert ask(fixture("input dedupe"), :input_dedupe_member?, "src-1") == true
    assert ask(fixture("input dedupe"), :input_dedupe_member?, "src-9") == false
    assert ask(fixture("idle empty"), :input_dedupe_member?, "src-1") == false

    assert ask(fixture("snapshot revision"), :session_snapshot_id) == "rev-42"
    assert ask(fixture("snapshot seq only"), :session_snapshot_id) == "seq:12"
    assert ask(fixture("idle empty"), :session_snapshot_id) == "seq:0"
  end
end
