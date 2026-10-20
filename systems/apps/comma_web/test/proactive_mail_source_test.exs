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
end
