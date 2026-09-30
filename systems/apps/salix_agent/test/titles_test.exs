defmodule SalixAgent.TitlesTest do
  @moduledoc """
  Auto session titles (willow's `maybeGenerateTitle` port): post-settle
  background generation from the first user message, willow's sanitization
  rules, the `if_unnamed` apply guard (a user rename always wins), the
  template-analyze-model resolution (Salix divergence from willow's global
  summarizer), and placeholder-only retitling.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{Fleet, Server, Titles}
  alias SalixAgent.LLM.Mock

  @session_id "ses1_0000000000000000401"

  defmodule HungTitleLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete(messages, tools, %{})

    @impl true
    def complete(_messages, _tools, _opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:hung_title_started, self()})
      receive do: (:never -> {:final, "unreachable"})
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_titles = Application.get_env(:salix_agent, :session_titles)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_media = Application.get_env(:salix_agent, :media_resolver)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :session_titles, true)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :session_titles, prev_titles)
      Application.put_env(:salix_agent, :llm, prev_llm)

      if prev_media,
        do: Application.put_env(:salix_agent, :media_resolver, prev_media),
        else: Application.delete_env(:salix_agent, :media_resolver)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  defp wake_and_settle(agent) do
    Server.wake(agent)
    Server.info(agent)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end

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

  test "title result is sanitized and the name applies only while placeholder", %{agent: a} do
    Mock.script([
      {:final, "ok"},
      {:final, ~s(Title: "Trip Planning"\nsecond line ignored)}
    ])

    {:ok, _} = Fleet.ensure_started(a, create: true)

    {:ok, :created} =
      deliver(a, "u1", %{content: "plan a trip", session_id: @session_id})

    {:parked, _} = wake_and_settle(a)

    eventually(fn -> session_name(a, @session_id) == "Trip Planning" end)

    # A later cycle never re-titles a named session (no script turn is taken:
    # an exhausted mock would error the round, so reaching :final proves it).
    Mock.script([{:final, "again"}])
    {:ok, :created} = deliver(a, "u2", %{content: "more", session_id: @session_id})
    {:parked, _owned} = wake_and_settle(a)
    assert session_name(a, @session_id) == "Trip Planning"
  end

  test "final title results with provider and trace metadata are accepted", %{agent: a} do
    Mock.script([
      {:final, "ok"},
      {:final, "Metadata Title",
       %{
         "responses_items" => [
           %{"type" => "compaction", "id" => "cmp_title", "encrypted_content" => "cipher"}
         ]
       }, %{"trace_id" => "trace-title"}}
    ])

    {:ok, _} = Fleet.ensure_started(a, create: true)

    {:ok, :created} =
      deliver(a, "u1", %{content: "name this", session_id: @session_id})

    {:parked, _} = wake_and_settle(a)

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
    Process.sleep(150)
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
        send(:titles_test_runner, {:llm_called, messages, opts})
        {:final, "Captured Title"}
      end
    end

    Process.register(self(), :titles_test_runner)
    Application.put_env(:salix_agent, :media_resolver, AnalyzeResolver)
    Application.put_env(:salix_agent, :llm, CapturingLLM)

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

  test "provider errors are dropped without creating a title", %{agent: a} do
    {:error, llm_error} = SalixAgent.LLM.Error.transport("mock", :timeout)
    Mock.script([{:error, llm_error}])

    assert :ok = Titles.generate_and_apply(a, @session_id, "set up CI for the repo", %{})

    {:ok, _} = Fleet.ensure_started(a, create: true)
    {:parked, _owned} = wake_and_settle(a)
    assert session_name(a, @session_id) == nil
  end

  test "a stuck title provider is deduplicated, deadlined, and never occupies core TaskSup", %{
    agent: a
  } do
    previous_timeout = Application.get_env(:salix_agent, :dependency_job_timeout_ms)
    previous_limit = Application.get_env(:salix_agent, :dependency_max_children_per_tenant)
    Application.put_env(:salix_agent, :llm, HungTitleLLM)
    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{llm: 250})
    Application.put_env(:salix_agent, :dependency_max_children_per_tenant, 1)
    :persistent_term.put({HungTitleLLM, :owner}, self())

    on_exit(fn ->
      restore_env(:dependency_job_timeout_ms, previous_timeout)
      restore_env(:dependency_max_children_per_tenant, previous_limit)
      :persistent_term.erase({HungTitleLLM, :owner})
    end)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 1,
          "role" => "user",
          "content" => "title this conversation"
        },
        %{
          "type" => "assistant",
          "session_id" => @session_id,
          "message_id" => 2,
          "content" => "done"
        }
      ])

    baseline = SalixAgent.DependencyRunner.active_count()
    assert :ok = Titles.maybe_generate_async(%{agent_id: a}, @session_id)
    assert_receive {:hung_title_started, dependency_pid}, 1_000
    assert SalixAgent.DependencyRunner.active_count() == baseline + 1

    # A second settled-round hook for the same placeholder session reuses the
    # key instead of spawning another hung provider.
    assert :ok = Titles.maybe_generate_async(%{agent_id: a}, @session_id)
    refute_receive {:hung_title_started, _other}, 50

    parent = self()

    assert {:ok, _pid} =
             Task.Supervisor.start_child(SalixAgent.TaskSup, fn -> send(parent, :core_ran) end)

    assert_receive :core_ran, 500
    refute dependency_pid in Task.Supervisor.children(SalixAgent.TaskSup)
    assert dependency_pid in Task.Supervisor.children(SalixAgent.DependencyTaskSup)

    eventually(fn -> SalixAgent.DependencyRunner.active_count() == baseline end)
    refute Process.alive?(dependency_pid)
    assert session_name(a, @session_id) in [nil, "Default"]
  end

  test "sanitize: willow's rules" do
    assert Titles.sanitize("  Plan the offsite  ") == "Plan the offsite"
    assert Titles.sanitize(~s("Quoted Title")) == "Quoted Title"
    assert Titles.sanitize("Title: With Prefix") == "With Prefix"
    assert Titles.sanitize("标题：中文前缀") == "中文前缀"
    assert Titles.sanitize("\n\nFirst real line\nrest") == "First real line"
    assert Titles.sanitize("“Curly quoted”") == "Curly quoted"
    assert Titles.sanitize(String.duplicate("x", 100)) == String.duplicate("x", 60)
    # Unusable results collapse to "" (skipped by the caller).
    assert Titles.sanitize("") == ""
    assert Titles.sanitize("   \n  ") == ""
    assert Titles.sanitize("Untitled") == ""
    assert Titles.sanitize(~s("Default")) == ""
    assert Titles.sanitize("[LLM error 400]") == ""
    assert Titles.sanitize("[LLM transport error]") == ""
  end

  test "placeholder?/1 matches willow's auto-placeholder set" do
    for name <- ["", "Chat", "Default", "Untitled", nil], do: assert(Titles.placeholder?(name))
    refute Titles.placeholder?("Quarterly Report Draft")
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
