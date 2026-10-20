defmodule SalixIM.Triage.SourcePresentationTest do
  use SystemsClock.Case, async: true
  alias SalixIM.Triage.SourcePresentation

  test "authors and mentions share bounded profile lookups without returning source text" do
    owner = SystemsRuntime.Proc.self()
    receipts = [receipt("one", "U123", "<@U456> review <@U456>"), receipt("two", "U456", "hello")]

    assert {:ok, result} =
             SourcePresentation.read("group", ["one", "two"],
               receipts_fun: fn "group", ["one", "two"] -> {:ok, receipts} end,
               profile_fun: fn payload ->
                 actor = hd(payload["source_messages"])["actor_id"]
                 SystemsRuntime.Proc.send(owner, {:profile, actor})
                 [if(actor == "U123", do: "Peng", else: "codex-3720")]
               end
             )

    assert result["one"] == %{speaker_label: "Peng", mentions: %{"U456" => "codex-3720"}}
    assert result["two"] == %{speaker_label: "codex-3720", mentions: %{}}
    assert_receive {:profile, "U123"}
    assert_receive {:profile, "U456"}
    refute_receive {:profile, _}
    refute inspect(result) =~ "review"
  end

  defp receipt(ref, actor, text),
    do: %{
      "receipt_ref" => ref,
      "connect_id" => "connect",
      "connect_generation" => "generation",
      "triage_event" => %{
        "actor_id" => actor,
        "text" => text,
        "bucket" => %{"workspace_id" => "workspace"}
      }
    }
end
