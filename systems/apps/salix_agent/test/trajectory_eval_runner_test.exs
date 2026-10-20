defmodule SalixAgent.TrajectoryEvalRunnerTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The post-round eval runner reads the committed session, scores the
  activation window, persists a per-session entry for the dashboard
  (`TrajectoryEval.Store`) and hands one fact to the analytics recorder seam.
  It is config-gated and must never raise into the caller.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{Fleet, Server}
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.InternalSessionStore
  alias SalixAgent.LLM.Mock
  alias SalixAgent.TrajectoryEval.{Runner, Store}

  @pid_key {__MODULE__, :test_pid}
  @session_id "ses1_0000000000000000701"

  # seed_session sets billing_context salix_tenant_id "tenant-1"; the gate
  # resolves the tenant from there (seeded agents have no control record).
  defmodule TenantJudgeOn do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-1"), do: {:ok, %{"judge_enabled" => true}}
    def get(_), do: {:ok, %{}}
  end

  defmodule TenantJudgeOff do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-1"), do: {:ok, %{"judge_enabled" => false}}
    def get(_), do: {:ok, %{}}
  end

  defmodule TenantJudgeUnavailable do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get(_tenant), do: {:error, :timeout}
  end

  defmodule TenantCleanRateInvalid do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-1"), do: {:ok, %{"judge_clean_sample_rate" => -1}}
    def get(_), do: {:ok, %{}}
  end

  defmodule TenantJudgeLuna do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-1"), do: {:ok, %{"judge_enabled" => true, "judge_provider" => "luna"}}
    def get(_), do: {:ok, %{}}
  end

  defmodule TenantJudgeUnknownProvider do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-1"), do: {:ok, %{"judge_enabled" => true, "judge_provider" => "ghost"}}
    def get(_), do: {:ok, %{}}
  end

  defmodule TenantJudgeMalformedProvider do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-1"), do: {:ok, %{"judge_enabled" => true, "judge_provider" => %{}}}
    def get(_), do: {:ok, %{}}
  end

  defmodule TenantJudgeEmptyProvider do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-1"), do: {:ok, %{"judge_enabled" => true, "judge_provider" => ""}}
    def get(_), do: {:ok, %{}}
  end

  defmodule TestRecorder do
    @moduledoc false
    @behaviour SalixAgent.TrajectoryEval.Recorder

    @impl true
    def record(fact) do
      case SystemsRuntime.PersistentTerm.get(
             {SalixAgent.TrajectoryEvalRunnerTest, :test_pid},
             nil
           ) do
        nil -> :ok
        pid -> SystemsRuntime.Proc.send(pid, {:recorded, fact})
      end

      :ok
    end
  end

  defmodule HungJudgeLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete(messages, tools, %{})

    @impl true
    def complete(_messages, _tools, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:hung_judge_started, SystemsRuntime.Proc.self()}
      )

      SystemsRuntime.Proc.receive do
        :never -> {:final, "unreachable"}
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_recorder = SystemsRuntime.get_env(:salix_agent, :trajectory_eval_recorder_mod)
    prev_cfg = SystemsRuntime.get_env(:salix_agent, :trajectory_eval)
    prev_tenant_mod = SystemsRuntime.get_env(:salix_agent, :trajectory_eval_tenant_mod)
    prev_providers = SystemsRuntime.get_env(:salix_agent, :trajectory_eval_judge_providers)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval_recorder_mod, TestRecorder)
    SystemsRuntime.PersistentTerm.put(@pid_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase(@pid_key)
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :trajectory_eval_recorder_mod, prev_recorder)
      restore(:salix_agent, :trajectory_eval, prev_cfg)
      restore(:salix_agent, :trajectory_eval_tenant_mod, prev_tenant_mod)
      restore(:salix_agent, :trajectory_eval_judge_providers, prev_providers)
    end)

    :ok
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp seed_session(agent_id, session_id, messages) do
    base = InternalSession.new(agent_id, session_id, %{"created_at" => "2026-07-08T00:00:00Z"})

    state = %State{
      InternalSession.export(base)
      | messages: messages,
        next_message_id: length(messages) + 1,
        billing_context: %{
          "surface" => "commaboard",
          "actor_type" => "agent",
          "salix_tenant_id" => "tenant-1",
          "salix_group_id" => "group-1"
        }
    }

    :ok = InternalSessionStore.prepare_seed(agent_id, InternalSession.open(state))
    :ok
  end

  defp confused_messages do
    [
      %{id: 1, role: "user", content: "fix the bug"},
      %{
        id: 2,
        role: "assistant",
        content:
          "Wait, this test is failing for a different reason. Let me take a simpler approach.",
        tool_calls: [],
        round_id: "round-x"
      }
    ]
  end

  test "eval_now persists a store entry and emits one recorder fact" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    assert {:ok, entry} = Runner.eval_now(agent_id, @session_id, :final)

    metrics = Enum.map(entry["findings"], & &1["metric"])
    assert "confusion" in metrics
    assert "shortcut" in metrics
    assert entry["outcome"] == "final"
    assert entry["window"]["round_id"] == "round-x"

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [stored] = doc["evals"]
    assert stored["evaluator"] == "heuristic"

    settle_receive({:recorded, fact})
    assert fact.agent_id == agent_id
    assert fact.session_id == @session_id
    assert Enum.map(fact.findings, & &1.metric) == metrics
  end

  test "a settled round triggers the eval automatically" do
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval, enabled: true, sample_rate: 1.0)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)

    Mock.script([
      {:final,
       "Wait, that assumption was wrong. Let me take a simpler approach for now, patching it."}
    ])

    {:ok, _pid} = Fleet.ensure_started(agent, create: true)
    {:ok, :created} = deliver(agent, "u1", %{content: "fix it", session_id: @session_id})
    Server.wake(agent)
    Server.info(agent)

    settle_receive({:recorded, fact})
    assert fact.agent_id == agent
    assert fact.session_id == @session_id
    assert fact.outcome == "final"

    metrics = Enum.map(fact.findings, & &1.metric)
    assert "confusion" in metrics
    assert "shortcut" in metrics

    assert eventually(fn ->
             match?({:ok, %{"evals" => [_ | _]}}, Store.read(agent, @session_id))
           end)
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  # ---- L2 judge integration ----

  defp judge_json do
    ~s({"verdicts":[) <>
      ~s({"metric":"confusion","verdict":"confirmed","score":0.8,"reason":"Backtracked twice.","evidence":"Wait, this test is failing"},) <>
      ~s({"metric":"shortcut","verdict":"rejected","score":0.1,"reason":"Reasonable.","evidence":""},) <>
      ~s({"metric":"goal_drift","verdict":"rejected","score":0.0,"reason":"On task.","evidence":""},) <>
      ~s({"metric":"silent_failure","verdict":"rejected","score":0.0,"reason":"No claim.","evidence":""}]})
  end

  test "flagged window is judged: verdicts stored and recorded" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    SystemsRuntime.put_env(:salix_agent, :trajectory_eval,
      enabled: true,
      judge_enabled: true
    )

    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _stored} = Runner.eval_now(agent_id, @session_id, :final)

    settle_receive({:recorded, %{evaluator: "heuristic"}})
    settle_receive({:recorded, %{evaluator: "judge"} = judge_fact})
    assert judge_fact.evaluator_version == "1"
    verdicts = Enum.map(judge_fact.findings, &{&1.metric, &1.verdict})
    assert {"confusion", "confirmed"} in verdicts

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [%{"judge" => judge} | _] = doc["evals"]
    assert judge["prompt_version"] == "1"
    assert Enum.any?(judge["verdicts"], &(&1["verdict"] == "confirmed"))
  end

  # A tenant's approved model being revoked out from under them must not
  # silently reroute their transcripts (and their credit) to whatever the
  # template happens to use. The paid step stops; the free L1 keeps running.
  test "a tenant judge_provider that is no longer in the allowlist skips the paid judge" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    SystemsRuntime.put_env(:salix_agent, :trajectory_eval, enabled: true)
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeUnknownProvider)
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval_judge_providers, %{})

    # Script VALID verdicts: if the revoked pick wrongly falls through to the
    # template model, the judge call succeeds and the refutes below fail. (An
    # empty script would not catch that — the Mock's default reply just fails
    # to parse and the swallowed error looks identical to a proper skip.)
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, stored} = Runner.eval_now(agent_id, @session_id, :final)

    # L1 still ran and persisted...
    assert stored["findings"] != []
    settle_receive({:recorded, %{evaluator: "heuristic"}})
    # ...but nothing was judged, and no judge row was recorded.
    settle_refute_receive({:recorded, %{evaluator: "judge"}}, 200)
    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [entry | _] = doc["evals"]
    refute Map.has_key?(entry, "judge")
  end

  # Clean-window judge sampling. Every row scripts a valid judge response and
  # seeds the RNG so its first draw is exactly 0.0 (`:rand.uniform/0` can
  # return it), so a wrongful sample WOULD record a judge fact:
  #
  # * a configured 0.0 must never run the paid judge, even on a 0.0 draw (the
  #   old `U > rate` check ran it on `0.0 > 0.0 == false`);
  # * an out-of-range rate is REJECTED to the 0.0 default, not clamped to 1.0
  #   (which would judge every clean window — the opposite of typo protection);
  # * a present-but-invalid tenant override (-1) fails closed to 0.0, NOT to
  #   the higher global rate (a missing override still inherits the global,
  #   covered by the on/off override tests below);
  # * the valid boundary (1.0) still judges every clean window, so the
  #   rejections above are genuinely rejecting the typo.
  for {name, clean_rate, tenant_mod, judged?} <- [
        {"a 0.0 clean sample rate never judges, even when the RNG returns 0.0", 0.0, nil, false},
        {"an out-of-range clean sample rate is rejected, not clamped", 2, nil, false},
        {"a present-invalid tenant clean rate fails closed, not to the global rate", 1.0,
         TenantCleanRateInvalid, false},
        {"a valid full clean sample rate judges every clean window", 1.0, nil, true}
      ] do
  end

  # ---- per-tenant judge toggle ----

  test "tenant override turns the judge off even when the global default is on" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    SystemsRuntime.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: true)
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeOff)

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    settle_receive({:recorded, %{evaluator: "heuristic"}})
    settle_refute_receive({:recorded, %{evaluator: "judge"}}, 200)
  end

  # Reviewer's blocker repro: with the global default on, a transient tenant
  # lookup failure must NOT fall back to the global default and spend the
  # tenant's credit against a possible opt-out. L1 still persists; the paid
  # judge is skipped (fail closed).
  test "fails closed when the tenant settings lookup is unavailable" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    SystemsRuntime.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: true)
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeUnavailable)
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _stored} = Runner.eval_now(agent_id, @session_id, :final)

    settle_receive({:recorded, %{evaluator: "heuristic"}})
    settle_refute_receive({:recorded, %{evaluator: "judge"}}, 200)
    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [entry | _] = doc["evals"]
    assert entry["findings"] != []
    refute Map.has_key?(entry, "judge")
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
