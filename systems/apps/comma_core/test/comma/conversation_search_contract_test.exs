defmodule Comma.ConversationSearchContractTest do
  use SystemsClock.Case, async: true

  alias SalixStore.SearchDocumentEnvelope

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
end
