defmodule SalixIM.Triage.SourcePresentationTest do
  use ExUnit.Case, async: true
  alias SalixIM.Triage.SourcePresentation

  test "authors and mentions share bounded profile lookups without returning source text" do
    owner = self()
    receipts = [receipt("one", "U123", "<@U456> review <@U456>"), receipt("two", "U456", "hello")]

    assert {:ok, result} =
             SourcePresentation.read("group", ["one", "two"],
               receipts_fun: fn "group", ["one", "two"] -> {:ok, receipts} end,
               profile_fun: fn payload ->
                 actor = hd(payload["source_messages"])["actor_id"]
                 send(owner, {:profile, actor})
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

  test "a slow profile leaves the sender unknown and does not block the page" do
    assert {:ok, %{"one" => %{speaker_label: nil}}} =
             SourcePresentation.read("group", ["one"],
               receipts_fun: fn _, _ -> {:ok, [receipt("one", "U123", "hello")]} end,
               profile_fun: fn _ ->
                 Process.sleep(1_000)
                 ["late"]
               end,
               timeout: 10
             )
  end

  test "one page never scans all actors or accepts more than twenty receipts" do
    owner = self()
    receipts = for n <- 1..20, do: receipt(to_string(n), "U#{100 + n}", "<@U#{200 + n}>")

    assert {:ok, _} =
             SourcePresentation.read("group", Enum.map(receipts, & &1["receipt_ref"]),
               receipts_fun: fn _, _ -> {:ok, receipts} end,
               profile_fun: fn _ ->
                 send(owner, :profile)
                 ["Name"]
               end
             )

    for _ <- 1..20, do: assert_receive(:profile)
    refute_receive :profile
    assert {:error, :invalid} = SourcePresentation.read("group", Enum.map(1..21, &to_string/1))
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
