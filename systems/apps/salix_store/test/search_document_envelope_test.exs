defmodule SalixStore.SearchDocumentEnvelopeTest do
  use SystemsClock.Case, async: true

  alias SalixStore.SearchDocumentEnvelope

  test "document and query envelopes share Unicode folding, bigrams, and byte bounds" do
    title = SearchDocumentEnvelope.build(:title, "ΟΣ Straße İX Cafe\u0301 ﬃ" <> <<0>>)

    assert title.content == "ΟΣ Straße İX Cafe\u0301 ﬃ�"
    assert title.folded_content == SearchDocumentEnvelope.fold(title.content)
    assert title.short_grams == SearchDocumentEnvelope.bigrams(title.folded_content)
    assert title.weight_bytes == max(byte_size(title.content), byte_size(title.folded_content))
    assert SearchDocumentEnvelope.valid?(title, :title)

    assert {:ok, query} = SearchDocumentEnvelope.query("  STRASSE  ")
    assert query.raw == "STRASSE"
    assert query.folded == SearchDocumentEnvelope.fold("STRASSE")
    assert query.short_grams == SearchDocumentEnvelope.bigrams(query.folded)
    assert [_first_gram | _rest] = query.short_grams

    assert {:error, :too_short} = SearchDocumentEnvelope.query("e\u0301")
    assert {:error, :null} = SearchDocumentEnvelope.query("AI" <> <<0>>)

    oversized = SearchDocumentEnvelope.build(:message, String.duplicate("İ", 40_000))
    assert byte_size(oversized.content) <= SearchDocumentEnvelope.max_bytes(:message)
    assert byte_size(oversized.folded_content) <= SearchDocumentEnvelope.max_bytes(:message)
    assert String.ends_with?(oversized.content, "…")
  end
end
