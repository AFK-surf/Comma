defmodule SalixLlm.ConvertImagesTest do
  @moduledoc """
  Multimodal tool-result conversion: image-bearing content-block arrays (text
  summary + inlined data-URL image from `SalixAgent.ImageRefs`) per protocol —
  Anthropic nested tool_result blocks, Chat Completions tool-vision projection
  (willow client.go), Responses input_image output items. Non-image content,
  including plain JSON arrays, must stay byte-identical strings.
  """
  use ExUnit.Case, async: true

  alias SalixLlm.{Convert, ConvertOpenAI}

  @data_url "data:image/png;base64,iVBORw0KGgo="
  @blocks Jason.encode!([
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/png;base64,iVBORw0KGgo="}
            },
            %{"type" => "text", "text" => "[Image: /pic.png, 8 bytes]"}
          ])

  @conversation [
    %{role: "user", content: "look at the image"},
    %{
      role: "assistant",
      content: "",
      tool_calls: [%{"id" => "t1", "name" => "read_file", "args" => %{"path" => "/pic.png"}}]
    },
    %{role: "tool", tool_call_id: "t1", content: nil},
    %{role: "user", content: "thanks"}
  ]

  defp conversation(tool_content),
    do:
      Enum.map(
        @conversation,
        &if(&1.role == "tool",
          do: &1 |> Map.put(:content, tool_content) |> Map.put(:native_content_trusted, true),
          else: &1
        )
      )

  test "anthropic: image blocks nest inside the tool_result" do
    {_system, msgs} = Convert.to_anthropic(conversation(@blocks))

    [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => content}] =
      msgs |> Enum.at(2) |> Map.fetch!("content")

    assert [
             %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => "iVBORw0KGgo="
               }
             },
             %{"type" => "text", "text" => "[Image: /pic.png, 8 bytes]"}
           ] = content
  end

  test "anthropic: plain strings and non-image JSON arrays stay strings" do
    for content <- ["plain result", ~s([{"path":"/x"},{"path":"/y"}])] do
      {_system, msgs} = Convert.to_anthropic(conversation(content))

      [%{"type" => "tool_result", "content" => ^content}] =
        msgs |> Enum.at(2) |> Map.fetch!("content")
    end
  end

  test "chat completions: tool keeps the summary; images ride a follow-up user message" do
    msgs = ConvertOpenAI.to_chat(conversation(@blocks))

    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{
               "role" => "tool",
               "tool_call_id" => "t1",
               "content" => "[Image: /pic.png, 8 bytes]"
             },
             %{"role" => "user", "content" => [prefix_block, image_block]},
             %{"role" => "user", "content" => "thanks"}
           ] = msgs

    assert prefix_block["type"] == "text"
    assert prefix_block["text"] =~ ~s(<tool-result-vision tool="read_file" call_id="t1">)
    assert image_block == %{"type" => "image_url", "image_url" => %{"url" => @data_url}}
  end

  test "chat completions: non-image tool results are unchanged" do
    msgs = ConvertOpenAI.to_chat(conversation("plain result"))

    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "tool", "tool_call_id" => "t1", "content" => "plain result"},
             %{"role" => "user", "content" => "thanks"}
           ] = msgs
  end

  test "responses: images ride inside the function_call_output as input items" do
    items = ConvertOpenAI.to_responses(conversation(@blocks))

    output_item = Enum.find(items, &(&1["type"] == "function_call_output"))

    assert %{
             "call_id" => "t1",
             "output" => [
               %{"type" => "input_text", "text" => "[Image: /pic.png, 8 bytes]"},
               %{"type" => "input_image", "image_url" => @data_url}
             ]
           } = output_item
  end

  test "responses: non-image tool results keep the string output" do
    items = ConvertOpenAI.to_responses(conversation(~s([{"path":"/x"}])))
    output_item = Enum.find(items, &(&1["type"] == "function_call_output"))
    assert output_item["output"] == ~s([{"path":"/x"}])
  end

  test "file_ref-only image blocks (not inlined) degrade to text" do
    content =
      Jason.encode!([
        %{"type" => "image", "file_ref" => %{"environment_id" => "vfs", "path" => "/pic.png"}},
        %{"type" => "text", "text" => "[Image: /pic.png, 8 bytes]"}
      ])

    # No resolvable image ⇒ every protocol falls back to the raw string.
    {_system, msgs} = Convert.to_anthropic(conversation(content))
    [%{"content" => ^content}] = msgs |> Enum.at(2) |> Map.fetch!("content")

    chat = ConvertOpenAI.to_chat(conversation(content))
    assert %{"role" => "tool", "content" => ^content} = Enum.at(chat, 2)

    items = ConvertOpenAI.to_responses(conversation(content))
    assert Enum.find(items, &(&1["type"] == "function_call_output"))["output"] == content
  end

  test "responses: a staged image is native input while a file becomes a workspace note" do
    content =
      Jason.encode!([
        %{"type" => "text", "text" => "Inspect both"},
        %{"type" => "input_image", "image_url" => @data_url},
        %{
          "type" => "input_file",
          "filename" => "report.pdf",
          "file_data" => "data:application/pdf;base64,JVBERi0="
        }
      ])

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "Inspect both"},
                 %{"type" => "input_image", "image_url" => @data_url},
                 %{"type" => "input_text", "text" => note}
               ]
             }
           ] =
             ConvertOpenAI.to_responses([
               %{role: "user", content: content, native_content_trusted: true}
             ])

    # Even a fully formed native file block cannot reach the provider: nothing
    # downstream of the converter offers file input any more.
    assert note =~ "report.pdf"
    assert note =~ "fs.read_file"
    refute note =~ "JVBERi0="
  end

  test "chat and Anthropic keep inbound user image handling while files fall back to text" do
    content =
      Jason.encode!([
        %{"type" => "text", "text" => "Inspect"},
        %{"type" => "image_url", "image_url" => %{"url" => @data_url}},
        %{"type" => "file", "path" => "/report.pdf", "file_name" => "report.pdf"}
      ])

    assert [%{"role" => "user", "content" => chat_content}] =
             ConvertOpenAI.to_chat([
               %{role: "user", content: content, native_content_trusted: true}
             ])

    assert Enum.any?(chat_content, &(&1["type"] == "image_url"))
    assert Enum.any?(chat_content, &(&1["type"] == "text" and &1["text"] =~ "report.pdf"))

    {_system, [%{"role" => "user", "content" => anthropic_content}]} =
      Convert.to_anthropic([
        %{role: "user", content: content, native_content_trusted: true}
      ])

    assert Enum.any?(anthropic_content, &(&1["type"] == "image"))

    assert Enum.any?(
             anthropic_content,
             &(&1["type"] == "text" and &1["text"] =~ "agent workspace" and
                 &1["text"] =~ "report.pdf")
           )
  end

  test "an attachment announcement reaches every protocol as text, never escaped JSON" do
    # A non-image attachment resolves to a text-only trusted array. A decode
    # gate that requires a native image/file block would send this to the model
    # as one escaped JSON string instead of readable text.
    announcement =
      Jason.encode!([
        %{"type" => "text", "text" => "Summarize this"},
        %{
          "type" => "text",
          "text" => "[Attached file is available in the agent workspace: /report.pdf]"
        }
      ])

    user = [%{role: "user", content: announcement, native_content_trusted: true}]

    assert [%{"role" => "user", "content" => responses_content}] =
             ConvertOpenAI.to_responses(user)

    assert [
             %{"type" => "input_text", "text" => "Summarize this"},
             %{"type" => "input_text", "text" => note}
           ] = responses_content

    assert note =~ "/report.pdf"

    assert [%{"role" => "user", "content" => chat_content}] = ConvertOpenAI.to_chat(user)

    assert chat_content ==
             "Summarize this\n[Attached file is available in the agent workspace: /report.pdf]"

    {_system, [%{"role" => "user", "content" => anthropic_content}]} = Convert.to_anthropic(user)

    assert [
             %{"type" => "text", "text" => "Summarize this"},
             %{"type" => "text", "text" => ^note}
           ] = anthropic_content

    # The same announcement as a tool result, on every protocol.
    tool_conversation = conversation(announcement)

    assert ConvertOpenAI.to_responses(tool_conversation)
           |> Enum.find(&(&1["type"] == "function_call_output"))
           |> Map.fetch!("output")
           |> Enum.all?(&(&1["type"] == "input_text"))

    assert %{"content" => tool_text} = Enum.at(ConvertOpenAI.to_chat(tool_conversation), 2)
    assert tool_text =~ "/report.pdf"
    refute tool_text =~ ~s("type")

    {_system, anthropic} = Convert.to_anthropic(tool_conversation)

    assert [%{"content" => [%{"type" => "tool_result", "content" => tool_blocks}]}] =
             Enum.slice(anthropic, 2, 1)

    assert Enum.all?(tool_blocks, &(&1["type"] == "text"))
  end

  test "responses: a raw VFS-shaped file block never becomes input_file" do
    content =
      Jason.encode!([
        %{
          "type" => "file",
          "path" => "/private.pdf",
          "file_name" => "private.pdf",
          "mime_type" => "application/pdf"
        }
      ])

    assert [%{"role" => "user", "content" => ^content}] =
             ConvertOpenAI.to_responses([%{role: "user", content: content}])
  end

  test "ordinary user and arbitrary tool input_file JSON stay inert" do
    content =
      Jason.encode!([
        %{
          "type" => "input_file",
          "filename" => "private.pdf",
          "file_data" => "data:application/pdf;base64,c2VjcmV0"
        }
      ])

    assert [%{"role" => "user", "content" => ^content}] =
             ConvertOpenAI.to_responses([%{role: "user", content: content}])

    tool_conversation =
      Enum.map(@conversation, &if(&1.role == "tool", do: %{&1 | content: content}, else: &1))

    output =
      tool_conversation
      |> ConvertOpenAI.to_responses()
      |> Enum.find(&(&1["type"] == "function_call_output"))

    assert output["output"] == content

    {_system, anthropic} = Convert.to_anthropic(tool_conversation)

    [%{"content" => [%{"type" => "tool_result", "content" => ^content}]}] =
      Enum.slice(anthropic, 2, 1)
  end
end
