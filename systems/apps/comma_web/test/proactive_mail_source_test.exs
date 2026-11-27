defmodule CommaWeb.ProactiveMailSourceTest do
  use SystemsClock.Case, async: true
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

  test "normalizes attachment-only Gmail messages with empty inline text parts and feeds full_mail merge" do
    attachment_only = %{
      "id" => "m-pdf",
      "threadId" => "t-pdf",
      "internalDate" => "1000",
      "labelIds" => ~w(INBOX UNREAD),
      "payload" => %{
        "mimeType" => "multipart/mixed",
        "headers" => [
          %{"name" => "Subject", "value" => "Invoice PDF"},
          %{"name" => "From", "value" => "billing@example.test"}
        ],
        "parts" => [
          %{"mimeType" => "text/plain", "body" => %{"size" => 0}},
          %{
            "mimeType" => "application/pdf",
            "filename" => "invoice.pdf",
            "body" => %{"attachmentId" => "att-1", "size" => 4096}
          }
        ]
      }
    }

    assert {:ok, normalized} =
             Source.normalize(
               attachment_only,
               %{"id" => "t-pdf", "messages" => [attachment_only]},
               "owner@example.test"
             )

    assert [%{"message_id" => "m-pdf", "body" => "", "attachments" => ["invoice.pdf"]}] =
             normalized["messages"]

    # Feed normalized Gmail output + read attachments directly through ProactiveCheck.merge_full_mail/2.
    mail_with_attachments =
      Map.merge(normalized, %{
        "attachments_read" => true,
        "attachments" => [%{"name" => "invoice.pdf", "text" => "Total due $120"}]
      })

    item = %{
      "toolkit" => "gmail",
      "messageId" => "m-pdf",
      "context" => %{"scope" => "snippet", "text" => "", "attachments" => "unread"}
    }

    assert {:ok, merged} = CommaWeb.ProactiveCheck.merge_full_mail(item, mail_with_attachments)
    assert merged["context"]["attachments"] == "read"
    assert merged["context"]["text"] =~ "invoice.pdf"
    assert merged["context"]["text"] =~ "Total due $120"

    # Empty message with NO attachments still fails normalization.
    empty_no_att = %{
      "id" => "m-empty",
      "threadId" => "t-empty",
      "internalDate" => "1000",
      "labelIds" => ~w(INBOX),
      "payload" => %{
        "mimeType" => "text/plain",
        "headers" => [%{"name" => "Subject", "value" => "Empty"}],
        "body" => %{"size" => 0}
      }
    }

    assert {:error, :mail_body_unavailable_or_too_large} =
             Source.normalize(
               empty_no_att,
               %{"id" => "t-empty", "messages" => [empty_no_att]},
               "owner@example.test"
             )

    # Empty text/plain placeholder falls back to non-empty text/html instead of dropping the body.
    empty_plain_with_html = %{
      "id" => "m-html-fallback",
      "threadId" => "t-html-fallback",
      "internalDate" => "1000",
      "labelIds" => ~w(INBOX UNREAD),
      "payload" => %{
        "mimeType" => "multipart/alternative",
        "headers" => [
          %{"name" => "Subject", "value" => "HTML Only Receipt"},
          %{"name" => "From", "value" => "billing@example.test"}
        ],
        "parts" => [
          %{"mimeType" => "text/plain", "body" => %{"size" => 0}},
          %{
            "mimeType" => "text/html",
            "body" => %{
              "data" => Base.url_encode64("<p>Receipt total: $99</p>", padding: false)
            }
          }
        ]
      }
    }

    assert {:ok, html_normalized} =
             Source.normalize(
               empty_plain_with_html,
               %{"id" => "t-html-fallback", "messages" => [empty_plain_with_html]},
               "owner@example.test"
             )

    assert [%{"body" => "Receipt total: $99"}] = html_normalized["messages"]
  end
end
