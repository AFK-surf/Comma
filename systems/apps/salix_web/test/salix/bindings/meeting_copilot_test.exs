defmodule Salix.Bindings.MeetingCopilotTest do
  use SystemsClock.Case, async: true

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
  end

  describe "accumulate/2" do
    test "appends the assistant reply to the running conversation" do
      prior = [%{"role" => "user", "content" => "d1"}]

      assert C.accumulate(prior, "r1") == [
               %{"role" => "user", "content" => "d1"},
               %{"role" => "assistant", "content" => "r1"}
             ]
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
  end
end
