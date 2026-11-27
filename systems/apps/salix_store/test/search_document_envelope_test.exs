defmodule SalixStore.SearchDocumentEnvelopeTest do
  use SystemsClock.Case, async: true

  alias SalixStore.SearchDocumentEnvelope

  test "document and query envelopes share Unicode folding, bigrams, and byte bounds" do
    title = SearchDocumentEnvelope.build(:title, "ΟΣ Straße İX Cafe\u0301 ﬃ" <> <<0>>)

    assert title.content == "ΟΣ Straße İX Cafe\u0301 ﬃ�"
    assert title.folded_content == SearchDocumentEnvelope.fold(title.content)

    assert title.short_grams ==
             SearchDocumentEnvelope.bigrams(title.folded_content) ++
               SearchDocumentEnvelope.unigrams(title.folded_content)

    assert title.weight_bytes == max(byte_size(title.content), byte_size(title.folded_content))
    assert SearchDocumentEnvelope.valid?(title, :title)

    assert {:ok, query} = SearchDocumentEnvelope.query("  STRASSE  ")
    assert query.raw == "STRASSE"
    assert query.folded == SearchDocumentEnvelope.fold("STRASSE")
    assert query.short_grams == SearchDocumentEnvelope.bigrams(query.folded)
    assert [_first_gram | _rest] = query.short_grams

    message = SearchDocumentEnvelope.build(:message, "安俞")
    assert message.short_grams == ["b:安俞"]

    assert {:ok, one} = SearchDocumentEnvelope.query("e\u0301")
    assert one.short_grams == ["u:é"]

    # One codepoint that folds to several still searches titles only.
    assert {:ok, %{short_grams: ["u:s"]}} = SearchDocumentEnvelope.query("ß")
    # One grapheme of several codepoints that folds to several searches Messages.
    assert {:ok, accented} = SearchDocumentEnvelope.query("e\u0301\u0301")
    assert [_ | _] = grams = accented.short_grams
    refute Enum.any?(grams, &String.starts_with?(&1, "u:"))
    assert {:error, :null} = SearchDocumentEnvelope.query("AI" <> <<0>>)

    oversized = SearchDocumentEnvelope.build(:message, String.duplicate("İ", 40_000))
    assert byte_size(oversized.content) <= SearchDocumentEnvelope.max_bytes(:message)
    assert byte_size(oversized.folded_content) <= SearchDocumentEnvelope.max_bytes(:message)
    assert String.ends_with?(oversized.content, "…")
  end
end
