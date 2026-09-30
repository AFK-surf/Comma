defmodule BridgeForTeams.TriageSourceAuthorityDiagnosticTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.TriageCollaborationCorpus, as: Corpus
  alias BridgeForTeams.TriageSourceAuthorityDiagnostic, as: Diagnostic

  test "source-only command preserves each original utterance with speaker attribution" do
    source = Corpus.fetch!("screenshot_implementation_uncertainty")["source_messages"]
    command = Diagnostic.command("source_messages_only", source)

    expected =
      Enum.map_join(source, "\n\n", fn row ->
        "#{row["display_name"]} (#{row["actor_kind"]}, #{row["ts"]}):\n#{row["text"]}"
      end)

    assert command == expected
    assert length(source) == 4

    for row <- source do
      assert String.contains?(command, row["text"])
    end

    refute command =~ "captured_router_command"
    refute command =~ "source_authority_arm"
    refute command =~ "expected"
  end

  test "control retains the captured Task command without introducing capture metadata" do
    fixture =
      Path.expand("../fixtures/triage/source_authority_screenshot_r1.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    source = Corpus.fetch!(fixture["source_case_id"])["source_messages"]
    control = Diagnostic.command("captured_router_assignment", source)
    treatment = Diagnostic.command("source_messages_only", source)

    assert control == fixture["captured_router_command"]
    refute treatment == control
    refute control =~ fixture["capture"]["task_id"]
    assert length(Corpus.cases()) == 8
    assert Enum.sort(Diagnostic.arms()) == ~w(captured_router_assignment source_messages_only)
  end
end
