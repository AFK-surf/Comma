defmodule SalixIM.TriageIdentityContractTest do
  use ExUnit.Case, async: false

  import SalixIM.TriageEngineFixtures

  alias SalixIM.Triage
  alias SalixIM.Triage.{CanonicalJSON, IdentityContract, Runtime}
  alias SalixStore.{CasRecord, ULID}

  defmodule ForbiddenContext do
    @moduledoc false
    def freeze(_input, opts) do
      send(Keyword.fetch!(opts, :test_pid), :identity_context_called)
      {:error, :must_not_run}
    end
  end

  defmodule ForbiddenEvaluator do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageEvaluator

    @impl true
    def evaluate(_input, opts) do
      send(Keyword.fetch!(opts, :test_pid), :identity_evaluator_called)
      {:error, :must_not_run}
    end
  end

  defmodule SourceModeContext do
    @moduledoc false
    def freeze(input, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:identity_context_input, input})

      identity_context =
        opts
        |> Keyword.fetch!(:identity_context)
        |> Map.put("source_mode", input["source_mode"])

      {:ok,
       %{
         "slack_context" => %{"messages" => [], "source_refs" => []},
         "team_project_memory" => %{"source_refs" => []},
         "answered_recheck" => %{
           "answered" => false,
           "checked_at" => "2026-08-14T12:00:00Z",
           "source_refs" => []
         },
         "identity_context" => identity_context
       }}
    end
  end

  defmodule SourceModeEvaluator do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageEvaluator

    @impl true
    def evaluate(model_input, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:identity_evaluator_input, model_input})
      {:error, :must_not_run}
    end
  end

  # The receipt-persistence cases from the source branch describe that branch's
  # `ProviderReceipts.record_slack_triage/2,3`, which main replaced with the
  # strict verified-root writer covered by `slack_triage_receipt_test.exs`, so
  # they do not port. Deliberately not ported:
  #   "new callback receipts retain outer v1 and freeze exact endpoint provenance"
  #   "only provenanced receipts freeze one closed source mode"
  #   "callback app mismatch fails before receipt persistence"
  #   "legacy incomplete connect fixture remains mechanically readable despite callback app id"
  #   "provenanced duplicate drift fails but a legacy receipt is never rewritten"
  #   "duplicate recovery preserves a sanctioned blank-to-known bot identity receipt"

  test "identity revision uses one exact canonical field whitelist" do
    identity = %{
      "source_ref" => "bft://projects/project-atlas/agents/agent-router",
      "principal_ref" => "comma-agent://agt1_atlas_router",
      "agent_id" => "agt1_atlas_router",
      "role" => "router",
      "display_name" => "BFT",
      "persona_revision_sha256" => String.duplicate("a", 64),
      "ignored_secret" => "must-not-affect-the-revision"
    }

    canonical_bytes =
      ~s({"agent_id":"agt1_atlas_router","display_name":"BFT","persona_revision_sha256":"#{String.duplicate("a", 64)}","principal_ref":"comma-agent://agt1_atlas_router","role":"router","source_ref":"bft://projects/project-atlas/agents/agent-router"})

    expected = CanonicalJSON.sha256(canonical_bytes)

    assert {:error, :invalid_self_agent_identity} =
             IdentityContract.identity_revision_sha256(identity)

    assert {:ok, ^expected} =
             identity
             |> Map.delete("ignored_secret")
             |> Map.new()
             |> IdentityContract.identity_revision_sha256()
  end

  test "endpoint revision uses one exact canonical field whitelist" do
    endpoint = %{
      "provider" => "slack",
      "tenant_id" => "tenant-atlas",
      "group_id" => "project-atlas",
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "workspace_id" => "T_ATLAS",
      "inbound_agent_id" => "agt1_atlas_router",
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT",
      "client_secret" => "must-not-affect-the-revision"
    }

    canonical_bytes =
      ~s({"app_id":"A_BFT","bot_user_id":"U_BFT","connect_generation":"generation-7","connect_id":"connect-atlas","group_id":"project-atlas","inbound_agent_id":"agt1_atlas_router","provider":"slack","tenant_id":"tenant-atlas","workspace_id":"T_ATLAS"})

    expected = CanonicalJSON.sha256(canonical_bytes)

    assert {:ok, ^expected} = IdentityContract.endpoint_revision_sha256(endpoint)

    assert {:ok, ^expected} =
             endpoint
             |> Map.delete("client_secret")
             |> IdentityContract.endpoint_revision_sha256()
  end

  test "endpoint revision accepts an explicitly blank backfill bot user id only" do
    endpoint = endpoint_identity("U_BFT")

    assert {:ok, _revision} =
             endpoint
             |> Map.put("bot_user_id", "")
             |> IdentityContract.endpoint_revision_sha256()

    assert {:ok, _same_revision} =
             endpoint
             |> Map.put("bot_id", "")
             |> IdentityContract.endpoint_revision_sha256()
  end

  test "sealed event provenance classifies legacy and identity-enabled runs" do
    assert {:ok, :legacy} =
             IdentityContract.classify_event_provenance([
               %{"event_id" => "Ev1"},
               %{"event_id" => "Ev2"}
             ])

    assert {:ok, :identity_enabled} =
             IdentityContract.classify_event_provenance([
               %{"event_id" => "Ev1", "endpoint_provenance" => endpoint_provenance()},
               %{"event_id" => "Ev2", "endpoint_provenance" => endpoint_provenance()}
             ])
  end

  test "mixed legacy and provenanced sealed events fail closed" do
    assert {:error, :mixed_identity_provenance} =
             IdentityContract.classify_event_provenance([
               %{"event_id" => "Ev1", "endpoint_provenance" => endpoint_provenance()},
               %{"event_id" => "Ev2"}
             ])
  end

  test "sealed-event validation rejects impossible addressing combinations" do
    authority = authority!()

    event =
      thread_receipt!(authority, "Ev-identity-addressing-shape", "1787019000.000001",
        event_type: "app_mention",
        text: "<@#{authority["bot_user_id"]}> review this"
      )["triage_event"]

    assert :ok = IdentityContract.validate_sealed_event(event)

    invalid_events = [
      event |> Map.put("addressing_kind", "ambient") |> Map.put("trigger_kind", "mention"),
      Map.put(event, "fast_path", false),
      event |> Map.put("addressing_kind", "directed") |> Map.put("trigger_kind", "none"),
      event |> Map.put("addressing_kind", "directed") |> Map.delete("addressed_connect")
    ]

    for invalid <- invalid_events do
      assert IdentityContract.validate_sealed_event(invalid) ==
               {:error, :invalid_identity_sealed_event}
    end
  end

  test "provenance projection is exact and typed" do
    assert {:error, :invalid_identity_provenance} =
             IdentityContract.classify_event_provenance([
               %{
                 "event_id" => "Ev1",
                 "endpoint_provenance" =>
                   Map.put(endpoint_provenance(), "signing_secret", "forbidden")
               }
             ])

    assert {:error, :invalid_identity_provenance} =
             IdentityContract.classify_event_provenance([
               %{
                 "event_id" => "Ev1",
                 "endpoint_provenance" =>
                   Map.put(endpoint_provenance(), "endpoint_revision_sha256", "UPPERCASE")
               }
             ])
  end

  test "identity context validates exact nested shapes and recomputed ref projections" do
    context = identity_context()

    assert :ok = IdentityContract.validate_context(context)

    assert IdentityContract.principal_refs(context) == ["comma-agent://agt1_atlas_router"]

    assert IdentityContract.remember_forbidden_source_refs(context) == [
             "bft://projects/project-atlas/agents/agent-router",
             "comma-agent://agt1_atlas_router",
             "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
           ]

    assert IdentityContract.source_refs(context) == [
             "bft://projects/project-atlas/agents/agent-router",
             "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
           ]

    assert {:error, :invalid_identity_context} =
             context
             |> put_in(["self_agent", "display_name"], "Wrong")
             |> IdentityContract.validate_context()

    assert {:error, :invalid_identity_context} =
             context
             |> Map.put("untrusted", true)
             |> IdentityContract.validate_context()
  end

  test "observed principals and per-message mentions close refs without making message refs remember-forbidden" do
    message_ref = "slack://T_ATLAS/C_ATLAS/200.001/200.002"
    foreign_ref = "slack-principal://T_ATLAS/U_FOREIGN"
    mention_ref = "slack-mention://T_ATLAS/C_ATLAS/200.001/200.002/U_FOREIGN"

    context =
      identity_context()
      |> Map.put("observed_principals", [
        %{
          "principal_ref" => foreign_ref,
          "provider" => "slack",
          "kind" => "agent",
          "relation_to_self" => "other",
          "display_aliases" => ["codex-3720"],
          "evidence_tier" => "thread_authorship",
          "source_refs" => [message_ref]
        }
      ])
      |> Map.put("mention_evidence", [
        %{
          "principal_ref" => foreign_ref,
          "provider_user_id" => "U_FOREIGN",
          "message_source_ref" => message_ref,
          "selectors" => ["text_token", "rich_text_user"],
          "source_ref" => mention_ref,
          "source_refs" => [message_ref]
        }
      ])
      |> refresh_identity_projections()

    assert :ok = IdentityContract.validate_context(context)

    assert context["principal_refs"] ==
             Enum.sort(["comma-agent://agt1_atlas_router", foreign_ref])

    assert mention_ref in context["remember_forbidden_source_refs"]
    assert foreign_ref in context["remember_forbidden_source_refs"]
    refute message_ref in context["remember_forbidden_source_refs"]
    assert message_ref in context["source_refs"]
  end

  # Reader, freeze, and verifier each carried their own copy of the rule, and
  # the copies had already drifted: the reader looked at `bot_profile`, the
  # recompute at `bot_profile_name`. One shared vector runs against the one rule
  # all three now call.
  test "one actor-kind rule answers for every key spelling the layers use" do
    connect = %{"bot_user_id" => "U_BFT"}

    vector = [
      {%{"user" => "U_HUMAN"}, "human"},
      {%{"actor_id" => "U_HUMAN"}, "human"},
      {%{"user" => "U_BFT"}, "agent"},
      {%{"user" => "U_HUMAN", "bot_id" => "B_BFT"}, "agent"},
      {%{"user" => "U_HUMAN", "app_id" => "A_BFT"}, "human"},
      {%{"user" => "U_HUMAN", "bot_id" => "B_UPLOAD", "actor_kind" => "human"}, "human"},
      {%{"user" => "U_HUMAN", "bot_profile" => %{"name" => "BFT"}}, "agent"},
      {%{"user" => "U_HUMAN", "bot_profile_name" => "BFT"}, "agent"},
      {%{"user" => "U_HUMAN", "is_bot" => true}, "agent"},
      {%{"user" => "U_HUMAN", "subtype" => "channel_join"}, "system"},
      {%{}, "unknown"}
    ]

    for {message, expected} <- vector do
      assert IdentityContract.actor_kind(message, connect) == expected,
             "#{inspect(message)} must classify as #{expected}"
    end

    assert IdentityContract.actor_kind(:not_a_message, connect) == "unknown"
  end

  test "body subtypes preserve authorship without reclassifying historical frozen messages" do
    connect = %{"bot_user_id" => "U_BFT"}

    for subtype <- ~w(file_share me_message thread_broadcast) do
      message = %{"user" => "U_HUMAN", "subtype" => subtype}
      assert IdentityContract.actor_kind(message, connect) == "human"
      assert IdentityContract.actor_kind(Map.put(message, "bot_id", "B_APP"), connect) == "agent"
      assert IdentityContract.actor_kind(Map.put(message, "user", "U_BFT"), connect) == "agent"

      assert IdentityContract.actor_kind(Map.put(message, "actor_kind", "system"), connect) ==
               "system"

      refute IdentityContract.actor_kind(Map.delete(message, "user"), connect) == "human"
    end

    for subtype <- ~w(channel_join channel_topic message_changed bot_message unknown_subtype) do
      assert IdentityContract.actor_kind(%{"user" => "U_HUMAN", "subtype" => subtype}, connect) ==
               "system"
    end
  end

  test "authorized tool text retains identities and refs but withholds credentials" do
    original =
      "mail ops@example.test about link://run/l001 and " <>
        "id 123e4567-e89b-12d3-a456-426614174000 at /var/secrets/key for <@U0123ABCD>"

    assert IdentityContract.redact_untrusted_text(original) == original

    for secret <- [
          "Bearer fixture-secret",
          "access_token=fixture-secret",
          "xoxb-fixture-secret",
          "https://user:fixture-password@example.test/file",
          "https://example.test/file?X-Amz-Signature=fixture-signature",
          "https://example.test/file?X-Goog-Signature=fixture-signature",
          "https://example.test/file?%74oken=fixture-token",
          "https://example.test/file#refresh_token=fixture-token",
          "https://example.test/file?pub_secret=fixture-secret"
        ] do
      result = IdentityContract.redact_untrusted_text(original <> " " <> secret)
      refute result =~ secret
      assert result == "[Credential-bearing source text withheld]"
    end

    ordinary = "https://example.test/file?project=123&view=token#section"
    assert IdentityContract.redact_untrusted_text(ordinary) == ordinary
  end

  # The token pattern used to swallow any shouted word carrying a year, and
  # redacting those out of a frozen context destroys the meaning the model reads.
  test "Slack id redaction keeps real ids and stops eating shouted words" do
    real_ids =
      ~w(U024BE7LH C1H9RESGL T0266FRGM B0G9QF9C6 W012A3CDE D01234567 G0G9QF9C6 A01B2C3D4E)

    for id <- real_ids do
      assert SalixStore.SlackPrivateToken.redact("actor #{id} spoke") == "actor @provider spoke",
             "#{id} must still be redacted"
    end

    for word <- ~w(GITHUB2024ACTION TEAM2024ROADMAP CHANGELOG2026NOTES) do
      assert SalixStore.SlackPrivateToken.redact("about #{word} today") == "about #{word} today",
             "#{word} must survive"
    end
  end

  test "identity decisions have exact action and interpretation fields" do
    context = identity_context()

    assert :ok =
             IdentityContract.validate_decision(
               %{
                 "action" => "reply",
                 "text" => "I am BFT.",
                 "source_refs" => [
                   "bft://projects/project-atlas/agents/agent-router"
                 ],
                 "identity_interpretation" => %{
                   "topic" => "self_identity",
                   "referenced_principal_refs" => ["comma-agent://agt1_atlas_router"]
                 }
               },
               context
             )

    assert {:error, :invalid_identity_decision} =
             IdentityContract.validate_decision(
               %{
                 "action" => "reply",
                 "text" => "I am BFT.",
                 "source_refs" => [
                   "bft://projects/project-atlas/agents/agent-router"
                 ],
                 "identity_interpretation" => %{
                   "topic" => "self_identity",
                   "referenced_principal_refs" => ["comma-agent://agt1_atlas_router"]
                 },
                 "reasoning" => "must not enter the Ledger"
               },
               context
             )
  end

  test "identity remember excludes identity topics and identity-specific refs" do
    context = identity_context()

    valid = %{
      "action" => "remember",
      "fact" => "Atlas deploys on Tuesdays.",
      "source_refs" => ["meeting://atlas/weekly/fact-1"],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert :ok = IdentityContract.validate_decision(valid, context)

    assert {:error, :invalid_identity_decision} =
             IdentityContract.validate_decision(
               put_in(valid, ["identity_interpretation", "topic"], "self_identity")
               |> put_in(
                 ["identity_interpretation", "referenced_principal_refs"],
                 ["comma-agent://agt1_atlas_router"]
               ),
               context
             )

    assert {:error, :invalid_identity_decision} =
             IdentityContract.validate_decision(
               %{valid | "source_refs" => ["comma-agent://agt1_atlas_router"]},
               context
             )
  end

  test "mixed legacy and provenanced sealed receipts fail before context or evaluator" do
    namespace = "identity-mixed-#{System.unique_integer([:positive])}"
    authority = authority!()
    scope = engine_scope(authority)
    generation = ULID.generate()

    provenanced = thread_receipt!(authority, "Ev-mixed-provenanced", "1787019000.000003")
    legacy = update_in(provenanced, ["triage_event"], &Map.delete(&1, "endpoint_provenance"))
    legacy = Map.put(legacy, "receipt_ref", provenanced["receipt_ref"] <> "-legacy")
    legacy = Map.put(legacy, "event_id", "Ev-mixed-legacy")
    legacy = put_in(legacy, ["triage_event", "event_id"], "Ev-mixed-legacy")

    seed_sealed_bucket!(namespace, scope, generation, [legacy, provenanced])
    runtime = start_engine_runtime(namespace)

    assert [%{"status" => "failed"} = run] =
             eventually(fn -> Triage.ledger_records(runtime) end)

    assert run["input_snapshot"]["schema"] == "comma.triage-input-snapshot.v2"
    assert run["input_snapshot"]["identity_provenance_error"] == "mixed_identity_provenance"
    assert run["decision"]["reason"] =~ "mixed_identity_provenance"
    refute_received :identity_context_called
    refute_received :identity_evaluator_called
  end

  test "mixed provenanced source modes in one sealed bucket fail before context or evaluator" do
    namespace = "identity-mixed-source-mode-#{System.unique_integer([:positive])}"
    authority = authority!()
    scope = engine_scope(authority)
    generation = ULID.generate()

    callback = thread_receipt!(authority, "Ev-mode-callback", "1787019000.000012")

    historical =
      authority
      |> thread_receipt!("Ev-mode-historical", "1787019000.000013")
      |> put_in(["triage_event", "source_mode"], "historical_thread_reenactment")

    seed_sealed_bucket!(namespace, scope, generation, [callback, historical])
    runtime = start_engine_runtime(namespace)

    assert [%{"status" => "failed"} = run] =
             eventually(fn -> Triage.ledger_records(runtime) end)

    assert run["input_snapshot"]["schema"] == "comma.triage-input-snapshot.v2"
    assert run["input_snapshot"]["identity_provenance_error"] == "mixed_identity_source_mode"
    refute Map.has_key?(run["input_snapshot"], "source_mode")
    refute_received :identity_context_called
    refute_received :identity_evaluator_called
  end

  test "provenanced Runtime rejects a nonproduction callback context port" do
    namespace = "identity-source-mode-#{System.unique_integer([:positive])}"
    authority = authority!()

    runtime =
      start_supervised!(
        {Runtime,
         name: nil,
         mode: :review,
         namespace: namespace,
         debounce_ms: 0,
         max_wait_ms: 10,
         evaluation_timeout_ms: 500,
         recovery_idle_ms: 200,
         context_port: {SourceModeContext, test_pid: self(), identity_context: identity_context()},
         evaluator_port: {SourceModeEvaluator, test_pid: self()}},
        id: make_ref()
      )

    receipt = receipt!(authority, "Ev-source-mode-runtime")
    assert get_in(receipt, ["triage_event", "source_mode"]) == "callback"
    assert {:ok, :accepted} = Runtime.accept_current(runtime, authority, receipt)

    refute_receive {:identity_context_input, _input}, 200
    refute_receive {:identity_evaluator_input, _input}, 100

    assert [%{"status" => "failed"} = run] =
             eventually(fn -> Triage.ledger_records(runtime) end)

    assert run["input_snapshot"]["source_mode"] == "callback"
    assert run["decision"]["reason"] == "identity_diagnostic_internal_error"
  end

  defp start_engine_runtime(namespace) do
    start_supervised!(
      {Runtime,
       name: nil,
       mode: :review,
       namespace: namespace,
       debounce_ms: 0,
       max_wait_ms: 10,
       evaluation_timeout_ms: 500,
       recovery_idle_ms: 50,
       context_port: {ForbiddenContext, test_pid: self()},
       evaluator_port: {ForbiddenEvaluator, test_pid: self()}},
      id: make_ref()
    )
  end

  # Main's callback route admits only exact provenanced roots, so a mixed
  # sealed generation can only arrive as durable evidence written before the
  # provenance contract closed. The recovery bucket lane is what meets it.
  defp seed_sealed_bucket!(namespace, scope, generation, receipts) do
    bucket = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => ULID.generate(),
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => [
        %{
          "generation" => generation,
          "receipts" => receipts,
          "sealed_at" => System.system_time(:millisecond)
        }
      ]
    }

    assert {:ok, ^bucket} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
               bucket
             )

    bucket
  end

  defp engine_scope(authority) do
    Enum.join(
      [
        authority["connect_generation"],
        authority["workspace_id"],
        authority["approved_channel_id"],
        "1787019000.000000"
      ],
      ":"
    )
  end

  defp endpoint_identity(bot_user_id) do
    %{
      "provider" => "slack",
      "tenant_id" => "tenant-atlas",
      "group_id" => "project-atlas",
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "workspace_id" => "T_ATLAS",
      "inbound_agent_id" => "agt1_atlas_router",
      "app_id" => "A_BFT",
      "bot_user_id" => bot_user_id,
      "bot_id" => "B_BFT"
    }
  end

  defp endpoint_provenance do
    %{
      "schema" => "comma.slack-endpoint-provenance.v1",
      "captured_at_ms" => 1_780_000_000_000,
      "callback_api_app_id" => "A_BFT",
      "fast_path_bot_user_id" => "U_BFT",
      "endpoint_revision_sha256" => String.duplicate("b", 64)
    }
  end

  defp identity_context do
    identity = %{
      "source_ref" => "bft://projects/project-atlas/agents/agent-router",
      "principal_ref" => "comma-agent://agt1_atlas_router",
      "agent_id" => "agt1_atlas_router",
      "role" => "router",
      "display_name" => "BFT",
      "persona_revision_sha256" => String.duplicate("a", 64)
    }

    {:ok, identity_revision} = IdentityContract.identity_revision_sha256(identity)

    %{
      "schema" => "comma.triage-identity-context.v1",
      "source_mode" => "callback",
      "self_agent" => Map.put(identity, "identity_revision_sha256", identity_revision),
      "self_endpoint" => %{
        "source_ref" => "slack-endpoint://T_ATLAS/connect-atlas@generation-7",
        "provider" => "slack",
        "workspace_id" => "T_ATLAS",
        "connect_id" => "connect-atlas",
        "connect_generation" => "generation-7",
        "provider_app_id" => "A_BFT",
        "bot_user_id" => "U_BFT",
        "bot_id" => "B_BFT",
        "display_aliases" => ["BFT"],
        "represents_principal_ref" => "comma-agent://agt1_atlas_router",
        "revision_sha256" => String.duplicate("b", 64),
        "revision_status" => "exact"
      },
      "observed_principals" => [],
      "mention_evidence" => [],
      "principal_refs" => ["comma-agent://agt1_atlas_router"],
      "remember_forbidden_source_refs" => [
        "bft://projects/project-atlas/agents/agent-router",
        "comma-agent://agt1_atlas_router",
        "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
      ],
      "source_refs" => [
        "bft://projects/project-atlas/agents/agent-router",
        "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
      ]
    }
  end

  defp refresh_identity_projections(context) do
    context
    |> Map.put("principal_refs", IdentityContract.principal_refs(context))
    |> Map.put(
      "remember_forbidden_source_refs",
      IdentityContract.remember_forbidden_source_refs(context)
    )
    |> Map.put("source_refs", IdentityContract.source_refs(context))
  end
end
