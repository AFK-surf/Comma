defmodule SalixAgent.TitlesTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Auto session titles (willow's `maybeGenerateTitle` port): post-settle
  background generation from the first user message, willow's sanitization
  rules, the `if_unnamed` apply guard (a user rename always wins), the
  template-analyze-model resolution (Salix divergence from willow's global
  summarizer), and placeholder-only retitling.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{Fleet, Server, Titles}
  alias SalixAgent.LLM.Mock

  @session_id "ses1_0000000000000000401"

  defmodule HungTitleLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete(messages, tools, %{})

    @impl true
    def complete(_messages, _tools, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:hung_title_started, SystemsRuntime.Proc.self()}
      )

      SystemsRuntime.Proc.receive(do: (:never -> {:final, "unreachable"}))
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_titles = SystemsRuntime.get_env(:salix_agent, :session_titles)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_media = SystemsRuntime.get_env(:salix_agent, :media_resolver)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.put_env(:salix_agent, :session_titles, true)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      SystemsRuntime.put_env(:salix_agent, :session_titles, prev_titles)
      SystemsRuntime.put_env(:salix_agent, :llm, prev_llm)

      if prev_media,
        do: SystemsRuntime.put_env(:salix_agent, :media_resolver, prev_media),
        else: SystemsRuntime.delete_env(:salix_agent, :media_resolver)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  defp wake_and_settle(agent) do
    Server.wake(agent)
    Server.info(agent)
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp session_name(agent, sid) do
    case SalixAgent.TestSupport.SessionData.read(agent, sid) do
      {:ok, session} -> session.name
      _ -> nil
    end
  end

  test "first round titles the placeholder-named session from the first user message", %{
    agent: a
  } do
    # Turn 1 is the round's reply; turn 2 is the background title call.
    Mock.script([{:final, "sure, working on it"}, {:final, "Quarterly Report Draft"}])
    {:ok, _} = Fleet.ensure_started(a, create: true)

    {:ok, :created} =
      deliver(a, "u1", %{content: "draft the Q2 report", session_id: @session_id})

    {:parked, _owned} = wake_and_settle(a)

    eventually(fn -> session_name(a, @session_id) == "Quarterly Report Draft" end)
  end

  test "final title results with provider and trace metadata are accepted", %{agent: a} do
    defmodule MetadataTitleLLM do
      def complete(messages, tools), do: complete(messages, tools, [])

      def complete(_messages, _tools, _opts) do
        {:final, "Metadata Title",
         %{
           "responses_items" => [
             %{"type" => "compaction", "id" => "cmp_title", "encrypted_content" => "cipher"}
           ]
         }, %{"trace_id" => "trace-title"}}
      end
    end

    # The round's own settlement would start a title job on the shared mock;
    # this test drives the title call directly with the provider's shape.
    SystemsRuntime.put_env(:salix_agent, :session_titles, false)
    Mock.script([{:final, "ok"}])
    {:ok, _} = Fleet.ensure_started(a, create: true)

    {:ok, :created} =
      deliver(a, "u1", %{content: "name this", session_id: @session_id})

    {:parked, _} = wake_and_settle(a)

    SystemsRuntime.put_env(:salix_agent, :llm, MetadataTitleLLM)
    assert :ok = Titles.generate_and_apply(a, @session_id, "name this")
    eventually(fn -> session_name(a, @session_id) == "Metadata Title" end)
  end

  test "if_unnamed apply guard: a user rename wins over a slow title", %{agent: a} do
    Mock.script([{:final, "ok"}, {:final, "Auto Title"}])
    {:ok, _} = Fleet.ensure_started(a, create: true)

    # User renames FIRST (plain session_update without if_unnamed)...
    {:ok, :created} =
      deliver(a, "rename", %{
        kind: "session_update",
        session_id: @session_id,
        name: "My Name Wins"
      })

    {:ok, :created} = deliver(a, "u1", %{content: "hello", session_id: @session_id})
    {:parked, _} = wake_and_settle(a)

    # ...so even after the auto-title delivery lands, the user's name stays.
    SystemsClock.sleep(150)
    Server.wake(a)
    Server.info(a)
    assert session_name(a, @session_id) == "My Name Wins"
  end

  test "uses the template's analyze model when configured", %{agent: a} do
    defmodule AnalyzeResolver do
      def resolve(_agent_id) do
        {:ok,
         %{
           "analyze_config" => %{
             "endpoint" => "https://analyze.example/v1",
             "model" => "tiny-titler"
           }
         }}
      end
    end

    defmodule CapturingLLM do
      def complete(messages, tools), do: complete(messages, tools, [])

      def complete(messages, _tools, opts) do
        SystemsRuntime.Proc.send(:titles_test_runner, {:llm_called, messages, opts})
        {:final, "Captured Title"}
      end
    end

    Process.register(SystemsRuntime.Proc.self(), :titles_test_runner)
    SystemsRuntime.put_env(:salix_agent, :media_resolver, AnalyzeResolver)
    SystemsRuntime.put_env(:salix_agent, :llm, CapturingLLM)

    {:ok, _} = Fleet.ensure_started(a, create: true)

    Titles.generate_and_apply(a, @session_id, "set up CI for the repo", %{
      "billing_account_id" => "ba-title"
    })

    assert_received {:llm_called, messages, opts}
    # The analyze model rode the call (protocol defaulted, willow max_tokens).
    assert opts["model"] == "tiny-titler"
    assert opts["base_url"] == "https://analyze.example/v1"
    assert opts["protocol"] == "chat_completions"
    assert opts["max_tokens"] == 64
    assert opts["entrypoint"] == "title_generation"
    assert opts["actor_type"] == "system"
    assert opts["billing_context"]["billing_account_id"] == "ba-title"

    # Willow's anti-injection system prompt + content template.
    assert [%{role: "system", content: _sys}, %{role: "user", content: user}] = messages
    assert user =~ "<conversation_content>\nset up CI for the repo\n</conversation_content>"
  end
  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
