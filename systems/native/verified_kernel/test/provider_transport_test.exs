defmodule SalixVerifiedKernel.ProviderTransportTest do
  use ExUnit.Case, async: true

  defp call(op, payload) do
    assert {:ok, {:value, value}} = SalixVerifiedKernel.invoke(:provider, op, payload)
    value
  end

  defp stream(resident, op, payload) do
    assert {next, {:ok, {:value, value}}} =
             SalixVerifiedKernel.invoke_provider_stream(resident, op, payload)

    {next, value}
  end

  test "HTTP-200 error bodies and SSE error events are not successful empty responses" do
    error = %{"error" => %{"code" => "context_length_exceeded", "message" => "input too large"}}

    for protocol <- ["chat", "responses", "anthropic"] do
      assert {:error, %{"category" => "context_overflow"}} =
               call(:complete, {protocol, error, "test", false})

      event = Map.put(error, "type", "error")
      raw = "data: " <> IO.iodata_to_binary(:json.encode(event)) <> "\n\n"

      assert {:error, %{"category" => "context_overflow"}} =
               call(:decode_stream, {protocol, raw, "test"})
    end

    for type <- ["response.failed", "response.incomplete"] do
      status = String.replace_prefix(type, "response.", "")
      event = %{"type" => type, "response" => Map.put(error, "status", status)}
      raw = "data: " <> IO.iodata_to_binary(:json.encode(event)) <> "\n\n"

      assert {:error, %{"category" => "context_overflow"}} =
               call(:decode_stream, {"responses", raw, "test"})
    end
  end

  test "wide JSON arrays and objects decode without native stack growth" do
    # The decoder runs on a BEAM dirty scheduler with a stack of a few hundred
    # kilobytes. One native frame per item overflowed it at a few thousand
    # items; tool results and provider bodies routinely carry far more.
    width = 60_000
    array = "[" <> Enum.map_join(1..width, ",", &Integer.to_string/1) <> "]"
    assert call(:normalize, array) == Enum.to_list(1..width)

    # Object normalization dedupes keys with linear scans, so it is quadratic
    # in key count; 8,000 keys stays well inside the CI timeout while the
    # per-item recursion it guards against overflowed at 4,000 keys.
    keys = 8_000
    object = "{" <> Enum.map_join(1..keys, ",", &"\"k#{&1}\":{\"v\":\"\\u4e2d\"}") <> "}"
    decoded = call(:normalize, object)
    assert map_size(decoded) == keys
    assert decoded["k#{keys}"] == %{"v" => "中"}

    nested =
      "{\"items\":[" <> Enum.map_join(1..width, ",", &"{\"i\":#{&1},\"t\":[#{&1}]}") <> "]}"

    assert %{"items" => items} = call(:normalize, nested)
    assert length(items) == width
    assert List.last(items) == %{"i" => width, "t" => [width]}
  end

  test "wire requests preserve explicit false values and scrub invalid transcript bytes" do
    cfg =
      call(:config, {%{"model" => "test", "store" => false, "prompt_caching" => false}, "", ""})

    messages = [%{role: "user", content: <<"snow-", 0xFF>>}]

    encoded = call(:encoded_body, {"anthropic", cfg, messages, [], "complete"})
    assert encoded =~ "snow-�"
    refute encoded =~ "cache_control"
    encoded = call(:encoded_body, {"responses", cfg, messages, [], "complete"})
    assert encoded =~ "\"store\":false"
  end

  test "wide JSON objects and empty nested containers retain valid separators" do
    args = Map.new(1..8_000, &{"key_#{&1}", [&1, [], %{}, "quote\" slash\\ snow雪"]})

    history = [
      %{role: "assistant", content: "", tool_calls: [%{id: "wide", name: "call", args: args}]}
    ]

    encoded = call(:encoded_body, {"chat", %{model: "test"}, history, [], "complete"})
    [assistant, _result] = :json.decode(encoded)["messages"]
    [tool] = assistant["tool_calls"]
    assert :json.decode(tool["function"]["arguments"]) == args
  end

  test "partial Responses arguments survive UTF-8 and surrogate splits without duplicate delivery" do
    added =
      ~s(data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc","call_id":"call","name":"reply","arguments":""}}\n)

    argument =
      ~S(data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc","delta":"{\"text\":\"\u96EA\uD83D\uDE00\"}"}) <>
        "\n"

    completed = ~s(data: {"type":"response.completed","response":{"output":[]}}\n)

    for width <- [1, 7, byte_size(argument)] do
      {resident, :opened} = stream(nil, :new, {"responses", "test", true})
      {resident, []} = stream(resident, :feed, {added, true})

      {resident, actions} =
        argument
        |> :binary.bin_to_list()
        |> Enum.chunk_every(width)
        |> Enum.map(&:erlang.list_to_binary/1)
        |> Enum.reduce({resident, []}, fn chunk, {state, actions} ->
          {state, next} = stream(state, :feed, {chunk, true})
          {state, actions ++ next}
        end)

      assert Enum.map_join(actions, fn {:tool, fragment} -> fragment.fragment end) ==
               ~s({"text":"雪😀"})

      assert Enum.all?(actions, fn {:tool, fragment} -> fragment.name == "reply" end)
      {resident, []} = stream(resident, :feed, {completed, true})
      {_, {[], {:assistant, "", [tool], _metadata}}} = stream(resident, :finish, nil)
      assert tool.args == %{"text" => "雪😀"}
    end
  end

  test "atom role values retain the leading system position on OpenAI protocols" do
    messages = [%{role: :system, content: "rules"}, %{role: :user, content: "hi"}]

    assert [%{"role" => "system", "content" => "rules"}, %{"role" => "user", "content" => "hi"}] =
             call(:chat_messages, {messages, nil})

    assert {[%{"role" => "user", "content" => "hi"}], "rules"} =
             call(:responses_parts, messages)
  end

  test "an invalid open argument event suppresses later fragments for that tool" do
    added =
      ~s(data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc","name":"reply"}}\n)

    partial =
      ~S(data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc","delta":"hello)

    {resident, :opened} = stream(nil, :new, {"responses", "test", true})
    {resident, []} = stream(resident, :feed, {added, true})
    {resident, [{:tool, %{fragment: "hello"}}]} = stream(resident, :feed, {partial, true})
    {resident, []} = stream(resident, :feed, {"\\q\n", true})

    later =
      ~s(data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc","delta":"must not be sent"}\n)

    {_, []} = stream(resident, :feed, {later, true})
  end

  test "non-success HTTP bodies cannot produce stream callbacks" do
    body =
      ~s(data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"not an answer"}}\n)

    {resident, :opened} = stream(nil, :new, {"anthropic", "test", true})
    {resident, []} = stream(resident, :feed, {body, false})
    {_, ^body} = stream(resident, :raw, nil)
  end

  test "malformed Responses arguments reject the whole sibling call batch" do
    response = %{
      "output" => [
        %{"type" => "function_call", "call_id" => "one", "name" => "call", "arguments" => "{}"},
        %{"type" => "function_call", "call_id" => "two", "name" => "call", "arguments" => "{"}
      ]
    }

    assert {:error, %{"reason" => "invalid_tool_arguments", "retryable" => false}} =
             call(:complete, {"responses", response, "test", false})
  end

  test "Chat completion rejects malformed argument batches but preserves valid empty objects" do
    response = fn arguments ->
      %{
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "tool_calls" =>
                Enum.with_index(arguments, fn args, i ->
                  %{"id" => "call-#{i}", "function" => %{"name" => "call", "arguments" => args}}
                end)
            }
          }
        ]
      }
    end

    for invalid <- ["{", "[]", "null"] do
      assert {:error, %{"reason" => "invalid_tool_arguments", "retryable" => false}} =
               call(:complete, {"chat", response.(["{}", invalid]), "test", false})
    end

    assert {:assistant, "", [first, second]} =
             call(:complete, {"chat", response.(["{}", ~s({"tool":"help"})]), "test", false})

    assert first.id == "call-0"
    assert first.args == %{}
    assert second.id == "call-1"
    assert second.args == %{"tool" => "help"}
  end
end
