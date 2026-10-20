defmodule Comma.RecommendationDraftTest do
  use SystemsClock.Case, async: true
  alias Comma.{RecommendationContract, RecommendationDraft}

  test "the application owns paragraph encoding, identity, links and confirmation" do
    {draft, context} = fixture()

    assert {:ok, snapshot} =
             RecommendationDraft.compile(draft, context, %{generation: 9, source_revision: 4}, [],
               now_ms: 1_000
             )

    assert snapshot["generation"] == 9
    assert snapshot["sourceRevision"] == 4
    assert snapshot["generatedAt"] == 1_000
    assert hd(snapshot["summary"])["text"] == "Good morning\n\nReview "

    assert get_in(snapshot, [
             "cards",
             Access.at(0),
             "items",
             Access.at(0),
             "action",
             "requiresConfirmation"
           ]) == true

    assert RecommendationContract.validate(
             snapshot,
             %{"account" => ["https://github.com/AFK-surf/Comma/pull/1"]},
             []
           ) == :ok
  end

  test "unknown references and model-authored protocol fields cannot become public output" do
    {draft, context} = fixture()
    bad = put_in(draft, ["paragraphs", Access.at(0), Access.at(1), "reference"], "invented")

    assert {:error, :unknown_briefing_reference} =
             RecommendationDraft.compile(bad, context, %{generation: 1, source_revision: 1}, [])

    assert {:error, :invalid_briefing_content} =
             RecommendationDraft.compile(
               Map.put(draft, "generation", 99),
               context,
               %{generation: 1, source_revision: 1},
               []
             )
  end

  test "three concise member suggestions compile with source excerpts" do
    records =
      for n <- 1..3,
          do: %{"text" => "Source request #{n}", "permalink" => "https://example.com/#{n}"}

    fact = %{
      "sourceId" => "mine",
      "toolkit" => "slack",
      "appName" => "Slack",
      "data" => %{"messages" => %{"matches" => records}}
    }

    context =
      RecommendationDraft.prepare([fact], %{"mine" => Enum.map(records, & &1["permalink"])})

    draft = %{
      "selected" =>
        Enum.map(1..3, &%{"id" => "s1r#{&1}", "recommendation" => "Follow up on request #{&1}"})
    }

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               draft,
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               []
             )

    assert length(hd(snapshot["cards"])["items"]) == 3

    assert RecommendationContract.validate(
             snapshot,
             %{"mine" => Enum.map(records, & &1["permalink"])},
             []
           ) == :ok
  end

  test "a source has no quota: six ranked suggestions from one mailbox all compile" do
    mail = fn source, count ->
      records =
        for n <- 1..count do
          url = "https://mail.example/#{source}/#{n}"

          %{
            "subject" => "Matter #{n}",
            "webUrl" => url,
            "threadId" => "t#{n}",
            "messageId" => "m#{n}"
          }
        end

      {%{
         "sourceId" => source,
         "toolkit" => "gmail",
         "appName" => "Gmail",
         "data" => %{"messages" => records}
       }, Enum.map(records, & &1["webUrl"])}
    end

    {home, home_urls} = mail.("home", 6)
    {work, work_urls} = mail.("work", 1)
    evidence = %{"home" => home_urls, "work" => work_urls}
    context = RecommendationDraft.prepare([home, work], evidence, "member")

    # The model ranks one work matter between the member's personal matters.
    ranked = ~w(s1r1 s1r2 s2r1 s1r3 s1r4 s1r5 s1r6)

    draft = %{
      "selected" => Enum.map(ranked, &%{"id" => &1, "recommendation" => "Handle matter #{&1}"})
    }

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               draft,
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               []
             )

    # Cards keep rank order: the first mailbox card, the second account, then
    # the mailbox's continued card. Two accounts of one app keep distinct IDs.
    assert Enum.map(snapshot["cards"], &{&1["id"], &1["sourceIds"], length(&1["items"])}) == [
             {"gmail", ["home"], 4},
             {"gmail-2", ["work"], 1},
             {"gmail-3", ["home"], 2}
           ]

    assert RecommendationContract.validate(snapshot, evidence, []) == :ok
  end

  test "card limits keep the highest ranked suggestions" do
    facts =
      for source <- ~w(a b c d e f) do
        %{
          "sourceId" => source,
          "toolkit" => "gmail",
          "appName" => "Gmail",
          "data" => %{
            "messages" =>
              for(
                n <- 1..4,
                do: %{
                  "subject" => "#{source}#{n}",
                  "webUrl" => "https://mail.example/#{source}/#{n}"
                }
              )
          }
        }
      end

    evidence =
      Map.new(facts, &{&1["sourceId"], Enum.map(&1["data"]["messages"], fn m -> m["webUrl"] end)})

    context = RecommendationDraft.prepare(facts, evidence, "member")

    # Sources s1..s4 fill four cards in rank order. s5 and s6 interleave after them.
    ranked =
      for(s <- 1..4, n <- 1..4, do: "s#{s}r#{n}") ++ ~w(s5r1 s5r2 s6r1 s6r2 s5r3 s5r4 s6r3 s6r4)

    draft = %{"selected" => Enum.map(ranked, &%{"id" => &1, "recommendation" => "Handle #{&1}"})}

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               draft,
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               []
             )

    # The 18 highest ranked rows remain; rank 19 onward drops, not a full card's last row.
    assert Enum.map(snapshot["cards"], &{&1["sourceIds"], length(&1["items"])}) ==
             [{["a"], 4}, {["b"], 4}, {["c"], 4}, {["d"], 4}, {["e"], 2}]
  end

  test "the hover renders each product's quote in the member's language" do
    quoted = "https://mail.google.com/mail/#inbox/m1"
    plain = "https://mail.google.com/mail/#inbox/m2"
    authored = "https://mail.google.com/mail/#inbox/m3"

    fact = %{
      "sourceId" => "mail",
      "toolkit" => "gmail",
      "appName" => "Gmail",
      "data" => %{
        "messages" => [
          %{"subject" => "Q4 renewal", "webUrl" => quoted},
          %{"subject" => "A <b> title", "webUrl" => plain},
          %{"subject" => "Shared file", "webUrl" => authored}
        ]
      },
      "quotes" => %{
        quoted => %{
          "title" => "Q4 renewal",
          "author" => "Alex",
          "facts" => [
            %{"kind" => "checks", "value" => "failing"},
            %{"kind" => "review", "value" => "changes_requested"}
          ],
          "lines" => ["Please sign <https://example.com/c|the copy>.", "• by Friday"]
        },
        authored => %{"author" => "Sam"}
      }
    }

    context =
      RecommendationDraft.prepare([fact], %{"mail" => [quoted, plain, authored]}, "member")

    draft = %{
      "selected" => [
        %{"id" => "s1r1", "recommendation" => "Sign the renewal"},
        %{"id" => "s1r2", "recommendation" => "Read the title"},
        %{"id" => "s1r3", "recommendation" => "Open the file"}
      ]
    }

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               draft,
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               [],
               locale: "zh-CN"
             )

    assert snapshot["prompts"]["s1r1"]["context"] ==
             "Q4 renewal\n检查未通过 · 需要修改\nAlex：Please sign <https://example.com/c|the copy>.\n• by Friday"

    # A record without a quote shows its title as quote text.
    assert snapshot["prompts"]["s1r2"]["context"] == "A &lt;b&gt; title"
    # A quote with an author and no words, such as a file-only Slack message,
    # shows the title too.
    assert snapshot["prompts"]["s1r3"]["context"] == "Shared file"
  end

  defp fixture do
    url = "https://github.com/AFK-surf/Comma/pull/1"

    context =
      RecommendationDraft.prepare(
        [%{"sourceId" => "account", "toolkit" => "github", "appName" => "GitHub", "data" => %{}}],
        %{"account" => [url]}
      )

    parts = [
      %{"text" => "Review "},
      %{"reference" => "s1r1", "label" => "#1"},
      %{"text" => " before release."}
    ]

    draft = %{
      "title" => "Good morning",
      "paragraphs" => [parts],
      "routines" => [
        %{
          "source" => "s1",
          "layout" => "text",
          "items" => [
            %{
              "parts" => parts,
              "action" => %{
                "type" => "send_to_comma",
                "label" => "Review PR #1",
                "prompt" => "Review PR #1 before release."
              }
            }
          ]
        }
      ]
    }

    {draft, context}
  end
end
