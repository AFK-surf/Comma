defmodule Comma.ChatSuggestionsTest do
  use ExUnit.Case, async: false

  alias Comma.ChatSuggestions
  alias SalixStore.Ids

  describe "conversation language" do
    @describetag :live_llm
    @describetag timeout: 120_000

    # Exercise generated text, not the spelling of a prompt or a scripted completion.
    for {name, locale, messages, chinese?} <- [
          {"Chinese conversation with English UI", "en",
           [
             %{"role" => "user", "content" => "这俩 PR 咋样了"},
             %{
               "role" => "assistant",
               "content" => "#1948 已合并。#1949 的 E2E Test 还在跑，其余检查已通过。要在检查通过后合并吗？"
             }
           ], true},
          {"English conversation with Chinese UI", "zh-CN",
           [
             %{"role" => "user", "content" => "What is the status of these two PRs?"},
             %{
               "role" => "assistant",
               "content" =>
                 "#1948 is merged. #1949 is waiting for E2E Test; all other checks passed. Should I merge it when green?"
             }
           ], false},
          {"user switches from English to Chinese", "en",
           [
             %{"role" => "user", "content" => "Check these two PRs."},
             %{"role" => "assistant", "content" => "Both are open."},
             %{"role" => "user", "content" => "现在进展怎么样了？"},
             %{"role" => "assistant", "content" => "#1948 已合并。#1949 还在等 E2E Test，其他检查已通过。"}
           ], true}
        ] do
      test name do
        config = SalixAgent.LiveLlmTestSupport.llm_config!()

        opts =
          config
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
          |> Map.put("max_tokens", 512)

        messages = unquote(Macro.escape(messages))

        request =
          messages
          |> ChatSuggestions.recent_exchange()
          |> ChatSuggestions.request_messages(unquote(locale))

        result = SalixLlm.Provider.complete(request, [], opts)
        assert elem(result, 0) == :final, inspect(result)
        suggestions = ChatSuggestions.parse(elem(result, 1))
        assert suggestions != []

        for suggestion <- suggestions, field <- ["label", "prompt"] do
          assert Regex.match?(~r/\p{Han}/u, suggestion[field]) == unquote(chinese?),
                 "wrong language in #{field}: #{suggestion[field]}"
        end

        assert Enum.any?(suggestions, &String.contains?(&1["prompt"], "#1949"))
      end
    end
  end

  describe "parse/1" do
    test "reads the documented shape and stamps ids" do
      assert [
               %{"id" => "sug_1", "label" => "Deploy this", "prompt" => "Deploy this."},
               %{"id" => "sug_2", "label" => "Add tests", "prompt" => "Add tests."}
             ] =
               ChatSuggestions.parse(~s({"suggestions":[
                 {"label":"Deploy this","prompt":"Deploy this."},
                 {"label":"Add tests","prompt":"Add tests."}
               ]}))
    end

    test "tolerates code fences and surrounding prose" do
      fenced = """
      Here you go:

      ```json
      {"suggestions":[{"label":"Ship it","prompt":"Open a PR."}]}
      ```
      """

      assert [%{"label" => "Ship it"}] = ChatSuggestions.parse(fenced)
    end

    test "ignores unknown keys rather than failing the payload" do
      assert [%{"id" => "sug_1", "label" => "Ship it", "prompt" => "Open a PR."}] =
               ChatSuggestions.parse(
                 ~s({"suggestions":[{"label":"Ship it","prompt":"Open a PR.","icon":"rocket"}]})
               )
    end

    test "drops unusable items and keeps the rest" do
      assert [%{"label" => "Keep me"}] =
               ChatSuggestions.parse(~s({"suggestions":[
                 {"label":"","prompt":"blank label"},
                 {"label":"no prompt"},
                 "not an object",
                 {"label":"Keep me","prompt":"Keep me too."}
               ]}))
    end

    test "keeps ranked alternatives, capped at four" do
      items = for n <- 1..6, do: %{"label" => "Choice #{n}", "prompt" => "Action #{n}"}
      parsed = ChatSuggestions.parse(Jason.encode!(%{"suggestions" => items}))
      assert Enum.map(parsed, & &1["prompt"]) == ["Action 1", "Action 2", "Action 3", "Action 4"]
    end

    test "drops overlong messages instead of truncating, preserving valid rank" do
      items = [
        %{"label" => "Too long", "prompt" => String.duplicate("a", 13)},
        %{"label" => "Wide Latin too long", "prompt" => String.duplicate("W", 13)},
        %{"label" => "Chinese too long", "prompt" => String.duplicate("界", 13)},
        %{"label" => "Emoji too long", "prompt" => String.duplicate("👩🏽‍💻", 13)},
        %{"label" => "Chinese boundary", "prompt" => String.duplicate("界", 12)},
        %{"label" => "ASCII boundary", "prompt" => String.duplicate("a", 12)},
        %{"label" => "Emoji boundary", "prompt" => String.duplicate("👩🏽‍💻", 12)},
        %{"label" => "Complete action", "prompt" => "Add\n tests."}
      ]

      parsed = ChatSuggestions.parse(Jason.encode!(%{"suggestions" => items}))

      assert Enum.map(parsed, & &1["prompt"]) ==
               [
                 String.duplicate("界", 12),
                 String.duplicate("a", 12),
                 String.duplicate("👩🏽‍💻", 12),
                 "Add tests."
               ]
    end

    test "clips labels without truncating the complete prompt" do
      parsed =
        ChatSuggestions.parse(
          Jason.encode!(%{
            "suggestions" => [
              %{"label" => String.duplicate("a", 80), "prompt" => "Add tests."}
            ]
          })
        )

      assert [%{"label" => label, "prompt" => "Add tests."}] = parsed
      assert String.length(label) == 60
    end

    test "answers with an empty row for anything unusable" do
      assert ChatSuggestions.parse("I'm sorry, I can't help with that.") == []
      assert ChatSuggestions.parse("{}") == []
      assert ChatSuggestions.parse(~s({"suggestions":"nope"})) == []
      assert ChatSuggestions.parse(~s({"suggestions":[]})) == []
      assert ChatSuggestions.parse(nil) == []
    end
  end

  describe "recent_exchange/1" do
    test "reads canonical Salix message resource blocks" do
      messages = [
        %{
          "actor_type" => "user",
          "content" => [%{"type" => "text", "text" => "show the report"}]
        },
        %{
          "actor_type" => "agent",
          "content" => [
            %{"type" => "text", "text" => "the report is ready"},
            %{"type" => "file", "file_name" => "report.pdf"}
          ]
        }
      ]

      assert ChatSuggestions.recent_exchange(messages) ==
               "user: show the report\nassistant: the report is ready"
    end

    test "starts at the third-most-recent user message" do
      messages =
        Enum.flat_map(1..5, fn index ->
          [
            %{"role" => "user", "content" => "ask #{index}"},
            %{"role" => "assistant", "content" => "answer #{index}"}
          ]
        end)

      transcript = ChatSuggestions.recent_exchange(messages)

      refute transcript =~ "ask 2"
      assert transcript =~ "user: ask 3"
      assert transcript =~ "assistant: answer 5"
    end

    test "keeps the whole transcript when it is shorter than the window" do
      messages = [
        %{"role" => "user", "content" => "only ask"},
        %{"role" => "assistant", "content" => "only answer"}
      ]

      assert ChatSuggestions.recent_exchange(messages) ==
               "user: only ask\nassistant: only answer"
    end

    test "drops rows with no text and non-lists" do
      messages = [
        %{"role" => "user", "content" => "kept"},
        %{"role" => "assistant", "content" => nil},
        %{"role" => "assistant"}
      ]

      assert ChatSuggestions.recent_exchange(messages) == "user: kept"
      assert ChatSuggestions.recent_exchange(nil) == ""
      assert ChatSuggestions.recent_exchange([]) == ""
    end
  end

  describe "generate_from_source/2" do
    test "asks the model in a dependency job and answers with its suggestions" do
      owner = self()
      tenant_id = Ids.new_tenant_id()
      agent_id = tenant_id |> Ids.new_group_id() |> Ids.new_agent_id()

      source = %{
        agent_id: agent_id,
        billing_context: %{},
        messages: [
          %{"role" => "user", "content" => "question"},
          %{"role" => "assistant", "content" => "answer"}
        ]
      }

      assert [%{"label" => "Ship it"}] =
               ChatSuggestions.generate_from_source(source,
                 locale: "en",
                 request_fun: fn transcript, _source, locale ->
                   send(owner, {:suggestion_request, self(), transcript, locale})
                   [%{"id" => "sug_1", "label" => "Ship it", "prompt" => "Open a PR."}]
                 end
               )

      assert_received {:suggestion_request, child, transcript, "en"}
      assert child != self()
      assert transcript =~ "assistant: answer"
    end

    test "answers with no suggestions before the Workspace has a Router agent" do
      assert [] =
               ChatSuggestions.generate_from_source(
                 %{
                   agent_id: nil,
                   billing_context: %{},
                   messages: [%{"role" => "user", "content" => "q"}]
                 },
                 request_fun: fn _transcript, _source, _locale -> flunk("asked the model") end
               )
    end
  end
end
