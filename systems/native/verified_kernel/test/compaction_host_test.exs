defmodule SalixVerifiedKernel.CompactionHostTest do
  # Compaction host data: the kernel admits a compaction, builds its request,
  # reads the model answer, and builds the commit events. A host runs the
  # model call and the storage commit.
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  @origin %{
    "provider" => "internal",
    "source_actor_type" => "user",
    "conversation_kind" => "user_chat",
    "conversation_id" => "alice",
    "source_message_id" => "m1"
  }

  # A settled exchange: the user asked, a tool ran, and the assistant answered
  # with 190,000 observed prompt tokens.
  defp session(patch \\ %{}) do
    Session.new("agent", "ses1_0000000000000000001")
    |> Session.export()
    |> Map.merge(%{
      status: :idle,
      next_message_id: 5,
      last_seq: 4,
      last_ack_message_id: 4,
      messages: messages(190_000)
    })
    |> Map.merge(patch)
    |> Session.open()
  end

  defp messages(tokens) do
    [
      %{id: 1, seq: 1, role: "user", content: "hi", trusted_origin: @origin},
      %{
        id: 2,
        seq: 2,
        role: "assistant",
        content: "",
        tool_calls: [%{"id" => "c1", "name" => "fs.read"}, %{"id" => "c2", "name" => "fs.list"}]
      },
      %{id: 3, seq: 3, role: "tool", tool_call_id: "c1", content: "file"},
      %{
        id: 4,
        seq: 4,
        role: "assistant",
        content: "done",
        model: "claude-x",
        input_tokens: tokens
      }
    ]
  end

  defp config(extra \\ %{}) do
    Map.merge(
      %{
        "protocol" => :anthropic,
        "provider" => "anthropic",
        "model" => "claude-x",
        "base_url" => "https://api.example/v1?q=\"é\"",
        "max_tokens" => 8192,
        "context_tokens" => 200_000
      },
      extra
    )
  end

  defp prepare(state, facts),
    do: Session.query(state, :compaction_prepare, {:maybe_compact, facts})

  test "an automatic compaction plan keeps the configuration fingerprint of earlier releases" do
    # The fingerprint keys a stored compaction failure. These values are the
    # ones the Elixir implementation wrote before the kernel owned it.
    assert {:summarize, plan} = prepare(session(), %{"config" => config()})

    assert plan["fingerprint"] ==
             "2a93afbeb9aa0d83fa02534ed52783fa088a5588f434db29e4c62cd052a82671"

    assert plan["last_id"] == 4 and plan["auto"] == true

    responses = %{"protocol" => "responses", "model" => "gpt-x"}

    assert {:done, %{"reason" => "below_context_window"}, []} =
             prepare(session(), %{"config" => responses})

    assert {:summarize, plan} =
             prepare(session(), %{
               "config" => Map.put(responses, "compaction", %{"strategy" => "openai"}),
               "context_tokens" => 128_000,
               "model" => "claude-x"
             })

    assert plan["fingerprint"] ==
             "797dd587752948820d844e19fd752b68cfd47bd603a29dc85e027f23e2d0b24c"
  end

  test "admission, the trigger, and the backoff settle without a model call" do
    assert {:done, %{"status" => "noop", "reason" => "session_active"}, []} =
             prepare(session(%{status: :active}), %{"config" => config()})

    assert {:done, %{"reason" => "below_context_window"}, []} =
             prepare(session(), %{"config" => config(%{"context_tokens" => 500_000})})

    # The host reads its model configuration only for a session past the
    # pre-filter.
    assert {:done, %{"reason" => "below_prefilter"}, []} =
             prepare(session(%{messages: messages(100)}), %{})

    assert :needs_config = prepare(session(), %{})

    assert {:fail, _plan, {:session_config, :unresolved}} =
             prepare(session(), %{"config_error" => :unresolved})

    {:summarize, plan} = prepare(session(), %{"config" => config()})

    failure = %{
      "config_fingerprint" => plan["fingerprint"],
      "retryable" => true,
      "next_retry_at" => System.system_time(:second) + 60
    }

    assert {:done, %{"reason" => "{:compaction_backoff, " <> _}, [event]} =
             prepare(session(%{compaction_failure: failure}), %{
               "config" => config(),
               "source_message_id" => "src-1"
             })

    assert event["type"] == "session_compact_result" and event["source_message_id"] == "src-1"
  end

  test "the first explicit strategy that names one wins" do
    strategy = fn candidates ->
      {:summarize, plan} =
        Session.query(session(), :compaction_prepare, {:compact, %{"strategy" => candidates}})

      plan["strategy"]
    end

    assert strategy.([" OpenAI ", "summary"]) == "openai_responses"
    assert strategy.(["bogus", :salix]) == "summary"
    assert strategy.([nil, nil]) == nil
  end

  test "the request drops unanswered tool calls and ends with the instruction" do
    {:summarize, plan} = prepare(session(), %{"config" => config()})

    assert {:summary, messages} =
             Session.query(session(), :compaction_request, {plan, config(), "system prompt"})

    assert [%{role: "summary", content: "system prompt"} | _] = messages
    assert %{tool_calls: [%{"id" => "c1"}]} = Enum.find(messages, &(&1[:id] == 2))
    assert %{role: "user", content: _instruction} = List.last(messages)

    responses = Map.put(config(), "compaction_strategy", "openai_responses")

    assert {:provider, _messages} =
             Session.query(session(), :compaction_request, {plan, responses, "p"})

    # A present text key wins over the atom key, even when it is nil.
    nested = Map.put(config(), "compaction", %{"strategy" => nil, strategy: "openai"})

    assert {:summary, _messages} =
             Session.query(session(), :compaction_request, {plan, nested, "p"})

    lone =
      session(%{
        messages: [%{id: 1, seq: 1, role: "user", content: "hi"}],
        last_seq: 1,
        next_message_id: 2,
        last_ack_message_id: 1
      })

    assert :skip = Session.query(lone, :compaction_request, {plan, config(), "p"})
  end

  test "a model answer becomes a summary, an invalid answer, or a failure" do
    {:summarize, plan} = prepare(session(), %{"config" => config()})
    outcome = &Session.query(session(), :compaction_outcome, {plan, &1})

    assert {:commit, {:summary, "<compacted-context>\nthe body\n</compacted-context>"}} =
             outcome.(
               {:summary_text, "x <compaction-summary>\n the body \n</compaction-summary> y"}
             )

    assert {:commit, {:error, :missing_compaction_summary_tags}} =
             outcome.({:summary_text, "<compaction-summary>  </compaction-summary>"})

    assert {:commit, {:error, :empty_provider_compaction}} = outcome.({:provider_items, []})

    assert {:result, %{"status" => "skipped", "reason" => "not_enough_context"}, []} =
             outcome.(:skip)

    explicit = %{plan | "auto" => false}

    assert {:result, %{"status" => "failed_soft", "reason" => "timeout"}, []} =
             Session.query(session(), :compaction_outcome, {explicit, {:error, :timeout}})
  end

  test "the commit writes the summary, or the failure and its recovery summary" do
    {:summarize, plan} = prepare(session(), %{"config" => config()})

    assert {:ok, [prompt, compaction], %{"status" => "compacted"}, true} =
             Session.query(session(), :compaction_commit, {plan, {:summary, "s"}, "new prompt"})

    assert prompt["system_prompt"] == "new prompt"
    assert compaction["compacted_through"] == 4 and compaction["summary_sequence"] == 1

    invalid = {:error, :missing_compaction_summary_tags}

    assert {:ok, events, %{"status" => "failed_soft"}, false} =
             Session.query(session(), :compaction_commit, {plan, invalid, nil})

    [recovery, failure, _marker] = events
    assert failure["category"] == "invalid_compaction_summary" and failure["retryable"] == false
    assert recovery["summary"] =~ "through message id 4, but it could not be summarized"

    changed = session(%{summary_sequence: 3})

    assert {:error, {:stale_compaction_snapshot, _}} =
             Session.query(changed, :compaction_commit, {plan, {:summary, "s"}, nil})
  end

  test "a reason is its text, an atom's name, or an inspected term, at most 2048 bytes" do
    reason = fn value ->
      {result, _events} =
        Session.query(session(), :compaction_result_events, {"noop", value, nil})

      result["reason"]
    end

    assert reason.("plain") == "plain"
    assert reason.(:session_active) == "session_active"

    assert reason.({:dependency_crashed, :compaction, %RuntimeError{message: "x"}}) ==
             inspect({:dependency_crashed, :compaction, %RuntimeError{message: "x"}})

    long = reason.(String.duplicate("é", 1500))
    assert byte_size(long) == 2048 and String.valid?(long)
    assert String.ends_with?(long, "...[truncated]")
  end
end
