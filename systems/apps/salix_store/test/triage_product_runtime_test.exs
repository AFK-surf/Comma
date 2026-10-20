defmodule SalixStore.TriageProductRuntimeTest do
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:triage_product_effects]

  alias SalixStore.{Crypto, Ids, Repo, TriageProductRuntime, ULID}

  setup do
    Repo.query!("""
    TRUNCATE
      schedule_runs,
      schedules,
      triage_context_entries,
      triage_patrol_cursors,
      triage_projection_obligations,
      triage_replays,
      triage_runs,
      triage_run_fences
    CASCADE
    """)

    :ok
  end

  test "intake joins only exact executions in the selected Agent scope within a fixed bound" do
    native_key = SalixStore.TriageKeys.namespace_key(SalixStore.TriageKeys.default_namespace())
    seed_obligation!("intake-execution", [], [], native_key)
    seed_obligation!("other-namespace", [])

    %{rows: [[obligation_id, group_id]]} =
      Repo.query!(
        "SELECT obligation_id, payload #>> '{product_identity,project_salix_group_id}' FROM triage_product_obligations WHERE run_id = $1",
        ["intake-execution"]
      )

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{product_identity,project_salix_group_id}', to_jsonb($1::text)) WHERE run_id = $2",
      [group_id, "other-namespace"]
    )

    assert TriageProductRuntime.outcome_ids_for_executions("project-1", group_id, "agent-1", [
             "intake-execution",
             "other-namespace"
           ]) ==
             {:ok, %{"intake-execution" => obligation_id}}

    for {project, group, agent} <- [
          {"other-project", group_id, "agent-1"},
          {"project-1", "other-group", "agent-1"},
          {"project-1", group_id, "other-agent"}
        ] do
      assert TriageProductRuntime.outcome_ids_for_executions(project, group, agent, [
               "intake-execution"
             ]) == {:ok, %{}}
    end

    assert {:error, :invalid} =
             TriageProductRuntime.outcome_ids_for_executions(
               "project-1",
               group_id,
               "agent-1",
               List.duplicate("intake-execution", 21)
             )
  end

  test "only confirmed reminders and agent-owned checks create schedules" do
    candidates =
      for basis <- ~w(unconfirmed reminder_confirmed agent_owned) do
        context("follow_up", basis, "Check the pending item", "explicit", ["slack://T/C/1/2"], 12)
        |> Map.put("follow_up_basis", basis)
      end

    seed_obligation!("follow-up-consent", candidates)
    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("consent")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    assert {:ok, entries} = TriageProductRuntime.list_context("project-1")
    by_subject = Map.new(entries, &{&1.payload["subject"], &1})
    assert by_subject["unconfirmed"].state == :proposed
    assert by_subject["unconfirmed"].next_check_at == nil
    refute by_subject["unconfirmed"].payload["schedule_id"]

    for basis <- ~w(reminder_confirmed agent_owned) do
      assert by_subject[basis].state == :active
      assert by_subject[basis].payload["follow_up_basis"] == basis
      assert is_binary(by_subject[basis].payload["schedule_id"])
    end

    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM schedules")
  end

  test "a confirmed reminder closes only after its scheduled reply is delivered" do
    candidate =
      context(
        "follow_up",
        "meeting reminder",
        "Remind me before the meeting",
        "explicit",
        ["slack://T1/C1/100.000001/100.000001"],
        12
      )
      |> Map.put("follow_up_basis", "reminder_confirmed")

    seed_obligation!("reminder-open", [candidate])
    assert {:ok, [opening]} = TriageProductRuntime.claim_obligations("open")
    assert {:ok, _} = TriageProductRuntime.settle_claim(opening, audit_effect(:applied))
    assert {:ok, [entry]} = TriageProductRuntime.list_context("project-1")
    event_id = "recheck:current-occurrence"

    assert {:ok, :rescheduled} =
             TriageProductRuntime.admit_follow_up_wakeup(
               entry.entry_id,
               entry.payload["authority_generation"],
               entry.payload["schedule_id"],
               DateTime.to_unix(entry.next_check_at, :millisecond),
               fn -> {:ok, event_id} end
             )

    ref = "triage-context://#{entry.entry_id}"

    resolution =
      context("follow_up_resolution", "meeting reminder", "The requested reminder", "explicit", [
        ref,
        "slack://T1/C1/100.000001/100.000001"
      ])
      |> Map.put("resolution_basis", "reminder_delivery")

    delivered = %{
      adapter: :slack,
      outcome: :applied,
      external_writes: 1,
      communication: %{"kind" => "reply", "status" => "delivered", "source_refs" => [ref]}
    }

    for {run_id, event_ids, effect, target} <- [
          {"ordinary-reply", [], delivered, entry.payload["target"]},
          {"old-occurrence", ["recheck:old"], delivered, entry.payload["target"]},
          {"capture-only", [event_id], %{delivered | adapter: :audit_sink},
           entry.payload["target"]},
          {"undelivered", [event_id], put_in(delivered, [:communication, "status"], "captured"),
           entry.payload["target"]},
          {"uncited", [event_id], put_in(delivered, [:communication, "source_refs"], []),
           entry.payload["target"]},
          {"wrong-thread", [event_id], delivered,
           Map.put(entry.payload["target"], "thread_ts", "101.000001")},
          {"delivered", [event_id], delivered, entry.payload["target"]}
        ] do
      seed_obligation!(run_id, [resolution])

      Repo.query!(
        "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
        [
          run_id,
          %{
            "target" => target,
            "recheck_event_ids" => event_ids,
            "delegations" => [%{"worker_ref" => "comma-agent://worker-1"}],
            "source_authority" => [%{"message_ts" => "100.000001"}]
          }
        ]
      )

      assert {:ok, [claim]} = TriageProductRuntime.claim_obligations(run_id)
      assert {:ok, _} = TriageProductRuntime.settle_claim(claim, effect)
      assert {:ok, [current]} = TriageProductRuntime.list_context("project-1")

      if run_id == "delivered" do
        assert current.state == :resolved
        assert current.payload["resolved_reason"] == "reminder_delivered"

        assert {:ok, :stale} =
                 TriageProductRuntime.admit_follow_up_wakeup(
                   current.entry_id,
                   current.payload["authority_generation"],
                   current.payload["schedule_id"],
                   DateTime.to_unix(entry.next_check_at, :millisecond),
                   fn -> flunk("delivered reminder re-entered") end
                 )
      else
        assert current.state == :active
      end
    end
  end

  test "a source-confirmed cancellation can stop a reminder without sending it" do
    candidate =
      context(
        "follow_up",
        "meeting reminder",
        "Remind me tomorrow",
        "explicit",
        ["slack://T1/C1/100.000001/100.000001"],
        24
      )
      |> Map.put("follow_up_basis", "reminder_confirmed")

    seed_obligation!("cancel-open", [candidate])
    assert {:ok, [opening]} = TriageProductRuntime.claim_obligations("open")
    assert {:ok, _} = TriageProductRuntime.settle_claim(opening, audit_effect(:applied))
    assert {:ok, [entry]} = TriageProductRuntime.list_context("project-1")

    resolution =
      context(
        "follow_up_resolution",
        "meeting reminder",
        "The requester cancelled it",
        "explicit",
        ["triage-context://#{entry.entry_id}", "slack://T1/C1/100.000001/100.000009"]
      )
      |> Map.put("resolution_basis", "source_confirmation")

    seed_obligation!("cancel-confirmed", [resolution])

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
      [
        "cancel-confirmed",
        %{
          "target" => entry.payload["target"],
          "source_authority" => [%{"message_ts" => "100.000009"}]
        }
      ]
    )

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("cancel")

    assert {:ok, _} =
             TriageProductRuntime.settle_claim(
               claim,
               audit_effect(
                 :applied,
                 %{"kind" => "silence", "status" => "no_public_effect"}
               )
             )

    assert {:ok, [%{state: :resolved}]} = TriageProductRuntime.list_context("project-1")
  end

  test "claims partition a bounded batch and an expired claim is safely stolen" do
    Enum.each(1..3, &seed_obligation!("run-#{&1}", []))

    assert {:ok, first} =
             TriageProductRuntime.claim_obligations("pod-a", limit: 2, lease_ms: 5_000)

    assert length(first) == 2
    assert Enum.all?(first, &(&1.attempt == 1 and &1.holder == "pod-a"))

    assert {:ok, [third]} =
             TriageProductRuntime.claim_obligations("pod-b", limit: 2, lease_ms: 5_000)

    assert third.run_id == "run-3"
    assert {:ok, []} = TriageProductRuntime.claim_obligations("pod-c", limit: 3)

    Repo.query!(
      "UPDATE triage_product_obligations SET lease_until = statement_timestamp() - interval '1 second' WHERE run_id = $1",
      [hd(first).run_id]
    )

    assert {:ok, [stolen]} = TriageProductRuntime.claim_obligations("pod-c", limit: 1)
    assert stolen.run_id == hd(first).run_id
    assert stolen.attempt == 2
    refute stolen.claim_token == hd(first).claim_token

    assert {:error, :conflict} =
             TriageProductRuntime.settle_claim(hd(first), audit_effect(:applied))
  end

  test "companion reactions claim and settle independently from the primary reply" do
    seed_obligation!("run-compound", [])
    seed_companion_reaction!("run-compound")

    assert {:ok, [primary]} = TriageProductRuntime.claim_obligations("primary-pod")

    assert {:ok, [companion]} =
             TriageProductRuntime.claim_companion_reactions("reaction-pod")

    assert primary.run_id == companion.run_id
    refute primary.obligation_id == companion.obligation_id

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_claim(primary, audit_effect(:applied))

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_companion_reaction(
               companion,
               audit_effect(:applied, %{
                 "kind" => "reaction",
                 "emoji" => "eyes",
                 "status" => "captured"
               })
             )

    assert %{rows: [["applied", "applied"]]} =
             Repo.query!(
               """
               SELECT p.state, c.state
               FROM triage_product_obligations AS p
               JOIN triage_companion_reaction_obligations AS c
                 USING (namespace_key, run_id)
               WHERE p.run_id = $1
               """,
               ["run-compound"]
             )
  end

  test "reply, context and zero-write audit evidence settle once" do
    candidates = [
      context("project_fact", "release owner", "Peng", "explicit", ["slack://T/C/1/2"]),
      context(
        "follow_up",
        "unanswered rollout",
        "check deployment",
        "explicit",
        ["slack://T/C/1/3"],
        12
      )
    ]

    delegations = [
      %{
        "task" => "Verify the release observer",
        "source_refs" => ["slack://T/C/1/4"]
      }
    ]

    seed_obligation!("run-product", candidates, delegations)
    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("shadow")

    effect =
      audit_effect(:applied, %{
        "kind" => "reply",
        "status" => "captured",
        "text" => "I found the release owner.",
        "target" => claim.payload["target"]
      })

    assert {:ok, %{status: :settled, state: :applied, result: result}} =
             TriageProductRuntime.settle_claim(claim, effect)

    assert result["external_writes"] == 0
    assert result["context"]["active_count"] == 2
    assert result["context"]["candidate_count"] == 2

    assert {:ok, %{status: :duplicate, state: :applied}} =
             TriageProductRuntime.settle_claim(claim, effect)

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM triage_product_effect_attempts")
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM triage_context_entries")

    assert {:ok, [outcome]} = TriageProductRuntime.recent_outcomes("project-1")
    assert outcome.state == :applied
    assert outcome.result["communication"]["status"] == "captured"
    assert outcome.delegations == delegations

    assert {:ok, context_entries} = TriageProductRuntime.list_context("project-1")
    assert Enum.sort(Enum.map(context_entries, & &1.kind)) == ["follow_up", "project_fact"]

    follow_up = Enum.find(context_entries, &(&1.kind == "follow_up"))
    assert %DateTime{} = follow_up.next_check_at

    schedule_id = follow_up.payload["schedule_id"]
    authority_generation = follow_up.payload["authority_generation"]
    due_ms = DateTime.to_unix(follow_up.next_check_at, :millisecond)

    assert %{rows: [[^schedule_id, "triage_follow_up", ^due_ms]]} =
             Repo.query!(
               "SELECT id, receiver, run_at FROM schedules WHERE id = $1",
               [schedule_id]
             )

    assert {:ok, %{entry_id: entry_id}} =
             TriageProductRuntime.get_due_follow_up(
               follow_up.entry_id,
               authority_generation,
               schedule_id,
               due_ms
             )

    assert entry_id == follow_up.entry_id

    assert {:ok, :rescheduled} =
             TriageProductRuntime.settle_follow_up_wakeup(
               follow_up.entry_id,
               authority_generation,
               schedule_id,
               due_ms,
               :admitted
             )

    assert {:ok, :stale} =
             TriageProductRuntime.get_due_follow_up(
               follow_up.entry_id,
               authority_generation,
               schedule_id,
               due_ms
             )

    assert {:ok, [rescheduled]} = TriageProductRuntime.list_context("project-1", limit: 1)
    next_schedule_id = rescheduled.payload["schedule_id"]
    next_due_ms = DateTime.to_unix(rescheduled.next_check_at, :millisecond)
    refute next_schedule_id == schedule_id

    assert {:ok, :resolved} =
             TriageProductRuntime.settle_follow_up_wakeup(
               rescheduled.entry_id,
               authority_generation,
               next_schedule_id,
               next_due_ms,
               :answered
             )

    assert {:ok, [%{state: :resolved}]} =
             TriageProductRuntime.list_context("project-1", limit: 1)
  end

  test "stale follow-up authority stops without claiming completion or scheduling another check" do
    seed_obligation!("run-stale-follow-up", [
      context(
        "follow_up",
        "unanswered rollout",
        "check deployment",
        "explicit",
        ["slack://T/C/1/3"],
        12
      )
    ])

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("shadow")

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    assert {:ok, [follow_up]} = TriageProductRuntime.list_context("project-1")
    schedule_id = follow_up.payload["schedule_id"]
    authority_generation = follow_up.payload["authority_generation"]
    due_ms = DateTime.to_unix(follow_up.next_check_at, :millisecond)

    assert {:ok, :stopped} =
             TriageProductRuntime.settle_follow_up_wakeup(
               follow_up.entry_id,
               authority_generation,
               schedule_id,
               due_ms,
               :stale_authority
             )

    assert {:ok, [%{state: :stopped, payload: payload} = stopped]} =
             TriageProductRuntime.list_context("project-1")

    assert payload["resolved_reason"] == "source_authority_stale"
    assert stopped.resolved_at == nil
    assert stopped.next_check_at == nil
    assert %DateTime{} = stopped.stopped_at

    assert {:ok, :stale} =
             TriageProductRuntime.get_due_follow_up(
               follow_up.entry_id,
               authority_generation,
               schedule_id,
               due_ms
             )
  end

  test "the same topic keeps two personal preferences separate from the team decision" do
    for {scope, owner, value} <- [
          {"person", "slack-user://T1/U_PENG", "prefer implementation first"},
          {"person", "slack-user://T1/U_LIN", "prefer tests first"},
          {"project", "project-1", "team requires regression coverage"}
        ] do
      candidate =
        context("decision", "Codex workflow", value, "explicit", ["slack://T1/C1/1/2"])
        |> Map.merge(%{
          "knowledge_scope" => scope,
          "scope_owner" => %{"kind" => scope, "id" => owner},
          "source_attribution" => [
            %{"source_ref" => "slack://T1/C1/1/2", "actor_id" => owner, "message_ts" => "2"}
          ]
        })

      seed_obligation!("scoped-#{owner}", [candidate])
      assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("scope-owner")
      assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    end

    assert {:ok, entries} = TriageProductRuntime.list_context("project-1")
    assert length(entries) == 3
    assert Enum.all?(entries, &(&1.state == :active))
    assert entries |> Enum.map(& &1.payload["scope_owner"]["id"]) |> Enum.uniq() |> length() == 3
    assert Enum.all?(entries, &(length(&1.payload["source_attribution"]) == 1))
  end

  test "conflicting context is proposed instead of rewriting active context" do
    seed_obligation!("run-first", [
      context("project_fact", "release owner", "Peng", "explicit", ["slack://T/C/1/2"])
    ])

    assert {:ok, [first]} = TriageProductRuntime.claim_obligations("pod-a")

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_claim(first, audit_effect(:applied))

    seed_obligation!("run-conflict", [
      context(
        "project_fact",
        "release owner",
        "Jimmy",
        "explicit",
        ["slack://T/C/1/3"]
      )
    ])

    assert {:ok, [second]} = TriageProductRuntime.claim_obligations("pod-b")

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_claim(second, audit_effect(:applied))

    assert {:ok, entries} = TriageProductRuntime.list_context("project-1")
    assert Enum.count(entries, &(&1.state == :active)) == 1
    assert Enum.count(entries, &(&1.state == :proposed)) == 1
    assert Enum.find(entries, &(&1.state == :active)).payload["value"] == "Peng"
  end

  test "a retryable failure is audited and returned to pending" do
    seed_obligation!("run-retry", [])
    assert {:ok, [first]} = TriageProductRuntime.claim_obligations("pod-a")

    assert {:ok, %{state: :pending}} =
             TriageProductRuntime.settle_claim(first, %{
               adapter: :audit_sink,
               outcome: :failed,
               external_writes: 0,
               communication: %{"kind" => "reply", "status" => "adapter_unavailable"},
               error: "temporary",
               retry: true
             })

    assert {:ok, [second]} = TriageProductRuntime.claim_obligations("pod-b")
    assert second.attempt == 2

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_claim(second, audit_effect(:applied))

    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM triage_product_effect_attempts")
  end

  defp seed_obligation!(
         run_id,
         candidates,
         delegations \\ [],
         namespace_key \\ Crypto.hex("triage-product-runtime-test")
       ) do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)

    Repo.query!(
      """
      INSERT INTO triage_runs (record_key, namespace_key, run_id, body)
      VALUES ($1, $2, $3, $4)
      """,
      [
        "triage-test-run://#{run_id}",
        namespace_key,
        run_id,
        %{
          "schema" => "comma.triage-run.v1",
          "run_id" => run_id,
          "authoritative" => true,
          "created_at" => 1,
          "status" => "evaluated"
        }
      ]
    )

    obligation = %{
      "schema" => "comma.triage-product-obligation.v1",
      "obligation_id" => "triage-product-" <> Crypto.hex(run_id),
      "namespace" => "triage-product-runtime-test",
      "fence_key" => "triage/fence/#{run_id}",
      "run_id" => run_id,
      "target" => %{
        "connect_id" => Ids.new_connect_id(),
        "connect_generation" => ULID.generate(),
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "100.000001"
      },
      "product_identity" => %{
        "project_id" => "project-1",
        "project_salix_group_id" => group_id,
        "agent_id" => "agent-1",
        "salix_agent_id" => agent_id
      },
      "communication" => %{
        "kind" => "reply",
        "text" => "A bounded reply",
        "source_refs" => ["slack://T/C/1/2"]
      },
      "context_candidates" => candidates,
      "delegations" => delegations,
      "target_cutoff" => %{"event_message_timestamps" => ["101.000001"]},
      "settled_at" => 1_787_900_000_001
    }

    Repo.query!(
      """
      INSERT INTO triage_product_obligations
        (namespace_key, run_id, obligation_id, payload)
      VALUES ($1, $2, $3, $4)
      """,
      [namespace_key, run_id, obligation["obligation_id"], obligation]
    )
  end

  defp seed_companion_reaction!(run_id) do
    %{rows: [[namespace_key, primary]]} =
      Repo.query!(
        "SELECT namespace_key, payload FROM triage_product_obligations WHERE run_id = $1",
        [run_id]
      )

    companion =
      primary
      |> Map.put("obligation_id", "triage-product-" <> Crypto.hex("#{run_id}:reaction"))
      |> Map.put("communication", %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => ["slack://T/C/1/2"]
      })
      |> Map.put("context_candidates", [])
      |> Map.put("delegations", [])

    Repo.query!(
      """
      INSERT INTO triage_companion_reaction_obligations
        (namespace_key, run_id, obligation_id, payload)
      VALUES ($1, $2, $3, $4)
      """,
      [namespace_key, run_id, companion["obligation_id"], companion]
    )
  end

  defp context(kind, subject, value, confidence, source_refs, recheck_after_hours \\ nil) do
    %{
      "kind" => kind,
      "subject" => subject,
      "value" => value,
      "confidence" => confidence,
      "source_refs" => source_refs
    }
    |> then(fn candidate ->
      if recheck_after_hours,
        do:
          candidate
          |> Map.put("recheck_after_hours", recheck_after_hours)
          |> Map.put("follow_up_basis", "agent_owned"),
        else: candidate
    end)
  end

  defp audit_effect(
         outcome,
         communication \\ %{"kind" => "silence", "status" => "recorded"}
       ) do
    %{
      adapter: :audit_sink,
      outcome: outcome,
      external_writes: 0,
      communication: communication,
      metadata: %{"mode" => "local_shadow"}
    }
  end
end
