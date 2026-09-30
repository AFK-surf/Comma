defmodule SalixLlm.OpenAIChatReasoningTest do
  @moduledoc """
  Model thinking on the chat-completions protocol. A plain-text assistant turn
  does not settle a Salix session — the transcript replays it on the next round
  — so reasoning has to survive a text turn, survive a stream that arrives as an
  ordinary JSON body, and come back out of the stream intact rather than
  concatenated into nonsense.
  """
  use ExUnit.Case, async: false

  alias SalixLlm.{ConvertOpenAI, MockSSEServer, OpenAIChat}

  setup do
    start_supervised!(MockSSEServer)
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockSSEServer, port: p} end)

    llm_opts = %{
      "protocol" => "",
      "model" => "reasoner-test",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test-key"
    }

    {:ok, llm_opts: llm_opts}
  end

  describe "blocking responses" do
    test "a text turn keeps its reasoning for the next round" do
      result =
        ConvertOpenAI.parse_chat(%{
          "choices" => [
            %{
              "message" => %{
                "content" => "Tomorrow looks clear.",
                "reasoning_content" => "The date tool already answered this."
              },
              "finish_reason" => "stop"
            }
          ]
        })

      assert {:final, "Tomorrow looks clear.", provider_meta, %{}} = result

      assert provider_meta == %{
               "chat_message_extra" => %{
                 "reasoning_content" => "The date tool already answered this."
               }
             }

      # And that meta replays onto the assistant message.
      assert [_user, assistant] =
               ConvertOpenAI.to_chat([
                 %{role: "user", content: "weather tomorrow"},
                 %{
                   role: "assistant",
                   content: "Tomorrow looks clear.",
                   provider_meta: provider_meta
                 }
               ])

      assert assistant["reasoning_content"] == "The date tool already answered this."
    end

    test "reasoning replays after a persisted transcript round-trip" do
      {:assistant, _text, _calls, provider_meta} =
        ConvertOpenAI.parse_chat(%{
          "choices" => [
            %{
              "message" => %{
                "content" => "checking",
                "reasoning_content" => "Call the date tool first.",
                "reasoning_details" => [%{"type" => "reasoning.text", "text" => "date first"}],
                "tool_calls" => [
                  %{
                    "id" => "c1",
                    "type" => "function",
                    "function" => %{"name" => "get_date", "arguments" => "{}"}
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })

      # The session store keeps events as JSON, so the replayed message arrives
      # back with string keys throughout.
      persisted =
        %{
          "role" => "assistant",
          "content" => "checking",
          "tool_calls" => [%{"id" => "c1", "name" => "get_date", "args" => %{}}],
          "provider_meta" => provider_meta
        }
        |> Jason.encode!()
        |> Jason.decode!()

      assert [assistant, _tool] =
               ConvertOpenAI.to_chat([
                 persisted,
                 %{role: "tool", tool_call_id: "c1", content: "2026-06-24"}
               ])

      assert assistant["reasoning_content"] == "Call the date tool first."

      assert assistant["reasoning_details"] == [
               %{"type" => "reasoning.text", "text" => "date first"}
             ]
    end

    test "reasoning from another model is omitted from chat replay" do
      [assistant] =
        ConvertOpenAI.to_chat(
          [
            %{
              "role" => "assistant",
              "content" => "Persisted answer",
              "model" => "source-model",
              "provider_meta" => %{
                "chat_message_extra" => %{
                  "reasoning_content" => "Private source reasoning",
                  "reasoning_details" => [
                    %{"type" => "reasoning.encrypted", "data" => "OPAQUE"}
                  ]
                }
              }
            }
          ],
          "target-model"
        )

      refute Map.has_key?(assistant, "reasoning_content")
      refute Map.has_key?(assistant, "reasoning_details")
    end

    test "reasoning stays attached for the same or an unknown producer model" do
      provider_meta = %{
        "chat_message_extra" => %{"reasoning_content" => "Reusable reasoning"}
      }

      [same_model] =
        ConvertOpenAI.to_chat(
          [
            %{
              role: "assistant",
              content: "Same-model answer",
              model: "reasoner-test",
              provider_meta: provider_meta
            }
          ],
          "reasoner-test"
        )

      [unknown_model] =
        ConvertOpenAI.to_chat(
          [
            %{
              role: "assistant",
              content: "Legacy answer",
              provider_meta: provider_meta
            }
          ],
          "reasoner-test"
        )

      assert same_model["reasoning_content"] == "Reusable reasoning"
      assert unknown_model["reasoning_content"] == "Reusable reasoning"
    end

    test "a text turn without reasoning stays a plain final" do
      assert {:final, "hi"} =
               ConvertOpenAI.parse_chat(%{
                 "choices" => [%{"message" => %{"content" => "hi"}, "finish_reason" => "stop"}]
               })
    end
  end

  describe "streaming" do
    test "a repeated thought signature is carried through, not concatenated", %{
      llm_opts: llm_opts
    } do
      MockSSEServer.set_chunks([
        chat_chunk(%{"reasoning_content" => "Weighing ", "thought_signature" => "SIG-1"}),
        chat_chunk(%{"reasoning_content" => "the options.", "thought_signature" => "SIG-1"}),
        chat_chunk(%{"content" => "Done."}),
        "data: [DONE]\n\n"
      ])

      assert {:final, "Done.", provider_meta, %{}} =
               OpenAIChat.complete_stream(
                 [%{role: "user", content: "hi"}],
                 [],
                 fn _ -> :ok end,
                 llm_opts
               )

      extra = provider_meta["chat_message_extra"]

      # Reasoning text is streamed in fragments and concatenates; a signature is
      # one opaque token and must survive verbatim.
      assert extra["reasoning_content"] == "Weighing the options."
      assert extra["thought_signature"] == "SIG-1"
    end

    test "a non-streaming JSON body still yields text, tool calls and reasoning", %{
      llm_opts: llm_opts
    } do
      MockSSEServer.set_chunks([
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => "checking",
                "reasoning_content" => "I should call the date tool.",
                "tool_calls" => [
                  %{
                    "id" => "c1",
                    "type" => "function",
                    "function" => %{"name" => "get_date", "arguments" => "{}"}
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 3}
        })
      ])

      assert {:assistant, "checking", [%{id: "c1", name: "get_date", args: %{}}], provider_meta,
              trace_meta} =
               OpenAIChat.complete_stream(
                 [%{role: "user", content: "weather tomorrow"}],
                 [],
                 fn _ -> :ok end,
                 llm_opts
               )

      assert provider_meta["chat_message_extra"] == %{
               "reasoning_content" => "I should call the date tool."
             }

      assert trace_meta["usage"]["total_tokens"] == 14
    end

    test "an unparseable body returns a retryable incomplete stream error", %{llm_opts: llm_opts} do
      MockSSEServer.set_chunks(["not json at all"])

      assert {:error,
              %{
                "category" => "transport_error",
                "reason" => "incomplete_stream",
                "retryable" => true
              }} =
               OpenAIChat.complete_stream(
                 [%{role: "user", content: "hi"}],
                 [],
                 fn _ -> :ok end,
                 llm_opts
               )
    end
  end

  defp chat_chunk(delta),
    do: "data: " <> Jason.encode!(%{"choices" => [%{"delta" => delta}]}) <> "\n\n"

  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40000 + :erlang.phash2(make_ref(), 20000)

      case ExUnit.Callbacks.start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not start mock server"
  end
end
