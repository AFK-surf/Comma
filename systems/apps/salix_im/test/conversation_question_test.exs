defmodule SalixIM.ConversationQuestionTest do
  use ExUnit.Case, async: true

  alias SalixIM.{ConversationMessage, ConversationQuestion}

  @question %{
    "type" => "question",
    "prompt" => "这两个会怎么处理？",
    "choices" => [
      %{"label" => "把同步会挪到周四", "description" => "双方周四下午都有空。", "recommended" => true},
      %{"label" => "两个都参加", "description" => "  "},
      "请对方改期"
    ],
    "text" => "would render twice in older clients"
  }

  defp question_message(question, actor \\ "agent"),
    do: %{
      "actor_type" => actor,
      "content" => [%{"type" => "text", "text" => "Context"}, question]
    }

  test "an Agent's question is numbered, defaulted, and followed by a plain-text fallback" do
    assert {:ok, [prose, question, fallback]} =
             ConversationQuestion.normalize_agent_content([
               %{"type" => "text", "text" => "Context"},
               @question
             ])

    assert prose == %{"type" => "text", "text" => "Context"}
    refute Map.has_key?(question, "text")
    assert Enum.map(question["choices"], & &1["id"]) == ["c1", "c2", "c3"]
    refute Map.has_key?(Enum.at(question["choices"], 1), "description")
    assert question["multi_select"] == false and question["allow_other"] == true

    assert fallback == %{
             "type" => "text",
             "text" => "这两个会怎么处理？\n\n1. 把同步会挪到周四\n2. 两个都参加\n3. 请对方改期",
             "fallback_for" => "question"
           }

    # A retry of the same send produces the same content, so its fingerprint holds.
    assert {:ok, [prose, question, fallback]} ==
             ConversationQuestion.normalize_agent_content([prose, question, fallback])

    assert {:ok, _attrs} =
             ConversationMessage.prepare(%{
               "actor_type" => "agent",
               "content" => [prose, question, fallback]
             })
  end

  test "a question out of bounds is refused with what to fix" do
    one_choice = Map.put(@question, "choices", [%{"label" => "only"}])

    two_recommended =
      Map.put(@question, "choices", [
        %{"label" => "a", "recommended" => true},
        %{"label" => "b", "recommended" => true}
      ])

    assert {:error, {:bad_request, "A question offers 2 to 6 choices"}} =
             ConversationQuestion.normalize_agent_content([one_choice])

    assert {:error, {:bad_request, "At most one choice is recommended"}} =
             ConversationQuestion.normalize_agent_content([two_recommended])

    assert {:error, {:bad_request, _}} =
             ConversationQuestion.normalize_agent_content([@question, @question])
  end

  test "only an Agent asks and only a user answers, replying to the question" do
    {:ok, content} = ConversationQuestion.normalize_agent_content([@question])
    question_id = SalixStore.Ids.new_message_id()

    answer = %{
      "type" => "question_answer",
      "question_message_id" => question_id,
      "choice_ids" => ["c1"]
    }

    assert {:error, {:bad_request, "Only an Agent can send a question block"}} =
             ConversationMessage.prepare(%{"actor_type" => "user", "content" => content})

    assert {:error, {:bad_request, "question_answer: only a user can answer a question"}} =
             ConversationMessage.prepare(%{
               "actor_type" => "agent",
               "reply_to_message_id" => question_id,
               "content" => [answer]
             })

    assert {:error, {:bad_request, "question_answer: reply to the question Message it answers"}} =
             ConversationMessage.prepare(%{"actor_type" => "user", "content" => [answer]})

    assert {:ok, _} =
             ConversationMessage.prepare(%{
               "actor_type" => "user",
               "reply_to_message_id" => question_id,
               "content" => [%{"type" => "text", "text" => "把同步会挪到周四。"}, answer]
             })

    assert {:error, {:bad_request, "question_answer: a skipped answer picks nothing"}} =
             ConversationQuestion.validate_blocks([Map.put(answer, "skipped", true)])
  end

  test "an answer picks only what its question offers" do
    {:ok, [question, _fallback]} = ConversationQuestion.normalize_agent_content([@question])
    single = question_message(question)
    closed = question_message(Map.put(question, "allow_other", false))
    answer = %{"type" => "question_answer", "choice_ids" => ["c2"]}

    assert :ok = ConversationQuestion.admit_answer(answer, single)

    assert :ok =
             ConversationQuestion.admit_answer(
               %{answer | "choice_ids" => []} |> Map.put("other", "改到下周一"),
               single
             )

    assert {:error, {:bad_request, "question_answer: this question takes one choice"}} =
             ConversationQuestion.admit_answer(%{answer | "choice_ids" => ["c1", "c2"]}, single)

    assert :ok =
             ConversationQuestion.admit_answer(
               %{answer | "choice_ids" => ["c1", "c2"]},
               question_message(Map.put(question, "multi_select", true))
             )

    assert {:error, {:bad_request, "question_answer: pick only the choices the question offers"}} =
             ConversationQuestion.admit_answer(%{answer | "choice_ids" => ["c9"]}, single)

    assert {:error, {:bad_request, "question_answer: this question does not take another answer"}} =
             ConversationQuestion.admit_answer(Map.put(answer, "other", "别的"), closed)

    assert {:error,
            {:bad_request, "question_answer: the replied Message does not ask a question"}} =
             ConversationQuestion.admit_answer(answer, question_message(question, "user"))
  end
end
