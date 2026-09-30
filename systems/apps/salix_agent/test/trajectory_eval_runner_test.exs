defmodule SalixAgent.TrajectoryEvalRunnerTest do
  @moduledoc """
  The post-round eval runner reads the committed session, scores the
  activation window, persists a per-session entry for the dashboard
  (`TrajectoryEval.Store`) and hands one fact to the analytics recorder seam.
  It is config-gated and must never raise into the caller.
  """
  use ExUnit.Case, async: false

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
      case :persistent_term.get({SalixAgent.TrajectoryEvalRunnerTest, :test_pid}, nil) do
        nil -> :ok
        pid -> send(pid, {:recorded, fact})
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
      send(:persistent_term.get({__MODULE__, :owner}), {:hung_judge_started, self()})

      receive do
        :never -> {:final, "unreachable"}
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_recorder = Application.get_env(:salix_agent, :trajectory_eval_recorder_mod)
    prev_cfg = Application.get_env(:salix_agent, :trajectory_eval)
    prev_tenant_mod = Application.get_env(:salix_agent, :trajectory_eval_tenant_mod)
    prev_providers = Application.get_env(:salix_agent, :trajectory_eval_judge_providers)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :trajectory_eval_recorder_mod, TestRecorder)
    :persistent_term.put(@pid_key, self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      :persistent_term.erase(@pid_key)
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :trajectory_eval_recorder_mod, prev_recorder)
      restore(:salix_agent, :trajectory_eval, prev_cfg)
      restore(:salix_agent, :trajectory_eval_tenant_mod, prev_tenant_mod)
      restore(:salix_agent, :trajectory_eval_judge_providers, prev_providers)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

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

    assert_receive {:recorded, fact}
    assert fact.agent_id == agent_id
    assert fact.session_id == @session_id
    assert Enum.map(fact.findings, & &1.metric) == metrics
  end

  test "store keeps newest entries first" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, {:error, :boom})

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [newest, _older] = doc["evals"]
    assert newest["outcome"] == "error"
  end

  test "same-signature re-evals merge into one entry and emit one recorder fact" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    assert {:ok, first} = Runner.eval_now(agent_id, @session_id, :final)
    refute Map.has_key?(first, "repeats")
    assert_receive {:recorded, _fact}

    assert {:ok, second} = Runner.eval_now(agent_id, @session_id, :final)
    assert second["repeats"] == 2
    assert second["first_evaluated_at"] == first["evaluated_at"]
    refute_receive {:recorded, _fact}, 200

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [only] = doc["evals"]
    assert only["repeats"] == 2
  end

  test "a changed signature appends a new entry and emits a new fact" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, _}

    # A different outcome changes the signature: appended and recorded anew.
    assert {:ok, entry} = Runner.eval_now(agent_id, @session_id, {:error, :boom})
    refute Map.has_key?(entry, "repeats")
    assert_receive {:recorded, fact}
    assert fact.outcome == "error"

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert length(doc["evals"]) == 2
  end

  test "eval_now on a missing session returns an error without raising" do
    assert {:error, :not_found} = Runner.eval_now("no-such-agent", @session_id, :final)
  end

  test "maybe_eval_async skips when disabled or outcome is mid-flight" do
    Application.put_env(:salix_agent, :trajectory_eval, enabled: false)
    assert :skip = Runner.maybe_eval_async(%{agent_id: "a"}, @session_id, :final)

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true)
    assert :skip = Runner.maybe_eval_async(%{agent_id: "a"}, @session_id, :round_boundary)
    assert :skip = Runner.maybe_eval_async(%{agent_id: "a"}, @session_id, {:llm_pending, %{}})
  end

  test "maybe_eval_async runs the eval end-to-end when enabled" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())
    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, sample_rate: 1.0)

    assert :ok = Runner.maybe_eval_async(%{agent_id: agent_id}, @session_id, :final)

    assert_receive {:recorded, fact}, 2_000
    assert fact.session_id == @session_id
  end

  test "a stuck production judge leaves core TaskSup and is killed by the dependency deadline" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    previous_timeout = Application.get_env(:salix_agent, :dependency_job_timeout_ms)
    Application.put_env(:salix_agent, :llm, HungJudgeLLM)
    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{llm: 100})
    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: true)
    :persistent_term.put({HungJudgeLLM, :owner}, self())

    on_exit(fn ->
      restore(:salix_agent, :dependency_job_timeout_ms, previous_timeout)
      :persistent_term.erase({HungJudgeLLM, :owner})
    end)

    baseline = SalixAgent.DependencyRunner.active_count()
    assert :ok = Runner.maybe_eval_async(%{agent_id: agent_id}, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}, 1_000
    assert_receive {:hung_judge_started, dependency_pid}, 1_000

    refute dependency_pid in Task.Supervisor.children(SalixAgent.TaskSup)
    assert dependency_pid in Task.Supervisor.children(SalixAgent.DependencyTaskSup)
    assert SalixAgent.DependencyRunner.active_count() == baseline + 1

    parent = self()

    assert {:ok, _pid} =
             Task.Supervisor.start_child(SalixAgent.TaskSup, fn -> send(parent, :core_ran) end)

    assert_receive :core_ran, 500

    assert eventually(fn -> SalixAgent.DependencyRunner.active_count() == baseline end)
    refute Process.alive?(dependency_pid)
  end

  test "a settled round triggers the eval automatically" do
    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, sample_rate: 1.0)

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

    assert_receive {:recorded, fact}, 5_000
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

  defp eventually(fun, retries \\ 200) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

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

    Application.put_env(:salix_agent, :trajectory_eval,
      enabled: true,
      judge_enabled: true
    )

    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _stored} = Runner.eval_now(agent_id, @session_id, :final)

    assert_receive {:recorded, %{evaluator: "heuristic"}}
    assert_receive {:recorded, %{evaluator: "judge"} = judge_fact}

    assert judge_fact.evaluator_version == "1"
    verdicts = Enum.map(judge_fact.findings, &{&1.metric, &1.verdict})
    assert {"confusion", "confirmed"} in verdicts

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [%{"judge" => judge} | _] = doc["evals"]
    assert judge["prompt_version"] == "1"
    assert Enum.any?(judge["verdicts"], &(&1["verdict"] == "confirmed"))
  end

  test "the tenant's judge_provider picks the allowlist model" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true)
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeLuna)

    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{
      "luna" => %{
        label: "GPT-5.6 Luna",
        protocol: "chat_completions",
        base_url: "https://gw.example/v1",
        model: "luna-x",
        api_key: "k"
      }
    })

    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "judge"}}

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [%{"judge" => %{"model" => "luna-x"}} | _] = doc["evals"]
  end

  # A tenant's approved model being revoked out from under them must not
  # silently reroute their transcripts (and their credit) to whatever the
  # template happens to use. The paid step stops; the free L1 keeps running.
  test "a tenant judge_provider that is no longer in the allowlist skips the paid judge" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true)
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeUnknownProvider)
    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{})

    # Script VALID verdicts: if the revoked pick wrongly falls through to the
    # template model, the judge call succeeds and the refutes below fail. (An
    # empty script would not catch that — the Mock's default reply just fails
    # to parse and the swallowed error looks identical to a proper skip.)
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, stored} = Runner.eval_now(agent_id, @session_id, :final)

    # L1 still ran and persisted...
    assert stored["findings"] != []
    assert_receive {:recorded, %{evaluator: "heuristic"}}

    # ...but nothing was judged, and no judge row was recorded.
    refute_receive {:recorded, %{evaluator: "judge"}}, 200
    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [entry | _] = doc["evals"]
    refute Map.has_key?(entry, "judge")
  end

  # Same rule for an explicit deployment default: config naming a model the
  # allowlist no longer defines is a revoked selection, not an absent one.
  test "an explicit global judge_provider outside the allowlist skips the paid judge" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval,
      enabled: true,
      judge_enabled: true,
      judge_provider: "ghost"
    )

    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{})

    # Valid verdicts scripted so an unintended fallback records a judge fact.
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}
    refute_receive {:recorded, %{evaluator: "judge"}}, 200
  end

  # A malformed persisted value (a JSON object where a name belongs) is not a
  # name, so it is a broken selection — same skip, no crash.
  test "a malformed tenant judge_provider skips the paid judge without crashing" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true)
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeMalformedProvider)

    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"}
    })

    # Valid verdicts scripted so an unintended fallback records a judge fact.
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}
    refute_receive {:recorded, %{evaluator: "judge"}}, 200
  end

  # A persisted "" is the dashboard's spelling of "use the deployment default"
  # — it must read as absent (inherit the valid global), not as a broken pick.
  test "an empty-string tenant judge_provider falls through to the global default" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_provider: "haiku")
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeEmptyProvider)

    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "haiku-x", api_key: "k"}
    })

    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "judge"}}

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [%{"judge" => %{"model" => "haiku-x"}} | _] = doc["evals"]
  end

  # Nothing selected anywhere is the documented default: inherit the agent
  # template's analyze model, exactly as before the allowlist existed.
  test "no selection anywhere still inherits the template analyze model" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: true)
    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{})

    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "judge"}}
  end

  test "debounced repeats do not re-judge and keep attached verdicts" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval,
      enabled: true,
      judge_enabled: true
    )

    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}
    assert_receive {:recorded, %{evaluator: "judge"}}

    # Same signature again: no new recorder fact, no LLM turn consumed, and
    # the merged entry still carries the judge verdicts.
    assert {:ok, stored} = Runner.eval_now(agent_id, @session_id, :final)
    assert stored["repeats"] == 2
    refute_receive {:recorded, _}, 200

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [%{"repeats" => 2, "judge" => %{"verdicts" => _}} | _] = doc["evals"]
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
    test name do
      agent_id = SalixAgent.TestSupport.new_agent_id()

      :ok =
        seed_session(agent_id, @session_id, [
          %{id: 1, role: "user", content: "hello"},
          %{id: 2, role: "assistant", content: "Done.", tool_calls: [], round_id: "round-c"}
        ])

      Application.put_env(:salix_agent, :trajectory_eval,
        enabled: true,
        judge_enabled: true,
        judge_clean_sample_rate: unquote(clean_rate)
      )

      Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, unquote(tenant_mod))

      SalixAgent.LLM.Mock.script([{:final, judge_json()}])
      :rand.seed({:exsss, [1 | 0]})
      assert :rand.uniform() == 0.0
      :rand.seed({:exsss, [1 | 0]})

      assert {:ok, stored} = Runner.eval_now(agent_id, @session_id, :final)
      assert stored["findings"] == []
      assert_receive {:recorded, %{evaluator: "heuristic"}}

      if unquote(judged?) do
        assert_receive {:recorded, %{evaluator: "judge"}}
      else
        refute_receive {:recorded, %{evaluator: "judge"}}, 200
        assert {:ok, doc} = Store.read(agent_id, @session_id)
        assert [entry | _] = doc["evals"]
        refute Map.has_key?(entry, "judge")
      end
    end
  end

  # The free L1 gate's changed behavior: an invalid sample_rate keeps L1 running
  # (rejected to the 1.0 default), rather than being clamped to 0.0 and skipped.
  # maybe_eval_async runs the sampling check in this process, so a positive RNG
  # state makes the pre-fix clamp(-1)=0.0 gate deterministically skip.
  test "an invalid L1 sample_rate keeps L1 running, not disabled" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, sample_rate: -1)
    :rand.seed({:exsss, [1 | 1]})
    assert :rand.uniform() > 0.0
    :rand.seed({:exsss, [1 | 1]})

    assert :ok = Runner.maybe_eval_async(%{agent_id: agent_id}, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}, 2_000
  end

  test "judge failure leaves the stored L1 entry intact" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval,
      enabled: true,
      judge_enabled: true
    )

    SalixAgent.LLM.Mock.script([{:final, "sorry, not json"}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}
    refute_receive {:recorded, %{evaluator: "judge"}}, 200

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [entry | _] = doc["evals"]
    assert entry["findings"] != []
    refute Map.has_key?(entry, "judge")
  end

  # ---- per-tenant judge toggle ----

  test "tenant override turns the judge on even when the global default is off" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: false)
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeOn)
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}
    assert_receive {:recorded, %{evaluator: "judge"}}
  end

  test "tenant override turns the judge off even when the global default is on" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: true)
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeOff)

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}
    refute_receive {:recorded, %{evaluator: "judge"}}, 200
  end

  # Reviewer's blocker repro: with the global default on, a transient tenant
  # lookup failure must NOT fall back to the global default and spend the
  # tenant's credit against a possible opt-out. L1 still persists; the paid
  # judge is skipped (fail closed).
  test "fails closed when the tenant settings lookup is unavailable" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    :ok = seed_session(agent_id, @session_id, confused_messages())

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: true)
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeUnavailable)
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _stored} = Runner.eval_now(agent_id, @session_id, :final)

    assert_receive {:recorded, %{evaluator: "heuristic"}}
    refute_receive {:recorded, %{evaluator: "judge"}}, 200

    assert {:ok, doc} = Store.read(agent_id, @session_id)
    assert [entry | _] = doc["evals"]
    assert entry["findings"] != []
    refute Map.has_key?(entry, "judge")
  end

  # A configured seam plus an unresolvable tenant (no control record, no tenant
  # in the billing context) is treated as unavailable, not as the global default.
  test "fails closed when the tenant cannot be resolved" do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    base = InternalSession.new(agent_id, @session_id, %{"created_at" => "2026-07-08T00:00:00Z"})

    state = %State{
      InternalSession.export(base)
      | messages: confused_messages(),
        next_message_id: length(confused_messages()) + 1,
        billing_context: %{"surface" => "commaboard"}
    }

    :ok = InternalSessionStore.prepare_seed(agent_id, InternalSession.open(state))

    Application.put_env(:salix_agent, :trajectory_eval, enabled: true, judge_enabled: true)
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, TenantJudgeOn)
    SalixAgent.LLM.Mock.script([{:final, judge_json()}])

    assert {:ok, _} = Runner.eval_now(agent_id, @session_id, :final)
    assert_receive {:recorded, %{evaluator: "heuristic"}}
    refute_receive {:recorded, %{evaluator: "judge"}}, 200
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
