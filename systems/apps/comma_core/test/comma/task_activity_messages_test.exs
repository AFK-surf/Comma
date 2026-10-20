defmodule Comma.TaskActivityMessagesTest do
  use ExUnit.Case, async: true

  alias Comma.TaskActivityMessages

  defp agent(content, metadata \\ %{}),
    do: %{
      "message_id" => "msg_1",
      "seq" => 7,
      "actor_type" => "agent",
      "role_label" => "worker",
      "created_at" => 1_720_000_007,
      "metadata" => metadata,
      "delivery_filter" => %{"participant_ids" => []},
      "content" => content
    }

  test "keeps what a Task's Activity reads and an empty text in place of what an Agent showed" do
    report = String.duplicate("A long report. ", 400)

    assert TaskActivityMessages.slim(
             agent([
               %{"type" => "text", "text" => report},
               %{"type" => "milestone", "title" => "Wrote the agenda"},
               %{"type" => "file", "path" => "agenda.pdf"}
             ])
           ) ==
             agent([
               %{"type" => "milestone", "title" => "Wrote the agenda"},
               %{"type" => "text", "text" => ""}
             ])

    # A milestone-only Message stays one, so no client shows it.
    only = agent([%{"type" => "milestone", "title" => "Wrote the agenda"}])
    assert TaskActivityMessages.slim(only) == only
  end

  test "keeps the words of a request: a person's Message and a Router's hand-in, cut short" do
    words = "Rewrite the invites.\n" <> String.duplicate("x", 1_000)

    person =
      TaskActivityMessages.slim(%{
        "actor_type" => "user",
        "content" => [%{"type" => "text", "text" => words}, %{"type" => "image", "path" => "a"}]
      })

    assert [%{"type" => "text", "text" => text}] = person["content"]
    assert String.starts_with?(text, "Rewrite the invites.\n")
    assert String.length(text) == 500

    handed_in =
      TaskActivityMessages.slim(
        agent([%{"type" => "text", "text" => "Rewrite the invites."}], %{"task_request" => true})
      )

    assert handed_in["content"] == [%{"type" => "text", "text" => "Rewrite the invites."}]
  end

  test "keeps a Loop wake's origin without its input" do
    wake =
      TaskActivityMessages.slim(%{
        "actor_type" => "system",
        "agent_input" => %{
          "role" => "user",
          "content" => String.duplicate("x", 2_000),
          "trusted_origin" => %{"provider" => "loop", "loop_id" => "lop_1", "source_text" => "x"}
        },
        "content" => "Run the hourly check."
      })

    assert wake["agent_input"] == %{"trusted_origin" => %{"provider" => "loop"}}
    assert wake["content"] == [%{"type" => "text", "text" => "Run the hourly check."}]

    # Any other delivery keeps only that it is one.
    other = TaskActivityMessages.slim(%{"actor_type" => "system", "agent_input" => %{}})
    assert other["agent_input"] == %{}
  end
end
