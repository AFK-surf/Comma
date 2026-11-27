defmodule SalixIM.TriageWorkerLoopFixtureTest do
  use ExUnit.Case, async: true

  alias SalixAgent.{SlackParticipationPrompt, ToolDisclosure}
  alias SalixIM.Triage.{Investigation, StillfailCoordination}

  @fixture_path Path.join(__DIR__, "fixtures/triage_worker_loop.json")
  @required_keys ~w(
    name
    command
    source_response
    slack_search_messages
    station_tasks
    composio_connections
    composio_pr_data
    allowed_kinds
    allowed_reason_codes
    required_reply_patterns
    forbidden_reply_substrings
    required_tools
    expected_follow_up_hours
    forbid_follow_up
    max_tool_calls
    max_complete_errors
  )

  test "triage_worker_loop.json defines 10 well-formed regression scenarios" do
    cases = @fixture_path |> File.read!() |> Jason.decode!()
    assert length(cases) == 10
    assert Enum.uniq(Enum.map(cases, & &1["name"])) |> length() == 10

    for sample <- cases do
      for key <- @required_keys do
        assert Map.has_key?(sample, key), "#{sample["name"]} missing #{key}"
      end

      assert is_binary(sample["name"]) and sample["name"] != ""
      assert is_binary(sample["command"]) and sample["command"] != ""
      assert is_map(sample["source_response"])
      assert is_binary(sample["source_response"]["source_snapshot"])
      assert is_list(sample["source_response"]["messages"])
      assert sample["source_response"]["messages"] != []
      assert is_list(sample["allowed_kinds"]) and sample["allowed_kinds"] != []
      assert is_integer(sample["max_tool_calls"]) and sample["max_tool_calls"] > 0
      assert is_integer(sample["max_complete_errors"]) and sample["max_complete_errors"] >= 0
      assert is_boolean(sample["forbid_follow_up"])
    end
  end

  test "stillfail_coordination fixtures match StillfailCoordination.evaluate/4" do
    cases =
      @fixture_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.new(&{&1["name"], &1})

    active = cases["stillfail_active_same_thread"]

    active_eval =
      StillfailCoordination.evaluate(
        active["station_tasks"],
        %{"channel_id" => "C_ENG", "thread_ts" => "1795200100.000100"},
        Enum.map(active["source_response"]["messages"], & &1["text"]),
        false
      )

    assert Atom.to_string(active_eval.disposition) ==
             active["source_response"]["stillfail_coordination"]["disposition"]

    blocker = cases["pr_status_github_composio_with_stillfail_blocker"]

    blocker_eval =
      StillfailCoordination.evaluate(
        blocker["station_tasks"],
        %{"channel_id" => "C_ENG", "thread_ts" => "1795200600.000100"},
        Enum.map(blocker["source_response"]["messages"], & &1["text"]),
        true
      )

    expected = blocker["source_response"]["stillfail_coordination"]
    assert Atom.to_string(blocker_eval.disposition) == expected["disposition"]
    assert blocker_eval.card_kind == expected["card_kind"]
    assert blocker_eval.recommended_recheck_hours == expected["recommended_recheck_hours"]
  end

  test "Investigation.valid_decision?/1 accepts canonical decisions and rejects malformed shapes" do
    assert Investigation.valid_decision?(%{
             "kind" => "reply",
             "text" => "PR #5451 is still open.",
             "source_refs" => ["slack://T_AFK/C_ENG/1795200600.000100/1795200600.000100"]
           })

    assert Investigation.valid_decision?(%{
             "kind" => "reaction",
             "emoji" => "eyes",
             "source_refs" => ["slack://T_AFK/C_ENG/1795200600.000100/1795200600.000100"]
           })

    assert Investigation.valid_decision?(%{
             "kind" => "silence",
             "reason_code" => "already_handled",
             "reason" => "Answered by a teammate.",
             "source_refs" => []
           })

    refute Investigation.valid_decision?(%{
             "kind" => "reply",
             "text" => "Answer",
             "reason" => "Extra key",
             "source_refs" => []
           })

    refute Investigation.valid_decision?(%{
             "kind" => "silence",
             "reason_code" => "invalid_code",
             "reason" => "Bad code",
             "source_refs" => []
           })

    refute Investigation.valid_decision?(%{
             "kind" => "reaction",
             "emoji" => "eyes",
             "source_refs" => []
           })
  end

  test "worker tool specs and triage investigation prompt are wired for the live loop" do
    spec_names =
      "worker"
      |> ToolDisclosure.internal_llm_specs()
      |> Enum.map(& &1["name"])

    assert "call" in spec_names
    assert "end_turn" in spec_names

    instructions = SlackParticipationPrompt.triage_investigation_instructions()
    assert is_binary(instructions) and String.trim(instructions) != ""
  end
end
