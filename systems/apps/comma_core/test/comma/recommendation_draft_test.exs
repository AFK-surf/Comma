defmodule Comma.RecommendationDraftTest do
  use ExUnit.Case, async: true
  alias Comma.{RecommendationContract, RecommendationDraft}

  test "Slack display removes only the verified recipient prefix and retains source evidence" do
    url = "https://example.com/message"

    for {text, expected} <- [
          {"<@SELF> Please test <@OTHER>'s fix", "Please test <@OTHER>'s fix"},
          {"<@OTHER> Please ask <@SELF>", "<@OTHER> Please ask you"},
          {"诊断说明。 <@SELF> 请提供会话链接", "请提供会话链接"}
        ] do
      fact = %{
        "sourceId" => "slack",
        "toolkit" => "slack",
        "appName" => "Slack",
        "memberSubject" => %{"provider_user_id" => "SELF"},
        "data" => %{"messages" => %{"matches" => [%{"text" => text, "permalink" => url}]}}
      }

      context = RecommendationDraft.prepare([fact], %{"slack" => [url]})
      assert [candidate] = Comma.RecommendationMemberSelection.candidates(context)
      assert candidate["title"] == expected
      assert candidate["excerpt"] == text
    end
  end

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

  test "a row the model leaves as a plain source link asks Comma for help with its task" do
    {draft, context} = fixture()
    url = "https://github.com/AFK-surf/Comma/pull/1"
    path = ["routines", Access.at(0), "items", Access.at(0)]

    draft =
      put_in(draft, path ++ ["action"], %{
        "type" => "open_url",
        "label" => "Open PR",
        "reference" => "s1r1"
      })

    assert {:ok, snapshot} =
             RecommendationDraft.compile(draft, context, %{generation: 1, source_revision: 1}, [],
               locale: "en"
             )

    assert get_in(snapshot, ["cards", Access.at(0), "items", Access.at(0), "action"]) == %{
             "type" => "send_to_comma",
             "label" => "Use prompt",
             "prompt" => "Help me review #1 before release.\n\n" <> url,
             "requiresConfirmation" => true
           }

    assert RecommendationContract.validate(snapshot, %{"account" => [url]}, []) == :ok

    # A full-length row keeps its source URL whole within the prompt limit.
    long =
      put_in(draft, path ++ ["parts"], [
        %{"text" => String.duplicate("a", 1_198)},
        %{"reference" => "s1r1", "label" => "#1"}
      ])

    assert {:ok, snapshot} =
             RecommendationDraft.compile(long, context, %{generation: 1, source_revision: 1}, [])

    prompt = get_in(snapshot, ["cards", Access.at(0), "items", Access.at(0), "action", "prompt"])
    assert String.length(prompt) == 1_200
    assert String.ends_with?(prompt, "\n\n" <> url)
    assert RecommendationContract.validate(snapshot, %{"account" => [url]}, []) == :ok
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

  test "empty results are a valid briefing and failures are program-owned warnings" do
    {draft, context} = fixture()
    draft = Map.put(draft, "routines", [])

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               draft,
               context,
               %{generation: 1, source_revision: 1},
               [%{"sourceId" => "failed-source"}],
               locale: "en"
             )

    assert snapshot["cards"] == []

    assert [%{"code" => "partial_sources", "sourceIds" => ["failed-source"]}] =
             snapshot["warnings"]

    assert RecommendationContract.validate(
             snapshot,
             %{"account" => ["https://github.com/AFK-surf/Comma/pull/1"]},
             ["failed-source"]
           ) == :ok
  end

  test "six full source cards retain the existing fair eighteen-row budget" do
    {draft, _context} = fixture()
    [routine] = draft["routines"]
    [item] = routine["items"]

    facts =
      for n <- 1..6,
          do: %{
            "sourceId" => "account-#{n}",
            "toolkit" => "source-#{n}",
            "appName" => "Source #{n}",
            "data" => %{}
          }

    evidence = Map.new(facts, &{&1["sourceId"], ["https://example.com/" <> &1["sourceId"]]})
    context = RecommendationDraft.prepare(facts, evidence)

    routines =
      for n <- 1..6 do
        items =
          for i <- 1..4,
              do: %{
                item
                | "parts" => [%{"text" => "Review item #{n}-#{i}"}],
                  "action" => Map.put(item["action"], "label", "Review #{n}-#{i}")
              }

        %{routine | "source" => "s#{n}", "items" => items}
      end

    draft = %{
      draft
      | "paragraphs" => [[%{"text" => "Your work needs review."}]],
        "routines" => routines
    }

    assert {:ok, snapshot} =
             RecommendationDraft.compile(draft, context, %{generation: 1, source_revision: 1}, [])

    assert Enum.map(snapshot["cards"], &length(&1["items"])) == [3, 3, 3, 3, 3, 3]
  end

  test "model response parsing has one JSON and byte boundary" do
    assert {:error, :invalid_briefing_content} = RecommendationDraft.decode("```json\n{}\n```")

    assert {:error, :invalid_briefing_content} =
             RecommendationDraft.decode(String.duplicate(" ", 65_537))
  end

  test "member rejects unrelated prose even with an admitted task reference" do
    {draft, context} = fixture()

    draft =
      put_in(draft, ["routines", Access.at(0), "items", Access.at(0), "parts"], [
        %{"text" => "Organize a birthday party using "},
        %{"reference" => "s1r1", "label" => "PAY-1"}
      ])

    assert {:error, :invalid_briefing_content} =
             RecommendationDraft.compile(
               draft,
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               []
             )
  end

  test "member prompts retain the exact record URL when identical source text has no link" do
    urls = ["https://github.com/team/a/pull/7", "https://github.com/team/b/pull/7"]

    fact = %{
      "sourceId" => "mine",
      "toolkit" => "github",
      "appName" => "GitHub",
      "data" => %{
        "issues" =>
          Enum.map(urls, fn url ->
            %{
              "title" => "Fix login",
              "html_url" => url,
              "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
            }
          end)
      }
    }

    context = RecommendationDraft.prepare([fact], %{"mine" => urls}, "member")

    draft = %{
      "selected" =>
        Enum.map(["s1r1", "s1r2"], &%{"id" => &1, "recommendation" => "Review login fix"})
    }

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               draft,
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               []
             )

    assert Enum.map(["s1r1", "s1r2"], &snapshot["prompts"][&1]["sourceUrl"]) == urls
    assert snapshot["prompts"]["s1r1"]["context"] == "Fix login"
    assert :ok = RecommendationContract.validate(snapshot)

    assert {:error, _} =
             snapshot
             |> put_in(["prompts", "s1r1", "sourceUrl"], Enum.at(urls, 1))
             |> RecommendationContract.validate()
  end

  test "member preview and recommendation bounds match client UTF-16 limits" do
    url = "https://example.com/item"

    fact = %{
      "sourceId" => "mine",
      "toolkit" => "slack",
      "appName" => "Slack",
      "data" => %{
        "messages" => %{
          "matches" => [%{"text" => String.duplicate("😀", 400), "permalink" => url}]
        }
      }
    }

    context = RecommendationDraft.prepare([fact], %{"mine" => [url]})
    run = %{generation: 1, source_revision: 1, relevance_mode: "member"}

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               %{"selected" => [%{"id" => "s1r1", "recommendation" => "Review this request."}]},
               context,
               run,
               []
             )

    preview = snapshot["prompts"]["s1r1"]["context"]

    assert preview == String.duplicate("😀", 300) <> "…"

    assert {:error, :invalid_briefing_content} =
             RecommendationDraft.compile(
               %{
                 "selected" => [%{"id" => "s1r1", "recommendation" => String.duplicate("😀", 51)}]
               },
               context,
               run,
               []
             )
  end

  test "member source links survive intact but never become clipped destinations" do
    source = "https://comma.slack.com/archives/C123/p123"
    run = %{generation: 1, source_revision: 1, relevance_mode: "member"}

    for {text, expected} <- [
          {"Read <https://example.com/fix|the fix> with <@U123|Alex>",
           "Read <https://example.com/fix|the fix> with <@U123|Alex>"},
          {String.duplicate("x", 580) <> " https://example.com/" <> String.duplicate("a", 80),
           String.duplicate("x", 580) <> " …"},
          {String.duplicate("x", 580) <> " <https://example.com/fix|long label>",
           String.duplicate("x", 580) <> " …"}
        ] do
      fact = %{
        "sourceId" => "mine",
        "toolkit" => "slack",
        "appName" => "Slack",
        "data" => %{"messages" => %{"matches" => [%{"text" => text, "permalink" => source}]}}
      }

      context = RecommendationDraft.prepare([fact], %{"mine" => [source]})

      assert {:ok, snapshot} =
               RecommendationDraft.compile(
                 %{"selected" => [%{"id" => "s1r1", "recommendation" => "Verify the fix"}]},
                 context,
                 run,
                 []
               )

      [card] = snapshot["cards"]
      [item] = card["items"]
      [%{"link" => link}] = item["parts"]
      assert snapshot["prompts"][link["promptId"]]["context"] == expected
      assert item["action"]["promptId"] == link["promptId"]
    end
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

  test "member renders bounded suggestions with source-owned previews and drops foreign rows" do
    context =
      RecommendationDraft.prepare(
        [
          %{
            "sourceId" => "mine",
            "toolkit" => "github",
            "appName" => "GitHub",
            "data" => %{
              "issues" => [
                %{
                  "title" => "Fix payment checkout",
                  "html_url" => "https://github.com/team/repo/issues/1",
                  "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
                }
              ]
            }
          }
        ],
        %{"mine" => ["https://github.com/team/repo/issues/1"]}
      )

    run = %{generation: 1, source_revision: 1, relevance_mode: "member"}

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               %{"selected" => [%{"id" => "s1r1", "recommendation" => "Review the work item"}]},
               context,
               run,
               []
             )

    assert get_in(snapshot, [
             "cards",
             Access.at(0),
             "items",
             Access.at(0),
             "parts",
             Access.at(0),
             "link",
             "label"
           ]) == "Review the work item"

    [card] = snapshot["cards"]
    [item] = card["items"]
    [%{"link" => link}] = item["parts"]

    assert %{"type" => "send_to_comma", "promptId" => id, "requiresConfirmation" => true} =
             item["action"]

    assert id == link["promptId"]

    assert snapshot["prompts"][id] == %{
             "sourceId" => "mine",
             "sourceUrl" => "https://github.com/team/repo/issues/1",
             "objective" => "Review the work item",
             "context" => "Fix payment checkout",
             "contextLabel" => "Original context (quoted)"
           }

    [summary_link] = Enum.filter(snapshot["summary"], &(&1["kind"] == "inline-link"))
    assert summary_link["link"]["promptId"] == id

    for text <- [
          " ",
          "Open https://evil.example",
          "<@OTHER> do this",
          "One\nTwo",
          String.duplicate("x", 101)
        ] do
      assert {:error, :invalid_briefing_content} =
               RecommendationDraft.compile(
                 %{"selected" => [%{"id" => "s1r1", "recommendation" => text}]},
                 context,
                 run,
                 []
               )
    end

    assert {:error, :invalid_briefing_content} =
             RecommendationDraft.compile(
               %{
                 "selected" => [
                   %{"id" => "s1r1", "recommendation" => "Review", "previewText" => "forged"}
                 ]
               },
               context,
               run,
               []
             )

    assert Jason.encode!(snapshot) =~ "Fix payment checkout"
    refute Jason.encode!(snapshot) =~ "birthday"

    for draft <- [
          %{"selected" => [%{"id" => "foreign", "recommendation" => "Review the work item"}]},
          %{"selected" => ["s1r1"], "title" => "birthday"}
        ] do
      assert {:error, :invalid_briefing_content} =
               RecommendationDraft.compile(draft, context, run, [])
    end

    # Foreign, forged and repeated rows drop alone. The first valid row publishes.
    assert {:ok, mixed} =
             RecommendationDraft.compile(
               %{
                 "selected" => [
                   %{"id" => "foreign", "recommendation" => "Review the work item"},
                   %{"id" => "s1r1", "recommendation" => "Review", "previewText" => "forged"},
                   %{"id" => "s1r1", "recommendation" => "Review the work item"},
                   %{"id" => "s1r1", "recommendation" => "Review it again"}
                 ]
               },
               context,
               run,
               []
             )

    assert [%{"items" => [_item]}] = mixed["cards"]
    assert mixed["prompts"]["s1r1"]["objective"] == "Review the work item"
    refute Jason.encode!(mixed) =~ "forged"

    assert {:ok, empty} = RecommendationDraft.compile(%{"selected" => []}, context, run, [])
    assert empty["cards"] == []
  end

  test "member summary places a named source immediately after each recommendation" do
    facts =
      for {app, url} <- [
            {"Slack", "https://example.com/one"},
            {"Linear", "https://example.com/two"}
          ] do
        data =
          if app == "Slack",
            do: %{"messages" => %{"matches" => [%{"text" => "First source", "permalink" => url}]}},
            else: %{
              "issues" => %{
                "nodes" => [
                  %{"title" => "Second source", "identifier" => "COMMA-244", "url" => url}
                ]
              }
            }

        %{"sourceId" => app, "toolkit" => String.downcase(app), "appName" => app, "data" => data}
      end

    context =
      RecommendationDraft.prepare(facts, %{
        "Slack" => ["https://example.com/one"],
        "Linear" => ["https://example.com/two"]
      })

    selection = %{
      "selected" => [
        %{"id" => "s1r1", "recommendation" => "Review first."},
        %{"id" => "s2r1", "recommendation" => "Review second."}
      ]
    }

    assert {:ok, draft} = Comma.RecommendationMemberSelection.project(selection, context, "zh-CN")

    assert [
             [
               %{"text" => _},
               %{"text" => "Review first "},
               %{"reference" => "s1r1", "label" => "Slack 原文"},
               %{"text" => "；"},
               %{"text" => "Review second "},
               %{"reference" => "s2r1", "label" => "COMMA-244"},
               %{"text" => "。"}
             ]
           ] = draft["paragraphs"]

    # The English lead-in and the first recommendation read as separate words.
    assert {:ok, english} = Comma.RecommendationMemberSelection.project(selection, context, "en")
    assert [paragraph] = english["paragraphs"]

    assert Enum.map_join(paragraph, &(&1["text"] || &1["label"])) =~
             ~r/:\sReview first Slack source; /

    assert {:ok, _} =
             RecommendationDraft.compile(
               selection,
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               [],
               locale: "zh-CN"
             )
  end

  test "all member provider projections retain source titles and URLs without invented tasks" do
    url = "https://example.com/work/1"

    inputs = [
      {"linear", %{"issues" => %{"nodes" => [%{"title" => "Work item", "url" => url}]}}},
      {"github",
       %{
         "issues" => [
           %{
             "title" => "Work item",
             "html_url" => url,
             "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
           }
         ]
       }},
      {"notion", %{"values" => [%{"title" => [%{"plain_text" => "Work item"}], "url" => url}]}},
      {"slack", %{"messages" => %{"matches" => [%{"text" => "Work item", "permalink" => url}]}}},
      {"gmail", %{"messages" => [%{"subject" => "Work item", "webUrl" => url}]}},
      {"googlecalendar", %{"items" => [%{"summary" => "Work item", "htmlLink" => url}]}},
      {"googledrive", %{"files" => [%{"name" => "Work item", "webViewLink" => url}]}}
    ]

    for {toolkit, data} <- inputs do
      context =
        RecommendationDraft.prepare(
          [%{"sourceId" => "mine", "toolkit" => toolkit, "appName" => toolkit, "data" => data}],
          %{"mine" => [url]}
        )

      assert [%{"id" => "s1r1", "title" => "Work item", "url" => ^url}] =
               Comma.RecommendationMemberSelection.candidates(context)

      assert {:ok, snapshot} =
               RecommendationDraft.compile(
                 %{"selected" => [%{"id" => "s1r1", "recommendation" => "Review the work item"}]},
                 context,
                 %{generation: 1, source_revision: 1, relevance_mode: "member"},
                 []
               )

      assert Jason.encode!(snapshot) =~ "Work item"
      assert RecommendationContract.validate(snapshot, %{"mine" => [url]}, []) == :ok
    end
  end

  test "bounded collector envelopes retain intact member candidates" do
    url = "https://github.com/example/project/issues/1"

    data = %{
      "_comma" => %{"truncated" => true, "originalBytes" => 20000},
      "value" => %{
        "issues" => [
          %{
            "title" => "Intact task",
            "html_url" => url,
            "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        ],
        "memberRelation" => "assigned_to_you"
      }
    }

    context =
      RecommendationDraft.prepare(
        [%{"sourceId" => "mine", "toolkit" => "github", "appName" => "GitHub", "data" => data}],
        %{"mine" => [url]}
      )

    assert [%{"title" => "Intact task", "relationship" => "assigned_to_you"}] =
             Comma.RecommendationMemberSelection.candidates(context)
  end

  test "old GitHub assignments are not current work candidates" do
    url = "https://github.com/example/project/issues/1"

    context =
      RecommendationDraft.prepare(
        [
          %{
            "sourceId" => "mine",
            "toolkit" => "github",
            "appName" => "GitHub",
            "data" => %{
              "issues" => [
                %{
                  "title" => "Historical assignment",
                  "html_url" => url,
                  "updated_at" => "2026-03-24T11:46:15Z"
                }
              ]
            }
          }
        ],
        %{"mine" => [url]}
      )
      |> Map.put(:prepared_at, ~U[2026-09-19 00:00:00Z])

    assert Comma.RecommendationMemberSelection.candidates(context) == []

    assert {:error, :invalid_briefing_content} =
             RecommendationDraft.compile(
               %{"selected" => [%{"id" => "s1r1", "recommendation" => "Review the work item"}]},
               context,
               %{generation: 1, source_revision: 1, relevance_mode: "member"},
               []
             )
  end

  test "eighteen multilingual tasks publish within the wire budget without losing source context" do
    facts =
      Enum.map(
        Enum.with_index(~w(slack linear notion gmail googlecalendar googledrive), 1),
        fn {toolkit, i} ->
          records =
            Enum.map(1..3, fn j ->
              title = String.duplicate("请", 120)
              url = "https://example.com/#{toolkit}/#{j}"

              case toolkit do
                "slack" -> %{"text" => String.duplicate("请", 1200), "permalink" => url}
                "linear" -> %{"title" => title, "url" => url}
                "notion" -> %{"title" => title, "url" => url}
                "gmail" -> %{"subject" => title, "webUrl" => url}
                "googlecalendar" -> %{"summary" => title, "htmlLink" => url}
                "googledrive" -> %{"name" => title, "webViewLink" => url}
              end
            end)

          data =
            case toolkit do
              "slack" -> %{"messages" => %{"matches" => records}}
              "linear" -> %{"issues" => %{"nodes" => records}}
              "notion" -> %{"values" => records}
              "gmail" -> %{"messages" => records}
              "googlecalendar" -> %{"items" => records}
              "googledrive" -> %{"files" => records}
            end

          %{
            "sourceId" => "source#{i}",
            "appName" => toolkit,
            "toolkit" => toolkit,
            "data" => data
          }
        end
      )

    evidence =
      Map.new(Enum.with_index(facts, 1), fn {fact, _} ->
        {fact["sourceId"], Enum.map(1..3, &"https://example.com/#{fact["toolkit"]}/#{&1}")}
      end)

    context = Comma.RecommendationDraft.prepare(facts, evidence, "member")

    selected =
      Enum.map(
        Comma.RecommendationMemberSelection.candidates(context),
        &%{"id" => &1["id"], "recommendation" => String.duplicate("核", 100)}
      )

    assert Enum.all?(facts, &(byte_size(Jason.encode!(&1["data"])) < 12_000))

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               %{"selected" => selected},
               context,
               %{relevance_mode: "member", generation: 1, source_revision: 1},
               [],
               locale: "zh-CN"
             )

    assert RecommendationContract.validate(snapshot, evidence, []) == :ok
    assert byte_size(Jason.encode!(snapshot)) <= 65_536
    assert Enum.sum(Enum.map(snapshot["cards"], &length(&1["items"]))) == 18
    assert map_size(snapshot["prompts"]) == 18

    for card <- snapshot["cards"], item <- card["items"] do
      [%{"link" => link}] = item["parts"]
      assert link["label"] == String.duplicate("核", 100)
      prompt = snapshot["prompts"][item["action"]["promptId"]]
      assert prompt["objective"] == link["label"]
      assert prompt["sourceId"] == link["sourceId"]

      assert prompt["context"] ==
               if(card["id"] == "slack",
                 do: String.duplicate("请", 600) <> "…",
                 else: String.duplicate("请", 120)
               )
    end

    assert {:error, :invalid_recommendation_prompt} =
             RecommendationContract.validate(
               put_in(snapshot, ["prompts", "s1r1", "sourceId"], "another-account")
             )

    assert {:error, :invalid_recommendation_prompt} =
             RecommendationContract.validate(
               update_in(snapshot, ["prompts"], &Map.delete(&1, "s1r1"))
             )
  end

  test "a non-Slack task carries its original record details to hover and composer" do
    url = "https://linear.app/team/issue/NET-1"
    description = "Retest the reconnect fix with a 30-second network interruption."

    facts = [
      %{
        "sourceId" => "mine",
        "toolkit" => "linear",
        "appName" => "Linear",
        "data" => %{"issues" => %{"nodes" => [%{"title" => "Reconnect failure", "url" => url}]}},
        "contexts" => %{
          url => %{"scope" => "record_excerpt", "text" => description, "truncated" => false}
        }
      }
    ]

    context = RecommendationDraft.prepare(facts, %{"mine" => [url]}, "member")

    assert {:ok, snapshot} =
             RecommendationDraft.compile(
               %{"selected" => [%{"id" => "s1r1", "recommendation" => "Retest reconnect"}]},
               context,
               %{relevance_mode: "member", generation: 1, source_revision: 1},
               []
             )

    prompt = snapshot["prompts"]["s1r1"]
    assert prompt["context"] == "Reconnect failure " <> description

    assert get_in(snapshot, ["cards", Access.at(0), "items", Access.at(0), "action", "promptId"]) ==
             "s1r1"
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
