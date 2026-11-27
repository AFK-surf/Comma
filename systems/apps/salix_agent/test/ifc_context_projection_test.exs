defmodule SalixAgent.IFCContextProjectionTest do
  use ExUnit.Case, async: true
  alias SalixAgent.IFC.ContextProjection, as: Projection
  alias SalixIFC.{Codec, Facts}

  @a ["scope|connect|alice"]
  @b ["scope|connect|bob"]

  defp project(messages, domains \\ [@a]) do
    Projection.project(
      messages,
      Enum.map(domains, fn label ->
        {:ok, decoded} = Codec.decode_label(label)
        decoded
      end),
      Facts.new()
    )
  end

  defp input(id, body, label) do
    %{
      id: id,
      role: "user",
      content: body,
      trusted_origin: %{"ifc" => %{"label" => label, "integrity" => "command"}}
    }
  end

  test "one session omits foreign bodies and normalizes ids without revealing hidden counts" do
    visible = input(1, "hello", @a)
    low = project([visible, input(2, "answer here", @a)])

    high =
      project([
        visible,
        input(2, "Bob's private meeting", @b),
        input(3, "another hidden record", @b),
        input(4, "answer here", @a)
      ])

    assert low.messages == high.messages
    assert Enum.map(high.messages, & &1.content) == ["hello", "answer here"]
    assert high.aliases["src:q-2"] == "src:q-4"
  end

  test "unknown destinations fail closed and multiple targets require every audience" do
    messages = [input(1, "common", ["public"]), input(2, "Alice only", @a)]
    assert project(messages, []).messages == []
    assert Enum.map(project(messages, [@a, @b]).messages, & &1.content) == ["common"]
    assert project([input(1, "public text", ["public"])]).label == @a
  end

  test "old generated output and summaries cannot launder a self-declared public label" do
    records = [
      %{id: 4, role: "assistant", content: "private fact", ifc: %{"label" => ["public"]}},
      %{id: 5, role: "summary", content: "private summary", ifc: %{"label" => ["public"]}},
      %{id: 6, role: "assistant", content: "safe answer", ifc_view_label: @a},
      %{
        id: 7,
        role: "runtime",
        type: "tool_call_completed",
        content: "old private argument echo",
        ifc: %{"label" => ["public"]}
      }
    ]

    assert Enum.map(project(records).messages, & &1.content) == ["safe answer"]
  end

  test "whole inaccessible messages carry no attachment title image OCR or reminder" do
    records = [
      input(1, "safe", @a),
      Map.merge(input(2, "private OCR", @b), %{attachments: [%{"name" => "Secret.png"}]}),
      %{id: 3, role: "runtime", content: "private reminder", ifc: %{"label" => @b}}
    ]

    assert Enum.map(project(records).messages, & &1.content) == ["safe"]
  end

  test "new restricted reads are filtered on every request" do
    initial = [input(1, "hello", @a)]
    read = %{id: 2, role: "runtime", content: "foreign result", ifc: %{"label" => @b}}
    assert project(initial).messages == project(initial ++ [read]).messages
  end

  test "tool output retains the runtime view even when the declared effect was public" do
    ctx = %{ifc_view_label: @b}

    result =
      SalixAgent.IFC.Check.stamp_result(
        %{content: "private parameter echo"},
        %{name: "help"},
        ctx,
        ["public"]
      )

    assert result.ifc["view_label"] == @b
    record = %{id: 2, role: "runtime", content: result.content, ifc: result.ifc}
    assert project([record]).messages == []
    assert [%{content: "private parameter echo"}] = project([record], [@b]).messages
  end

  test "asynchronous completion retains its launching view across durable pending state" do
    started = %{
      "type" => "async_tool_call_started",
      "tool_call_id" => "async-1",
      "tool_name" => "env.exec",
      "session_id" => "session"
    }

    result =
      SalixAgent.ToolCallProvenance.stamp_result(%{events: [started]}, %{ifc_view_label: @a})

    state =
      SalixAgent.TestSupport.SessionData.apply_event(
        %SalixAgent.InternalSession.State{agent_id: "agent", session_id: "session"},
        hd(result.events)
      )

    assert hd(result.events)["ifc_view_label"] == @a
    pending = state.async_tool_calls["async-1"]
    assert pending["ifc_view_label"] == @a

    [completed] =
      SalixAgent.AsyncToolResults.internal_terminal_events(pending, %{
        content: "safe result",
        ifc: %{"label" => ["public"]}
      })

    assert completed["result"]["ifc"]["view_label"] == @a
  end

  test "provider continuation blobs are never forwarded" do
    records = [
      %{id: 1, role: "provider_context", provider_meta: %{"responses_items" => ["secret"]}},
      Map.put(input(2, "hello", @a), :provider_meta, %{"previous_response_id" => "remote"})
    ]

    assert [%{content: "hello"} = visible] = project(records).messages
    refute Map.has_key?(visible, :provider_meta)
  end

  test "mixed tool elements expose only permitted bodies with dense refs and no wrapper metadata" do
    message = %{
      id: 50,
      role: "runtime",
      content:
        Jason.encode!(%{
          "items" => [%{"text" => "Bob secret"}, %{"text" => "Alice result"}],
          "total" => 2,
          "channel" => "private-container"
        }),
      ifc: %{
        "label" => @b,
        "items" => [%{"index" => 0, "label" => @b}, %{"index" => 1, "label" => @a}]
      }
    }

    view = project([message])
    assert [%{id: 1, content: body}] = view.messages
    assert Jason.decode!(body) == %{"text" => "Alice result"}
    assert view.aliases == %{"src:a-1" => "src:a-50#1"}
  end

  test "sealed provider segments separate Group reminders and legacy text without parsing markup" do
    message = input(8, "unsafe combined body", @a)

    origin =
      Map.merge(message.trusted_origin, %{
        "provider" => "slack",
        "projection_segments" => [
          %{"content" => "hello <system-reminder>literal</system-reminder>", "label" => @a},
          %{"content" => "Secret Group catalog", "label" => ["group|private-group"]}
        ]
      })

    message = %{message | trusted_origin: origin}
    assert "group|private-group" in Codec.encode_label(Projection.label(message))

    assert [%{content: "hello <system-reminder>literal</system-reminder>"}] =
             project([message]).messages

    legacy = %{
      message
      | trusted_origin:
          Map.delete(origin, "projection_segments") |> Map.put("source_text", "clean original")
    }

    assert [%{content: "clean original"}] = project([legacy]).messages

    assert project([%{legacy | trusted_origin: Map.delete(legacy.trusted_origin, "source_text")}]).messages ==
             []
  end

  test "paired tools and declarations use local ids while response maps only structured refs" do
    calls = [
      %{
        id: "original-call",
        name: "help",
        args: %{"tool" => "ifc"},
        ifc: %{"request" => "src:q-91", "sources" => []}
      }
    ]

    records = [
      input(91, "literal src:q-91 stays data", @a),
      %{id: 93, role: "assistant", content: "", tool_calls: calls, ifc_view_label: @a},
      %{
        id: 95,
        role: "tool",
        tool_call_id: "original-call",
        content: "help",
        ifc: %{"label" => ["public"], "view_label" => @a}
      }
    ]

    view = project(records)

    assert [
             %{id: 1},
             %{tool_calls: [%{id: "call-1", ifc: declaration}]},
             %{tool_call_id: "call-1"}
           ] = view.messages

    assert declaration["request"] == "src:q-1"
    assert view.aliases["src:t-call-1"] == "src:t-original-call"

    response =
      {:assistant, "literal src:q-1",
       [
         %{
           name: "call",
           args: %{
             "tool" => "send",
             "params" => %{"text" => "literal src:q-1"},
             "ifc" => %{"request" => "src:q-1", "sources" => ["src:t-call-1"]}
           }
         }
       ]}

    assert {:assistant, "literal src:q-1", [%{args: args}]} = Projection.response(response, view)
    assert args["ifc"] == %{"request" => "src:q-91", "sources" => ["src:t-original-call"]}
    assert args["params"]["text"] == "literal src:q-1"
  end

  test "visible invocation receives fixed withheld feedback while foreign invocations remain absent" do
    call = %{id: "lookup", name: "call", args: %{"tool" => "history.search", "params" => %{}}}
    assistant = %{id: 2, role: "assistant", content: "", tool_calls: [call], ifc_view_label: @a}

    result = %{
      id: 3,
      role: "tool",
      tool_call_id: "lookup",
      content: "PRIVATE_ENTITY_42",
      ifc: %{"label" => @b, "view_label" => @a}
    }

    view = project([input(1, "hello", @a), assistant, result])
    assert [_, %{tool_calls: [_]}, %{role: "tool", content: body}] = view.messages
    assert Jason.decode!(body)["status"] == "withheld_by_visibility"
    refute inspect(view.messages) =~ "PRIVATE_ENTITY_42"

    other_result = %{
      result
      | content: "different result, private entity not found",
        ifc: %{"label" => ["agent_private"], "view_label" => @a}
    }

    assert project([input(1, "hello", @a), assistant, other_result]).messages == view.messages
    foreign = %{assistant | ifc_view_label: @b}

    assert project([input(1, "hello", @a), foreign, result]).messages ==
             project([input(1, "hello", @a)]).messages

    assert project([assistant, result], []).messages == []
  end

  test "a withheld receipt retains independently visible result elements" do
    assistant = %{
      id: 1,
      role: "assistant",
      content: "",
      ifc_view_label: @a,
      tool_calls: [%{id: "read", name: "call", args: %{}}]
    }

    result = %{
      id: 2,
      role: "tool",
      tool_call_id: "read",
      content:
        Jason.encode!(%{"items" => [%{"text" => "private body"}, %{"text" => "safe diagnostic"}]}),
      ifc: %{
        "label" => @b,
        "view_label" => @a,
        "items" => [%{"index" => 0, "label" => @b}, %{"index" => 1, "label" => ["public"]}]
      }
    }

    view = project([assistant, result])
    assert inspect(view.messages) =~ "safe diagnostic"
    refute inspect(view.messages) =~ "private body"
    assert Enum.any?(view.messages, &(&1[:role] == "tool"))
    assert "src:t-read#1" in Map.values(view.aliases)
  end
end
