defmodule SalixVerifiedKernel.ProviderRequestTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  test "Responses keeps prior implicit cache boundaries across three rounds" do
    user = %{id: 1, role: "user", content: "question"}
    summary = %{id: 2, role: "summary", content: "Historical quoted context"}

    histories = [
      [user, summary],
      [user, summary] ++ cache_tool_round(3, ["read-a", "read-b"]),
      [user, summary] ++
        cache_tool_round(3, ["read-a", "read-b"]) ++
        cache_tool_round(6, ["read-c"]) ++
        [%{id: 8, role: "assistant", content: "", tool_calls: []}]
    ]

    bodies =
      for history <- histories do
        state = session(%{system_prompt: "Stable instructions", messages: history})
        before = Session.export(state)
        body = request_body(state, "responses")

        assert body["instructions"] == "Stable instructions"
        assert Session.export(state) == before
        body
      end

    for [previous, next] <- Enum.chunk_every(bodies, 2, 1, :discard) do
      assert List.last(cache_prefixes(previous)) in cache_prefixes(next)
    end
  end

  test "with no history, a placeholder turn follows the prompt outside Responses" do
    state = session(%{system_prompt: "Stable instructions"})
    placeholder = "[No new user message.]"

    assert [
             %{"role" => "system", "content" => "Stable instructions"},
             %{"role" => "user", "content" => ^placeholder}
           ] = request_body(state, "chat")["messages"]

    anthropic = request_body(state, "anthropic")
    assert [%{"text" => "Stable instructions"}] = anthropic["system"]
    assert [%{"role" => "user", "content" => [%{"text" => ^placeholder}]}] = anthropic["messages"]
  end

  test "a request marks private diagnostics and shows public summaries" do
    call = %{
      id: 2,
      role: "assistant",
      content: "",
      tool_calls: [%{id: "a", name: "read", args: %{}}, %{id: "b", name: "read", args: %{}}]
    }

    private = %{
      id: 3,
      role: "tool",
      tool_call_id: "a",
      content: "upstream 500 at internal host",
      diagnostic_visibility: "model_only"
    }

    public = %{
      id: 4,
      role: "tool",
      tool_call_id: "b",
      content: "secret detail",
      diagnostic_visibility: "user_reportable",
      public_summary: "Search is unavailable."
    }

    messages = [%{id: 1, role: "user", content: "question"}, call, private, public]
    state = session(%{messages: messages})
    args = {nil, :neutral, nil, [], "stream"}
    request = Session.query(state, :provider_dispatch, args)

    assert Enum.find(request, &(&1[:id] == 3)).content ==
             "[private diagnostic]\nupstream 500 at internal host"

    shown = Enum.find(request, &(&1[:id] == 4))
    refute shown.content =~ "secret detail"
    assert shown.content =~ "Search is unavailable."

    # A later message does not change how these render.
    later = session(%{messages: messages ++ [%{id: 5, role: "user", content: "next"}]})
    assert Enum.take(Session.query(later, :provider_dispatch, args), length(request)) == request
  end

  defp cache_tool_round(id, calls) do
    [
      %{
        id: id,
        role: "assistant",
        content: "",
        tool_calls: Enum.map(calls, &%{id: &1, name: "read", args: %{}})
      }
      | Enum.with_index(calls, id + 1)
        |> Enum.map(fn {call, id} ->
          %{id: id, role: "tool", tool_call_id: call, content: "Result " <> call}
        end)
    ]
  end

  defp request_body(state, protocol) do
    Session.query(
      state,
      :provider_dispatch,
      {nil, protocol, %{model: "test"}, [], "stream"}
    )
    |> then(&call(:normalize, &1))
  end

  # Model only the documented message-boundary lookup used by these fixtures.
  # This checks request structure, not provider cache availability or tokenization.
  defp cache_prefixes(body) do
    input = body["input"]

    input
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      next = Enum.at(input, index + 1, %{})

      eligible =
        item["role"] == "user" or
          (item["type"] == "function_call_output" and next["type"] != "function_call_output")

      if eligible,
        do: [{body["instructions"], body["tools"], Enum.take(input, index + 1)}],
        else: []
    end)
  end

  test "source annotations name only labelled inputs and remain stable on replay" do
    user = %{id: 7, role: "user", content: "问题", trusted_origin: %{"ifc" => %{}}}
    runtime = %{"id" => 8, "role" => "runtime", "content" => "结果", "ifc" => %{}}
    unlabelled = %{id: 9, role: "user", content: "legacy"}
    tool = %{id: 10, role: "tool", content: "tool", ifc: %{}}
    session = Session.new("agent", "session")
    args = {:annotate_messages, [user, runtime, unlabelled, tool]}

    assert [annotated_user, annotated_runtime, ^unlabelled, ^tool] =
             Session.query(session, :provider_request_part, args)

    assert annotated_user.content == "[src:q-7]\n问题"
    assert annotated_runtime["content"] == "[src:a-8]\n结果"
    projected = [annotated_user, annotated_runtime, unlabelled, tool]

    assert Session.query(session, :provider_request_part, {:annotate_messages, projected}) ==
             projected
  end

  test "request preserves prefix order and recursively projects transient activation facts" do
    session =
      session(%{
        system_prompt: "stored prompt",
        summary: "durable summary",
        messages: [
          %{
            id: 1,
            role: "user",
            content: "问题",
            accepted_input: {1, "user_message", "source", %{"content" => "private-original"}}
          }
        ]
      })

    before = Session.export(session)

    delta = %{
      messages: [
        %{
          runtime_message_id: "delta",
          runtime_message_type: "context",
          summary: "更新",
          source_refs: %{nested: [%{id: "来源"}]}
        }
      ]
    }

    args = {delta, :neutral, nil, [], "stream"}

    assert [prompt, summary, user, activation] = Session.query(session, :provider_dispatch, args)
    assert prompt == %{role: "summary", content: "stored prompt"}
    assert summary.content == "durable summary"
    assert user.content == "问题"
    refute Map.has_key?(user, :accepted_input)
    refute Map.has_key?(user, "accepted_input")

    assert activation == %{
             role: "runtime",
             kind: "runtime_message",
             runtime_message_id: "delta",
             type: "context",
             summary: "更新",
             content: "更新",
             source_refs: %{"nested" => [%{"id" => "来源"}]}
           }

    assert Session.query(session, :provider_dispatch, args) == [prompt, summary, user, activation]
    assert Session.export(session) == before
  end

  test "a committed knowledge block renders where its activation delta rendered" do
    user = %{id: 1, role: "user", content: "What does Lin own?"}
    facts = ~s({"contract":"Quoted project evidence only.","entities":[],"facts":[]})
    refs = %{"provider" => "bft_project_knowledge", "retrieval_id" => "project-knowledge:1"}

    delta = %{
      messages: [
        %{
          runtime_message_id: "project-knowledge:1",
          runtime_message_type: "project_knowledge",
          summary: "Resolved project knowledge for this question",
          content: facts,
          source_refs: refs
        }
      ]
    }

    args = fn delta ->
      {delta, :neutral, nil, [], "stream"}
    end

    first = Session.query(session(%{messages: [user]}), :provider_dispatch, args.(delta))
    {first_items, _instructions} = call(:responses_parts, first)

    stored = %{
      id: 2,
      role: "runtime",
      kind: "runtime_message",
      type: "project_knowledge",
      runtime_message_id: "project-knowledge:1",
      summary: "Resolved project knowledge for this question",
      content: facts,
      source_refs: refs
    }

    assistant = %{id: 3, role: "assistant", content: "Lin owns it.", tool_calls: []}

    second =
      Session.query(
        session(%{messages: [user, stored, assistant]}),
        :provider_dispatch,
        args.(nil)
      )

    {second_items, _instructions} = call(:responses_parts, second)

    # Project knowledge renders as a synthetic `get_runtime_message` result.
    knowledge? = &(&1["type"] == "function_call_output" and inspect(&1) =~ "project-knowledge:1")
    knowledge_index = Enum.find_index(first_items, knowledge?)
    assert is_integer(knowledge_index)

    assert Enum.take(second_items, knowledge_index + 1) ==
             Enum.take(first_items, knowledge_index + 1)

    assert Enum.count(second_items, knowledge?) == 1
  end

  # An inbound attachment is never model input, whatever type the sender's block
  # declared: the kernel asks the host for it as a workspace file, and the host
  # answers with an announcement. Image bytes reach a request only when a tool
  # read produced them, which `SalixLlm.ConvertImagesTest` encodes per protocol.
  test "resident dispatch announces authorized attachments and reads no other one" do
    block = %{
      "type" => "image",
      "file_ref" => %{"environment_id" => "vfs", "path" => "/current.png"}
    }

    announced = %{block | "type" => "file"}
    note = "[Attached image is available in the agent workspace: /current.png]"

    content = ~s([{"type":"image","file_ref":{"environment_id":"vfs","path":"/current.png"}}])
    old = %{id: 1, role: "user", content: content, trusted_attachment_refs: [block]}
    untrusted = %{id: 2, role: "user", content: content}
    current = %{id: 3, role: "user", content: content, trusted_attachment_refs: [block]}
    state = session(%{last_ack_message_id: 1, messages: [old, untrusted, current]})
    snapshot = Session.export(state)

    read = fn {:request_image, ^announced} ->
      send(self(), :attachment_announced)
      [%{"type" => "text", "text" => note}]
    end

    for protocol <- ["anthropic", "chat", "responses"] do
      cfg = SalixVerifiedKernel.Provider.call(:config, {%{"model" => "test-model"}, "", ""})

      body =
        Session.query(
          state,
          :provider_dispatch,
          {nil, protocol, cfg, [], "stream"},
          read
        )

      assert is_binary(body)
      wire = SalixVerifiedKernel.Provider.call(:normalize, body)
      assert wire["model"] == "test-model"
      message = List.last(wire["messages"] || wire["input"])

      case protocol do
        # Chat carries no image block, so the announcement joins as plain text.
        "chat" ->
          assert message["content"] =~ note

        "anthropic" ->
          assert %{"type" => "text", "text" => ^note} = List.last(message["content"])

        "responses" ->
          assert %{"type" => "input_text", "text" => ^note} = List.last(message["content"])
      end

      # The acked message and the message with no trusted ref are never read.
      assert_receive :attachment_announced
      refute_receive :attachment_announced
      refute body =~ "image_url"
      refute body =~ "input_image"
    end

    assert Session.export(state) == snapshot
  end

  test "runtime page sizing preserves complete graphemes and a usable continuation offset" do
    content = String.duplicate("é👩‍💻", 25_000)

    envelope =
      ~s({"tool_name":"tool_call.get_result","result_page":{"result_ref":"ref","offset":0,"total_chars":50000,"content":"#{content}"}})

    state = session(%{messages: [%{id: 1, role: "runtime", content: envelope}]})
    assert [message] = Session.query(state, :provider_context)
    page = SalixVerifiedKernel.Provider.call(:normalize, message.content)["result_page"]
    assert page["content_chars"] == String.length(page["content"])
    assert page["content_chars"] > 0
    assert page["content_chars"] < 50_000
    assert page["next_offset"] == page["content_chars"]
    assert String.slice(content, 0, page["content_chars"]) == page["content"]
    assert page["truncated"]
  end

  # Sixteen large attachment answers in one dispatch. Each is requested as a
  # workspace file, because these are inbound attachments, and the measurement
  # is of the batch transport, not of what the host chooses to answer with.
  test "multi-attachment dispatch keeps transport proportional to the final request" do
    messages =
      for id <- 1..16 do
        block = image_ref(id)
        content = ~s([{"type":"image","file_ref":{"environment_id":"vfs","path":"/#{id}.png"}}])
        %{id: id, role: "user", content: content, trusted_attachment_refs: [block]}
      end

    state = session(%{messages: messages, last_ack_message_id: 0})

    payloads =
      Map.new(1..16, fn id -> {"/#{id}.png", Base.encode64(:binary.copy(<<id>>, 65_536))} end)

    read = fn {:request_image, block} ->
      send(self(), {:read_image, block})
      [%{"type" => "text", "text" => Map.fetch!(payloads, block["file_ref"]["path"])}]
    end

    {body, calls, bytes} = measured_dispatch(state, read)
    wire = SalixVerifiedKernel.Provider.call(:normalize, body)
    assert length(wire["messages"]) == 16

    assert Enum.all?(Enum.with_index(wire["messages"], 1), fn {message, id} ->
             message["content"] == payloads["/#{id}.png"]
           end)

    for message <- messages do
      block = %{hd(message.trusted_attachment_refs) | "type" => "file"}
      assert_receive {:read_image, ^block}
    end

    refute_receive {:read_image, _}
    assert calls <= 3
    assert bytes < 4 * byte_size(body)
    assert Session.get(state, :messages) == messages
  end

  test "runtime attachment batches validate each record before requesting its image" do
    messages =
      for id <- 1..8 do
        %{
          id: id,
          role: "runtime",
          type: "tool_call_completed",
          content: "completed",
          source_tool_call_id: "call-#{id}",
          result_seq: id
        }
      end

    state = session(%{messages: messages, last_ack_message_id: 1})

    read = fn
      {:request_result, id} ->
        send(self(), {:read_result, id})

        {:ok,
         %{
           "seq" => id,
           "tool_call_id" => "call-#{id}",
           "tool_name" => "fs.read_file",
           "status" => "completed",
           "error" => id == 4,
           "result" => %{
             "id" => "call-#{id}",
             "name" => "fs.read_file",
             "status" => "completed",
             "content" =>
               ~s([{"type":"image","file_ref":{"environment_id":"vfs","path":"/#{id}.png"}}])
           }
         }}

      {:request_image, block} ->
        send(self(), {:read_image, block})
        [%{"type" => "text", "text" => block["file_ref"]["path"]}]
    end

    {body, calls, _bytes} = measured_dispatch(state, read)
    wire = SalixVerifiedKernel.Provider.call(:normalize, body)
    for id <- 2..8, do: assert_receive({:read_result, ^id})
    refute_receive {:read_result, _}

    for id <- [2, 3, 5, 6, 7, 8] do
      block = image_ref(id)
      assert_receive {:read_image, ^block}

      assert Enum.any?(
               wire["messages"],
               &(&1["role"] == "user" and &1["content"] == "/#{id}.png")
             )
    end

    refute_receive {:read_image, _}
    assert calls <= 3
    assert Session.get(state, :messages) == messages
  end

  defp image_ref(id),
    do: %{"type" => "image", "file_ref" => %{"environment_id" => "vfs", "path" => "/#{id}.png"}}

  defp measured_dispatch({:verified_kernel, 1, :session_state, resident}, read) do
    cfg = SalixVerifiedKernel.Provider.call(:config, {%{"model" => "test-model"}, "", ""})
    args = {nil, "chat", cfg, [], "stream"}
    measure(resident, :query, {:provider_dispatch, args, Session.prelude()}, read, 0, 0)
  end

  # Count actual ETF traffic, without wall-clock thresholds or VM-global tracing.
  defp measure(resident, operation, payload, read, calls, bytes) do
    input = :erlang.term_to_binary({1, :session, 1, operation, payload}, minor_version: 2)
    {resident, output} = SalixVerifiedKernel.Native.session(resident, input)
    bytes = bytes + byte_size(input) + byte_size(output)

    case :erlang.binary_to_term(output, [:safe]) do
      {1, :ok, {:value, body}} ->
        {body, calls + 1, bytes}

      {1, :ok, {:observe, request, token}} ->
        value =
          case request do
            {:request_batch, requests} -> Enum.map(requests, read)
            request -> read.(request)
          end

        measure(resident, :resume, {token, {:ok, value}}, read, calls + 1, bytes)
    end
  end

  defp session(fields),
    do: Session.new("agent", "session") |> Session.export() |> Map.merge(fields) |> Session.open()

  defp call(op, payload) do
    assert {:ok, {:value, value}} = SalixVerifiedKernel.invoke(:provider, op, payload)
    value
  end

  test "activation adopts the configured prompt without changing accepted work" do
    configured = "current configured prompt"
    history = [%{id: 1, role: "assistant", content: "previous answer"}]
    old = session(%{system_prompt: "old prompt", messages: history, summary: "prior context"})
    before = Session.export(old)

    assert {[event], ^configured} = Session.query(old, :prepare_prompt_snapshot, configured)

    assert event == %{
             "type" => "session_system_prompt",
             "session_id" => "session",
             "system_prompt" => configured
           }

    assert Session.export(old) == before

    done = session(%{system_prompt: configured, messages: history, summary: "prior context"})
    assert {[], ^configured} = Session.query(done, :prepare_prompt_snapshot, configured)
    assert {[], "old prompt"} = Session.query(old, :prepare_prompt_snapshot, nil)

    adopted = session(%{messages: history, summary: "prior context"})
    assert {[^event], ^configured} = Session.query(adopted, :prepare_prompt_snapshot, configured)
  end
end
