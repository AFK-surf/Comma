defmodule SalixAgent.LiveLlmSlackParticipationTest do
  @moduledoc """
  Real-model participation decisions with a supplied source-read result.
  This does not exercise source retrieval, Task execution, or Slack delivery.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live
  alias SalixAgent.SlackParticipationPrompt

  @moduletag :live_llm
  @moduletag timeout: 120_000
  @cases Jason.decode!(File.read!(Path.join(__DIR__, "fixtures/slack_participation.json")))

  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  for sample <- @cases do
    @sample sample
    test "live LLM participation: #{sample["name"]}", %{llm: llm} do
      messages = [
        %{
          role: "system",
          content:
            SlackParticipationPrompt.worker_instructions() <>
              """

              The original source-read result is supplied below. Choose the final participation decision.
              Return only JSON with kind (reply, reaction, or silence), text (public reply or empty),
              emoji (reaction name or empty), and reason (one short private explanation).
              This isolated evaluation cannot execute tools or send messages.
              """
        },
        %{role: "user", content: @sample["source"]}
      ]

      # Use the production protocol dispatcher, as in the shared live preflight.
      result = apply(SalixLlm.Provider, :complete, [messages, [], llm])

      text =
        case result do
          {:final, text, _usage} -> text
          {:final, text, _state, _usage} -> text
          other -> flunk("Expected a final model decision, got: #{inspect(other)}")
        end

      assert {:ok, decision} = Jason.decode(text)
      assert decision["kind"] in @sample["allowed_kinds"], inspect(decision)

      if decision["kind"] == "reply" do
        assert is_binary(decision["text"]) and String.trim(decision["text"]) != ""

        for pattern <- @sample["required_reply_patterns"] || [] do
          assert Regex.match?(Regex.compile!(pattern), decision["text"]), inspect(decision)
        end
      else
        assert decision["text"] == "", inspect(decision)
      end

      if decision["kind"] == "reaction" do
        assert decision["emoji"] == "eyes", inspect(decision)
      end
    end
  end
end
