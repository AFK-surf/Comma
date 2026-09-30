defmodule SalixStore.TriageProductRuntimeTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Crypto, Ids, Repo, TriageProductRuntime, ULID}

  @product_effect_workers [
    :"Elixir.SalixIM.Triage.ProductEffectWorker",
    :"Elixir.SalixIM.Triage.CompanionReactionEffectWorker"
  ]

  setup_all do
    # Both application workers consume the lanes that this suite drives.
    # Suspend them before inserting rows so the tests own both claim lanes.
    for worker <- @product_effect_workers do
      case Process.whereis(worker) do
        pid when is_pid(pid) ->
          :ok = :sys.suspend(pid)

          on_exit(fn ->
            if Process.alive?(pid), do: :sys.resume(pid)
          end)

        nil ->
          :ok
      end
    end

    :ok
  end

  setup do
    Repo.query!("""
    TRUNCATE
      schedule_runs,
      schedules,
      triage_product_effect_attempts,
      triage_companion_reaction_obligations,
      triage_product_obligations,
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

  test "an event trajectory returns current effects across rounds without mixing sources" do
    seed_obligation!("trajectory-first", [])
    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("trajectory")
    target = claim.payload["target"]
    group_id = claim.payload["product_identity"]["project_salix_group_id"]

    opts = [agent_id: "agent-1", group_id: group_id, target: target, limit: 3]
    assert {:ok, [pending]} = TriageProductRuntime.recent_outcomes("project-1", opts)
    assert pending.state == :claimed

    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    seed_obligation!("trajectory-next", [])

    Repo.query!(
      """
      UPDATE triage_product_obligations
      SET payload = jsonb_set(jsonb_set(payload, '{target}', $2::jsonb),
        '{product_identity,project_salix_group_id}', to_jsonb($3::text))
      WHERE run_id = $1
      """,
      ["trajectory-next", target, group_id]
    )

    seed_obligation!("trajectory-other-source", [])

    assert {:ok, rounds} = TriageProductRuntime.recent_outcomes("project-1", opts)
    assert length(rounds) == 2
    assert Enum.all?(rounds, &(&1.target == target))
    assert Enum.any?(rounds, &(&1.state == :applied))
    assert Enum.any?(rounds, &(&1.state == :pending))

    assert {:ok, [_]} =
             TriageProductRuntime.recent_outcomes("project-1", Keyword.put(opts, :limit, 1))

    assert {:ok, []} = TriageProductRuntime.recent_outcomes("foreign-project", opts)

    assert {:ok, []} =
             TriageProductRuntime.recent_outcomes(
               "project-1",
               Keyword.put(opts, :group_id, "foreign-group")
             )

    assert {:ok, []} =
             TriageProductRuntime.recent_outcomes(
               "project-1",
               Keyword.put(opts, :agent_id, "foreign-agent")
             )

    assert {:ok, []} =
             TriageProductRuntime.recent_outcomes(
               "project-1",
               Keyword.put(opts, :target, %{target | "connect_generation" => "rotated"})
             )
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

  test "timeline pages keep tied executions stable when effects change and scope every filter" do
    for id <- ~w(page-a page-b page-c), do: seed_obligation!(id, [])

    Repo.query!("""
    UPDATE triage_product_obligations
    SET payload = jsonb_set(payload, '{product_identity,project_salix_group_id}', '"timeline-group"'),
        inserted_at = '2026-09-10T01:00:00.123456Z'
    """)

    assert {:ok, %{outcomes: [first, second], next_cursor: cursor}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1", limit: 2)

    assert is_binary(cursor)

    Repo.query!(
      "UPDATE triage_product_obligations SET updated_at = now() + interval '1 day' WHERE obligation_id = $1",
      [first.obligation_id]
    )

    assert {:ok, %{outcomes: [third], next_cursor: nil}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               limit: 2,
               cursor: cursor
             )

    assert MapSet.size(
             MapSet.new([first.obligation_id, second.obligation_id, third.obligation_id])
           ) == 3

    assert {:ok, %{outcomes: []}} =
             TriageProductRuntime.outcome_page("foreign", "timeline-group", "agent-1",
               cursor: cursor
             )

    assert {:ok, %{outcomes: []}} =
             TriageProductRuntime.outcome_page("project-1", "foreign", "agent-1")

    assert {:ok, %{outcomes: []}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "foreign")

    assert {:ok, %{outcomes: []}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               kind: "silence"
             )

    assert {:ok, %{outcomes: [exact], next_cursor: nil}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               obligation_id: first.obligation_id
             )

    assert exact.obligation_id == first.obligation_id

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{communication,kind}', $2::jsonb), state = 'failed' WHERE obligation_id = $1",
      [first.obligation_id, "silence"]
    )

    assert {:ok, %{outcomes: [filtered], next_cursor: nil}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               kind: "silence"
             )

    assert filtered.obligation_id == first.obligation_id

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{communication,reason}', $2::jsonb) WHERE obligation_id = $1",
      [first.obligation_id, "worker_pending"]
    )

    assert {:ok, %{outcomes: []}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               kind: "silence"
             )

    assert {:error, :invalid} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               cursor: "garbage"
             )

    # A channel filter pages only that channel's executions.
    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{target,channel_id}', '\"C2\"') WHERE run_id = 'page-c'"
    )

    assert {:ok, %{outcomes: [other_channel], next_cursor: nil}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               channel_id: "C2"
             )

    assert other_channel.target["channel_id"] == "C2"

    assert {:ok, %{outcomes: [_one], next_cursor: cursor}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               channel_id: "C1",
               limit: 1
             )

    assert {:ok, %{outcomes: [second_c1], next_cursor: nil}} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               channel_id: "C1",
               limit: 1,
               cursor: cursor
             )

    assert second_c1.target["channel_id"] == "C1"

    assert {:error, :invalid} =
             TriageProductRuntime.outcome_page("project-1", "timeline-group", "agent-1",
               channel_id: ""
             )
  end

  test "the heatmap counts one Agent's outcomes per channel and hour, and pages start before a time" do
    for id <- ~w(heat-a heat-b heat-c heat-d heat-old), do: seed_obligation!(id, [])

    Repo.query!("""
    UPDATE triage_product_obligations
    SET payload = jsonb_set(
          jsonb_set(payload, '{product_identity,project_salix_group_id}', '"heat-group"'),
          '{target,connect_id}', '"K1"'
        ),
        inserted_at = CASE run_id
          WHEN 'heat-old' THEN '2026-09-01T00:00:00Z'::timestamptz
          WHEN 'heat-c' THEN '2026-09-10T02:10:00Z'::timestamptz
          ELSE '2026-09-10T01:15:00Z'::timestamptz
        END
    """)

    Repo.query!("""
    UPDATE triage_product_obligations
    SET payload = jsonb_set(payload, '{communication}', '{"kind":"silence","reason":"not_addressed"}')
    WHERE run_id IN ('heat-b', 'heat-c')
    """)

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{target,channel_id}', '\"C2\"') WHERE run_id = 'heat-d'"
    )

    since_ms = DateTime.to_unix(~U[2026-09-10 00:00:00Z], :millisecond)
    hour_1 = DateTime.to_unix(~U[2026-09-10 01:00:00Z], :millisecond)
    hour_2 = DateTime.to_unix(~U[2026-09-10 02:00:00Z], :millisecond)

    assert {:ok, %{bucket_ms: 3_600_000, truncated: false, cells: cells}} =
             TriageProductRuntime.outcome_heatmap("project-1", "heat-group", "agent-1", since_ms)

    assert Enum.sort_by(cells, &{&1.at_ms, &1.channel_id}) == [
             %{
               connect_id: "K1",
               channel_id: "C1",
               at_ms: hour_1,
               reply: 1,
               reaction: 0,
               silence: 1,
               total: 2
             },
             %{
               connect_id: "K1",
               channel_id: "C2",
               at_ms: hour_1,
               reply: 1,
               reaction: 0,
               silence: 0,
               total: 1
             },
             %{
               connect_id: "K1",
               channel_id: "C1",
               at_ms: hour_2,
               reply: 0,
               reaction: 0,
               silence: 1,
               total: 1
             }
           ]

    assert {:ok, %{cells: []}} =
             TriageProductRuntime.outcome_heatmap("project-1", "foreign", "agent-1", since_ms)

    assert {:error, :invalid} =
             TriageProductRuntime.outcome_heatmap("project-1", "heat-group", "agent-1", -1)

    # A page that starts before 02:00 skips the later execution, then keeps
    # paging by cursor from there.
    id = &("triage-product-" <> Crypto.hex(&1))

    assert {:ok, %{outcomes: first_page, next_cursor: cursor}} =
             TriageProductRuntime.outcome_page("project-1", "heat-group", "agent-1",
               channel_id: "C1",
               before_ms: hour_2,
               limit: 2
             )

    assert MapSet.new(first_page, & &1.obligation_id) == MapSet.new(~w(heat-a heat-b), id)

    assert {:ok, %{outcomes: [oldest], next_cursor: nil}} =
             TriageProductRuntime.outcome_page("project-1", "heat-group", "agent-1",
               channel_id: "C1",
               before_ms: hour_2,
               cursor: cursor,
               limit: 2
             )

    assert oldest.obligation_id == id.("heat-old")

    assert {:error, :invalid} =
             TriageProductRuntime.outcome_page("project-1", "heat-group", "agent-1",
               before_ms: -1
             )
  end

  test "an explicit follow-up reference reuses its schedule despite rewritten wording" do
    source = "slack://T1/C1/100.000001/100.000001"

    seed_obligation!("reuse-open", [
      context("follow_up", "latency investigation", "get trace", "explicit", [source], 2)
    ])

    assert {:ok, [opening]} = TriageProductRuntime.claim_obligations("opening")
    assert {:ok, _} = TriageProductRuntime.settle_claim(opening, audit_effect(:applied))
    assert {:ok, [entry]} = TriageProductRuntime.list_context("project-1")
    ref = "triage-context://#{entry.entry_id}"

    rewritten =
      context(
        "follow_up",
        "latency investigation (waiting for trace)",
        "wait for Peng's trace",
        "explicit",
        [ref, source],
        24
      )
      |> Map.put("follow_up_ref", ref)

    seed_obligation!("reuse-recheck", [rewritten])

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
      [
        "reuse-recheck",
        %{
          "target" => opening.payload["target"],
          "source_authority" => [%{"message_ts" => "100.000001"}]
        }
      ]
    )

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("recheck")

    assert {:ok, %{result: %{"context" => %{"entries" => [%{"disposition" => "reinforced"}]}}}} =
             TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    assert {:ok, [updated]} = TriageProductRuntime.list_context("project-1")
    assert updated.entry_id == entry.entry_id
    assert updated.payload["schedule_id"] == entry.payload["schedule_id"]
    assert updated.payload["recheck_after_hours"] == 2
    assert updated.payload["subject"] == rewritten["subject"]
    assert updated.payload["value"] == rewritten["value"]
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM schedules")

    # A citation is evidence, not a request to merge a distinct goal.
    independent =
      rewritten
      |> Map.delete("follow_up_ref")
      |> Map.put("subject", "latency investigation")
      |> Map.put("follow_up_action", "create")

    seed_obligation!("independent", [
      independent,
      Map.put(independent, "value", "check capacity separately")
    ])

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("independent")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    assert {:ok, entries} = TriageProductRuntime.list_context("project-1")
    assert length(entries) == 3
    assert Enum.all?(entries, &(&1.state == :active))
    assert %{rows: [[3]]} = Repo.query!("SELECT count(*) FROM schedules")
  end

  test "operator-selected duplicates retain their evidence and cannot admit another wakeup" do
    candidates =
      for subject <- ["Incident investigation", "Incident trace", "Incident deployment"] do
        context(
          "follow_up",
          subject,
          "Confirm the same incident recovery",
          "explicit",
          [
            "slack://T1/C1/100.000001/100.000001"
          ],
          1
        )
      end

    seed_obligation!("duplicate-follow-ups", candidates)
    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("opening")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    assert {:ok, [retained | duplicates]} = TriageProductRuntime.list_context("project-1")

    assert {:ok, result} =
             TriageProductRuntime.supersede_follow_ups("project-1", retained, duplicates)

    assert result.retained_entry_id == retained.entry_id

    assert Enum.sort(result.superseded_entry_ids) ==
             Enum.sort(Enum.map(duplicates, & &1.entry_id))

    assert {:ok, [^retained]} = TriageProductRuntime.list_active_context("project-1")

    for entry <- duplicates do
      assert %{rows: [["superseded", payload, superseded_by, nil]]} =
               Repo.query!(
                 "SELECT state, payload, superseded_by, resolved_at FROM triage_context_entries WHERE entry_id = $1",
                 [entry.entry_id]
               )

      assert payload == entry.payload
      assert superseded_by == retained.entry_id
      due = DateTime.to_unix(entry.next_check_at, :millisecond)

      assert {:ok, :stale} =
               TriageProductRuntime.get_due_follow_up(
                 entry.entry_id,
                 payload["authority_generation"],
                 payload["schedule_id"],
                 due
               )

      assert {:ok, :stale} =
               TriageProductRuntime.admit_follow_up_wakeup(
                 entry.entry_id,
                 payload["authority_generation"],
                 payload["schedule_id"],
                 due,
                 fn -> flunk("a superseded follow-up must not create a receipt") end
               )
    end

    assert {:ok, ^result} =
             TriageProductRuntime.supersede_follow_ups("project-1", retained, duplicates)
  end

  test "follow-up supersession rejects changed snapshots and foreign scope atomically" do
    seed_obligation!(
      "supersede-race",
      for subject <- ["one", "two", "three"] do
        context(
          "follow_up",
          subject,
          "pending incident",
          "explicit",
          ["slack://T1/C1/100/100"],
          1
        )
      end
    )

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("opening")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    assert {:ok, [retained, first, changed] = original} =
             TriageProductRuntime.list_context("project-1")

    assert {:error, :conflict} =
             TriageProductRuntime.supersede_follow_ups("other-project", retained, [first, changed])

    Repo.query!(
      "UPDATE triage_context_entries SET payload = jsonb_set(payload, '{value}', to_jsonb($2::text)) WHERE entry_id = $1",
      [changed.entry_id, "new evidence arrived after the operator read"]
    )

    assert {:error, :conflict} =
             TriageProductRuntime.supersede_follow_ups("project-1", retained, [first, changed])

    assert {:ok, current} = TriageProductRuntime.list_context("project-1")
    assert Enum.all?(current, &(&1.state == :active))
    assert length(current) == length(original)

    # Even a current snapshot cannot authorize merging another source target.
    Repo.query!(
      "UPDATE triage_context_entries SET payload = jsonb_set(payload, '{target,thread_ts}', to_jsonb($2::text)) WHERE entry_id = $1",
      [changed.entry_id, "200.000001"]
    )

    assert {:ok, current} = TriageProductRuntime.list_context("project-1")
    foreign = Enum.find(current, &(&1.entry_id == changed.entry_id))

    assert {:error, :conflict} =
             TriageProductRuntime.supersede_follow_ups("project-1", retained, [first, foreign])

    assert {:ok, current} = TriageProductRuntime.list_active_context("project-1")
    assert length(current) == 3
  end

  test "invalid reuse cannot create a replacement or revive a closed follow-up" do
    source = "slack://T1/C1/100.000001/100.000001"

    seed_obligation!("reuse-boundary-open", [
      context("follow_up", "investigation", "get trace", "explicit", [source], 2)
    ])

    assert {:ok, [opening]} = TriageProductRuntime.claim_obligations("opening")
    assert {:ok, _} = TriageProductRuntime.settle_claim(opening, audit_effect(:applied))
    assert {:ok, [entry]} = TriageProductRuntime.list_context("project-1")
    ref = "triage-context://#{entry.entry_id}"

    candidate =
      context("follow_up", "renamed investigation", "new wording", "explicit", [ref, source], 24)
      |> Map.put("follow_up_ref", ref)

    for {run, patch, effect} <- [
          {"reuse-foreign-project",
           %{
             "product_identity" =>
               Map.put(opening.payload["product_identity"], "project_id", "foreign")
           }, :applied},
          {"reuse-foreign-thread",
           %{"target" => Map.put(opening.payload["target"], "thread_ts", "101.000001")},
           :applied},
          {"reuse-rotated",
           %{"target" => Map.put(opening.payload["target"], "connect_generation", "rotated")},
           :applied},
          {"reuse-no-evidence", %{"source_authority" => []}, :applied},
          {"reuse-stale", %{}, :stale}
        ] do
      seed_obligation!(run, [candidate])

      patch =
        Map.merge(
          %{
            "target" => opening.payload["target"],
            "source_authority" => [%{"message_ts" => "100.000001"}]
          },
          patch
        )

      Repo.query!(
        "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
        [run, patch]
      )

      assert {:ok, [claim]} = TriageProductRuntime.claim_obligations(run)

      assert {:ok, %{result: %{"context" => %{"entries" => [%{"state" => "ignored"}]}}}} =
               TriageProductRuntime.settle_claim(claim, audit_effect(effect))
    end

    resolution =
      context("follow_up_resolution", "investigation", "source cancels the work", "explicit", [
        ref,
        source
      ])

    seed_obligation!("reuse-resolve", [resolution])

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
      [
        "reuse-resolve",
        %{
          "target" => opening.payload["target"],
          "source_authority" => [%{"message_ts" => "100.000001"}]
        }
      ]
    )

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("resolve")

    assert {:ok, %{result: %{"context" => %{"resolved_count" => 1}}}} =
             TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    seed_obligation!("reuse-closed", [candidate])

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
      [
        "reuse-closed",
        %{
          "target" => opening.payload["target"],
          "source_authority" => [%{"message_ts" => "100.000001"}]
        }
      ]
    )

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("closed")

    assert {:ok, %{result: %{"context" => %{"entries" => [%{"state" => "ignored"}]}}}} =
             TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM triage_context_entries")
  end

  test "follow-up completion requires exact project, source generation and applied evidence" do
    seed_obligation!("followup-open", [
      context(
        "follow_up",
        "deployment recovery",
        "verify public health",
        "explicit",
        ["slack://T1/C1/100.000001/100.000001"],
        12
      )
    ])

    assert {:ok, [opening]} = TriageProductRuntime.claim_obligations("opening")
    assert {:ok, _} = TriageProductRuntime.settle_claim(opening, audit_effect(:applied))
    assert {:ok, [entry]} = TriageProductRuntime.list_context("project-1")

    assert {:ok, [^entry]} =
             TriageProductRuntime.list_context("project-1",
               agent_id: "agent-1",
               kind: "follow_up",
               entry_id: entry.entry_id
             )

    assert {:ok, []} =
             TriageProductRuntime.list_context("project-1",
               agent_id: "foreign",
               entry_id: entry.entry_id
             )

    assert {:ok, []} =
             TriageProductRuntime.list_context("project-1",
               kind: "decision",
               entry_id: entry.entry_id
             )

    assert {:ok, []} = TriageProductRuntime.list_context("foreign", entry_id: entry.entry_id)
    target = entry.payload["target"]
    evidence_ref = "slack://T1/C1/100.000001/100.000009"

    candidate =
      context(
        "follow_up_resolution",
        "deployment recovery",
        "public health confirmed",
        "explicit",
        ["triage-context://#{entry.entry_id}", evidence_ref]
      )

    for {variant, changes, effect} <- [
          {"wrong-project",
           %{
             "product_identity" =>
               Map.put(opening.payload["product_identity"], "project_id", "other-project")
           }, :applied},
          {"wrong-thread", %{"target" => Map.put(target, "thread_ts", "101.000001")}, :applied},
          {"rotated", %{"target" => Map.put(target, "connect_generation", "rotated")}, :applied},
          {"no-current-evidence", %{"source_authority" => []}, :applied},
          {"stale-effect", %{}, :stale}
        ] do
      seed_obligation!(variant, [candidate])

      patch =
        Map.merge(
          %{"target" => target, "source_authority" => [%{"message_ts" => "100.000009"}]},
          changes
        )

      Repo.query!(
        "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
        [variant, patch]
      )

      assert {:ok, [claim]} = TriageProductRuntime.claim_obligations(variant)
      assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(effect))
      assert {:ok, [%{state: :active}]} = TriageProductRuntime.list_context("project-1")
    end

    seed_obligation!("confirmed", [candidate])

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = payload || $2 WHERE run_id = $1",
      [
        "confirmed",
        %{"target" => target, "source_authority" => [%{"message_ts" => "100.000009"}]}
      ]
    )

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("confirmed")

    assert {:ok, %{result: %{"context" => %{"resolved_count" => 1}}}} =
             TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    assert {:ok, [%{state: :resolved}]} = TriageProductRuntime.list_context("project-1")

    assert {:ok, %{status: :duplicate}} =
             TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
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

  test "an unclassified human plan does not become an automatic reminder" do
    candidate =
      context(
        "follow_up",
        "Ask tomorrow",
        "A person plans to ask at the meeting",
        "explicit",
        ["slack://T/C/1/2"],
        24
      )
      |> Map.delete("follow_up_basis")

    seed_obligation!("unclassified-plan", [candidate])
    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("unclassified")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    assert {:ok, [%{state: :proposed, next_check_at: nil}]} =
             TriageProductRuntime.list_context("project-1")

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM schedules")
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

  test "an exact delegation read survives settlement without claiming or rewriting the obligation" do
    proposal = %{"task" => "Inspect the captured source", "source_refs" => ["source-1"]}
    seed_obligation!("delegation-read", [], [proposal])
    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("delegation-owner")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))

    before =
      Repo.query!("SELECT state, attempts, claim_token, result FROM triage_product_obligations").rows

    assert {:ok, original} =
             TriageProductRuntime.fetch_delegation(claim.namespace_key, claim.obligation_id, 0)

    assert original.payload == claim.payload
    assert original.delegation == proposal
    assert original.index == 0
    refute Map.has_key?(original, :claim_token)

    for {namespace, obligation_id, index} <- [
          {Crypto.hex("another namespace"), claim.obligation_id, 0},
          {claim.namespace_key, "triage-product-" <> Crypto.hex("missing"), 0},
          {claim.namespace_key, claim.obligation_id, 1}
        ] do
      assert {:error, :not_found} =
               TriageProductRuntime.fetch_delegation(namespace, obligation_id, index)
    end

    assert {:error, :invalid} =
             TriageProductRuntime.fetch_delegation(claim.namespace_key, claim.obligation_id, 2)

    assert Repo.query!(
             "SELECT state, attempts, claim_token, result FROM triage_product_obligations"
           ).rows == before
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

  test "relevant active memory remains searchable beyond the most recent twenty entries" do
    seed_obligation!("memory-older-topic", [
      context(
        "project_fact",
        "Mafuzhen 电视播放",
        "已经下载到电视，下一步确认能否播放",
        "explicit",
        ["slack://T/C/1/1"],
        nil
      )
    ])

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("memory-seed")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    assert {:ok, [older]} = TriageProductRuntime.list_context("project-1")

    for index <- 1..21 do
      seed_obligation!("memory-newer-#{index}", [
        context(
          "project_fact",
          "unrelated meeting #{index}",
          "meeting room reservation",
          "explicit",
          ["slack://T/C/2/#{index}"],
          nil
        )
      ])

      assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("memory-seed")
      assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    end

    assert {:ok, recent} = TriageProductRuntime.list_active_context("project-1", limit: 20)
    refute Enum.any?(recent, &(&1.entry_id == older.entry_id))

    assert {:ok, [found]} =
             TriageProductRuntime.list_active_context("project-1", query: "电视能播了", limit: 20)

    assert found.entry_id == older.entry_id
    assert found.payload["source_refs"] == older.payload["source_refs"]

    assert {:ok, []} = TriageProductRuntime.list_active_context("project-1", query: "好")

    assert {:ok, [pinned | rest]} =
             TriageProductRuntime.list_active_context("project-1",
               query: "meeting",
               entry_ids: [older.entry_id],
               limit: 20
             )

    assert pinned.entry_id == older.entry_id
    assert length(rest) == 19
    refute Enum.any?(rest, &(&1.entry_id == older.entry_id))

    assert {:ok, []} =
             TriageProductRuntime.list_active_context("another-project",
               query: "好",
               entry_ids: [older.entry_id]
             )

    assert {:error, :invalid} =
             TriageProductRuntime.list_active_context("project-1",
               entry_ids: List.duplicate(older.entry_id, 21)
             )

    assert {:ok, []} =
             TriageProductRuntime.list_active_context("another-project", query: "电视", limit: 20)

    Repo.query!("UPDATE triage_context_entries SET state = 'proposed' WHERE entry_id = $1", [
      older.entry_id
    ])

    assert {:ok, []} =
             TriageProductRuntime.list_active_context("project-1",
               query: "好",
               entry_ids: [older.entry_id]
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

  test "unattributed personal knowledge remains proposed and is not recalled as active" do
    candidate =
      context("decision", "Codex workflow", "Prefer implementation first", "explicit", [
        "slack://T1/C1/1/2"
      ])
      |> Map.put("knowledge_scope", "unattributed")

    seed_obligation!("unattributed-person", [candidate])
    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("scope-owner")
    assert {:ok, _} = TriageProductRuntime.settle_claim(claim, audit_effect(:applied))
    assert {:ok, [%{state: :proposed}]} = TriageProductRuntime.list_context("project-1")

    assert {:ok, []} =
             TriageProductRuntime.list_active_context("project-1", query: "Codex workflow")
  end

  test "stale communication still commits independent context" do
    seed_obligation!("run-stale", [
      context(
        "decision",
        "database",
        "use PostgreSQL",
        "explicit",
        ["slack://T/C/1/2"]
      )
    ])

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("pod-a")

    assert {:ok, %{state: :stale, result: result}} =
             TriageProductRuntime.settle_claim(
               claim,
               audit_effect(:stale, %{"kind" => "reply", "status" => "freshness_blocked"})
             )

    assert result["context"]["active_count"] == 1
    assert {:ok, [%{state: :active}]} = TriageProductRuntime.list_context("project-1")
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
