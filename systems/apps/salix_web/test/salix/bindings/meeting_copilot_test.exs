defmodule Salix.Bindings.MeetingCopilotTest do
  use ExUnit.Case, async: true

  alias Salix.Bindings.MeetingCopilot, as: C

  describe "parse_say/1" do
    for {label, raw, expected} <- [
          {"extracts say from a bare JSON object", ~s|{"say":"稍等，我记一下。"}|, "稍等，我记一下。"},
          {"strips ```json fences", "```json\n{\"say\":\"ok\"}\n```", "ok"},
          {"extracts the JSON from surrounding prose",
           "Sure:\n{\"say\":\"done\"}\nhope that helps", "done"},
          {"empty say means stay silent", ~s|{"say":""}|, ""},
          {"non-JSON content stays silent", "I think I should stay quiet", ""},
          {"non-string say stays silent", ~s|{"say":123}|, ""}
        ] do
      @raw raw
      @expected expected
      test label do
        assert C.parse_say(@raw) == @expected
      end
    end
  end

  describe "build_digest/3" do
    test "renders new transcript and incoming chat, skipping outgoing chat" do
      state = %{"title" => "周会"}
      caps = [%{"speaker" => "Alice", "text" => "帮我记一下这个 action。"}]

      chats = [
        %{"direction" => "incoming", "sender" => "Bob", "text" => "@bot 提醒一下"},
        %{"direction" => "outgoing", "sender" => "bot", "text" => "收到"}
      ]

      d = C.build_digest(state, caps, chats)
      assert String.contains?(d, "## Meeting: 周会")
      assert String.contains?(d, "## New transcript\nAlice: 帮我记一下这个 action。")
      assert String.contains?(d, "## New in-meeting chat\nBob: @bot 提醒一下")
      refute String.contains?(d, "收到")
    end

    test "includes prior actions as a do-not-repeat section" do
      state = %{"title" => "Sync", "copilot" => %{"prior_actions" => ["已记：跟进首页文案"]}}
      d = C.build_digest(state, [%{"speaker" => "A", "text" => "ok"}], [])
      assert String.contains?(d, "## Already sent (do NOT repeat)\n- 已记：跟进首页文案")
    end

    test "omits empty content sections but always states the bot name" do
      d = C.build_digest(%{"title" => "M"}, [], [])
      assert String.starts_with?(d, "## Meeting: M")
      assert String.contains?(d, ~s(You appear in this meeting as "Cirno"))
      refute String.contains?(d, "## New transcript")
      refute String.contains?(d, "## New in-meeting chat")
      refute String.contains?(d, "## Already sent")
    end
  end

  describe "accumulate/2" do
    test "appends the assistant reply to the running conversation" do
      prior = [%{"role" => "user", "content" => "d1"}]

      assert C.accumulate(prior, "r1") == [
               %{"role" => "user", "content" => "d1"},
               %{"role" => "assistant", "content" => "r1"}
             ]
    end

    test "a silent turn keeps the user delta but adds no assistant turn" do
      prior = [%{"role" => "user", "content" => "d1"}]
      assert C.accumulate(prior, "") == prior
    end

    test "keeps a prior summary in history so a later summary can build on it" do
      history = [
        %{"role" => "user", "content" => "总结一下"},
        %{"role" => "assistant", "content" => "0-5 分钟的要点：..."},
        %{"role" => "user", "content" => "再总结一次"}
      ]

      out = C.accumulate(history, "5-10 分钟的更新：...")
      assert Enum.any?(out, &(&1["content"] == "0-5 分钟的要点：..."))
      assert List.last(out) == %{"role" => "assistant", "content" => "5-10 分钟的更新：..."}
    end

    test "caps by dropping whole oldest turns and never leaves a leading assistant" do
      big = String.duplicate("x", 25_000)

      prior = [
        %{"role" => "user", "content" => big},
        %{"role" => "assistant", "content" => "r1"},
        %{"role" => "user", "content" => big}
      ]

      # over budget: the oldest user+assistant turn is dropped as a whole, so the
      # newest reply is never orphaned from the user it answered.
      out = C.accumulate(prior, "r2")
      assert List.first(out)["role"] == "user"
      refute match?([%{"role" => "assistant"} | _], out)
      assert List.last(out) == %{"role" => "assistant", "content" => "r2"}
    end

    test "strips a leading orphan assistant left by earlier capping" do
      stale = [
        %{"role" => "assistant", "content" => "orphaned reply"},
        %{"role" => "user", "content" => "u1"}
      ]

      out = C.accumulate(stale, "r1")
      assert List.first(out)["role"] == "user"
      refute Enum.any?(out, &(&1["content"] == "orphaned reply"))
    end
  end

  describe "apply_outcome/3" do
    test "a sent reply is appended to the conversation and reported as spoken" do
      prior = [%{"role" => "user", "content" => "d1"}]

      assert C.apply_outcome(prior, "hi", :sent) ==
               {[
                  %{"role" => "user", "content" => "d1"},
                  %{"role" => "assistant", "content" => "hi"}
                ], "hi"}
    end

    test "a failed send records neither an assistant turn nor a spoken value" do
      prior = [%{"role" => "user", "content" => "d1"}]
      assert C.apply_outcome(prior, "hi", :failed) == {prior, ""}
    end

    test "a silent turn keeps the delta and reports nothing spoken" do
      prior = [%{"role" => "user", "content" => "d1"}]
      assert C.apply_outcome(prior, "", :silent) == {prior, ""}
    end
  end
end
