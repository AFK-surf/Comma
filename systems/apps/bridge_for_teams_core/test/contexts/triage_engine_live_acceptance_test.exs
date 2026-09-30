defmodule BridgeForTeams.TriageEngineLiveAcceptanceTest do
  @moduledoc """
  Native Triage assignments and captured-input evaluator replays with a live provider profile.

  Ordinary intake freezes source context and assigns a dedicated Worker without
  a decision-model request. These rounds check durable assignment and replay,
  and stop before Worker execution. Captured-input replays call the real model
  through `SalixLlm.Provider`; they check evaluator rejection and input fidelity.

  Both paths use an in-BEAM ClickHouse corpus and a loopback Slack boundary.
  They do not import sources or write to Slack. Provider credentials are resolved
  through `SalixAgent.LlmResolver.resolve_runtime/1` from the selected template.

  ## Running it

  Excluded by default — `test/test_helper.exs` excludes `:live_llm`, so a normal
  suite never opens a socket to a model provider. To run:

      COMMA_TRIAGE_EXPECTED_MODEL=<current product model> \\
        COMMA_TRIAGE_LIVE_MODEL=<the same confirmed model> \\
        mix test apps/bridge_for_teams_core/test/contexts/triage_engine_live_acceptance_test.exs \\
        --include live_llm --only live_llm

  The key and explicit matching expected-model selection are required. Location
  filters can override ExUnit tag exclusions, so the profile guard runs before
  preflight even when a developer selects one test by line number.

  For product acceptance, choose the existing product's complete provider profile
  (model, protocol, endpoint and credential) before running. The defaults below
  are not evidence that an unrelated shell key belongs to the product. Keep
  credentials in the test process environment, never in fixtures or reports.

    * `COMMA_TRIAGE_LIVE_API_KEY_ENV` — the NAME of the env var holding the key
      (default `OPENAI_API_KEY`). The key itself is never read into a fixture,
      a template record or a durable proof; only its variable name travels, and
      `SalixLlm.ProviderConfig` resolves it at request time.
    * `COMMA_TRIAGE_LIVE_BASE_URL` — default `https://api.openai.com/v1`
    * `COMMA_TRIAGE_LIVE_MODEL` — default `gpt-5.6-luna`, the adapter's own default
    * `COMMA_TRIAGE_LIVE_PROTOCOL` — default `responses`, the ONE protocol on which
      the adapter's strict `json_schema` response format is structurally
      enforced rather than advisory.

  ## Cost

  Ordinary intake rounds make no decision-model requests. The suite retains one
  provider preflight and real requests for captured-input evaluator replays.
  Observe those requests when reporting cost; a passing assignment round does
  not prove that the Worker model ran.

  ## Scope

  Native rounds assert one pending Worker assignment, a valid terminal, frozen
  source bytes, durable proof, ledger agreement and offline replay. They stop
  before Worker execution. They do not assert reply quality or Slack delivery.
  Captured inputs without Worker rosters are fidelity controls. The current
  evaluator must reject them. They are not executable product acceptance cases.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.TriageEngineFixture, as: Fixture
  alias BridgeForTeams.TriageEngineLiveHarness, as: Harness
  alias SalixStore.Ids

  @moduletag :live_llm
  # Live evaluator replays retain the engine evaluation timeout.
  @moduletag timeout: 900_000
  @moduletag sandbox_ownership_timeout: 900_000

  @key_env_var "COMMA_TRIAGE_LIVE_API_KEY_ENV"
  @default_key_env "OPENAI_API_KEY"
  @default_base_url "https://api.openai.com/v1"
  @default_model "gpt-5.6-luna"
  @default_protocol "responses"
  @default_provider "openai"

  setup do
    SalixStore.S3.Fake.reset()
    unless Process.whereis(Ids), do: start_supervised!(Ids)

    :ok = Fixture.install_clickhouse_reader!(self())
    :ok = install_agent_llm_resolver!()

    %{profile: profile!()}
  end

  test "six scenarios retain replayable assignments with a live provider profile", ctx do
    %{profile: profile} = ctx

    # Check the live profile separately from the zero-request intake rounds.
    :ok = preflight!(profile)

    evaluator_port = Harness.evaluator_port(self())

    rounds =
      Enum.map(Harness.scenario_ids(), fn id ->
        spec = Harness.scenario(id, Harness.new_round_context!(profile))

        Harness.drive_round!(spec, evaluator_port,
          attempts: 8_000,
          evaluation_timeout_ms: 180_000
        )
      end)

    IO.puts(
      Harness.report(
        "intake assignments — live profile #{profile.model} @ #{profile.base_url}",
        rounds
      )
    )

    ## Cross-round invariants.

    assert length(rounds) == 6

    assert Enum.map(rounds, & &1.request_count) == [0, 0, 0, 0, 0, 0]

    # Ordinary intake carries an assignment proof without a model claim.
    for round <- rounds, round.status == "evaluated" do
      assert round.model == nil
      assert Enum.all?(round.proof_checks, fn {_name, ok?} -> ok? end)
      assert Harness.decision_action(round.decision) == "delegate"
    end

    for round <- rounds, is_binary(round.expected_communication) do
      assert Harness.communication_kind(round.decision) == round.expected_communication,
             "#{round.id} expected #{round.expected_communication}: #{round.why}; " <>
               "decision=#{inspect(round.decision)}"
    end

    assert Enum.sum(Enum.map(rounds, & &1.request_count)) == 0
  end

  ## Provider profile

  @tag :slack_permalink_assignment
  test "the real model assigns the frozen Slack permalink to a Worker", %{profile: profile} do
    spec = Harness.scenario("slack_permalink", Harness.new_round_context!(profile))

    round =
      Harness.drive_round!(spec, Harness.evaluator_port(self()),
        attempts: 8_000,
        evaluation_timeout_ms: 180_000
      )

    Harness.assert_worker_assignment!(round.run)
    IO.puts(Harness.report("live Slack permalink assignment — #{profile.model}", [round]))
  end

  @tag :online_case_fidelity
  test "the current evaluator rejects captured inputs without Worker rosters", %{profile: profile} do
    alias BridgeForTeams.TriageOnlineCaseFixture, as: Online

    for id <- ["bare_forwarded_reply", "token_report_no_tools"] do
      assert {:error, :invalid_triage_decision} = Online.replay(id, profile)
      refute_receive {:slack_link_read, _}
      refute_receive {:slack_reply_posted, _}
    end
  end

  defp profile! do
    model = System.get_env("COMMA_TRIAGE_LIVE_MODEL") || @default_model
    :ok = Harness.require_live_model!(model, System.get_env("COMMA_TRIAGE_EXPECTED_MODEL"))
    key_env = System.get_env(@key_env_var) || @default_key_env

    if System.get_env(key_env) in [nil, ""] do
      flunk("""
      #{key_env} is not set, and :live_llm tests must never fabricate a decision.

      Set the key (or point #{@key_env_var} at the variable that holds it) and
      rerun with --include live_llm.
      """)
    end

    %{
      protocol: System.get_env("COMMA_TRIAGE_LIVE_PROTOCOL") || @default_protocol,
      base_url: System.get_env("COMMA_TRIAGE_LIVE_BASE_URL") || @default_base_url,
      model: model,
      provider: System.get_env("COMMA_TRIAGE_LIVE_PROVIDER") || @default_provider,
      api_key_env: key_env,
      max_tokens: String.to_integer(System.get_env("COMMA_TRIAGE_LIVE_MAX_TOKENS") || "2000"),
      context_tokens:
        String.to_integer(System.get_env("COMMA_TRIAGE_LIVE_CONTEXT_TOKENS") || "0"),
      reasoning_effort:
        case System.get_env("COMMA_TRIAGE_LIVE_REASONING_EFFORT") do
          value when value in [nil, ""] -> nil
          value -> value
        end
    }
  end

  for {id, source_text, source_ts} <- [
        {"personal_codex", "我禁止 codex 用 computer use 和 in app browser 操作任何非 localhost 的页面",
         "1787811795.711469"},
        {"cost_estimate", "现在 bft staging bot 每天烧一两百刀这样 :doge:", "1788404837.144179"},
        {"implicit_plan", "明天我再问一下发布进度。", nil},
        {"confirmed_reminder", "好的，明天提醒我问一下发布进度。", nil},
        {"team_person_conflict", "团队已确定：合并前必须有回归测试。我个人偏好先写实现，这不是团队决定。请确认这次合并前应该按哪个要求执行？", nil}
      ] do
    @tag :triage_scope_behavior
    @tag live_scope_case: id
    test "current intake assigns scope and consent evidence: #{id}", %{profile: profile} do
      id = unquote(id)
      text = unquote(source_text)
      context = Harness.new_round_context!(profile)
      root = unquote(source_ts) || context.root_ts

      spec = %{
        id: id,
        label: id,
        why:
          "Local source replay; first two texts are captured Slack statements, other texts are synthetic scope or consent cases. No online effects.",
        expected_communication: "silence",
        fast_path_event_ids: [],
        authority: context.authority,
        root_ts: root,
        thread: [Fixture.mirrored_message(root, "U_LIN", text)],
        inputs: [{:root, "Ev-scope-#{id}", text}]
      }

      round =
        Harness.drive_round!(spec, Harness.evaluator_port(self()),
          attempts: 8000,
          evaluation_timeout_ms: 180_000
        )

      IO.puts(Harness.report("scope and consent: #{id}", [round]))
      Harness.assert_worker_assignment!(round.run)
      snapshot = Jason.decode!(round.run["input_snapshot"]["canonical_snapshot_bytes"])
      assert Enum.any?(snapshot["slack_context"]["messages"], &(&1["text"] == text))
    end
  end

  @tag :triage_scope_behavior
  @tag live_scope_case: "old_cost_retrieval"
  test "an older cost estimate reaches the frozen Worker assignment as historical evidence",
       %{profile: profile} do
    context = Harness.new_round_context!(profile)
    old_id = "cost-estimate-#{System.unique_integer([:positive])}"
    source_ref = "slack://T_ATLAS/C_ATLAS/1788404837.144179/1788404837.144179"

    # Canonical stored-state fixture from the captured 2026-09-03 statement.
    # The SQL read, BFT freeze, real model request, terminal, and replay are real.
    for index <- 0..21 do
      entry_id = if index == 0, do: old_id, else: "#{old_id}-unrelated-#{index}"
      subject = if index == 0, do: "bft staging bot daily cost", else: "unrelated room #{index}"

      value =
        if index == 0,
          do: "2026-09-03 Heyang 口头粗估：bft staging bot 每天约 100 至 200 美元。不是核实账单，也不是当前费用。",
          else: "Meeting room reservation"

      payload = %{
        "schema" => "comma.triage-context-entry.v1",
        "entry_id" => entry_id,
        "kind" => "project_fact",
        "subject" => subject,
        "value" => value,
        "confidence" => "explicit",
        "knowledge_scope" => "project",
        "scope_owner" => %{"kind" => "project", "id" => context.project.id},
        "source_refs" => [source_ref],
        "source_attribution" => [
          %{
            "source_ref" => source_ref,
            "actor_id" => "U_HEYANG",
            "message_ts" => "1788404837.144179"
          }
        ]
      }

      SalixStore.Repo.query!(
        """
        INSERT INTO triage_context_entries
          (entry_id, project_id, agent_id, kind, subject_key, value_key, evidence_key, state, payload, updated_at)
        VALUES ($1, $2, $3, 'project_fact', $4, $5, $6, 'active', $7,
          statement_timestamp() - ($8::bigint * interval '1 minute'))
        """,
        [
          entry_id,
          context.project.id,
          "scope-fixture-agent",
          Fixture.sha256(subject),
          Fixture.sha256(value),
          Fixture.sha256(source_ref),
          payload,
          22 - index
        ]
      )
    end

    assert {:ok, latest} =
             SalixStore.TriageProductRuntime.list_active_context(context.project.id, limit: 20)

    refute Enum.any?(latest, &(&1.entry_id == old_id))

    root = "#{System.system_time(:second)}.000001"
    question = "bft staging bot 目前每天实际花多少钱？之前有没有费用记录？"

    spec = %{
      id: "old_cost_retrieval",
      label: "old cost retrieval",
      why:
        "Stored historical estimate, 21 newer unrelated records, no billing source, no online writes.",
      expected_communication: "silence",
      fast_path_event_ids: [],
      authority: context.authority,
      root_ts: root,
      thread: [Fixture.mirrored_message(root, "U_LIN", question)],
      inputs: [{:root, "Ev-old-cost", question}]
    }

    round =
      Harness.drive_round!(spec, Harness.evaluator_port(self()),
        attempts: 8000,
        evaluation_timeout_ms: 180_000
      )

    IO.puts(Harness.report("old estimate retrieval", [round]))
    Harness.assert_worker_assignment!(round.run)
    assert round.run["input_snapshot"]["canonical_snapshot_bytes"] =~ "100 至 200 美元"
  end

  @tag :current_source_fidelity
  test "current actor projection does not supply a missing Worker roster", %{profile: profile} do
    alias BridgeForTeams.TriageOnlineCaseFixture, as: Online

    assert {:error, :invalid_triage_decision} =
             Online.replay("token_report_no_tools", profile, source_projection: :current)

    refute_receive {:slack_link_read, _}
    refute_receive {:slack_reply_posted, _}
  end

  # Use the same transport as the captured-input evaluator replays.
  defp preflight!(profile) do
    opts = %{
      "protocol" => profile.protocol,
      "base_url" => profile.base_url,
      "api_key_env" => profile.api_key_env,
      "model" => profile.model,
      "max_tokens" => 16
    }

    # Include this existing request in cost observations as well as the
    # evaluated requests; otherwise a full-suite total silently misses one.
    case BridgeForTeams.TriageObservedLiveProvider.complete(
           [%{role: "user", content: "ping"}],
           [],
           opts
         ) do
      {:final, _text} ->
        :ok

      {:final, _text, _meta} ->
        :ok

      {:final, _text, _provider_meta, _trace_meta} ->
        :ok

      other ->
        flunk("""
        The configured provider refused a small preflight request, so no live round can run.

        protocol:  #{profile.protocol}
        base_url:  #{profile.base_url}
        model:     #{profile.model}
        key from:  $#{profile.api_key_env} (value never printed)

        provider returned: #{inspect(other, limit: :infinity, printable_limit: 4_000)}
        """)
    end
  end

  # `Salix.App.configure/0` installs this resolver in production. Asserting it
  # here keeps a suite that ran with a different resolver from silently
  # resolving the round's provider config somewhere else.
  defp install_agent_llm_resolver! do
    previous = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm_resolver, Salix.Bindings.AgentLlmResolver)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_agent, :llm_resolver),
        else: Application.put_env(:salix_agent, :llm_resolver, previous)
    end)

    :ok
  end
end

defmodule BridgeForTeams.TriageEngineLiveHarnessWireTest do
  @moduledoc """
  The live harness's own transport contract, proved with no network.

  This runs the SAME six rounds through the SAME driver as the live drive —
  real `Salix.Bindings.TriageEvaluator`, real `SalixLlm.Provider`, real agent
  template, real `SalixAgent.LlmResolver.resolve_runtime/1`, real HTTP, real
  OpenAI Responses request encoding and response parsing — with the template's
  `base_url` pointed at a loopback Bandit plug that speaks that wire instead of
  at a model provider.

  It exists because a live round is expensive and slow, and because a harness
  bug and a model disagreement look identical from the outside. Everything this
  file can prove without a model is proved here: that the adapter's strict
  response format reaches the wire in the shape the Responses API defines, that
  a decision decoded off that wire survives the whole proof lattice, that the
  frozen snapshot really is the request body's user content, and that all six
  scenarios reach evaluated terminals, without certifying model judgment.

  What it cannot prove — and does not claim — is that a real model returns a
  decision the lattice accepts. That is what the `:live_llm` module above is
  for.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.TriageEngineFixture, as: Fixture
  alias BridgeForTeams.TriageEngineLiveHarness, as: Harness
  alias SalixStore.{Ids, Repo}

  @owner_env_key :triage_live_wire_owner
  @action_env_key :triage_live_wire_action

  # A loopback OpenAI Responses endpoint. It answers the one method the protocol
  # client posts to, records every request body, and builds its decision out of
  # the strict `json_schema` the adapter attached — so, exactly like a compliant
  # model, it can only name sources this run actually froze.
  defmodule ResponsesLoopback do
    @moduledoc false

    alias SalixIM.Triage.ProductDecision

    def init(opts), do: opts

    def call(conn, _opts) do
      owner = Application.fetch_env!(:bridge_for_teams_core, :triage_live_wire_owner)
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 32_000_000)
      request = Jason.decode!(body)
      send(owner, {:wire_request, Enum.join(conn.path_info, "/"), request})

      response = %{
        "id" => "resp_loopback",
        "object" => "response",
        "status" => "completed",
        "model" => request["model"],
        "output" => output(request),
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    defp output(request) do
      action = Application.get_env(:bridge_for_teams_core, :triage_live_wire_action, "reply")

      if action in ["slack_permalink", "online_bare_link"] and
           match?([_ | _], request["tools"]) do
        snapshot =
          request["input"]
          |> Enum.find(&(&1["role"] == "user"))
          |> Map.fetch!("content")
          |> Jason.decode!()

        [link_ref] = get_in(snapshot, ["slack_context", "decision_target", "link_refs"])

        [
          %{
            "type" => "function_call",
            "id" => "fc_slack_link",
            "call_id" => "slack-link-read-1",
            "name" => "call",
            "status" => "completed",
            "arguments" =>
              Jason.encode!(%{
                "tool" => "triage.slack_read_permalink",
                "params" => %{"link_ref" => link_ref}
              })
          }
        ]
      else
        [
          %{
            "type" => "message",
            "id" => "msg_loopback",
            "role" => "assistant",
            "status" => "completed",
            "content" => [
              %{
                "type" => "output_text",
                "text" => Jason.encode!(decision(request)),
                "annotations" => []
              }
            ]
          }
        ]
      end
    end

    defp decision(request) do
      schema = get_in(request, ["text", "format", "schema"])

      case get_in(request, ["text", "format", "name"]) do
        "comma_triage_product_decision_v2" -> product_decision(schema, request)
        "comma_triage_decision_v1" -> legacy_decision(schema)
      end
    end

    defp product_decision(schema, request) do
      pending_reason =
        get_in(schema, ["properties", "communication", "properties", "reason", "enum"])

      if pending_reason == ["worker_pending"] do
        snapshot =
          request["input"]
          |> Enum.find(&(&1["role"] == "user"))
          |> Map.fetch!("content")
          |> Jason.decode!()

        source_ref =
          snapshot["slack_context"]["messages"] |> List.last() |> Map.fetch!("source_ref")

        decision = Harness.assignment_decision(schema, [source_ref])

        if Application.get_env(:bridge_for_teams_core, :triage_live_wire_action) ==
             "forged_source" do
          put_in(decision, ["delegations", Access.at(0), "source_refs"], [
            "meeting://run/m999-never-frozen"
          ])
        else
          decision
        end
      else
        historical_product_decision(schema, request)
      end
    end

    defp historical_product_decision(schema, request) do
      source_refs =
        get_in(schema, [
          "properties",
          "communication",
          "anyOf",
          Access.at(0),
          "properties",
          "source_refs",
          "items",
          "enum"
        ]) || []

      action = Application.get_env(:bridge_for_teams_core, :triage_live_wire_action, "reply")

      base = %{
        "schema" => ProductDecision.schema(),
        "communication" => %{
          "kind" => "silence",
          "reason" => "no_actionable_request",
          "source_refs" => []
        },
        "companion_reaction" => nil,
        "context_candidates" => [],
        "delegations" => [],
        "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
      }

      case action do
        "online_token_report" ->
          BridgeForTeams.TriageOnlineCaseFixture.fetch!("token_report_no_tools")[
            "historical_decision"
          ]

        "slack_permalink" ->
          # The scripted model is deliberately unable to answer from the
          # scenario definition: the answer must arrive through real tool I/O.
          output = Enum.find(request["input"], &(&1["type"] == "function_call_output"))
          source = output |> Map.fetch!("output") |> Jason.decode!()
          [%{"text" => text}] = source["messages"]

          put_in(base, ["communication"], %{
            "kind" => "reply",
            "text" => "链接中的发布结论：" <> text,
            "source_refs" => [decision_target_source_ref(request, source_refs)]
          })

        "reply" ->
          put_in(base, ["communication"], %{
            "kind" => "reply",
            "text" => "The frozen context names who owns the login follow-up.",
            "source_refs" => sources_for(action, source_refs)
          })

        "delegate" ->
          put_in(base, ["delegations"], [
            %{
              "task" => "Write the rollback paging rule into the runbook.",
              "source_refs" => sources_for(action, source_refs)
            }
          ])

        "react" ->
          put_in(base, ["communication"], %{
            "kind" => "reaction",
            "emoji" => "eyes",
            # A reaction is executable only against the exact latest message,
            # not merely any member of the frozen source closure. Read the
            # projected target from the same bound snapshot the provider saw.
            "source_refs" => [decision_target_source_ref(request, source_refs)]
          })

        # A non-compliant provider: a well-formed decision naming a source this
        # run never froze. The strict schema's enum would have stopped a
        # compliant one, which is exactly why the engine may not rely on it.
        "forged_source" ->
          put_in(base, ["communication"], %{
            "kind" => "reply",
            "text" => "Per the runbook I was never shown.",
            "source_refs" => ["meeting://run/m999-never-frozen"]
          })

        _silence ->
          base
      end
    end

    defp legacy_decision(schema) do
      source_refs = get_in(schema, ["properties", "source_refs", "items", "enum"]) || []
      action = Application.get_env(:bridge_for_teams_core, :triage_live_wire_action, "reply")

      base = %{
        "action" => action,
        "text" => nil,
        "reaction" => nil,
        "task" => nil,
        "fact" => nil,
        "source_refs" => sources_for(action, source_refs),
        "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
      }

      case action do
        "reply" ->
          %{base | "text" => "The frozen context names who owns the login follow-up."}

        "delegate" ->
          %{base | "task" => "Write the rollback paging rule into the runbook."}

        "react" ->
          %{base | "reaction" => "eyes"}

        "forged_source" ->
          %{
            base
            | "action" => "reply",
              "text" => "Per the runbook I was never shown.",
              "source_refs" => ["meeting://run/m999-never-frozen"]
          }

        _silence ->
          base
      end
    end

    defp sources_for("silence", _refs), do: []
    defp sources_for(_action, []), do: []
    defp sources_for(_action, [first | _rest]), do: [first]

    defp decision_target_source_ref(request, source_refs) do
      target_source_ref =
        request
        |> Map.fetch!("input")
        |> Enum.find(&(&1["role"] == "user"))
        |> Map.fetch!("content")
        |> Jason.decode!()
        |> get_in(["slack_context", "decision_target", "source_ref"])

      if target_source_ref in source_refs,
        do: target_source_ref,
        else: raise("projected reaction target is absent from the provider source closure")
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    unless Process.whereis(Ids), do: start_supervised!(Ids)

    :ok = Fixture.install_clickhouse_reader!(self())
    :ok = install_agent_llm_resolver!()

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: ResponsesLoopback, port: port, startup_log: false}
      end)

    Application.put_env(:bridge_for_teams_core, @owner_env_key, self())
    Application.put_env(:bridge_for_teams_core, @action_env_key, "reply")

    on_exit(fn ->
      Application.delete_env(:bridge_for_teams_core, @owner_env_key)
      Application.delete_env(:bridge_for_teams_core, @action_env_key)
    end)

    profile = %{
      protocol: "responses",
      base_url: "http://127.0.0.1:#{port}/v1",
      model: "triage-wire-contract-model",
      provider: "openai",
      api_key: "loopback-only-not-a-credential",
      max_tokens: 65_536
    }

    %{profile: profile}
  end

  test "the six intake rounds settle with Worker assignments and no decision request", ctx do
    %{profile: profile} = ctx
    evaluator_port = Harness.evaluator_port(self())

    rounds =
      Enum.map(Harness.scenario_ids(), fn id ->
        Application.put_env(:bridge_for_teams_core, @action_env_key, "assignment")
        spec = Harness.scenario(id, Harness.new_round_context!(profile))
        Harness.drive_round!(spec, evaluator_port)
      end)

    IO.puts(Harness.report("harness wire contract (loopback Responses endpoint)", rounds))

    assert Enum.map(rounds, & &1.id) == Harness.scenario_ids()
    assert Enum.map(rounds, & &1.request_count) == [0, 0, 0, 0, 0, 0]

    assert Enum.map(rounds, & &1.expected_communication) == List.duplicate("silence", 6)

    for round <- rounds, is_binary(round.expected_communication) do
      assert Harness.communication_kind(round.decision) == round.expected_communication
    end

    assert Enum.all?(rounds, &(&1.status == "evaluated"))

    # Each assignment survives the engine and durable proof unchanged.
    assert Enum.map(rounds, &Harness.decision_action(&1.decision)) ==
             List.duplicate("delegate", 6)

    for round <- rounds, round.status == "evaluated" do
      assert round.model == nil
      assert Enum.all?(round.proof_checks, fn {_name, ok?} -> ok? end)
    end

    assert drain_wire_requests() == []
  end

  test "live acceptance accepts a matching product model and rejects unpinned or mismatched profiles" do
    assert :ok = Harness.require_live_model!("gpt-5.6-luna", "gpt-5.6-luna")
    assert :ok = Harness.require_live_model!("openai/gpt-6-astra", "openai/gpt-6-astra")

    for {model, expected} <- [
          {"gpt-5.6-luna", nil},
          {"gpt-5.6-luna", "other"},
          {"", ""}
        ] do
      assert_raise ArgumentError, fn -> Harness.require_live_model!(model, expected) end
    end
  end

  test "a human file-share question stays human through source read, freeze and Worker handoff",
       %{
         profile: profile
       } do
    Application.put_env(:bridge_for_teams_core, @action_env_key, "reply")

    spec =
      Harness.scenario("reply", Harness.new_round_context!(profile))
      |> Map.update!(:thread, fn [message] -> [Map.put(message, "subtype", "file_share")] end)

    round = Harness.drive_round!(spec, Harness.evaluator_port(self()), attempts: 1_200)
    assert Enum.all?(round.proof_checks, fn {_name, ok?} -> ok? end)
    assert drain_wire_requests() == []
    input = round.run["input_snapshot"]["canonical_snapshot_bytes"]
    snapshot = Jason.decode!(input)
    assert [%{"actor_kind" => "human"}] = snapshot["events"]
    assert [%{"actor_kind" => "human"}] = snapshot["slack_context"]["messages"]
    assert input == round.run["input_snapshot"]["canonical_snapshot_bytes"]
    refute_receive {:slack_reply_posted, _}
  end

  test "captured bare-link input stays exact while the current evaluator rejects its absent roster",
       %{
         profile: profile
       } do
    alias BridgeForTeams.TriageOnlineCaseFixture, as: Online
    Application.put_env(:bridge_for_teams_core, @action_env_key, "online_bare_link")

    assert {:error, :invalid_triage_decision} = Online.replay("bare_forwarded_reply", profile)

    [{_, first}] = drain_wire_requests()
    [input] = for %{"role" => "user", "content" => content} <- first["input"], do: content
    assert input == Online.model_input("bare_forwarded_reply")["canonical_snapshot_bytes"]
    snapshot = Jason.decode!(input)
    assert [%{"text" => "<@link:l001|@link:l001>"}] = snapshot["slack_context"]["messages"]
    assert [%{"fast_path" => false, "actor_kind" => "human"}] = snapshot["events"]
    assert length(snapshot["team_project_memory"]["facts"]) == 20
    assert length(snapshot["team_project_memory"]["members"]) == 1
    assert input =~ "不希望 router 因此启动 bot"
    refute input =~ "发布步骤"
    refute input =~ "IMG_4242.MOV"
    assert first["max_output_tokens"] == 16_384
    assert first["reasoning"]["effort"] == "medium"
    assert first["tools"] in [nil, []]

    assert get_in(first, [
             "text",
             "format",
             "schema",
             "properties",
             "delegations",
             "items",
             "properties",
             "worker_ref",
             "enum"
           ]) == ["unavailable"]

    refute_receive {:slack_link_read, _}
    refute_receive {:slack_reply_posted, _}
  end

  test "captured token input is rejected without leaking later answers", %{
    profile: profile
  } do
    alias BridgeForTeams.TriageOnlineCaseFixture, as: Online
    Application.put_env(:bridge_for_teams_core, @action_env_key, "online_token_report")

    assert {:error, :invalid_triage_decision} = Online.replay("token_report_no_tools", profile)
    [{_, body}] = drain_wire_requests()
    [input] = for %{"role" => "user", "content" => content} <- body["input"], do: content
    assert input == Online.model_input("token_report_no_tools")["canonical_snapshot_bytes"]
    snapshot = Jason.decode!(input)

    assert [%{"actor_kind" => "system", "text" => "orion meet bot 的 salix token 怎么被注销了"}] =
             snapshot["slack_context"]["messages"]

    assert snapshot["slack_context"]["links"] == []
    assert body["tools"] in [nil, []]
    assert length(snapshot["team_project_memory"]["facts"]) == 20
    refute input =~ "k8s"
    refute input =~ "1478"
    refute input =~ "image.png"
    refute_receive {:slack_link_read, _}
    refute_receive {:slack_reply_posted, _}
  end

  test "current source replay changes only the actor derived by the real reader", %{
    profile: profile
  } do
    alias BridgeForTeams.TriageOnlineCaseFixture, as: Online
    Application.put_env(:bridge_for_teams_core, @action_env_key, "online_token_report")

    assert {:error, :invalid_triage_decision} =
             Online.replay("token_report_no_tools", profile, source_projection: :current)

    [{_, body}] = drain_wire_requests()
    [input] = for %{"role" => "user", "content" => content} <- body["input"], do: content
    snapshot = Jason.decode!(input)
    historical = Online.fetch!("token_report_no_tools")["snapshot"]

    expected =
      put_in(historical, ["slack_context", "messages", Access.at(0), "actor_kind"], "human")

    assert snapshot == expected
    assert [%{"actor_kind" => "system"}] = historical["slack_context"]["messages"]
    assert body["tools"] in [nil, []]
    refute_receive {:slack_reply_posted, _}
  end

  test "a separate Slack permalink stays frozen in a pending Worker handoff", %{profile: profile} do
    Application.put_env(:bridge_for_teams_core, @action_env_key, "slack_permalink")
    context = Harness.new_round_context!(profile)
    spec = Harness.scenario("slack_permalink", context)
    round = Harness.drive_round!(spec, Harness.evaluator_port(self()))

    assert round.status == "evaluated"
    assert round.request_count == 0
    Harness.assert_worker_assignment!(round.run)
    assert drain_wire_requests() == []
    snapshot = round.run["input_snapshot"]["canonical_snapshot_bytes"] |> Jason.decode!()

    assert [%{"link_ref" => "link://run/l001", "source_refs" => [source_ref]}] =
             snapshot["slack_context"]["links"]

    assert source_ref in hd(round.decision["delegations"])["source_refs"]
    url = "https://atlas.slack.com/archives/C_ATLAS/p1787019000000001"
    refute Jason.encode!(snapshot) =~ "0.5%"
    refute Jason.encode!(snapshot) =~ "xoxb-"

    assert %{rows: [["pending", payload]]} =
             Repo.query!(
               "SELECT state, payload FROM triage_product_obligations WHERE run_id = $1",
               [round.run["run_id"]]
             )

    assert [%{"worker_ref" => "comma-agent://" <> worker_id}] = payload["delegations"]

    assert Enum.any?(BridgeForTeams.Agents.list_agents(context.project.id), fn agent ->
             agent.role == "worker" and agent.salix_agent_id == worker_id
           end)

    assert Jason.encode!(payload) =~ url
    refute Jason.encode!(payload) =~ "0.5%"
    refute_receive {:slack_link_read, _}
    refute_receive {:slack_reply_posted, _}
    refute SalixAgent.Fleet.running?(worker_id)
    refute SalixAgent.Fleet.running?(spec.authority["inbound_agent_id"])
  end

  test "a decision naming a source this run never froze settles as a failed terminal", ctx do
    %{profile: profile} = ctx

    # A recorded-shape response: same wire, same encoding, but the decision
    # names a source outside the frozen closure. Nothing about this needs a
    # network, and the engine must seal an explicit failed terminal for it.
    Application.put_env(:bridge_for_teams_core, @action_env_key, "forged_source")

    spec = Harness.scenario("reply", Harness.new_round_context!(profile))
    namespace = "triage-wire-forged-#{System.unique_integer([:positive])}"
    server = Fixture.start_engine!(namespace, Harness.evaluator_port(self()))

    Fixture.put_thread(spec.thread)

    message = %{
      "workspace_id" => spec.authority["workspace_id"],
      "channel_id" => spec.authority["approved_channel_id"],
      "root_thread_ts" => spec.root_ts,
      "message_ts" => spec.root_ts,
      "actor_id" => "U_LIN",
      "actor_kind" => "human",
      "text" => hd(spec.thread)["text"]
    }

    occurrence = %{
      "entry_id" => "forged-source-recheck",
      "schedule_id" => "forged-source-schedule",
      "scheduled_for_ms" => System.system_time(:millisecond)
    }

    assert {:ok, _, receipt} =
             SalixIM.ProviderReceipts.record_slack_triage_recheck(
               spec.authority,
               message,
               occurrence
             )

    assert {:ok, :accepted} = SalixIM.Triage.accept_current(server, spec.authority, receipt)

    # The provider was reached and answered.
    assert_receive {:wire_request, "v1/responses", _body}, 15_000

    run = Fixture.await_run!(server)

    # The forged decision is refused as a `failed` terminal carrying the
    # engine's own diagnostic, and carries NO
    # proof at all. Nothing the provider said became authoritative content.
    assert run["status"] == "failed"
    assert run["decision"]["action"] == "silence"
    assert run["decision"]["reason"] == "identity_decision_invalid"
    assert run["evaluator"] == %{}
    refute run["decision"]["text"]
    refute Jason.encode!(run) =~ "m999-never-frozen"
    refute Jason.encode!(run) =~ "runbook I was never shown"

    # Still zero external effects on the refusal path, and the refusal is as
    # durable and replayable as any other terminal.
    assert Fixture.collected_source_reads() |> Enum.map(&elem(&1, 0)) == [
             "clickhouse.thread_current"
           ]

    assert Fixture.collected_slack_calls() == ["api/emoji.list"]
    refute SalixAgent.Fleet.running?(spec.authority["inbound_agent_id"])

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM triage_product_obligations WHERE run_id = $1",
               [run["run_id"]]
             )

    assert {:ok, ^run} = SalixIM.Triage.replay(server, run["run_id"])
  end

  ## Helpers

  defp drain_wire_requests(acc \\ []) do
    receive do
      {:wire_request, path, body} -> drain_wire_requests([{path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp install_agent_llm_resolver! do
    previous = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm_resolver, Salix.Bindings.AgentLlmResolver)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_agent, :llm_resolver),
        else: Application.put_env(:salix_agent, :llm_resolver, previous)
    end)

    :ok
  end
end
