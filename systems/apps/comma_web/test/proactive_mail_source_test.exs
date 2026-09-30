defmodule CommaWeb.ProactiveMailSourceTest do
  use ExUnit.Case, async: true
  alias CommaWeb.ProactiveMailSource, as: Source

  defp message(id, body, labels \\ ~w(INBOX UNREAD)) do
    %{
      "id" => id,
      "threadId" => "t1",
      "internalDate" => "1000",
      "labelIds" => labels,
      "payload" => %{
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64(body, padding: false)},
        "headers" => [
          %{"name" => "Subject", "value" => "Approval"},
          %{"name" => "From", "value" => "client@example.test"}
        ]
      }
    }
  end

  test "keeps original body and later thread facts, not the misleading snippet" do
    first =
      message("m1", "Please approve the revised contract by Friday.") |> Map.put("snippet", "FYI")

    second =
      message("m2", "Resolved. The signature is complete.", ["SENT"])
      |> Map.put("internalDate", "2000")

    assert {:ok, result} =
             Source.normalize(
               first,
               %{"id" => "t1", "messages" => [second, first]},
               "owner@example.test"
             )

    assert result["thread_complete"]
    assert [a, b] = result["messages"]
    assert a["body"] =~ "approve the revised contract"
    assert b["body"] =~ "signature is complete"
    assert b["labels"] == ["SENT"]
    assert result["url"] =~ "authuser=owner%40example.test"
  end

  test "extracts HTML-only content and reports unread attachments" do
    mail = message("m1", "")

    payload =
      Map.merge(mail["payload"], %{
        "mimeType" => "multipart/mixed",
        "parts" => [
          %{
            "mimeType" => "text/html",
            "body" => %{
              "data" =>
                Base.url_encode64("<p>Pay <strong>Friday</strong>.</p><script>ignore</script>",
                  padding: false
                )
            }
          },
          %{
            "mimeType" => "application/pdf",
            "filename" => "bill.pdf",
            "body" => %{"attachmentId" => "a1"}
          }
        ]
      })

    mail = Map.put(mail, "payload", payload)

    assert {:ok, result} =
             Source.normalize(mail, %{"id" => "t1", "messages" => [mail]}, "owner@example.test")

    assert [item] = result["messages"]
    assert item["body"] =~ "Friday"
    refute item["body"] =~ "ignore"
    assert item["attachments"] == ["bill.pdf"]
    refute result["attachments_read"]
  end

  test "missing body or an incomplete thread cannot become a quiet success" do
    mail = message("m1", "") |> Map.put("snippet", "Nothing urgent")

    assert {:error, :mail_body_unavailable_or_too_large} =
             Source.normalize(mail, %{"id" => "t1", "messages" => [mail]}, "owner@example.test")

    mail = message("m1", "Please review")

    assert {:error, _} =
             Source.normalize(
               mail,
               %{"id" => "other", "messages" => [mail]},
               "owner@example.test"
             )

    assert {:error, _} =
             Source.normalize(mail, %{"id" => "t1", "messages" => []}, "owner@example.test")

    assert {:error, _} =
             Source.normalize(
               mail,
               %{"id" => "t1", "messages" => List.duplicate(mail, 21)},
               "owner@example.test"
             )
  end
end
