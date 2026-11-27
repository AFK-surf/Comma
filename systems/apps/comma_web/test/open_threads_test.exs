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

  test "Slack member read paginates past one chatty thread and keeps more than ten distinct threads and DMs" do
    alias CommaWeb.RecommendationSlackMemberSource

    page_1_threads =
      for i <- 1..15 do
        %{
          "text" => "noisy reply #{i}",
          "user" => "UOTHER",
          "ts" => "1761990#{String.pad_leading("#{i}", 3, "0")}.000100",
          "channel" => %{"id" => "C1"},
          "permalink" =>
            "https://team.slack.com/archives/C1/p1761990#{i}?thread_ts=1761900001.000100"
        }
      end

    page_2_threads =
      for t <- 2..16 do
        %{
          "text" => "waiting on you in thread #{t}",
          "user" => "UOTHER",
          "ts" => "1761980#{String.pad_leading("#{t}", 3, "0")}.000100",
          "channel" => %{"id" => "C1"},
          "permalink" =>
            "https://team.slack.com/archives/C1/p1761980#{t}?thread_ts=1761900#{String.pad_leading("#{t}", 3, "0")}.000100"
        }
      end

    dms =
      for d <- 1..14 do
        %{
          "text" => "dm #{d}",
          "user" => "U#{d}",
          "ts" => "1761970#{String.pad_leading("#{d}", 3, "0")}.000100",
          "channel" => %{"id" => "D#{d}", "is_im" => true},
          "permalink" => "https://team.slack.com/archives/D#{d}/p1761970#{d}"
        }
      end

    request = fn "GET", url, _opts ->
      uri = URI.parse(url)
      params = URI.decode_query(uri.query || "")

      case {uri.path, params["query"], params["page"]} do
        {"/api/auth.test", _, _} ->
          {:ok, %{"ok" => true, "user_id" => "UME1", "team_id" => "T1"}}

        {"/api/search.messages", "<@UME1>" <> _, _} ->
          {:ok, %{"ok" => true, "messages" => %{"matches" => [], "paging" => %{"pages" => 1}}}}

        {"/api/search.messages", "to:me" <> _, "1"} ->
          {:ok, %{"ok" => true, "messages" => %{"matches" => dms, "paging" => %{"pages" => 1}}}}

        {"/api/search.messages", "is:thread" <> _, "1"} ->
          {:ok,
           %{
             "ok" => true,
             "messages" => %{"matches" => page_1_threads, "paging" => %{"pages" => 2}}
           }}

        {"/api/search.messages", "is:thread" <> _, "2"} ->
          {:ok,
           %{
             "ok" => true,
             "messages" => %{"matches" => page_2_threads, "paging" => %{"pages" => 2}}
           }}
      end
    end

    assert {:ok, %{"messages" => %{"matches" => matches}}, _subject} =
             RecommendationSlackMemberSource.read(request, ~U[2026-11-19 00:00:00Z])

    by_rel = Enum.group_by(matches, & &1["memberRelation"])
    assert length(by_rel["direct_message_to_you"]) == 14
    assert length(by_rel["replied_in_your_thread"]) == 16
  end

  test "own_messages paginates until since_ts and thread_news falls back to channel replies" do
    alias CommaWeb.RecommendationSlackMemberSource

    request = fn "GET", url, _opts ->
      uri = URI.parse(url)
      params = URI.decode_query(uri.query || "")

      case {uri.path, params["page"]} do
        {"/api/auth.test", _} ->
          {:ok, %{"ok" => true, "user_id" => "UME1", "team_id" => "T1", "user" => "me"}}

        {"/api/search.messages", "1"} ->
          {:ok,
           %{
             "ok" => true,
             "messages" => %{
               "matches" => [
                 %{
                   "user" => "UME1",
                   "text" => "newest",
                   "ts" => "1761990300.000100",
                   "channel" => %{"id" => "C1", "name" => "eng"},
                   "permalink" => "https://team.slack.com/archives/C1/p1761990300000100"
                 }
               ],
               "paging" => %{"pages" => 3}
             }
           }}

        {"/api/search.messages", "2"} ->
          {:ok,
           %{
             "ok" => true,
             "messages" => %{
               "matches" => [
                 %{
                   "user" => "UME1",
                   "text" => "just after cursor",
                   "ts" => "1761990200.000100",
                   "channel" => %{"id" => "C1", "name" => "eng"},
                   "permalink" => "https://team.slack.com/archives/C1/p1761990200000100"
                 },
                 %{
                   "user" => "UME1",
                   "text" => "at cursor",
                   "ts" => "1761990100.000100",
                   "channel" => %{"id" => "C1", "name" => "eng"},
                   "permalink" => "https://team.slack.com/archives/C1/p1761990100000100"
                 }
               ],
               "paging" => %{"pages" => 3}
             }
           }}

        {"/api/conversations.replies", _} ->
          # Only the root post itself, no thread replies.
          {:ok,
           %{
             "ok" => true,
             "messages" => [%{"user" => "UME1", "ts" => "1761990200.000100", "text" => "root"}]
           }}

        {"/api/conversations.history", _} ->
          # Slack history returns newest first; a reply in another thread is ignored.
          {:ok,
           %{
             "ok" => true,
             "messages" => [
               %{
                 "user" => "UOTHER",
                 "ts" => "1761990260.000100",
                 "thread_ts" => "1761900000.000100",
                 "text" => "other thread"
               },
               %{
                 "user" => "UOTHER",
                 "ts" => "1761990250.000100",
                 "text" => "Answered directly in channel"
               }
             ]
           }}
      end
    end

    # Stops at page 2 once `since_ts` is reached (page 3 would fail CaseClauseError if called).
    assert {:ok, own, _subject} =
             RecommendationSlackMemberSource.own_messages(
               request,
               ~U[2026-11-19 00:00:00Z],
               nil,
               since_ts: "1761990100.000100"
             )

    assert Enum.map(own, & &1["text"]) == ["newest", "just after cursor", "at cursor"]

    assert {:ok, %{"t1" => [%{"from" => "other", "text" => "Answered directly in channel"}]}} =
             RecommendationSlackMemberSource.thread_news(request, %{
               "t1" => {"C1", "1761990200.000100", "1761990200.000100"}
             })
  end
end
