defmodule SalixAgent.Utf8Test do
  use ExUnit.Case, async: true

  alias SalixAgent.Utf8

  # "接入" with the second character cut after one of its three bytes — the
  # byte-truncation shape that wedged production sessions (invalid byte 0xE5).
  @truncated_cjk binary_part("接入", 0, 4)

  test "scrub/1 replaces each invalid byte with U+FFFD and keeps the rest" do
    scrubbed = Utf8.scrub(@truncated_cjk)
    assert String.valid?(scrubbed)
    assert scrubbed == "接�"
    assert {:ok, _} = Jason.encode(scrubbed)
  end

  test "scrub/1 handles invalid bytes mid-string" do
    corrupt = "prefix " <> @truncated_cjk <> " suffix"
    scrubbed = Utf8.scrub(corrupt)
    assert String.valid?(scrubbed)
    assert scrubbed == "prefix 接� suffix"
  end

  test "scrub_term/1 deep-scrubs binaries in maps and lists" do
    term = %{
      "summary" => @truncated_cjk,
      :nested => [%{"content" => "ok"}, %{"content" => @truncated_cjk}],
      "count" => 3
    }

    scrubbed = Utf8.scrub_term(term)

    assert scrubbed["summary"] == "接�"
    assert [%{"content" => "ok"}, %{"content" => "接�"}] = scrubbed[:nested]
    assert scrubbed["count"] == 3
    assert {:ok, _} = Jason.encode(Map.delete(scrubbed, :nested))
  end

  test "scrub_term/1 leaves an all-valid term equal to its input" do
    term = %{"messages" => [%{"role" => "user", "content" => "你好"}], "max_tokens" => 4096}
    assert Utf8.scrub_term(term) == term
  end

  test "scrub_term/1 passes structs and non-binary leaves through" do
    now = DateTime.utc_now()

    assert Utf8.scrub_term(%{"at" => now, "n" => 1, "ok" => true}) == %{
             "at" => now,
             "n" => 1,
             "ok" => true
           }
  end

  test "Session input repair preserves valid values and container types" do
    input = %{
      source_message_id: "source-1",
      payload: %{
        content: "把我的电脑/Mac 接入",
        events: [%{"payload" => MapSet.new([{"content", "你好"}, {"wake", false}])}],
        context: {nil, 12, [%{"role" => "user"}]}
      }
    }

    assert Utf8.scrub_session_input(input) == input
  end
end
