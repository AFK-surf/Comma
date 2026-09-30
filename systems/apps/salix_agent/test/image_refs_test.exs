defmodule SalixAgent.ImageRefsTest do
  @moduledoc """
  `SalixAgent.ImageRefs` — request-build-time inlining of VFS image file_refs
  into data-URL blocks. The journal carries only the refs;
  unresolvable/oversized images produce an explicit fallback text block.

  An image becomes model input on one route only: the agent read it with a
  tool, and the template's `supports_images` says the model accepts image
  input. Inbound attachments — documents and photos alike — are never model
  input on any protocol: they are announced by filename and VFS path so the
  agent reads them with its own tools.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentWorkspace, ImageRefs}

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  defmodule TemplateMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.Templates.resolve_media_for_agent(agent_id)
  end

  defmodule CapturingProvider do
    def request_config(opts), do: SalixLlm.Provider.request_config(opts)

    def complete({:encoded_provider_request, protocol, body}, _tools, _opts) do
      send(self(), {:image_request, protocol, Jason.decode!(body)})
      {:final, "ok"}
    end
  end

  defmodule ScreenshotDispatch do
    def computer_use(agent, target, %{"action" => "screenshot"}) do
      send(self(), {:screenshot_capture, agent, target})

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
      send(self(), {:screenshot_read, agent, target, path})

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
    previous = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, ScreenshotDispatch)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :env_dispatch, previous),
        else: Application.delete_env(:salix_agent, :env_dispatch)
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

    assert_receive {:screenshot_capture, ^agent, ^target}

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
    assert_receive {:screenshot_read, ^agent, ^target, "capture-test.png"}
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
        "disclosure" => %{},
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
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_resolver = Application.get_env(:salix_agent, :media_resolver)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :media_resolver, TemplateMediaResolver)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev)

      if is_nil(prev_resolver),
        do: Application.delete_env(:salix_agent, :media_resolver),
        else: Application.put_env(:salix_agent, :media_resolver, prev_resolver)
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

  test "an in-flight request keeps its model's image capability across a template switch", %{
    agent: agent
  } do
    previous = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, CapturingProvider)
    on_exit(fn -> Application.put_env(:salix_agent, :llm, previous) end)
    {:ok, record} = SalixAgent.Control.get_record(agent)
    template = record["template_id"]

    for {request_support, current_support} <- [{false, true}, {true, false}] do
      {:ok, _} = SalixAgent.Templates.update(template, %{"supports_images" => request_support})
      {:ok, request_opts} = SalixAgent.Templates.resolve_llm_for_agent(agent)
      {:ok, _} = SalixAgent.Templates.update(template, %{"supports_images" => current_support})

      dispatch_image_request(agent, request_opts)
      assert_receive {:image_request, "chat", body}
      assert Jason.encode!(body) =~ Base.encode64(@png) == request_support
    end
  end

  test "the same image history is encoded for each newly selected model protocol", %{agent: agent} do
    previous = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, CapturingProvider)
    on_exit(fn -> Application.put_env(:salix_agent, :llm, previous) end)
    {:ok, record} = SalixAgent.Control.get_record(agent)

    for protocol <- ["chat", "responses", "anthropic"] do
      {:ok, template} =
        SalixAgent.Templates.create(%{
          "name" => "image-switch-#{protocol}",
          "model" => "image-#{protocol}",
          "supports_images" => true,
          "provider_config" => %{"protocol" => protocol}
        })

      {:ok, _} =
        SalixAgent.Control.configure(
          agent,
          %{"template_id" => template["template_id"]},
          record["tenant_id"]
        )

      {:ok, opts} = SalixAgent.Templates.resolve_llm_for_agent(agent)
      dispatch_image_request(agent, opts)
      assert_receive {:image_request, ^protocol, body}
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

  for {pool, protocol} <- [{"codex", "responses"}, {"claude", "anthropic"}] do
    test "#{pool} subscription template preserves image capability into the round request", %{
      agent: agent
    } do
      previous = Application.get_env(:salix_agent, :llm)
      Application.put_env(:salix_agent, :llm, CapturingProvider)
      on_exit(fn -> Application.put_env(:salix_agent, :llm, previous) end)
      {:ok, record} = SalixAgent.Control.get_record(agent)
      tenant = record["tenant_id"]
      id = SalixAgent.SubscriptionStore.id()

      {:ok, credentials} =
        SalixAgent.SubscriptionStore.seal(tenant, id, %{"access_token" => "test-only"})

      {:ok, _} =
        SalixAgent.SubscriptionStore.create(tenant, %{
          "id" => id,
          "credential_kind" => "subscription_oauth",
          "provider" => unquote(pool),
          "status" => "active",
          "disabled" => false,
          "prepared" => true,
          "credentials" => credentials
        })

      for support <- [true, false] do
        {:ok, template} =
          SalixAgent.Templates.create_private(
            %{
              "name" => "subscription-image-#{unquote(pool)}",
              "model" => "image-test",
              "supports_images" => support,
              "provider_config" => %{"account_pool" => unquote(pool)}
            },
            tenant
          )

        {:ok, _} =
          SalixAgent.Control.configure(agent, %{"template_id" => template["template_id"]}, tenant)

        {:ok, opts, _cache} =
          SalixAgent.RoundConfigCache.begin_round(
            %SalixAgent.RoundConfigCache{},
            fn -> SalixAgent.Templates.resolve_llm_for_agent(agent) end
          )

        dispatch_image_request(agent, opts)
        assert_receive {:image_request, unquote(protocol), body}
        assert Jason.encode!(body) =~ Base.encode64(@png) == support
      end
    end
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
      "disclosure" => %{},
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

  test "failed preview materialization is an explicit note, not oversized raw input", %{agent: a} do
    source = :binary.copy("not an image", 60_000)
    {:ok, ev} = AgentWorkspace.prepare_write(a, "/bad.png", source)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "bad-image-seed", %{}, [ev])

    message = %{
      role: "tool",
      tool_name: "fs.read_file",
      tool_call_id: "bad-image",
      content: image_read_content("/bad.png", byte_size(source))
    }

    assert [inlined] = ImageRefs.inline([message], %{agent_id: a})
    assert [%{"type" => "text", "text" => _note}, _] = Jason.decode!(inlined.content)
    refute inlined.content =~ "base64"
  end

  test "missing file drops the image block but keeps the summary", %{agent: a} do
    msg = %{
      role: "tool",
      tool_name: "im_api.slack.fetch_file",
      tool_call_id: "t1",
      content: image_read_content("/gone.png", 8)
    }

    [inlined] = ImageRefs.inline([msg], %{agent_id: a})

    assert [
             %{"type" => "text", "text" => fallback},
             %{"type" => "text", "text" => text}
           ] = Jason.decode!(inlined.content)

    assert fallback =~ "reason=not_found"
    assert text =~ "/gone.png"
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

    # The agent template accepts image input; the attachment is withheld
    # because nothing asked for it, not because the model cannot see it.
    assert note =~ "/pic.png"
    assert note =~ "fs.read_file"
    refute inlined_user.content =~ "image_url"
    refute inlined_user.content =~ Base.encode64(@png)
  end

  test "an inbound image is withheld on every protocol", %{agent: a} do
    content = image_read_content("/pic.png", 8)
    [image_ref | _] = Jason.decode!(content)
    message = %{role: "user", content: content, trusted_attachment_refs: [image_ref]}

    for protocol <- ["chat_completions", "responses", "anthropic"] do
      assert [inlined] = ImageRefs.inline([message], %{agent_id: a, protocol: protocol})
      refute inlined.content =~ Base.encode64(@png)
    end
  end

  test "a tool read is refused native image input when the template has none" do
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

  test "a provider fetch is refused native image input when the template has none" do
    text_only = text_only_agent!()

    message = %{
      role: "tool",
      tool_name: "im_api.slack.fetch_file",
      tool_call_id: "fetch",
      content: image_read_content("/pic.png", 8)
    }

    assert [inlined] = ImageRefs.inline([message], %{agent_id: text_only})
    refute inlined.content =~ "image_url"
    refute inlined.content =~ Base.encode64(@png)
  end

  # Fail closed: an agent record that cannot be read answers the capability
  # question with "no", so an unreachable control plane withholds the image
  # rather than letting the provider classify the rejection for us.
  test "an unresolvable agent never materializes image bytes" do
    message = %{
      role: "tool",
      tool_name: "fs.read_file",
      tool_call_id: "read",
      content: image_read_content("/pic.png", 8)
    }

    unknown = SalixAgent.TestSupport.new_agent_id()
    assert [inlined] = ImageRefs.inline([message], %{agent_id: unknown})

    assert [%{"type" => "text", "text" => _note}, %{"type" => "text"}] =
             Jason.decode!(inlined.content)

    refute inlined.content =~ "image_url"
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

  test "announces a completed async provider PDF returned by tool_call.get_result", %{
    agent: a
  } do
    pdf = "%PDF-1.4\nasync provider result\n%%EOF\n"
    {:ok, event} = AgentWorkspace.prepare_write(a, "/async-report.pdf", pdf)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "async-pdf-native-input", %{}, [event])

    provider_blocks = [
      %{"type" => "text", "text" => ~s({"file_name":"async-report.pdf"})},
      %{
        "type" => "file",
        "path" => "/async-report.pdf",
        "file_name" => "async-report.pdf",
        "mime_type" => "application/pdf"
      }
    ]

    message = %{
      role: "tool",
      tool_name: "tool_call.get_result",
      content:
        Jason.encode!(%{
          "status" => "completed",
          "tool_call_id" => "provider-fetch-async",
          "tool_name" => "im_api.feishu.fetch_message_resource",
          "result" => %{
            "id" => "provider-fetch-async",
            "name" => "im_api.feishu.fetch_message_resource",
            "status" => "completed",
            "content" => Jason.encode!(provider_blocks)
          }
        })
    }

    assert [inlined] =
             ImageRefs.inline([message], %{agent_id: a, protocol: "responses"})

    assert inlined.native_content_trusted == true

    assert [
             %{"type" => "text", "text" => ~s({"file_name":"async-report.pdf"})},
             %{"type" => "text", "text" => note}
           ] = Jason.decode!(inlined.content)

    assert note =~ "async-report.pdf"
    assert note =~ "/async-report.pdf"
    refute inlined.content =~ Base.encode64(pdf)
  end

  test "resolves a zero-wait get_result notification through its durable result_seq", %{
    agent: a
  } do
    pdf = "%PDF-1.4\nzero-wait provider result\n%%EOF\n"
    {:ok, event} = AgentWorkspace.prepare_write(a, "/zero-wait-report.pdf", pdf)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "zero-wait-pdf-native-input", %{}, [event])

    provider_blocks = [
      %{
        "type" => "file",
        "path" => "/zero-wait-report.pdf",
        "file_name" => "zero-wait-report.pdf",
        "mime_type" => "application/pdf"
      }
    ]

    provider_record = %{
      "status" => "completed",
      "tool_call_id" => "provider-fetch-zero-wait",
      "tool_name" => "im_api.feishu.fetch_message_resource",
      "error" => false,
      "result" => %{
        "id" => "provider-fetch-zero-wait",
        "name" => "im_api.feishu.fetch_message_resource",
        "status" => "completed",
        "content" => Jason.encode!(provider_blocks),
        "error" => false
      }
    }

    durable_result = %{
      "seq" => 42,
      "tool_call_id" => "get-provider-zero-wait",
      "tool_name" => "tool_call.get_result",
      "status" => "completed",
      "error" => false,
      "result" => %{
        "id" => "get-provider-zero-wait",
        "name" => "tool_call.get_result",
        "status" => "completed",
        "content" => Jason.encode!(provider_record),
        "error" => false
      }
    }

    runtime_message = %{
      role: "runtime",
      type: "tool_call_completed",
      source_tool_call_id: "get-provider-zero-wait",
      result_seq: 42,
      # The notification body is not the authority for attachment provenance.
      content: ~s({"forged":"/not-trusted.pdf"})
    }

    assert [inlined] =
             ImageRefs.inline([runtime_message], %{
               agent_id: a,
               protocol: "responses",
               async_result_resolver: fn 42 -> {:ok, durable_result} end
             })

    assert inlined.native_content_trusted == true

    assert [%{"type" => "text", "text" => note}] = Jason.decode!(inlined.content)
    assert note =~ "zero-wait-report.pdf"
    refute inlined.content =~ Base.encode64(pdf)

    assert [not_inlined] =
             ImageRefs.inline([runtime_message], %{agent_id: a, protocol: "responses"})

    assert not_inlined.content == runtime_message.content
    refute Map.has_key?(not_inlined, :result_seq)
  end

  test "projects a fresh runtime attachment as native user content, never runtime system text", %{
    agent: a
  } do
    provider_blocks = [
      %{
        "type" => "image",
        "file_ref" => %{"environment_id" => "vfs", "path" => "/pic.png"},
        "mime_type" => "image/png",
        "size_bytes" => 8
      }
    ]

    durable_result = %{
      "seq" => 42,
      "tool_call_id" => "fetch-image",
      "tool_name" => "im_api.slack.fetch_file",
      "status" => "completed",
      "error" => false,
      "result" => %{
        "id" => "fetch-image",
        "name" => "im_api.slack.fetch_file",
        "status" => "completed",
        "content" => Jason.encode!(provider_blocks),
        "error" => false
      }
    }

    runtime_message = %{
      id: 11,
      role: "runtime",
      type: "tool_call_completed",
      source_tool_call_id: "fetch-image",
      result_seq: 42,
      content: ~s({"status":"completed"})
    }

    assert [projected] =
             ImageRefs.inline([runtime_message], %{
               agent_id: a,
               protocol: "chat_completions",
               attachment_after_message_id: 10,
               async_result_resolver: fn 42 -> {:ok, durable_result} end
             })

    assert projected.role == "user"
    assert projected.native_content_trusted == true
    refute Map.has_key?(projected, :result_seq)

    encoded_png = Base.encode64(@png)
    assert projected.content =~ encoded_png

    [chat_message] = SalixLlm.ConvertOpenAI.to_chat([projected])
    assert chat_message["role"] == "user"
    assert [%{"type" => "image_url"}] = chat_message["content"]

    textual_values =
      chat_message
      |> Map.get("content")
      |> Enum.flat_map(&Map.values/1)
      |> Enum.filter(&is_binary/1)

    refute Enum.any?(textual_values, &String.contains?(&1, encoded_png))
  end

  test "does not read or materialize acknowledged or disabled attachment history", %{agent: a} do
    old = %{
      id: 10,
      role: "tool",
      tool_name: "im_api.slack.fetch_file",
      tool_call_id: "old",
      content: image_read_content("/pic.png", 8)
    }

    fresh = %{old | id: 11, tool_call_id: "fresh"}

    assert [^old, inlined] =
             ImageRefs.inline([old, fresh], %{
               agent_id: a,
               attachment_after_message_id: 10
             })

    assert inlined.content =~ Base.encode64(@png)

    assert [^fresh] =
             ImageRefs.inline([fresh], %{
               agent_id: a,
               materialize_native_attachments: false
             })
  end

  test "tool_call.get_result requires one complete successful canonical provider result", %{
    agent: a
  } do
    secret = "%PDF-1.4\nprivate async result\n%%EOF\n"
    {:ok, event} = AgentWorkspace.prepare_write(a, "/async-private.pdf", secret)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "async-private-pdf", %{}, [event])

    blocks =
      Jason.encode!([
        %{
          "type" => "file",
          "path" => "/async-private.pdf",
          "file_name" => "async-private.pdf",
          "mime_type" => "application/pdf"
        }
      ])

    trusted_tool = "im_api.feishu.fetch_message_resource"

    canonical = %{
      "status" => "completed",
      "tool_call_id" => "async-private",
      "tool_name" => trusted_tool,
      "error" => false,
      "result" => %{
        "id" => "async-private",
        "name" => trusted_tool,
        "status" => "completed",
        "content" => blocks,
        "error" => false
      }
    }

    page = %{
      "encoding" => "json",
      "offset" => 0,
      "next_offset" => 100,
      "content" => blocks
    }

    records = [
      put_in(canonical, ["tool_name"], "env.exec")
      |> put_in(["result", "name"], "env.exec"),
      put_in(canonical, ["result", "name"], "env.exec"),
      canonical
      |> put_in(["tool_name"], "env.exec")
      |> put_in(["result", "name"], trusted_tool),
      put_in(canonical, ["status"], "failed"),
      put_in(canonical, ["status"], "cancelled"),
      put_in(canonical, ["error"], true),
      put_in(canonical, ["result", "status"], "failed"),
      put_in(canonical, ["result", "error"], true),
      put_in(canonical, ["result", "id"], "different-call"),
      put_in(canonical, ["result", "content"], Jason.encode!(%{"not" => "blocks"})),
      canonical
      |> Map.delete("result")
      |> Map.put("result_page", page),
      Map.put(canonical, "result_page", page)
    ]

    messages =
      Enum.map(records, fn record ->
        %{
          role: "tool",
          tool_name: "tool_call.get_result",
          content: Jason.encode!(record)
        }
      end)

    assert ImageRefs.inline(messages, %{agent_id: a, protocol: "responses"}) == messages
    refute Enum.any?(messages, &String.contains?(&1.content, Base.encode64(secret)))
  end

  test "a read static GIF remains native image input", %{agent: a} do
    frame =
      <<0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0>>

    gif =
      <<"GIF89a", 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 255, 255, 255>> <>
        frame <> <<0x3B>>

    {:ok, event} = AgentWorkspace.prepare_write(a, "/static.gif", gif)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "static-gif-native", %{}, [event])

    content =
      Jason.encode!([
        %{
          "type" => "image",
          "file_ref" => %{"environment_id" => "vfs", "path" => "/static.gif"},
          "file_name" => "static.gif",
          "mime_type" => "image/gif"
        }
      ])

    [inlined] =
      ImageRefs.inline(
        [%{role: "tool", tool_name: "fs.read_file", tool_call_id: "static", content: content}],
        %{agent_id: a, protocol: "responses"}
      )

    assert [%{"type" => "image_url", "image_url" => %{"url" => data_url}}] =
             Jason.decode!(inlined.content)

    assert data_url == "data:image/gif;base64," <> Base.encode64(gif)
  end

  test "a read animated GIF uses the explicit first-frame preprocessing path", %{agent: a} do
    frame =
      <<0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0>>

    gif =
      <<"GIF89a", 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 255, 255, 255>> <>
        frame <> frame <> <<0x3B>>

    {:ok, event} = AgentWorkspace.prepare_write(a, "/animated.gif", gif)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "animated-gif-fallback", %{}, [event])

    content =
      Jason.encode!([
        %{
          "type" => "image",
          "file_ref" => %{"environment_id" => "vfs", "path" => "/animated.gif"},
          "file_name" => "animated.gif",
          "mime_type" => "image/gif"
        }
      ])

    [inlined] =
      ImageRefs.inline(
        [%{role: "tool", tool_name: "fs.read_file", tool_call_id: "animated", content: content}],
        %{agent_id: a, protocol: "responses"}
      )

    assert [%{"type" => "text", "text" => fallback}] = Jason.decode!(inlined.content)
    assert fallback =~ "reason=animated_gif"
    assert fallback =~ "env.exec"
    refute fallback =~ "data:image/gif"
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

  test "fs.read_file image output remains trusted native vision", %{agent: a} do
    content = image_read_content("/pic.png", 8)
    message = %{role: "tool", tool_name: "fs.read_file", content: content}

    assert [inlined] = ImageRefs.inline([message], %{agent_id: a, protocol: "responses"})
    assert inlined.native_content_trusted == true
    assert [%{"type" => "image_url"}, %{"type" => "text"}] = Jason.decode!(inlined.content)
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

  test "oversized staged images produce an explicit fallback instead of disappearing", %{agent: a} do
    oversized = :binary.copy(<<0>>, 5 * 1024 * 1024 + 1)
    {:ok, event} = AgentWorkspace.prepare_write(a, "/large.png", oversized)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "large-image", %{}, [event])

    content = image_read_content("/large.png", byte_size(oversized))

    [inlined] =
      ImageRefs.inline(
        [%{role: "tool", tool_name: "fs.read_file", tool_call_id: "oversized", content: content}],
        %{agent_id: a}
      )

    assert [
             %{"type" => "text", "text" => fallback},
             %{"type" => "text", "text" => _summary}
           ] = Jason.decode!(inlined.content)

    assert fallback =~ "large.png"
    assert fallback =~ "reason=oversized"
    assert fallback =~ "env.exec"
  end

  test "unsupported provider image MIME types require explicit preprocessing", %{agent: a} do
    for {path, mime} <- [
          {"/photo.heic", "image/heic"},
          {"/scan.tiff", "image/tiff"},
          {"/drawing.svg", "image/svg+xml"}
        ] do
      {:ok, event} = AgentWorkspace.prepare_write(a, path, "unsupported-image")
      assert {:ok, _} = AgentWorkspace.seed_operation(a, "unsupported-#{path}", %{}, [event])

      image_ref = %{
        "type" => "image",
        "file_ref" => %{"environment_id" => "vfs", "path" => path},
        "file_name" => Path.basename(path),
        "mime_type" => mime
      }

      message = %{
        role: "tool",
        id: 1,
        tool_name: "fs.read_file",
        tool_call_id: "unsupported",
        content: Jason.encode!([image_ref])
      }

      assert [inlined] = ImageRefs.inline([message], %{agent_id: a, protocol: "responses"})
      assert inlined.native_content_trusted == true
      assert [%{"type" => "text", "text" => fallback}] = Jason.decode!(inlined.content)
      assert fallback =~ "reason=unsupported_format"
      assert fallback =~ "env.exec"
      assert fallback =~ Path.basename(path)
    end
  end
end
