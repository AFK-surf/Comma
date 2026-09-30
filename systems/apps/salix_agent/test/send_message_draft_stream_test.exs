defmodule SalixAgent.SendMessageDraftStreamTest do
  use ExUnit.Case, async: true

  alias SalixAgent.SendMessageDraftStream

  @conversation_id "cnv_streaming_target"
  @scope %{"conversation_id" => @conversation_id}

  test "projects a decoded text prefix and then the completed text" do
    {prefix, suffix} =
      ordered_encoded_arguments("正在给你发送")
      |> split_after("正在")

    {state, {:publish, "正在"}} =
      SendMessageDraftStream.consume(
        SendMessageDraftStream.new(),
        delta(prefix, "call"),
        @scope
      )

    {_state, {:publish, "正在给你发送"}} =
      SendMessageDraftStream.consume(state, delta(suffix), @scope)
  end

  test "every provider fragment boundary converges on the same semantic text" do
    encoded = encoded_arguments("line one\nquoted: \"yes\" ✓")

    {state, publications} =
      encoded
      |> String.graphemes()
      |> Enum.reduce({SendMessageDraftStream.new(), []}, fn fragment, {state, publications} ->
        name = if publications == [] and state.calls == %{}, do: "call"
        {state, action} = SendMessageDraftStream.consume(state, delta(fragment, name), @scope)

        publications =
          case action do
            {:publish, text} -> publications ++ [text]
            :noop -> publications
          end

        {state, publications}
      end)

    assert state.published_text == "line one\nquoted: \"yes\" ✓"
    assert List.last(publications) == state.published_text

    assert publications
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [previous, current] -> String.starts_with?(current, previous) end)
  end

  test "complete terminal arguments remain private until dispatch authorizes the reply" do
    encoded = ~s({"outcome":"done","reply":#{ordered_encoded_arguments("正在给你发送")}})
    {prefix, suffix} = split_after(encoded, "正在")

    {state, :noop} =
      SendMessageDraftStream.consume(
        SendMessageDraftStream.new(),
        delta(prefix, "end_turn"),
        @scope
      )

    {_state, :noop} = SendMessageDraftStream.consume(state, delta(suffix), @scope)
  end

  test "filtered replies never publish a draft regardless of parameter order" do
    content = ~s("content":[{"type":"text","text":"must-not-draft"}])
    filter = ~s("delivery_filter":{"participant_ids":[]})

    for fields <- [
          filter <> "," <> content,
          content <> "," <> filter,
          ~s("delivery_filter":{},) <> content <> "," <> filter
        ] do
      args =
        ~s({"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":"#{@conversation_id}",#{fields}}})

      encoded = ~s({"outcome":"done","reply":#{args}})

      Enum.reduce(String.graphemes(encoded), SendMessageDraftStream.new(), fn fragment, state ->
        {state, action} =
          SendMessageDraftStream.consume(state, delta(fragment, "end_turn"), @scope)

        assert action == :noop
        state
      end)

      refute SendMessageDraftStream.exact_source_send?(
               [%{name: "end_turn", args: Jason.decode!(encoded)}],
               @scope,
               :clean
             )
    end
  end

  test "does not project raw arguments for another conversation" do
    {_state, :noop} =
      SendMessageDraftStream.consume(
        SendMessageDraftStream.new(),
        delta(encoded_arguments("private parser diagnostic", "cnv_other"), "call"),
        @scope
      )
  end

  test "completed-call handoff requires one clean exact plain-text send" do
    call = %{
      name: "call",
      args: Jason.decode!(encoded_arguments("final answer"))
    }

    assert SendMessageDraftStream.exact_source_send?([call], @scope, :clean)

    refute SendMessageDraftStream.exact_source_send?(
             [call],
             @scope,
             {:repair_required, 1}
           )
  end

  defp encoded_arguments(text, conversation_id \\ @conversation_id) do
    Jason.encode!(%{
      "tool" => "im_api.internal.send_message",
      "params" => %{
        "connect_id" => "internal",
        "conversation_id" => conversation_id,
        "content" => [%{"type" => "text", "text" => text}]
      }
    })
  end

  defp ordered_encoded_arguments(text) do
    ~s({"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":"#{@conversation_id}","content":[{"type":"text","text":#{Jason.encode!(text)}}]}})
  end

  defp split_after(encoded, marker) do
    {start, size} = :binary.match(encoded, marker)
    :erlang.split_binary(encoded, start + size)
  end

  defp delta(fragment, name \\ nil),
    do: %{index: 0, name: name, fragment: fragment}
end
