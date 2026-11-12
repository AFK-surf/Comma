defmodule CommaWeb.OpenThreadsTest do
  use ExUnit.Case, async: true
  alias CommaWeb.OpenThreads

  @start "https://team.slack.com/archives/C1/p1761984000000100"
  @reply "https://team.slack.com/archives/C1/p1761990000000200?thread_ts=1761984000.000100&cid=C1"
  @elsewhere "https://team.slack.com/archives/C2/p1761999000000300"

  defp input do
    OpenThreads.input(
      [
        %{
          "text" => "I'll send Lena the Q3 numbers by Friday",
          "ts" => "1761984000.000100",
          "permalink" => @start
        },
        %{
          "text" => "still on it,  numbers\ntomorrow",
          "ts" => "1761990000.000200",
          "permalink" => @reply
        },
        %{"text" => "lunch?", "ts" => "1761999000.000300", "permalink" => @elsewhere}
      ],
      [],
      "pengx"
    )
  end

  test "a thread keeps only cited evidence, keyed by its Slack thread" do
    answer = %{
      "threads" => [
        %{
          "kind" => "promised",
          "status" => "open",
          "summary" => "Send Lena the Q3 numbers",
          "counterpart" => "Lena",
          "due" => "2025-11-07",
          # A newer message of another thread is not this thread's evidence.
          "evidence" => [@reply, @start, @elsewhere]
        },
        # A made-up permalink is no evidence.
        %{
          "kind" => "asked",
          "status" => "open",
          "summary" => "Invented",
          "counterpart" => nil,
          "due" => "Friday",
          "evidence" => ["https://team.slack.com/archives/C9/p1"]
        }
      ]
    }

    assert {:ok, [thread]} = OpenThreads.build(answer, input())

    # The reply and the thread start key the same thread; the newest gives the link.
    assert thread["thread_key"] == "slack:C1/1761984000.000100"
    assert thread["url"] == @reply
    assert thread["quote"] == "still on it, numbers tomorrow"
    assert thread["due_on"] == ~D[2025-11-07]
    assert thread["evidence_at"] == ~U[2025-11-01 09:40:00.000000Z]
    assert OpenThreads.thread_key(@start) == thread["thread_key"]

    assert {:error, :invalid_open_threads} = OpenThreads.build(%{"entries" => []}, input())
  end

  test "new messages split into batches that each fit, so every message reaches the model" do
    message = fn n, text -> %{"text" => text, "ts" => "#{n}.0", "permalink" => "p#{n}"} end
    many = for n <- 1..70, do: message.(n, String.duplicate("x", 500))
    # Too large alone, in multi-byte graphemes: a family emoji is 25 bytes.
    huge =
      message.(71, String.duplicate("👨‍👩‍👧‍👦", 1_200))
      |> Map.put("thread", String.duplicate("线", 1_200))
      |> Map.put("replies", [%{"text" => "z"}])

    batches = OpenThreads.batches(many ++ [huge])

    assert Enum.map(List.flatten(batches), & &1["ts"]) == Enum.map(many ++ [huge], & &1["ts"])

    for batch <- batches do
      assert length(batch) <= 60
      # Each batch reaches the model whole: the input keeps every message.
      sent = OpenThreads.input(batch, [], "member")["ownMessages"]
      assert Enum.map(sent, & &1["ts"]) == Enum.map(batch, & &1["ts"])
    end

    # A message too large alone loses its replies and is cut to valid text.
    cut = List.last(List.last(batches))
    refute Map.has_key?(cut, "replies")
    assert String.valid?(cut["text"]) and cut["text"] != ""
    assert byte_size(Jason.encode!(cut)) <= 24_000
  end
end
