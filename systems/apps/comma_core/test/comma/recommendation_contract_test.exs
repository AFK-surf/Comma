defmodule Comma.RecommendationContractTest do
  use SystemsClock.Case, async: true

  alias Comma.RecommendationContract

  test "accepts a bounded versioned text-list snapshot" do
    assert :ok = RecommendationContract.validate(snapshot())

    assert :ok =
             RecommendationContract.validate(snapshot(), %{
               "source-1" => ["https://linear.app/comma/issue/COMMA-143"]
             })
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

  test "rejects a side-effecting action without confirmation" do
    invalid =
      put_in(snapshot(), ["cards", Access.at(0), "footerAction", "requiresConfirmation"], false)

    assert {:error, :invalid_recommendation_cards} = RecommendationContract.validate(invalid)
  end

  test "rejects unknown snapshot root fields" do
    assert {:error, :invalid_recommendation_snapshot} =
             snapshot()
             |> Map.put("rawProviderPayload", %{"access_token" => "must-not-persist"})
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
