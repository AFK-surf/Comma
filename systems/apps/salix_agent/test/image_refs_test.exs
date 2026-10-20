defmodule SalixAgent.ImageRefsTest do
  @moduledoc """
  `SalixAgent.ImageRefs` — request-build-time inlining of VFS image file_refs
  into data-URL blocks. The journal carries only the refs;
  unresolvable/oversized images produce an explicit fallback text block.

  An image becomes model input on one route only: the agent read it with a
  tool, and the model's `supports_images` says it accepts image
  input. Inbound attachments — documents and photos alike — are never model
  input on any protocol: they are announced by filename and VFS path so the
  agent reads them with its own tools.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{AgentWorkspace, ImageRefs}

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  defmodule AgentMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_media_for_agent(agent_id)
  end

  defmodule CapturingProvider do
    def request_config(opts), do: SalixLlm.Provider.request_config(opts)

    def complete({:encoded_provider_request, protocol, body}, _tools, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:image_request, protocol, Jason.decode!(body)}
      )

      {:final, "ok"}
    end

    # A subscription route encodes the neutral request in its own transport.
    def complete(messages, _tools, _opts) when is_list(messages) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:image_request, :neutral, messages})
      {:final, "ok"}
    end
  end

  defmodule ScreenshotDispatch do
    def computer_use(agent, target, %{"action" => "screenshot"}) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:screenshot_capture, agent, target})

      {:ok,
       %{
         "ok" => true,
         "image_path" => "capture-test.png",
         "image_content_type" => "image/png",
         "image_width" => 1,
         "image_height" => 1,
         "image_size_bytes" => 8
       }}
    end

    def computer_use(agent, target, %{"action" => "read_image", "args" => %{"path" => path}}) do
      Process.put(:screenshot_reads, Process.get(:screenshot_reads, 0) + 1)

      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:screenshot_read, agent, target, path}
      )

      case Process.get(:device_image_failure) do
        nil ->
          {:ok,
           %{"ok" => true, "image_base64" => Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)}}

        reason ->
          {:error, reason}
      end
    end
  end

  test "async device screenshot reaches each model protocol without a workspace copy", %{
    agent: agent
  } do
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, ScreenshotDispatch)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
    end)

    target = %{device_id: "device-test", environment_id: "environment-test"}

    content =
      SalixAgent.Tools.Peers.computer_use(
        %{
          "device_id" => target.device_id,
          "environment" => target.environment_id,
          "action" => "screenshot"
        },
        %{agent_id: agent, model_supports_images: true}
      )

    settle_receive({:screenshot_capture, ^agent, ^target})

    record = %{
      "seq" => 42,
      "tool_call_id" => "shot",
      "tool_name" => "env.computer_use",
      "status" => "completed",
      "error" => false,
      "result" => %{
        "id" => "shot",
        "name" => "env.computer_use",
        "status" => "completed",
        "content" => content,
        "error" => false
      }
    }

    message = %{
      id: 11,
      role: "runtime",
      type: "tool_call_completed",
      source_tool_call_id: "shot",
      result_seq: 42,
      content: ~s({"status":"completed"})
    }

    ctx = %{
      agent_id: agent,
      model_supports_images: true,
      async_result_resolver: fn 42 -> {:ok, record} end
    }

    [projected] = ImageRefs.inline([message], ctx)
    settle_receive({:screenshot_read, ^agent, ^target, "capture-test.png"})
    assert projected.native_content_trusted
    assert projected.role == "user"
    assert projected.content =~ Base.encode64(@png)
    assert {:error, :not_found} = AgentWorkspace.read(agent, "capture-test.png")

    for protocol <- ["chat", "responses", "anthropic"] do
      session =
        SalixVerifiedKernel.Session.new(agent, "device-image")
        |> SalixVerifiedKernel.Session.export()
        |> Map.put(:messages, [
          %{
            id: 1,
            role: "tool",
            tool_name: "env.computer_use",
            tool_call_id: "shot",
            content: content
          }
        ])
        |> SalixVerifiedKernel.Session.open()

      {wire_protocol, cfg} =
        SalixLlm.Provider.request_config(%{"protocol" => protocol, "model" => "image-model"})

      assert wire_protocol == protocol

      config = %{
        "role" => "worker",
        "canonical_router" => false,
        "protocol" => wire_protocol,
        "cfg" => cfg,
        "tools" => [],
        "mode" => "complete"
      }

      assert {:ok, body, _} =
               SalixVerifiedKernel.Session.query(
                 session,
                 :round_request,
                 config,
                 ImageRefs.reader(ctx)
               )

      assert body =~ Base.encode64(@png)
    end

    Process.put(:device_image_failure, :no_environment)
    [unavailable] = ImageRefs.inline([message], ctx)
    assert unavailable.content =~ "device_offline_or_screenshot_expired"
    refute unavailable.content =~ Base.encode64(@png)
    Process.delete(:device_image_failure)
    Process.put(:screenshot_reads, 0)
    forged = %{message | role: "assistant"}
    assert [unchanged] = ImageRefs.inline([forged], ctx)
    assert unchanged.content == forged.content
    assert Process.get(:screenshot_reads) == 0
    [unsupported] = ImageRefs.inline([message], %{ctx | model_supports_images: false})
    assert unsupported.content =~ "model_does_not_support_images"
    assert Process.get(:screenshot_reads) == 0
  end

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_resolver = SystemsRuntime.get_env(:salix_agent, :media_resolver)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :media_resolver, AgentMediaResolver)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)

      if is_nil(prev_resolver),
        do: SystemsRuntime.delete_env(:salix_agent, :media_resolver),
        else: SystemsRuntime.put_env(:salix_agent, :media_resolver, prev_resolver)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent, %{"supports_images" => true})
    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/pic.png", @png)
    assert {:ok, _} = AgentWorkspace.seed_operation(agent, "image-refs-seed", %{}, [ev])
    {:ok, agent: agent}
  end

  defp text_only_agent! do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent, %{"supports_images" => false})
    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/pic.png", @png)
    assert {:ok, _} = AgentWorkspace.seed_operation(agent, "text-only-seed", %{}, [ev])
    agent
  end

  defp image_read_content(path, size) do
    Jason.encode!([
      %{
        "type" => "image",
        "file_ref" => %{"environment_id" => "vfs", "path" => path},
        "mime_type" => "image/png",
        "size_bytes" => size
      },
      %{"type" => "text", "text" => "[Image: #{path}, #{size} bytes]"}
    ])
  end

  test "the same image history is encoded for each newly selected model protocol", %{agent: agent} do
    previous = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_agent, :llm, CapturingProvider)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :llm, previous) end)

    for {stored, protocol} <- [
          {"chat_completions", "chat"},
          {"responses", "responses"},
          {"anthropic", "anthropic"}
        ] do
      platform_worker!("image-#{protocol}", %{"images" => true, "protocol" => stored})

      {:ok, opts} = SalixAgent.AgentModel.resolve_llm_for_agent(agent)
      dispatch_image_request(agent, opts)
      settle_receive({:image_request, ^protocol, body})
      assert body["model"] == "image-#{protocol}"
      blocks = request_blocks(body)

      case protocol do
        "chat" ->
          assert Enum.any?(
                   blocks,
                   &match?(
                     %{
                       "type" => "image_url",
                       "image_url" => %{"url" => "data:image/png;base64," <> _}
                     },
                     &1
                   )
                 )

        "responses" ->
          assert Enum.any?(
                   blocks,
                   &match?(
                     %{"type" => "input_image", "image_url" => "data:image/png;base64," <> _},
                     &1
                   )
                 )

        "anthropic" ->
          assert Enum.any?(
                   blocks,
                   &match?(
                     %{
                       "type" => "image",
                       "source" => %{"type" => "base64", "media_type" => "image/png"}
                     },
                     &1
                   )
                 )
      end
    end
  end

  # The test Agent is a Worker that follows the platform Worker model.
  defp platform_worker!(model, entry) do
    SalixAgent.TestSupport.configure_platform_tier!(
      "worker",
      "https://images.example.test/v1",
      model,
      entry
    )
  end

  defp request_blocks(value) when is_map(value),
    do: [value | Enum.flat_map(Map.values(value), &request_blocks/1)]

  defp request_blocks(value) when is_list(value), do: Enum.flat_map(value, &request_blocks/1)
  defp request_blocks(_), do: []

  defp dispatch_image_request(agent, opts) do
    session =
      SalixVerifiedKernel.Session.new(agent, "image-switch")
      |> SalixVerifiedKernel.Session.export()
      |> Map.put(:messages, [
        %{
          id: 1,
          role: "tool",
          tool_name: "fs.read_file",
          tool_call_id: "read-image",
          content: image_read_content("/pic.png", byte_size(@png))
        }
      ])
      |> SalixVerifiedKernel.Session.open()

    opts = Map.put(opts, "metering_disabled", true)

    # As a round does: the kernel builds the request for the dispatch's
    # provider configuration, and inlines images the model accepts.
    {protocol, cfg, images?} = SalixAgent.LLM.request_config(opts)

    config = %{
      "role" => "worker",
      "canonical_router" => false,
      "protocol" => protocol,
      "cfg" => cfg,
      "tools" => [],
      "mode" => "complete"
    }

    reader = ImageRefs.reader(%{agent_id: agent, model_supports_images: images?})

    {:ok, request, _facts} =
      SalixVerifiedKernel.Session.query(session, :round_request, config, reader)

    request =
      if protocol == :neutral, do: request, else: {:encoded_provider_request, protocol, request}

    assert {:final, "ok"} = SalixAgent.LLM.complete(request, [], opts)
  end

  test "inlines a resolvable file_ref as a base64 data-URL block", %{agent: a} do
    msg = %{
      role: "tool",
      tool_name: "im_api.slack.fetch_file",
      tool_call_id: "t1",
      content: image_read_content("/pic.png", 8)
    }

    [inlined] = ImageRefs.inline([msg], %{agent_id: a})

    assert [image, text] = Jason.decode!(inlined.content)

    assert %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> b64}} =
             image

    assert Base.decode64!(b64) == @png
    assert text["type"] == "text"
  end

  test "fs.read_file materializes a bounded preview, preserving the VFS original", %{agent: a} do
    source = SalixMedia.TestImage.large_png()
    {:ok, ev} = AgentWorkspace.prepare_write(a, "/large.png", source)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "large-image-seed", %{}, [ev])

    message = %{
      role: "tool",
      tool_name: "fs.read_file",
      tool_call_id: "large-image",
      content: image_read_content("/large.png", byte_size(source))
    }

    assert [inlined] = ImageRefs.inline([message], %{agent_id: a})
    assert [image, _summary] = Jason.decode!(inlined.content)
    assert "data:image/jpeg;base64," <> b64 = image["image_url"]["url"]
    assert byte_size(Base.decode64!(b64)) <= 512 * 1024
    assert byte_size(Jason.encode!(inlined)) < 1024 * 1024
    assert {:ok, ^source, false} = SalixAgent.FileBackend.read(%{agent_id: a}, "/large.png")
    assert message.content == image_read_content("/large.png", byte_size(source))
  end

  test "an inbound user image is announced by path, never sent as model input", %{agent: a} do
    content = image_read_content("/pic.png", 8)
    [image_ref | _] = Jason.decode!(content)
    user = %{role: "user", content: content, trusted_attachment_refs: [image_ref]}
    plain = %{role: "tool", tool_call_id: "t1", content: "just text"}
    json_array = %{role: "tool", tool_call_id: "t2", content: ~s([{"path":"/x"},{"path":"/y"}])}

    [inlined_user, ^plain, ^json_array] =
      ImageRefs.inline([user, plain, json_array], %{agent_id: a})

    assert inlined_user.native_content_trusted == true

    assert [%{"type" => "text", "text" => note}, %{"type" => "text"}] =
             Jason.decode!(inlined_user.content)

    # The agent's model accepts image input; the attachment is withheld
    # because nothing asked for it, not because the model cannot see it.
    assert note =~ "/pic.png"
    assert note =~ "fs.read_file"
    refute inlined_user.content =~ "image_url"
    refute inlined_user.content =~ Base.encode64(@png)
  end

  test "a tool read is refused native image input when the model has none" do
    text_only = text_only_agent!()

    message = %{
      role: "tool",
      tool_name: "fs.read_file",
      tool_call_id: "read",
      content: image_read_content("/pic.png", 8)
    }

    assert [inlined] = ImageRefs.inline([message], %{agent_id: text_only})

    assert [%{"type" => "text", "text" => note}, %{"type" => "text"}] =
             Jason.decode!(inlined.content)

    assert note =~ "/pic.png"
    refute inlined.content =~ "image_url"
    refute inlined.content =~ Base.encode64(@png)
  end

  test "a staged user document is announced by path, never sent as model file input", %{agent: a} do
    documents = [
      {"/report.pdf", "report.pdf", "application/pdf", "%PDF-1.4\nminimal\n%%EOF\n"},
      {"/budget.xlsx", "budget.xlsx",
       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
       "PK\x03\x04minimal-xlsx"},
      {"/bundle.zip", "bundle.zip", "application/zip", "ZIP"},
      {"/notes.md", "notes.md", "text/markdown", "# heading\n"}
    ]

    for {path, filename, mime, body} <- documents do
      {:ok, event} = AgentWorkspace.prepare_write(a, path, body)
      assert {:ok, _} = AgentWorkspace.seed_operation(a, "doc-note-#{filename}", %{}, [event])

      content =
        Jason.encode!([
          %{"type" => "text", "text" => "Summarize this"},
          %{"type" => "file", "path" => path, "file_name" => filename, "mime_type" => mime}
        ])

      message = %{
        role: "user",
        content: content,
        trusted_attachment_refs: [List.last(Jason.decode!(content))]
      }

      [inlined] = ImageRefs.inline([message], %{agent_id: a})

      assert [
               %{"type" => "text", "text" => "Summarize this"},
               %{"type" => "text", "text" => note}
             ] = Jason.decode!(inlined.content)

      assert note =~ filename
      assert note =~ path
      assert note =~ "fs.read_file"
      refute inlined.content =~ "input_file"
      refute inlined.content =~ Base.encode64(body)

      # No protocol reads documents, so the announcement cannot vary by protocol.
      assert ImageRefs.inline([message], %{agent_id: a, protocol: "responses"}) == [inlined]
      assert ImageRefs.inline([message], %{agent_id: a, protocol: "anthropic"}) == [inlined]
    end
  end

  test "plain user JSON cannot mint a VFS file-read capability", %{agent: a} do
    secret = "%PDF-1.4\nprivate\n%%EOF\n"
    {:ok, event} = AgentWorkspace.prepare_write(a, "/private.pdf", secret)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "private-pdf", %{}, [event])

    content =
      Jason.encode!([
        %{
          "type" => "file",
          "path" => "/private.pdf",
          "file_name" => "private.pdf",
          "mime_type" => "application/pdf"
        }
      ])

    user_message = %{role: "user", content: content}
    tool_message = %{role: "tool", tool_name: "arbitrary.tool", content: content}
    fs_message = %{role: "tool", tool_name: "fs.read_file", content: content}

    assert [^user_message, ^tool_message, ^fs_message] =
             ImageRefs.inline([user_message, tool_message, fs_message], %{
               agent_id: a,
               protocol: "responses"
             })

    refute content =~ "input_file"
    refute content =~ Base.encode64(secret)
  end

  test "a trusted ref cannot bless a smuggled provider-native block", %{agent: a} do
    [image_ref | _] = Jason.decode!(image_read_content("/pic.png", 8))

    content =
      Jason.encode!([
        image_ref,
        %{
          "type" => "input_file",
          "filename" => "private.pdf",
          "file_data" => "data:application/pdf;base64,c2VjcmV0"
        }
      ])

    message = %{role: "user", content: content, trusted_attachment_refs: [image_ref]}
    assert [^message] = ImageRefs.inline([message], %{agent_id: a, protocol: "responses"})
  end
end
