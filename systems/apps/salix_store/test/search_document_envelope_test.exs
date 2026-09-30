defmodule SalixStore.SearchDocumentEnvelopeTest do
  use ExUnit.Case, async: true

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

  test "latest-slot window charges max original/folded bytes and rejects duplicate sequences" do
    expansion = String.duplicate("İ", 1_600)
    contraction = String.duplicate("ẞ", 1_600)

    slots =
      Enum.map(1..64, fn seq ->
        content = if rem(seq, 2) == 0, do: expansion, else: contraction
        slot!(seq, content)
      end)

    all_messages = Enum.map(slots, & &1.message)
    original_total = Enum.sum(Enum.map(all_messages, &byte_size(&1.envelope.content)))
    folded_total = Enum.sum(Enum.map(all_messages, &byte_size(&1.envelope.folded_content)))
    weight_total = Enum.sum(Enum.map(all_messages, & &1.envelope.weight_bytes))

    assert original_total <= SearchDocumentEnvelope.message_window_bytes()
    assert folded_total <= SearchDocumentEnvelope.message_window_bytes()
    assert weight_total > SearchDocumentEnvelope.message_window_bytes()

    assert {:ok, window} = SearchDocumentEnvelope.message_window(slots, 1, 64)
    assert length(window.messages) == 54
    assert hd(window.messages).seq == 11
    assert List.last(window.messages).seq == 64
    assert window.indexed_bytes == 259_200

    duplicate_seq = [slot!(1, "first").message, slot!(1, "second").message]
    refute SearchDocumentEnvelope.valid_message_window?(duplicate_seq, 1, 2)
    refute SearchDocumentEnvelope.valid_sequence_range?(0, 1)
    assert {:error, :invalid} = SearchDocumentEnvelope.message_window([slot!(1, "body")], 0, 1)
  end

  test "whitespace-only canonical text stays empty before truncation" do
    assert {:ok, %{message: nil}} = slot_result(1, String.duplicate(" ", 100_000))
  end

  test "public contextual snippet includes ellipses in its 32-KiB cap" do
    prefix = String.duplicate("a", 49)
    matched_grapheme = "e" <> String.duplicate("\u0301", 16_319)
    suffix = String.duplicate("b", 80)
    content = prefix <> matched_grapheme <> suffix

    assert byte_size(content) == SearchDocumentEnvelope.max_bytes(:message)
    envelope = SearchDocumentEnvelope.build(:message, content)
    assert envelope.content == content
    assert {:ok, query} = SearchDocumentEnvelope.query("e\u0301\u0301")

    assert {:ok, snippet, %{"start" => start, "end" => finish}} =
             SearchDocumentEnvelope.render_match(:message, envelope.content, query)

    assert byte_size(snippet) == SearchDocumentEnvelope.max_bytes(:message)
    assert snippet == content
    assert utf16_slice(snippet, start, finish) == matched_grapheme
  end

  defp slot!(seq, content) do
    assert {:ok, slot} = slot_result(seq, content)
    slot
  end

  defp slot_result(seq, content) do
    SearchDocumentEnvelope.message_slot(%{
      id: "message-#{seq}-#{System.unique_integer([:positive])}",
      seq: seq,
      created_at: seq,
      content: content
    })
  end

  defp utf16_slice(value, start, finish) do
    utf16 = :unicode.characters_to_binary(value, :utf8, {:utf16, :little})
    bytes = binary_part(utf16, start * 2, (finish - start) * 2)
    :unicode.characters_to_binary(bytes, {:utf16, :little}, :utf8)
  end
end
