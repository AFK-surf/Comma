defmodule SalixVerifiedKernel.ProviderToolHistoryTest do
  use ExUnit.Case, async: true

  defp chat(messages) do
    assert {:ok, {:value, wire}} =
             SalixVerifiedKernel.invoke(
               :provider,
               :chat_messages,
               {messages, "google/gemini-3.8-flash"}
             )

    wire
  end

  defp assistant(id, name, extra \\ %{}) do
    Map.merge(
      %{role: "assistant", content: "", tool_calls: [%{id: id, name: name, args: %{}}]},
      extra
    )
  end

  defp tool(id, content), do: %{role: "tool", tool_call_id: id, content: content}
  defp outputs(wire), do: for(%{"role" => "tool", "content" => value} <- wire, do: value)

  defp assert_adjacent(wire) do
    for {%{"role" => "assistant", "tool_calls" => calls}, index} <- Enum.with_index(wire),
        {call, offset} <- Enum.with_index(calls, 1) do
      assert %{"role" => "tool", "tool_call_id" => id} = Enum.at(wire, index + offset)
      assert id == call["id"]
    end

    wire
  end

  test "two rounds reusing an ID retain their own tool results and signed metadata" do
    for next_name <- ["reply", "call"] do
      first_extra = %{
        "reasoning_details" => [
          %{"type" => "reasoning.encrypted", "id" => "reused", "data" => "first-signature"}
        ]
      }

      next_extra = %{
        "reasoning_details" => [
          %{"type" => "reasoning.encrypted", "id" => "reused", "data" => "next-signature"}
        ]
      }

      messages = [
        assistant("reused", "reply", %{provider_meta: %{"chat_message_extra" => first_extra}}),
        tool("reused", "old send_message result"),
        %{role: "user", content: "next request"},
        assistant("reused", next_name, %{provider_meta: %{"chat_message_extra" => next_extra}}),
        %{role: "runtime", content: "context between call and result"},
        tool("reused", "new status result")
      ]

      wire = messages |> chat() |> assert_adjacent()
      assert outputs(wire) == ["old send_message result", "new status result"]
      [first, next] = Enum.filter(wire, &(&1["role"] == "assistant"))
      assert first["reasoning_details"] == first_extra["reasoning_details"]

      assert next["reasoning_details"] ==
               Enum.map(next_extra["reasoning_details"], &Map.put(&1, "id", "reused__2"))

      assert Enum.map([first, next], &hd(&1["tool_calls"])["id"]) == ["reused", "reused__2"]
      assert chat(messages) == wire
    end
  end

  test "encoded streaming and non-streaming chat requests deduplicate historical calls" do
    history = [
      assistant("call_82076", "reply"),
      tool("call_82076", "sent"),
      assistant("call_82076", "call"),
      tool("call_82076", "status")
    ]

    for mode <- ["stream", "complete"] do
      assert {:ok, {:value, body}} =
               SalixVerifiedKernel.invoke(
                 :provider,
                 :encoded_body,
                 {"chat", %{model: "google/gemini-3.8-flash"}, history, [], mode}
               )

      wire = :json.decode(body)["messages"] |> assert_adjacent()
      ids = for %{"tool_calls" => calls} <- wire, call <- calls, do: call["id"]
      assert ids == ["call_82076", "call_82076__2"]
      assert outputs(wire) == ["sent", "status"]
    end
  end

  test "large encoded history does not overflow the native JSON join stack" do
    # The pre-fix NIF terminated BEAM at this width in JSON List.intersperseTR.
    history =
      Enum.flat_map(1..4_000, fn n ->
        [assistant("call_#{n}", "call"), tool("call_#{n}", String.duplicate("r", 256))]
      end)

    assert {:ok, {:value, body}} =
             SalixVerifiedKernel.invoke(
               :provider,
               :encoded_body,
               {"chat", %{model: "google/gemini-3.8-flash"}, history, [], "stream"}
             )

    wire = :json.decode(body)["messages"]
    assert length(wire) == 8_000

    for {[assistant, result], n} <- wire |> Enum.chunk_every(2) |> Enum.with_index(1) do
      assert hd(assistant["tool_calls"])["id"] == "call_#{n}"
      assert result["tool_call_id"] == "call_#{n}"
      assert result["content"] == String.duplicate("r", 256)
    end
  end

  test "suffixes avoid original IDs in later parallel calls and leave unique IDs unchanged" do
    parallel = %{
      role: "assistant",
      content: "",
      tool_calls: for(n <- 2..8, do: %{id: "same__#{n}", name: "call", args: %{}})
    }

    messages = [
      assistant("same", "reply"),
      tool("same", "old"),
      assistant("same", "call"),
      tool("same", "new"),
      parallel
    ]

    wire = chat(messages) |> assert_adjacent()
    ids = for %{"tool_calls" => calls} <- wire, call <- calls, do: call["id"]
    assert ids == ["same", "same__9"] ++ Enum.map(2..8, &"same__#{&1}")
    assert length(Enum.uniq(ids)) == length(ids)
    assert chat(messages) == wire
  end

  test "a suffixed orphan cannot become the renamed invocation's result" do
    wire =
      chat([
        assistant("same", "reply"),
        tool("same", "old"),
        assistant("same", "call"),
        tool("same__2", "orphan"),
        tool("same", "new")
      ])
      |> assert_adjacent()

    assert outputs(wire) == ["old", "new"]
    assert Enum.any?(wire, &(&1["role"] == "user" and &1["content"] =~ "orphan"))
    [_, renamed] = Enum.filter(wire, &(&1["role"] == "assistant"))
    assert hd(renamed["tool_calls"])["id"] == "same__3"
  end

  test "renamed calls preserve unrelated reasoning and update vision references" do
    extra = %{
      "reasoning_details" => [
        %{"id" => "same", "type" => "reasoning.encrypted", "data" => "signature"},
        %{"id" => "unrelated", "type" => "reasoning.text", "text" => "opaque text"}
      ]
    }

    image = ~s([{"type":"image_url","image_url":{"url":"data:image/png;base64,eA=="}}])

    messages = [
      assistant("same", "reply"),
      tool("same", "old"),
      assistant("same", "read_file", %{provider_meta: %{"chat_message_extra" => extra}}),
      Map.put(tool("same", image), :native_content_trusted, true)
    ]

    wire = chat(messages) |> assert_adjacent()
    [_, renamed] = Enum.filter(wire, &(&1["role"] == "assistant"))

    assert renamed["reasoning_details"] == [
             Map.put(hd(extra["reasoning_details"]), "id", "same__2"),
             List.last(extra["reasoning_details"])
           ]

    [vision] = for %{"role" => "user", "content" => blocks} <- wire, is_list(blocks), do: blocks
    assert hd(vision)["text"] =~ ~s(call_id="same__2")
    # Projecting never rewrites the source transcript or signed payload bytes.
    assert Enum.at(messages, 2).tool_calls |> hd() |> Map.fetch!(:id) == "same"
    assert Enum.at(messages, 2).provider_meta["chat_message_extra"] == extra
  end

  test "an earlier missing result cannot consume the later invocation's result" do
    wire =
      [assistant("same", "reply"), assistant("same", "call"), tool("same", "new")]
      |> chat()
      |> assert_adjacent()

    assert outputs(wire) == [~s({"status":"no_result_recorded"}), "new"]
  end

  test "a later missing result cannot reuse the earlier invocation's result" do
    wire =
      [assistant("same", "reply"), tool("same", "old"), assistant("same", "call")]
      |> chat()
      |> assert_adjacent()

    assert outputs(wire) == ["old", ~s({"status":"no_result_recorded"})]
  end

  test "duplicate results are deduplicated within each invocation, not across rounds" do
    wire =
      [
        assistant("same", "reply"),
        tool("same", "old"),
        tool("same", "old"),
        assistant("same", "call"),
        tool("same", "new"),
        tool("same", "new")
      ]
      |> chat()
      |> assert_adjacent()

    assert outputs(wire) == ["old", "new"]
  end

  test "results may cross unrelated assistant calls but never a newer call with the same ID" do
    wire =
      [
        assistant("a", "read_file"),
        assistant("b", "search"),
        tool("a", "file"),
        tool("b", "search results"),
        assistant("a", "call"),
        tool("a", "status")
      ]
      |> chat()
      |> assert_adjacent()

    assert outputs(wire) == ["file", "search results", "status"]
  end

  test "an orphan before an invocation cannot become that invocation's result" do
    wire =
      [tool("same", "orphan"), assistant("same", "call"), tool("same", "new")]
      |> chat()
      |> assert_adjacent()

    assert outputs(wire) == ["new"]
    assert hd(wire)["content"] =~ "<unclaimed-tool-result"
    assert hd(wire)["content"] =~ "orphan"
  end

  test "vision labels use the preceding invocation's name, not a later reused ID" do
    # The chat protocol recognizes `image_url` blocks, which is what
    # `SalixAgent.ImageRefs` produces for tool results; an Anthropic-shaped
    # `source` block is not converted here and would leave no vision message.
    image = ~s([{"type":"image_url","image_url":{"url":"data:image/png;base64,eA=="}}])

    wire =
      [
        assistant("same", "read_file"),
        Map.put(tool("same", image), :native_content_trusted, true),
        assistant("same", "call"),
        tool("same", "status")
      ]
      |> chat()
      |> assert_adjacent()

    [vision] = for %{"role" => "user", "content" => blocks} <- wire, is_list(blocks), do: blocks
    assert hd(vision)["text"] =~ ~s(tool="read_file" call_id="same")
    assert outputs(wire) == ["[Image tool result]", "status"]
  end

  test "long reused-ID history retains every invocation result" do
    messages =
      Enum.flat_map(1..1_000, fn index ->
        [assistant("reused", "call"), tool("reused", "result-#{index}")]
      end)

    wire = chat(messages) |> assert_adjacent()
    assert outputs(wire) == Enum.map(1..1_000, &"result-#{&1}")
    ids = for %{"tool_calls" => calls} <- wire, call <- calls, do: call["id"]
    assert length(Enum.uniq(ids)) == 1_000
  end

  test "wide parallel history retains every result with hash-indexed ownership" do
    calls = for n <- 1..2_000, do: %{id: "call_#{n}", name: "call", args: %{}}
    message = %{role: "assistant", content: "", tool_calls: calls}
    results = for n <- 2_000..1//-1, do: tool("call_#{n}", "result-#{n}")
    [assistant | projected] = chat([message | results])
    assert Enum.map(assistant["tool_calls"], & &1["id"]) == Enum.map(calls, & &1.id)
    assert Enum.map(projected, & &1["tool_call_id"]) == Enum.map(calls, & &1.id)
    assert outputs(projected) == Enum.map(1..2_000, &"result-#{&1}")
  end

  test "hash indexes do not alias empty binary IDs with legacy non-binary IDs" do
    history = [
      assistant("", "call"),
      tool("", "empty"),
      assistant(1, "call"),
      tool(1, "integer"),
      assistant("1", "call"),
      tool("1", "binary")
    ]

    assert outputs(chat(history)) == ["empty", "integer", "binary"]
  end

  test "parallel calls share a round without sharing results" do
    message = %{
      role: "assistant",
      content: "",
      tool_calls: [
        %{id: "a", name: "call", args: %{}},
        %{id: "b", name: "call", args: %{}}
      ]
    }

    wire = chat([message, tool("b", "B"), tool("a", "A")]) |> assert_adjacent()
    assert outputs(wire) == ["A", "B"]
  end
end
