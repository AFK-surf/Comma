defmodule Comma.RecommendationContractTest do
  use ExUnit.Case, async: true

  alias Comma.RecommendationContract

  test "renderer disclosure rejects the malformed action and item shapes seen in staging" do
    entry =
      Enum.find(
        SalixAgent.Tools.Recommendations.defs(),
        &(elem(&1, 0) == "recommendation.publish")
      )

    schema = SalixAgent.Tools.entry_schema(entry)
    args = %{"run_id" => "test-run", "snapshot" => snapshot()}
    assert :ok = ExJsonSchema.Validator.validate(schema, args)

    action_path = ["snapshot", "cards", Access.at(0), "items", Access.at(0), "action"]
    action = get_in(args, action_path)

    invalid_shapes = [
      put_in(args, action_path, Map.delete(action, "type")),
      put_in(args, action_path, %{action["type"] => Map.delete(action, "type")}),
      put_in(args, ["snapshot", "cards", Access.at(0), "items", Access.at(0), "sourceIds"], [
        "source-1"
      ])
    ]

    for invalid <- invalid_shapes do
      assert {:error, :invalid_recommendation_cards} =
               RecommendationContract.validate(invalid["snapshot"])

      assert {:error, _} = ExJsonSchema.Validator.validate(schema, invalid)
    end
  end

  test "accepts a bounded versioned text-list snapshot" do
    assert :ok = RecommendationContract.validate(snapshot())

    assert :ok =
             RecommendationContract.validate(snapshot(), %{
               "source-1" => ["https://linear.app/comma/issue/COMMA-143"]
             })
  end

  test "failed sources only authorize partial-source warnings" do
    evidence = %{"source-1" => ["https://linear.app/comma/issue/COMMA-143"]}
    failed_source_ids = ["failed-source"]

    warning = %{
      "code" => "partial_sources",
      "message" => "One connected source could not be read.",
      "sourceIds" => failed_source_ids
    }

    warning_only = Map.put(snapshot(), "warnings", [warning])

    assert :ok =
             RecommendationContract.validate(warning_only, evidence, failed_source_ids)

    card_from_failed_source =
      put_in(warning_only, ["cards", Access.at(0), "sourceIds"], failed_source_ids)

    assert {:error, :invalid_recommendation_evidence} =
             RecommendationContract.validate(
               card_from_failed_source,
               evidence,
               failed_source_ids
             )

    inline_task_from_failed_source =
      Map.put(warning_only, "summary", [
        %{
          "kind" => "inline-task",
          "task" => %{
            "conversationId" => "comma-unsupported",
            "label" => "Unsupported task",
            "sourceId" => "failed-source"
          }
        }
      ])

    assert {:error, :invalid_recommendation_evidence} =
             RecommendationContract.validate(
               inline_task_from_failed_source,
               evidence,
               failed_source_ids
             )

    stale_warning = put_in(warning_only, ["warnings", Access.at(0), "code"], "stale")

    assert {:error, :invalid_recommendation_evidence} =
             RecommendationContract.validate(stale_warning, evidence, failed_source_ids)
  end

  test "rejects duplicate card ids" do
    [card] = snapshot()["cards"]

    duplicate =
      snapshot()
      |> Map.put("cards", [card, Map.put(card, "title", "Duplicate document")])

    assert {:error, :invalid_recommendation_cards} =
             RecommendationContract.validate(duplicate)
  end

  test "rejects model-authored references that were not present in collected facts" do
    evidence = %{"source-1" => ["https://linear.app/comma/issue/COMMA-143"]}

    forged_link =
      snapshot()
      |> put_in(
        ["summary", Access.at(1), "link", "href"],
        "https://attacker.example/steal"
      )

    assert {:error, :invalid_recommendation_evidence} =
             RecommendationContract.validate(forged_link, evidence)

    forged_action =
      snapshot()
      |> put_in(
        ["cards", Access.at(0), "footerAction"],
        %{
          "href" => "https://attacker.example/steal",
          "label" => "Open",
          "requiresConfirmation" => false,
          "type" => "open_url"
        }
      )

    assert {:error, :invalid_recommendation_evidence} =
             RecommendationContract.validate(forged_action, evidence)

    forged_markdown =
      snapshot()
      |> put_in(
        ["summary", Access.at(0), "text"],
        "Good morning.\n\n[Open this](https://attacker.example/steal)"
      )

    assert {:error, :invalid_recommendation_evidence} =
             RecommendationContract.validate(forged_markdown, evidence)
  end

  test "keeps title presentation mistakes from discarding an otherwise valid snapshot" do
    assert :ok =
             snapshot()
             |> Map.put("summary", [
               %{
                 "kind" => "markdown",
                 "text" =>
                   "GitHub: 3 unread notifications to review, including a very important pull request.\n\nReview the updates."
               }
             ])
             |> RecommendationContract.validate()

    assert :ok =
             snapshot()
             |> Map.put("summary", [%{"kind" => "markdown", "text" => "Good morning."}])
             |> RecommendationContract.validate()
  end

  test "rejects a side-effecting action without confirmation" do
    invalid =
      put_in(snapshot(), ["cards", Access.at(0), "footerAction", "requiresConfirmation"], false)

    assert {:error, :invalid_recommendation_cards} = RecommendationContract.validate(invalid)
  end

  test "rejects a snapshot with a mismatched protocol version" do
    assert {:error, :invalid_recommendation_snapshot} =
             snapshot()
             |> Map.put("protocolVersion", 2)
             |> RecommendationContract.validate()
  end

  test "rejects unknown snapshot root fields" do
    assert {:error, :invalid_recommendation_snapshot} =
             snapshot()
             |> Map.put("rawProviderPayload", %{"access_token" => "must-not-persist"})
             |> RecommendationContract.validate()
  end

  test "rejects unknown or malformed warning fields" do
    warning = %{
      "code" => "partial_sources",
      "message" => "GitHub could not be read.",
      "sourceIds" => ["source-1"]
    }

    assert :ok =
             snapshot()
             |> Map.put("warnings", [warning])
             |> RecommendationContract.validate()

    assert {:error, :invalid_recommendation_warnings} =
             snapshot()
             |> Map.put("warnings", [Map.put(warning, "rawProviderPayload", %{"token" => "x"})])
             |> RecommendationContract.validate()

    assert {:error, :invalid_recommendation_warnings} =
             snapshot()
             |> Map.put("warnings", [Map.put(warning, "sourceIds", %{"source-1" => true})])
             |> RecommendationContract.validate()
  end

  test "rejects unknown document-part outer fields" do
    parts = [
      %{
        "kind" => "markdown",
        "text" => "Review the report",
        "rawProviderPayload" => %{"private" => "must-not-persist"}
      },
      %{
        "kind" => "inline-link",
        "link" => %{
          "href" => "https://linear.app/comma/issue/COMMA-143",
          "label" => "COMMA-143",
          "sourceId" => "source-1"
        },
        "rendererProps" => %{"component" => "arbitrary"}
      },
      %{
        "kind" => "inline-task",
        "task" => %{"conversationId" => "comma-143", "label" => "COMMA-143"},
        "rendererProps" => %{"component" => "arbitrary"}
      }
    ]

    for part <- parts do
      assert {:error, :invalid_recommendation_document} =
               snapshot()
               |> Map.put("summary", [part])
               |> RecommendationContract.validate()
    end
  end

  test "rejects unknown action outer fields" do
    actions = [
      %{
        "href" => "https://linear.app/comma/issue/COMMA-143",
        "label" => "Open",
        "requiresConfirmation" => false,
        "type" => "open_url"
      },
      %{
        "label" => "Open in Comma",
        "prompt" => "Review the report",
        "requiresConfirmation" => false,
        "type" => "open_task_form"
      },
      %{
        "label" => "Send to Comma",
        "prompt" => "Review the report",
        "requiresConfirmation" => true,
        "type" => "send_to_comma"
      }
    ]

    for action <- actions do
      invalid_action = Map.put(action, "rawProviderPayload", %{"secret" => "must-not-persist"})

      assert {:error, :invalid_recommendation_cards} =
               snapshot()
               |> put_in(["cards", Access.at(0), "items", Access.at(0), "action"], invalid_action)
               |> RecommendationContract.validate()
    end
  end

  test "rejects the removed rich-list template and text rows without actions" do
    assert {:error, :invalid_recommendation_cards} =
             snapshot()
             |> put_in(["cards", Access.at(0), "template"], "rich-list@1")
             |> RecommendationContract.validate()

    item_without_action =
      snapshot()
      |> get_in(["cards", Access.at(0), "items", Access.at(0)])
      |> Map.delete("action")

    assert {:error, :invalid_recommendation_cards} =
             snapshot()
             |> put_in(["cards", Access.at(0), "items"], [item_without_action])
             |> RecommendationContract.validate()
  end

  test "requires an action on every media row" do
    media_card = %{
      "fallbackText" => "Release brief",
      "id" => "news",
      "items" => [
        %{
          "description" => "Everything that changed today.",
          "id" => "release-brief",
          "imageUrl" => "https://example.com/release.png",
          "title" => "Release brief"
        }
      ],
      "sourceIds" => ["news-account"],
      "template" => "media-list@1",
      "title" => "News"
    }

    assert {:error, :invalid_recommendation_cards} =
             snapshot()
             |> Map.put("cards", [media_card])
             |> RecommendationContract.validate()
  end

  test "media images require credential-free HTTPS while open_url keeps HTTP support" do
    assert :ok =
             RecommendationContract.validate(media_snapshot("https://example.com/release.png"))

    assert {:error, :invalid_recommendation_cards} =
             media_snapshot("http://example.com/release.png")
             |> RecommendationContract.validate()

    assert {:error, :invalid_recommendation_cards} =
             media_snapshot("https://user:secret@example.com/release.png")
             |> RecommendationContract.validate()

    assert :ok =
             snapshot()
             |> put_in(
               ["cards", Access.at(0), "footerAction"],
               %{
                 "href" => "http://example.com/report",
                 "label" => "Open report",
                 "requiresConfirmation" => false,
                 "type" => "open_url"
               }
             )
             |> RecommendationContract.validate()
  end

  test "rejects forged reserved inline markup only as inert markdown data" do
    assert :ok =
             snapshot()
             |> put_in(
               ["summary", Access.at(0), "text"],
               ~s(<comma-inline data-key="forged"></comma-inline>)
             )
             |> RecommendationContract.validate()
  end

  test "rejects escaped line breaks and HTML anchors written into markdown text" do
    # Seen on staging 2026-09-07: the renderer copied the paragraph-break escape
    # into its JSON as the two characters backslash-n and wrapped entities in
    # <a> tags with no href; the client rendered both verbatim, with no chips.
    escaped = put_in(snapshot(), ["summary", Access.at(0), "text"], "Good morning.\\n\\nReview ")

    assert {:error, :invalid_recommendation_document} =
             RecommendationContract.validate(escaped)

    anchored = put_in(snapshot(), ["summary", Access.at(2), "text"], " before <a>standup</a>.")

    assert {:error, :invalid_recommendation_document} =
             RecommendationContract.validate(anchored)

    anchored_item =
      put_in(snapshot(), ["cards", Access.at(0), "items", Access.at(0), "parts"], [
        %{
          "kind" => "markdown",
          "text" => ~s(Review <a href="https://linear.app/comma/issue/COMMA-143">COMMA-143</a>)
        }
      ])

    assert {:error, :invalid_recommendation_cards} =
             RecommendationContract.validate(anchored_item)

    # Real line breaks and angle brackets that are not anchors stay prose.
    prose =
      put_in(snapshot(), ["summary", Access.at(0), "text"], "Good morning.\n\nReview <any> ")

    assert :ok = RecommendationContract.validate(prose)
  end

  defp snapshot do
    %{
      "cards" => [
        %{
          "fallbackText" => "Summarize the report",
          "footerAction" => %{
            "label" => "Summarize the report",
            "prompt" => "Summarize the latest report",
            "requiresConfirmation" => true,
            "type" => "send_to_comma"
          },
          "id" => "document",
          "items" => [
            %{
              "action" => %{
                "label" => "Review the report",
                "prompt" => "Review the report",
                "requiresConfirmation" => false,
                "type" => "open_task_form"
              },
              "id" => "report",
              "parts" => [%{"kind" => "markdown", "text" => "Review the report"}]
            }
          ],
          "sourceIds" => ["source-1"],
          "template" => "text-list@1",
          "title" => "Document"
        }
      ],
      "generatedAt" => 1,
      "generation" => 1,
      "protocolVersion" => 1,
      "sourceRevision" => 0,
      "summary" => [
        %{"kind" => "markdown", "text" => "Good morning.\n\nReview "},
        %{
          "kind" => "inline-link",
          "link" => %{
            "href" => "https://linear.app/comma/issue/COMMA-143",
            "label" => "COMMA-143",
            "sourceId" => "source-1"
          }
        },
        %{"kind" => "markdown", "text" => " before standup."}
      ],
      "templateCatalogVersion" => 1,
      "warnings" => []
    }
  end

  defp media_snapshot(image_url) do
    snapshot()
    |> Map.put("cards", [
      %{
        "fallbackText" => "Release brief",
        "id" => "news",
        "items" => [
          %{
            "action" => %{
              "label" => "Review release",
              "prompt" => "Review the release",
              "requiresConfirmation" => false,
              "type" => "open_task_form"
            },
            "description" => "Everything that changed today.",
            "id" => "release-brief",
            "imageUrl" => image_url,
            "title" => "Release brief"
          }
        ],
        "sourceIds" => ["news-account"],
        "template" => "media-list@1",
        "title" => "News"
      }
    ])
  end
end
