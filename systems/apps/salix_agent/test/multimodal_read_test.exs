defmodule SalixAgent.MultimodalReadTest do
  @moduledoc """
  End-to-end multimodal read: a round where the LLM calls `fs.read_file` on a
  binary image. The durable async result carries willow's file_ref block array
  (no raw bytes — the JSON-lines journal cannot hold them), while the terminal
  runtime notification in the NEXT LLM request is projected request-only as
  user/native content with the image inlined as a base64 data URL.
  """
  use ExUnit.Case, async: false

  alias SalixStore.Keys
  alias SalixAgent.{AgentWorkspace, Fleet, Server}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>
  @session_id "ses1_0000000000000000502"

  defmodule SeeingLLM do
    @moduledoc "Reads /pic.png on the first turn; reports what it saw after."
    def complete(messages, _specs) do
      send(:multimodal_read_test, {:llm_saw, messages})

      case Enum.count(messages, &((&1[:role] || &1["role"]) == "tool")) do
        0 ->
          {:assistant, "",
           [
             %{
               id: "t1",
               name: "call",
               args: %{
                 "tool" => "fs.read_file",
                 "params" => %{"path" => "/pic.png", "vision_query" => "Read the task titles"}
               }
             }
           ]}

        1 ->
          {:assistant, "checking once",
           [
             %{
               id: "t2",
               name: "call",
               args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
             }
           ]}

        _ ->
          {:assistant, "described",
           [%{id: "finish", name: "end_turn", args: %{"outcome" => "done"}}]}
      end
    end
  end

  defmodule TemplateMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.Templates.resolve_media_for_agent(agent_id)
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_media_resolver = Application.get_env(:salix_agent, :media_resolver)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, SeeingLLM)
    Application.put_env(:salix_agent, :media_resolver, TemplateMediaResolver)
    Process.register(self(), :multimodal_read_test)
    agent = SalixAgent.TestSupport.new_agent_id()

    on_exit(fn ->
      if SalixStore.S3.Fake.paused?(), do: SalixStore.S3.Fake.release_pause()
      _ = SalixAgent.TestSupport.await_session_quiet(agent, @session_id)
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      Application.put_env(:salix_agent, :llm, prev_llm)

      if is_nil(prev_media_resolver),
        do: Application.delete_env(:salix_agent, :media_resolver),
        else: Application.put_env(:salix_agent, :media_resolver, prev_media_resolver)
    end)

    {:ok, agent: agent}
  end

  test "async journal keeps the file_ref; the next LLM request sees inline image bytes", %{
    agent: a
  } do
    # Seed the image into VFS before the server claims the agent.
    SalixAgent.TestSupport.create_control_agent!(a, %{"supports_images" => true})
    {:ok, ev} = AgentWorkspace.prepare_write(a, "/pic.png", @png)
    assert {:ok, _} = AgentWorkspace.seed_operation(a, "multimodal-seed", %{}, [ev])

    # `execute_with_async_window/2` intentionally accepts a dependency result
    # that is already in the actor mailbox as a synchronous fast path. Pause
    # this exact blob read so this test deterministically exercises the async
    # ownership and terminal-journal path named by the test.
    blob_key = Keys.blob(get_in(ev, ["ref", "uuid"]))
    :ok = SalixStore.S3.Fake.set_fault({:pause, :get, blob_key})

    {:ok, _pid} = Fleet.ensure_started(a)

    {:ok, :created} =
      deliver(a, "u1", %{content: "what's in pic.png?", session_id: @session_id})

    Server.wake(a)
    {:parked, _owned} = Server.info(a)

    # The three LLM observations are explicit progress signals for this round.
    # Once the final continuation starts, drain only this session's actor work
    # before reading its durable terminal state.
    deadline = System.monotonic_time(:millisecond) + 10_000
    [first] = await_llm_requests!(a, 1, deadline)
    await_paused_blob_read!(deadline)
    early = await_early_async_boundary!(a, deadline)
    :ok = SalixStore.S3.Fake.release_pause()
    [second, third] = await_llm_requests!(a, 2, deadline)
    await_session_quiet!(a, deadline)
    session = read_session!(a)

    assert Enum.any?(session.messages, &(&1.role == "assistant" and &1.content == "described"))

    # The zero-wait tool message is only the early ownership boundary. The
    # terminal async record is the durable authority for the result content.
    assert ^early = Enum.find(session.messages, &(&1.role == "tool" and &1.tool_call_id == "t1"))
    assert Jason.decode!(early.content)["status"] == "running"

    assert {:ok, terminal} =
             SalixAgent.InternalAgentRuntime.get_async_tool_call(a, @session_id, "t1")

    assert terminal["status"] == "completed"
    assert [image, text] = terminal |> get_in(["result", "content"]) |> Jason.decode!()
    assert image["file_ref"] == %{"environment_id" => "vfs", "path" => "/pic.png"}
    assert text["text"] == "[Image: /pic.png, #{byte_size(@png)} bytes]"
    refute terminal["result"]["content"] =~ "base64"

    # Durable storage reproduces the same journal-safe terminal content.
    assert {:ok, replayed} =
             SalixAgent.InternalAgentRuntime.get_async_tool_call(a, @session_id, "t1")

    assert replayed["result"]["content"] == terminal["result"]["content"]

    # First request: no tool messages. Second request: the inlined image.
    refute Enum.any?(first, &(&1[:role] == "tool"))

    attachment_seen =
      Enum.find(second, fn message ->
        (message[:role] || message["role"]) == "user" and
          (message[:source_tool_call_id] || message["source_tool_call_id"]) == "t1"
      end)

    assert [
             %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> b64}},
             _text
           ] =
             Jason.decode!(attachment_seen.content)

    assert Base.decode64!(b64) == @png

    # Responses requests are rebuilt for each continuation, so the trusted
    # attachment remains native input instead of being retired by local state.
    repeated_attachment =
      Enum.find(third, fn message ->
        (message[:role] || message["role"]) == "user" and
          (message[:source_tool_call_id] || message["source_tool_call_id"]) == "t1"
      end)

    assert [%{"type" => "image_url", "image_url" => %{"url" => repeated}}, _summary] =
             Jason.decode!(repeated_attachment.content)

    assert repeated == "data:image/png;base64," <> Base.encode64(@png)
  end

  defp await_llm_requests!(agent, count, deadline) do
    Enum.map(1..count, fn request_number ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:llm_saw, messages} ->
          messages
      after
        remaining ->
          flunk(
            "timed out waiting for LLM request #{request_number}/#{count}; " <>
              "session=#{inspect(session_diagnostic(agent))}"
          )
      end
    end)
  end

  defp await_session_quiet!(agent, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case SalixAgent.TestSupport.await_session_quiet(agent, @session_id, remaining) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk(
          "timed out draining multimodal session; session=#{inspect(session_diagnostic(agent))}"
        )
    end
  end

  defp await_paused_blob_read!(deadline) do
    await_until!(deadline, "timed out waiting for the controlled blob read", fn ->
      if SalixStore.S3.Fake.paused?(), do: {:ok, :paused}, else: :retry
    end)
  end

  defp await_early_async_boundary!(agent, deadline) do
    await_until!(deadline, "timed out waiting for the early async tool boundary", fn ->
      session = read_session!(agent)

      early =
        Enum.find(session.messages, &(&1.role == "tool" and &1.tool_call_id == "t1"))

      case early && Jason.decode(early.content) do
        {:ok, %{"status" => "running"}} -> {:ok, early}
        _ -> :retry
      end
    end)
  end

  defp await_until!(deadline, message, fun) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(message)
        else
          Process.sleep(5)
          await_until!(deadline, message, fun)
        end
    end
  end

  defp read_session!(agent) do
    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent, @session_id)
    session
  end

  defp session_diagnostic(agent) do
    case SalixAgent.TestSupport.SessionData.read(agent, @session_id) do
      {:ok, session} ->
        %{
          status: session.status,
          messages: Enum.map(session.messages, &{&1.role, &1.content}),
          async_tool_calls: session.async_tool_calls,
          work_index_reasons: session.work_index_reasons
        }

      {:error, reason} ->
        reason
    end
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
