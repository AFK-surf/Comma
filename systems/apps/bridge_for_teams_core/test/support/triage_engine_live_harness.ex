defmodule BridgeForTeams.TriageEngineLiveHarness do
  @moduledoc """
  The six-round driver both real-provider acceptance drives share.

  A "round" is one scenario carried through the whole engine chain exactly once:
  admission → debounce/seal → fence → freeze → the REAL
  `Salix.Bindings.TriageEvaluator` over the REAL `SalixLlm.Provider` → terminal →
  ledger → `SalixIM.Triage.replay/2`. Nothing between admission and the ledger is
  stubbed; the only thing a caller chooses is where the provider's `base_url`
  points — at a real model, or at a loopback that speaks the same wire.

  ## Why the provider is resolved through the agent template

  `SalixWeb.Application` wires the production evaluator port as
  `provider_config: :agent_template`, so a production Triage run never carries
  provider credentials in its port options: the adapter reads the Router agent id
  out of the identity fence, `SalixAgent.LlmResolver.resolve_runtime/1` maps that
  id → agent control record → `template_id` → the template's `provider_config`,
  and `SalixLlm.ProviderConfig` resolves `api_key_env` against the OS
  environment at request time. This harness reproduces that chain rather than
  short-circuiting it, so a live round also proves the composition root's own
  provider resolution reaches a real model — and so no API key is ever written
  into a test file, a fixture, or a durable record.

  ## The one seam the harness keeps

  Production passes `transport_receipt: :single_attempt`, which makes the adapter
  self-declare its request count. This harness passes a closure that computes the
  same receipt AND reports every observed outbound payload to the test process.
  That makes "this round cost exactly one request" an assertion about the
  transport seam rather than intent, including when a human has already answered.

  ## Round isolation

  Every round mints its own Slack connect, its own project, its own twelve
  meetings and its own thread root, so a round can neither reuse another round's
  durable receipts nor inherit its bucket. A failing assertion identifies that
  scenario and aborts the drive; later scenarios are then unexercised.
  """

  import ExUnit.Assertions

  alias BridgeForTeams.TriageEngineFixture, as: Fixture
  alias SalixIM.Triage
  alias SalixIM.Triage.{Bucketing, CanonicalJSON, Ledger, ProductDecision, RunFence}
  alias SalixStore.CasRecord

  @scenario_ids ~w(silence reply fast_path human_answered durable_decision alert_ongoing)
  @product_decision_schemas ~w(comma.triage-product-decision.v1 comma.triage-product-decision.v2)

  @doc "The six scenarios, in the order the acceptance drives run them."
  def scenario_ids, do: @scenario_ids

  @doc "Requires the live model to match the selected product profile before provider preflight."
  def require_live_model!(model, expected_model) do
    unless is_binary(expected_model) and expected_model != "" and model == expected_model do
      raise ArgumentError,
            "set COMMA_TRIAGE_EXPECTED_MODEL to the selected product profile's COMMA_TRIAGE_LIVE_MODEL before live acceptance"
    end

    :ok
  end

  @doc false
  def communication_kind(%{
        "schema" => schema,
        "communication" => %{"kind" => kind}
      })
      when schema in @product_decision_schemas and kind in ["reply", "reaction", "silence"],
      do: kind

  def communication_kind(%{"action" => "react"}), do: "reaction"
  def communication_kind(%{"action" => kind}) when kind in ["reply", "silence"], do: kind
  def communication_kind(_decision), do: nil

  @doc false
  def decision_action(%{
        "schema" => schema,
        "delegations" => [_first | _rest]
      })
      when schema in @product_decision_schemas,
      do: "delegate"

  def decision_action(%{
        "schema" => schema,
        "communication" => %{"kind" => "reaction"}
      })
      when schema in @product_decision_schemas,
      do: "react"

  def decision_action(%{
        "schema" => schema,
        "communication" => %{"kind" => kind}
      })
      when schema in @product_decision_schemas and kind in ["reply", "silence"],
      do: kind

  def decision_action(%{"action" => action}), do: action
  def decision_action(_decision), do: nil

  ## Provider wiring

  @doc """
  The evaluator port every round runs behind: the real adapter, the real
  protocol dispatcher, provider credentials resolved live from the agent
  template, and an observing transport receipt that reports each outbound
  payload to `test_pid`.
  """
  def evaluator_port(test_pid) do
    {Salix.Bindings.TriageEvaluator,
     [
       provider: live_provider(),
       provider_config: :agent_template,
       transport_receipt: fn payload_bytes ->
         send(test_pid, {:llm_request, byte_size(payload_bytes)})
         %{payload_sha256: Fixture.sha256(payload_bytes), request_count: 1}
       end
     ]}
  end

  def live_provider do
    if System.get_env("COMMA_TRIAGE_TRACE_TOOL_CALLS") == "1",
      do: BridgeForTeams.TriageObservedLiveProvider,
      else: SalixLlm.Provider
  end

  @doc """
  A complete, isolated round fixture: a fresh Slack connect and control group, a
  fresh project with three members, a Router and a Worker, a fresh
  twelve-meeting group, and the agent template that names the model this round
  will call.
  """
  def new_round_context!(profile) do
    authority = Fixture.seed_authority!()
    template_id = seed_agent_template!(authority, profile)
    project = Fixture.seed_project!(authority)
    seed_worker!(authority, project, template_id)
    Fixture.seed_meetings!(authority["group_id"])

    %{
      authority: authority,
      template_id: template_id,
      root_ts: Fixture.new_root_ts(),
      project: project
    }
  end

  @doc false
  def seed_worker!(authority, project, template_id \\ nil) do
    template_id = template_id || seed_worker_template!()

    assert {:ok, _} =
             BridgeForTeams.Salix.Erpc.update_tenant_config(
               authority["tenant_id"],
               "agent_defaults",
               %{"worker_template_id" => template_id}
             )

    assert {:ok, worker} =
             BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
               project.id,
               %{
                 "name" => "Investigator",
                 "role" => "worker",
                 "template_id" => template_id
               }
             )

    assert {:ok, %{"revision" => revision}} = SalixAgent.TriageWorker.get(authority["group_id"])

    assert {:ok, _} =
             BridgeForTeams.Salix.Erpc.configure_triage_worker(
               authority["group_id"],
               authority["inbound_agent_id"],
               worker.salix_agent_id,
               revision,
               %{"actor_user_id" => "fixture-admin", "request_id" => Ecto.UUID.generate()}
             )

    worker
  end

  defp seed_worker_template! do
    {:ok, template} =
      SalixAgent.Templates.create(%{
        "name" => "Triage fixture Worker",
        "model" => "mock",
        "provider" => "mock"
      })

    template["template_id"]
  end

  @doc false
  def assignment_decision(schema, source_refs \\ nil) do
    properties = get_in(schema, ["properties", "delegations", "items", "properties"])
    [worker_ref | _] = get_in(properties, ["worker_ref", "enum"])

    source_refs =
      source_refs || Enum.take(get_in(properties, ["source_refs", "items", "enum"]), 1)

    %{
      "schema" => ProductDecision.schema(),
      "assessment" => %{
        "requested_outcome" => "",
        "available_evidence" => "",
        "unread_source_refs" => [],
        "unavailable_input" => ""
      },
      "communication" => %{
        "kind" => "silence",
        "reason" => "worker_pending",
        "explanation" => "The assigned Worker owns the participation decision.",
        "source_refs" => []
      },
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" => [
        %{
          "task" => "Review the frozen Slack batch and decide whether to participate.",
          "worker_ref" => worker_ref,
          "source_refs" => source_refs
        }
      ],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }
  end

  @doc false
  def assert_worker_assignment!(run) do
    decision = run["decision"]

    assert decision["communication"] == %{
             "kind" => "silence",
             "reason" => "worker_pending",
             "explanation" => "The assigned Worker owns the participation decision.",
             "source_refs" => []
           }

    assert decision["companion_reaction"] == nil
    assert decision["context_candidates"] == []
    assert [%{"worker_ref" => worker_ref}] = decision["delegations"]
    snapshot = Jason.decode!(run["input_snapshot"]["canonical_snapshot_bytes"])

    assert Enum.any?(snapshot["team_project_memory"]["facts"], fn fact ->
             fact["kind"] == "available_investigation_worker" and fact["source_ref"] == worker_ref
           end)
  end

  @doc """
  Gives a round's Router agent a real agent control record and a real template
  carrying `provider_config` — the only place this harness ever names a model, a
  base URL, or the NAME of the environment variable holding the key.
  """
  def seed_agent_template!(authority, profile) do
    template_id = "tmpl-triage-live-#{System.unique_integer([:positive])}"

    provider_config =
      %{"protocol" => profile.protocol, "base_url" => profile.base_url}
      |> put_credential(profile)

    provider_config =
      if profile[:reasoning_effort],
        do: Map.put(provider_config, "reasoning_effort", profile.reasoning_effort),
        else: provider_config

    assert {:ok, template} =
             SalixAgent.Templates.create(%{
               "template_id" => template_id,
               "name" => "Triage live acceptance",
               "model" => profile.model,
               # Named rather than inferred. `SalixAgent.Templates` derives the
               # provider label from the base URL or the model when a template
               # omits it, and a loopback base URL matches neither — which the
               # adapter's `valid_resolved_provider?/1` then rejects as an
               # incomplete provider config, several layers away from the cause.
               "provider" => profile.provider,
               "provider_config" => provider_config,
               "max_tokens" => profile.max_tokens,
               "context_tokens" => profile[:context_tokens] || 0
             })

    assert template["template_id"] == template_id

    assert {:ok, _agent} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => authority["group_id"],
                 "template_id" => template_id,
                 "name" => "BFT Router",
                 "role" => "router"
               },
               authority["tenant_id"],
               authority["inbound_agent_id"]
             )

    # The chain the adapter walks on every round, asserted once per round so a
    # broken template surfaces as a fixture error here instead of as an opaque
    # `:invalid_triage_provider_config` six rounds deep.
    assert {:ok, resolved} =
             SalixAgent.LlmResolver.resolve_runtime(authority["inbound_agent_id"])

    assert resolved["model"] == profile.model
    assert resolved["base_url"] == profile.base_url
    assert resolved["protocol"] == profile.protocol

    # Every field the adapter's own `valid_resolved_provider?/1` requires. Left
    # unasserted, a missing one surfaces four layers later as a terminal whose
    # only word for it is `identity_diagnostic_internal_error`.
    assert resolved["provider"] == profile.provider
    assert resolved["api_key"] != "" or resolved["api_key_env"] != ""

    template_id
  end

  defp put_credential(config, %{api_key_env: env}) when is_binary(env) and env != "",
    do: Map.put(config, "api_key_env", env)

  defp put_credential(config, %{api_key: key}) when is_binary(key) and key != "",
    do: Map.put(config, "api_key", key)

  ## Scenarios

  @doc """
  One scenario, bound to a round's own authority and thread root.

  Each returns the Slack thread the loopback reader will answer with, the typed
  receipts to admit, whether the engine is expected to reach the model at all,
  and the pending communication marker required by ordinary intake.
  The assigned Worker makes the later participation decision.
  """
  def scenario("silence", %{authority: authority, root_ts: root_ts}) do
    %{
      id: "silence",
      label: "1 routine discussion assignment",
      expected_communication: "silence",
      fast_path_event_ids: [],
      why: "two humans mid-discussion, no question and no mention",
      authority: authority,
      root_ts: root_ts,
      thread: [
        Fixture.mirrored_message(root_ts, "U_LIN", "我把 Atlas 的重试预算过了一遍，当前配置看起来是合理的"),
        Fixture.mirrored_message(Fixture.ts(2, root_ts), "U_PENG", "嗯，我下午再对一遍监控面板的数字")
      ],
      inputs: [
        {:root, "Ev-silence-1", "我把 Atlas 的重试预算过了一遍，当前配置看起来是合理的"},
        {:reply, "Ev-silence-2", Fixture.ts(2, root_ts), "嗯，我下午再对一遍监控面板的数字",
         [root_ts: root_ts, actor_id: "U_PENG"]}
      ]
    }
  end

  def scenario("reply", %{authority: authority, root_ts: root_ts}) do
    question = "Atlas 登录事故现在谁在跟进？runbook 放在哪里了？"

    %{
      id: "reply",
      label: "2 answerable question assignment",
      expected_communication: "silence",
      fast_path_event_ids: [],
      why: "an unanswered question whose answer is in the frozen meeting facts",
      authority: authority,
      root_ts: root_ts,
      thread: [Fixture.mirrored_message(root_ts, "U_LIN", question)],
      inputs: [{:root, "Ev-reply-1", question}]
    }
  end

  def scenario("slack_permalink", %{authority: authority, root_ts: root_ts}) do
    url = "https://atlas.slack.com/archives/C_ATLAS/p1787019000000001"
    question = "#{url} 这条消息最终批准了怎样的发布步骤和放量条件？"

    %{
      id: "slack_permalink",
      label: "Slack permalink assignment",
      expected_communication: "silence",
      fast_path_event_ids: [],
      why: "the frozen link reaches a Worker before any external source read",
      authority: authority,
      root_ts: root_ts,
      thread: [Fixture.mirrored_message(root_ts, "U_LIN", question)],
      inputs: [{:root, "Ev-slack-link-1", question}],
      linked_message: %{
        "workspace_url" => "https://atlas.slack.com/",
        "ts" => "1787019000.000001",
        "user" => "U_LIN",
        "text" => "Atlas 登录修复只批准灰度 10%，观察 30 分钟且错误率低于 0.5% 后再全量。"
      }
    }
  end

  def scenario("fast_path", %{authority: authority, root_ts: root_ts}) do
    question = "你怎么看这个回滚窗口？"

    %{
      id: "fast_path",
      label: "3 ambient question waits for debounce",
      expected_communication: "silence",
      fast_path_event_ids: [],
      why: "an ambient question waits for the ordinary quiet period before Worker assignment",
      authority: authority,
      root_ts: root_ts,
      engine_opts: [debounce_ms: 5_000, max_wait_ms: 60_000],
      min_seal_ms: 5_000,
      thread: [
        Fixture.mirrored_message(root_ts, "U_LIN", "Atlas 登录事故的回滚窗口还没定下来"),
        Fixture.mirrored_message(Fixture.ts(2, root_ts), "U_PENG", "我倾向放在周五下班之后"),
        Fixture.mirrored_message(Fixture.ts(3, root_ts), "U_LIN", question)
      ],
      inputs: [
        {:root, "Ev-fast-1", "Atlas 登录事故的回滚窗口还没定下来"},
        {:reply, "Ev-fast-2", Fixture.ts(2, root_ts), "我倾向放在周五下班之后",
         [root_ts: root_ts, actor_id: "U_PENG"]},
        {:reply, "Ev-fast-3", Fixture.ts(3, root_ts), question,
         [root_ts: root_ts, actor_id: "U_LIN"]}
      ]
    }
  end

  def scenario("human_answered", %{authority: authority, root_ts: root_ts}) do
    question = "谁在跟进 Atlas 登录事故？"

    %{
      id: "human_answered",
      label: "4 human answered first",
      expected_communication: "silence",
      fast_path_event_ids: [],
      why: "the Worker receives the human answer before deciding whether to participate",
      authority: authority,
      root_ts: root_ts,
      thread: [
        Fixture.mirrored_message(root_ts, "U_LIN", "Atlas 登录事故还需要确认处理人"),
        Fixture.mirrored_message(Fixture.ts(2, root_ts), "U_PENG", "我记得周会里讨论过这件事"),
        Fixture.mirrored_message(Fixture.ts(3, root_ts), "U_LIN", question),
        Fixture.mirrored_message(Fixture.ts(9, root_ts), "U_ADA", "我来跟进，负责人是 Lin。")
      ],
      inputs: [
        {:root, "Ev-answered-1", "Atlas 登录事故还需要确认处理人"},
        {:reply, "Ev-answered-2", Fixture.ts(2, root_ts), "我记得周会里讨论过这件事",
         [root_ts: root_ts, actor_id: "U_PENG"]},
        {:reply, "Ev-answered-3", Fixture.ts(3, root_ts), question,
         [root_ts: root_ts, actor_id: "U_LIN"]}
      ]
    }
  end

  def scenario("alert_ongoing", %{authority: authority, root_ts: root_ts}) do
    alert = "P1: Atlas 服务公网健康检查连续失败，HTTP 503。需要确认影响和恢复情况。"

    %{
      id: "alert_ongoing",
      label: "6 alert remains unresolved",
      expected_communication: "silence",
      fast_path_event_ids: [],
      why: "the alert source's later update explicitly leaves public recovery unconfirmed",
      authority: authority,
      root_ts: root_ts,
      engine_opts: [debounce_ms: 20],
      thread: [
        Fixture.mirrored_agent_message(root_ts, "U_ALERTS", alert),
        Fixture.mirrored_agent_message(
          Fixture.ts(9, root_ts),
          "U_ALERTS",
          "内部探测已恢复，但公网恢复仍未确认；还需要继续检查公网入口。"
        )
      ],
      inputs: [
        {:root, "Ev-alert-ongoing", alert,
         [root_ts: root_ts, actor_kind: "agent", actor_id: "U_ALERTS"]}
      ]
    }
  end

  def scenario("durable_decision", %{authority: authority, root_ts: root_ts}) do
    question = "这条以后就按这个来，帮我们处理一下，可以吗？"
    rule = "我们定个规矩：以后任何回滚之前都必须先 page on-call，并且在纪要里记录一次。"

    %{
      id: "durable_decision",
      label: "5 durable decision assignment",
      expected_communication: "silence",
      fast_path_event_ids: [],
      why: "a discussion that lands a stable team rule plus follow-up work",
      authority: authority,
      root_ts: root_ts,
      thread: [
        Fixture.mirrored_message(root_ts, "U_LIN", rule),
        Fixture.mirrored_message(Fixture.ts(2, root_ts), "U_PENG", "同意，我们从这周开始就这么执行"),
        Fixture.mirrored_message(Fixture.ts(3, root_ts), "U_LIN", question)
      ],
      inputs: [
        {:root, "Ev-durable-1", rule},
        {:reply, "Ev-durable-2", Fixture.ts(2, root_ts), "同意，我们从这周开始就这么执行",
         [root_ts: root_ts, actor_id: "U_PENG"]},
        {:reply, "Ev-durable-3", Fixture.ts(3, root_ts), question,
         [root_ts: root_ts, actor_id: "U_LIN"]}
      ]
    }
  end

  ## Round driver

  @doc """
  Drives one scenario end to end and returns everything the acceptance report
  needs, having already asserted every invariant that does not depend on the
  model's judgment.
  """
  def drive_round!(spec, evaluator_port, opts \\ []) do
    %{authority: authority, root_ts: root_ts} = spec
    namespace = "triage-live-#{spec.id}-#{System.unique_integer([:positive])}"
    attempts = Keyword.get(opts, :attempts, 400)
    owner = self()

    # The harness admits each scenario synchronously. Keep the ordinary window
    # comfortably wider than a real PostgreSQL admission so a root cannot seal
    # before the following fixture receipts arrive. Questions use the same
    # quiet period as other ordinary messages.
    engine_opts =
      [debounce_ms: 5_000, max_wait_ms: 60_000]
      |> Keyword.merge(Map.get(spec, :engine_opts, []))
      |> Keyword.put_new(
        :evaluation_timeout_ms,
        Keyword.get(opts, :evaluation_timeout_ms, 30_000)
      )
      |> Keyword.put(:before_seal_hook, fn _scope_key, _generation ->
        send(owner, {:sealed_at, System.monotonic_time(:millisecond)})
        :ok
      end)

    server = Fixture.start_engine!(namespace, evaluator_port, engine_opts)

    Fixture.put_thread(spec.thread)
    Fixture.put_linked_message(Map.get(spec, :linked_message))

    # Drain anything an earlier round left behind, so this round's request count
    # and Slack surface are this round's alone.
    _ = drain_llm_requests()
    _ = Fixture.collected_source_reads()
    _ = Fixture.collected_slack_calls()

    started_at = System.monotonic_time(:millisecond)

    receipts =
      Enum.map(spec.inputs, fn
        {:root, event_id, text} ->
          Fixture.admit_root!(server, authority, event_id, text, root_ts: root_ts)

        {:root, event_id, text, root_opts} ->
          Fixture.admit_root!(server, authority, event_id, text, root_opts)

        {:reply, event_id, ts, text, reply_opts} ->
          Fixture.admit_reply!(server, authority, event_id, ts, text, reply_opts)
      end)

    # None of these ordinary receipts bypasses the quiet period.
    Enum.zip(spec.inputs, receipts)
    |> Enum.each(fn {input, receipt} ->
      event_id = elem(input, 1)
      fast? = receipt["triage_event"]["fast_path"]

      if event_id in spec.fast_path_event_ids,
        do: assert(fast?, "expected #{event_id} to arm the fast path"),
        else: refute(fast?, "#{event_id} armed the fast path unexpectedly")
    end)

    run = Fixture.await_run!(server, attempts)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    seal_ms = awaited_seal_ms(started_at)
    request_count = length(drain_llm_requests())
    source_reads = Fixture.collected_source_reads()
    slack_calls = Fixture.collected_slack_calls()

    # Measure sealing before the provider response, so model latency cannot
    # hide an early seal caused by a question.
    case Map.get(spec, :min_seal_ms) do
      nil -> :ok
      bound -> assert seal_ms >= bound, "seal took #{seal_ms}ms, expected >= #{bound}ms"
    end

    ## Invariants that hold for every round, whatever the model decided.

    assert run["authoritative"] == true
    assert run["input_snapshot"]["schema"] == "comma.triage-model-input.v3"

    scope = Bucketing.scope_key(hd(receipts))
    assert scope == Fixture.scope(authority, "__channel__")
    fence = load_fence!(namespace, scope, run["generation"])
    assert RunFence.valid_terminal?(fence["terminal"])
    assert fence["terminal"]["status"] == run["status"]
    assert fence["terminal"]["decision"] == run["decision"]

    # The terminal archives the exact admitted receipts in its fence and clears
    # the completed generation from the channel bucket.
    assert {:ok, bucket} = Bucketing.load(namespace, scope)
    assert bucket["open_receipts"] == []
    assert bucket["sealed_generations"] == []
    assert %{"receipts" => sealed} = fence["sealed_generation"]
    assert Enum.map(sealed, & &1["receipt_ref"]) == Enum.map(receipts, & &1["receipt_ref"])

    # Ledger, listing and offline replay all agree on the one authoritative run.
    assert {:ok, ^run} = Ledger.fetch(namespace, run["run_id"])
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])
    assert {:ok, listed} = Ledger.list(namespace)
    assert Enum.filter(listed, &(&1["run_id"] == run["run_id"])) == [run]

    # A runtime with no local state reads back the same durable record.
    fresh = Fixture.start_engine!(namespace, evaluator_port)
    assert Triage.ledger_records(fresh) == [run]
    assert {:ok, ^run} = Triage.replay(fresh, run["run_id"])

    # Zero external effects: the whole chain only read the mirrored channel window and
    # bounded workspace emoji catalog; no agent worker was ever started.
    assert Enum.map(source_reads, &elem(&1, 0)) == ["clickhouse.channel_current"]
    assert slack_calls == Map.get(spec, :expected_slack_calls, ["api/emoji.list"])
    refute SalixAgent.Fleet.running?(authority["inbound_agent_id"])

    # Authorized meeting text keeps its useful links and contact details. The
    # credential and source-authorization regressions remain separate gates.
    ledger_bytes = Jason.encode!(run)
    snapshot_bytes = run["input_snapshot"]["canonical_snapshot_bytes"]

    for literal <- Fixture.raw_meeting_literals() do
      assert snapshot_bytes =~ literal
      assert ledger_bytes =~ literal
    end

    expected_tool = Map.get(spec, :expected_tool)
    checks = proof_checks(run, expected_tool)
    failed = for {name, false} <- checks, do: name

    assert failed == [],
           "proof checks failed for #{spec.id}: #{inspect(failed)}\n" <>
             "status: #{inspect(run["status"])}\n" <>
             "decision: #{inspect(run["decision"])}\n" <>
             "evaluator: #{inspect(run["evaluator"], limit: 20, printable_limit: 800)}"

    assert run["status"] == "evaluated"
    assert request_count == expected_request_count(run["evaluator"], expected_tool)

    assert_worker_assignment!(run)

    %{
      id: spec.id,
      label: spec.label,
      expected_communication: spec.expected_communication,
      why: spec.why,
      status: run["status"],
      decision: run["decision"],
      proof_checks: checks,
      replay: :agrees,
      seal_ms: seal_ms,
      elapsed_ms: elapsed_ms,
      request_count: request_count,
      provider: get_in(run, ["evaluator", "provider"]),
      model: get_in(run, ["evaluator", "model"]),
      run: run,
      namespace: namespace
    }
  end

  # The seal timestamp the engine reported through its own pre-seal hook. Only
  # the FIRST is meaningful: it is the moment this bucket became due.
  defp awaited_seal_ms(started_at) do
    receive do
      {:sealed_at, at} ->
        _later = drain_seal_marks()
        at - started_at
    after
      0 -> nil
    end
  end

  defp drain_seal_marks(acc \\ []) do
    receive do
      {:sealed_at, at} -> drain_seal_marks([at | acc])
    after
      0 -> acc
    end
  end

  ## Proof

  @doc """
  Every hash the durable proof claims, recomputed from the bytes the same record
  carries. Every ordinary scenario must reach a valid Worker assignment,
  including threads where a human has already answered.
  """
  def proof_checks(run, expected_tool \\ nil)

  def proof_checks(
        %{
          "status" => "evaluated",
          "evaluator" => %{"schema" => "comma.triage-worker-assignment.v1"} = proof
        } = run,
        expected_tool
      ) do
    input = run["input_snapshot"]

    [
      {"run_fence.valid_model_proof?", RunFence.valid_model_proof?(proof)},
      {"fixed_assignment",
       SalixIM.Triage.WorkerSelection.assignment(input) == {:ok, run["decision"]}},
      {"canonical_snapshot_sha256",
       proof["canonical_snapshot_sha256"] == input["canonical_snapshot_sha256"]},
      {"source_refs_sha256", proof["source_refs_sha256"] == input["source_refs_sha256"]},
      {"zero_model_requests", proof["request_count"] == 0},
      {"no_claimed_read_exchange", is_nil(expected_tool)},
      {"review_artifact_sha256", review_artifact_sha256_agrees?(proof)},
      {"decision_sources_in_closure", decision_sources_in_closure?(run)}
    ]
  end

  def proof_checks(%{"status" => "evaluated"} = run, expected_tool) do
    proof = run["evaluator"]
    input = run["input_snapshot"]
    payload_sha256 = CanonicalJSON.sha256(proof["provider_payload_bytes"])
    artifact = proof["review_artifact"] || %{}

    [
      {"run_fence.valid_model_proof?", RunFence.valid_model_proof?(proof)},
      {"schema",
       proof["schema"] in ~w(comma.triage-model-proof.v1 comma.triage-model-proof.v2 comma.triage-model-proof.v3)},
      {"provider_sha256", proof["provider_sha256"] == CanonicalJSON.sha256(proof["provider"])},
      {"model_sha256", proof["model_sha256"] == CanonicalJSON.sha256(proof["model"])},
      {"provider_payload_sha256", proof["provider_payload_sha256"] == payload_sha256},
      {"observer_payload_sha256", proof["observer_payload_sha256"] == payload_sha256},
      {"transport_payload_sha256", proof["transport_payload_sha256"] == payload_sha256},
      {"canonical_snapshot_sha256",
       proof["canonical_snapshot_sha256"] == input["canonical_snapshot_sha256"]},
      {"source_refs_sha256", proof["source_refs_sha256"] == input["source_refs_sha256"]},
      {"payload_carries_frozen_snapshot",
       payload_carries_snapshot?(proof["provider_payload_bytes"], input)},
      {"review_artifact_sha256", review_artifact_sha256_agrees?(proof)},
      {"review_delivery_mode", review_delivery_mode_agrees?(artifact, run["decision"])},
      {"review_executed_actions_empty", artifact["executed_actions"] == []},
      {"review_readback_zero_effect", review_readback_agrees?(artifact, run["decision"])},
      {"bounded_requests",
       proof["request_count"] == expected_request_count(proof, expected_tool)},
      {"no_retry", proof["retry"] == false},
      {"exact_read_exchange", exact_read_exchange?(proof, expected_tool)},
      {"decision_sources_in_closure", decision_sources_in_closure?(run)}
    ]
  end

  def proof_checks(_run, _expected_tool), do: [{"unexpected_status", false}]

  defp expected_request_count(%{"schema" => "comma.triage-worker-assignment.v1"}, nil), do: 0

  defp expected_request_count(%{"schema" => "comma.triage-model-proof.v3"}, expected_tool),
    do: if(expected_tool, do: 3, else: 2)

  defp expected_request_count(_proof, expected_tool), do: if(expected_tool, do: 2, else: 1)

  defp exact_read_exchange?(%{"schema" => "comma.triage-model-proof.v3"} = proof, nil),
    do:
      proof["tool_receipts"] == [] and proof["tool_names"] == [] and proof["tool_call_count"] == 0

  defp exact_read_exchange?(proof, nil), do: not Map.has_key?(proof, "tool_receipts")

  defp exact_read_exchange?(proof, tool) do
    proof["tool_names"] == [tool] and proof["tool_call_count"] == 1 and
      match?([_], proof["tool_receipts"]) and
      Enum.all?(proof["tool_receipts"], &RunFence.valid_read_tool_receipt?/1)
  end

  defp payload_carries_snapshot?(payload_bytes, input) when is_binary(payload_bytes) do
    case Jason.decode(payload_bytes) do
      {:ok, payload} ->
        RunFence.payload_has_exact_message_content?(payload, input["canonical_snapshot_bytes"])

      _invalid ->
        false
    end
  end

  defp payload_carries_snapshot?(_payload_bytes, _input), do: false

  defp review_artifact_sha256_agrees?(proof) do
    with %{} = artifact <- proof["review_artifact"],
         {:ok, bytes} <- CanonicalJSON.encode(artifact) do
      CanonicalJSON.sha256(bytes) == proof["review_artifact_sha256"]
    else
      _invalid -> false
    end
  end

  defp review_delivery_mode_agrees?(
         %{"delivery_mode" => "authoritative_obligations"},
         %{"schema" => schema}
       ),
       do: schema in @product_decision_schemas

  defp review_delivery_mode_agrees?(%{"delivery_mode" => "review"}, %{"action" => _action}),
    do: true

  defp review_delivery_mode_agrees?(_artifact, _decision), do: false

  defp review_readback_agrees?(artifact, %{"schema" => schema})
       when schema in @product_decision_schemas do
    artifact["readback"] == %{
      "status" => "authoritative_obligations_pending",
      "slack_writes" => 0,
      "worker_starts" => 0,
      "context_writes" => 0
    }
  end

  defp review_readback_agrees?(artifact, %{"action" => _action}) do
    artifact["readback"] == %{
      "status" => "review_only_not_sent",
      "slack_writes" => 0,
      "worker_starts" => 0,
      "memory_writes" => 0
    }
  end

  defp review_readback_agrees?(_artifact, _decision), do: false

  defp decision_sources_in_closure?(run) do
    closure = MapSet.new(run["input_snapshot"]["source_refs"] || [])

    refs =
      case run["decision"] do
        %{"schema" => schema} = decision
        when schema in @product_decision_schemas ->
          ProductDecision.source_refs(decision)

        decision ->
          decision["source_refs"] || []
      end

    MapSet.subset?(MapSet.new(refs), closure)
  end

  @doc "Drains and returns the byte size of every observed outbound payload."
  def drain_llm_requests(acc \\ []) do
    receive do
      {:llm_request, size} -> drain_llm_requests([size | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The sealed fence record a run was cut from."
  def load_fence!(namespace, scope, generation) do
    assert {:ok, fence} =
             CasRecord.get(
               SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
             )

    fence
  end

  ## Report

  @doc """
  The per-round report the acceptance drives print verbatim: what the model
  decided, whether every proof hash agreed, whether replay agreed, how long the
  round took, and how many provider requests it cost.
  """
  def report(title, rounds) do
    header =
      "\n=== #{title} ===\n" <>
        pad("round", 32) <>
        pad("status", 26) <>
        pad("action", 10) <>
        pad("proof", 9) <>
        pad("replay", 9) <> pad("seal ms", 9) <> pad("total ms", 10) <> "reqs\n"

    body =
      Enum.map_join(rounds, "\n", fn round ->
        pad(round.label, 32) <>
          pad(round.status, 26) <>
          pad(to_string(decision_action(round.decision)), 10) <>
          pad(proof_verdict(round.proof_checks), 9) <>
          pad(to_string(round.replay), 9) <>
          pad(to_string(round.seal_ms), 9) <>
          pad(to_string(round.elapsed_ms), 10) <> to_string(round.request_count)
      end)

    detail =
      Enum.map_join(rounds, "\n", fn round ->
        "\n-- #{round.label} (#{round.why}) --\n" <>
          "provider/model: #{round.provider || "-"} / #{round.model || "-"}\n" <>
          "decision: #{inspect(round.decision, pretty: true, limit: :infinity)}"
      end)

    totals =
      "\n\ntotal provider requests: #{Enum.sum(Enum.map(rounds, & &1.request_count))}" <>
        "\ntotal wall clock ms: #{Enum.sum(Enum.map(rounds, & &1.elapsed_ms))}\n"

    header <> body <> "\n" <> detail <> totals
  end

  defp pad(value, width), do: String.pad_trailing(value, width)

  defp proof_verdict(checks) do
    total = length(checks)
    green = Enum.count(checks, fn {_name, ok?} -> ok? end)
    if green == total, do: "#{green}/#{total}", else: "FAILED #{green}/#{total}"
  end
end

defmodule BridgeForTeams.TriageObservedLiveProvider do
  def complete(messages, tools, opts) do
    started = System.monotonic_time(:millisecond)
    # This optional provider is loaded by the release-composition harness,
    # not a compile dependency of the product core.
    result = apply(SalixLlm.Provider, :complete, [messages, tools, opts])

    IO.puts(
      Jason.encode!(%{
        "triage_live_request" => %{
          "model" => opts["model"],
          "reasoning_effort" => opts["reasoning_effort"],
          "max_tokens" => opts["max_tokens"],
          "elapsed_ms" => System.monotonic_time(:millisecond) - started,
          "usage" => usage(result),
          "output" => output_summary(result)
        }
      })
    )

    if is_tuple(result) and tuple_size(result) >= 3 and elem(result, 0) == :assistant do
      calls = Enum.map(elem(result, 2), &Map.take(&1, [:name, :args, "name", "args"]))
      IO.puts(Jason.encode!(%{"triage_live_read_calls" => calls}))
    end

    result
  end

  defp usage({:final, _content, meta}), do: reported_usage(meta)
  defp usage({:final, _content, _provider_meta, meta}), do: reported_usage(meta)
  defp usage({:assistant, _content, _calls, _provider_meta, meta}), do: reported_usage(meta)
  defp usage(_result), do: nil

  # Diagnose invalid/truncated output without printing source content, private
  # reasoning, credentials, or the provider's unrestricted metadata.
  defp output_summary(result)
       when is_tuple(result) and tuple_size(result) >= 2 and elem(result, 0) == :final do
    content = elem(result, 1)

    if is_binary(content) do
      %{
        "kind" => "final",
        "bytes" => byte_size(content),
        "valid_json" => match?({:ok, _}, Jason.decode(content))
      }
    else
      %{"kind" => "final", "content_type" => "non_text"}
    end
  end

  defp output_summary(result) when is_tuple(result),
    do: %{"kind" => to_string(elem(result, 0))}

  defp output_summary(_result), do: %{"kind" => "unknown"}

  defp reported_usage(%{"usage" => usage}) when is_map(usage) do
    Map.take(
      usage,
      ~w(prompt_tokens completion_tokens total_tokens cache_read_input_tokens cache_write_input_tokens)
    )
  end

  defp reported_usage(_meta), do: nil
end
