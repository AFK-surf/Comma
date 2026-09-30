defmodule Comma.ConversationSearchContractTest do
  use ExUnit.Case, async: true

  alias SalixStore.SearchDocumentEnvelope

  test "content DTO preserves a long combining grapheme and leaks no projection internals" do
    snippet = "e" <> String.duplicate("\u0301", 9_000) <> "😀x"

    result = %{
      "conversation_id" => "cnv1_0000000000000000001",
      "title" => "Unicode Task",
      "snippet" => snippet,
      "matched_field" => "content",
      "highlights" => [%{"start" => 0, "end" => 2}],
      "updated_at" => 1_788_177_000_123,
      "message_id" => "msg1_0000000000000000001",
      "role" => "user",
      "source" => "canonical",
      "score" => 1.0,
      "writer_generation" => "internal"
    }

    assert byte_size(snippet) > 16_384
    assert byte_size(snippet) <= SearchDocumentEnvelope.max_bytes(:message)
    assert {:ok, [public]} = Comma.Conversations.validate_search_results_for_test([result])
    assert public["snippet"] == snippet
    assert public["highlights"] == [%{"start" => 0, "end" => 2}]
    assert public["updated_at"] == 1_788_177_000_123

    refute Map.has_key?(public, "message_id")
    refute Map.has_key?(public, "role")
    refute Map.has_key?(public, "source")
    refute Map.has_key?(public, "score")
    refute Map.has_key?(public, "writer_generation")
  end

  test "title and content enforce their separate projection byte bounds" do
    base = %{
      "conversation_id" => "cnv1_0000000000000000001",
      "title" => "Task",
      "matched_field" => "content",
      "highlights" => [%{"start" => 0, "end" => 2}]
    }

    assert {:error, :invalid_salix_conversation_search} =
             Comma.Conversations.validate_search_results_for_test([
               Map.put(
                 base,
                 "snippet",
                 String.duplicate("a", SearchDocumentEnvelope.max_bytes(:message) + 1)
               )
             ])

    title = String.duplicate("a", SearchDocumentEnvelope.max_bytes(:title) + 1)

    assert {:error, :invalid_salix_conversation_search} =
             Comma.Conversations.validate_search_results_for_test([
               base
               |> Map.put("title", title)
               |> Map.put("snippet", title)
               |> Map.put("matched_field", "title")
             ])
  end

  test "title DTO preserves a validated optional content match" do
    result = %{
      "conversation_id" => "cnv1_0000000000000000001",
      "title" => "Needle Task",
      "snippet" => "Needle Task",
      "matched_field" => "title",
      "highlights" => [%{"start" => 0, "end" => 6}],
      "content_match" => %{
        "snippet" => "The latest needle appears here",
        "highlights" => [%{"start" => 11, "end" => 17}],
        "source_seq" => 42
      }
    }

    assert {:ok, [public]} = Comma.Conversations.validate_search_results_for_test([result])

    assert public["content_match"] == %{
             "snippet" => "The latest needle appears here",
             "highlights" => [%{"start" => 11, "end" => 17}]
           }

    invalid = put_in(result, ["content_match", "highlights"], [%{"start" => 0, "end" => 99}])

    assert {:error, :invalid_salix_conversation_search} =
             Comma.Conversations.validate_search_results_for_test([invalid])

    oversized =
      put_in(
        result,
        ["content_match", "snippet"],
        String.duplicate("a", SearchDocumentEnvelope.max_bytes(:message) + 1)
      )

    assert {:error, :invalid_salix_conversation_search} =
             Comma.Conversations.validate_search_results_for_test([oversized])
  end

  test "Comma accepts the envelope producer's exact maximum contextual snippet" do
    matched_grapheme = "e" <> String.duplicate("\u0301", 16_319)

    content =
      String.duplicate("a", 49) <>
        matched_grapheme <>
        String.duplicate("b", 80)

    assert byte_size(content) == SearchDocumentEnvelope.max_bytes(:message)
    assert {:ok, query} = SearchDocumentEnvelope.query("e\u0301\u0301")

    assert {:ok, snippet, range} =
             SearchDocumentEnvelope.render_match(:message, content, query)

    result = %{
      "conversation_id" => "cnv1_0000000000000000001",
      "title" => "Boundary Task",
      "snippet" => snippet,
      "matched_field" => "content",
      "highlights" => [range]
    }

    assert byte_size(snippet) == SearchDocumentEnvelope.max_bytes(:message)
    assert {:ok, [^result]} = Comma.Conversations.validate_search_results_for_test([result])
  end
end
