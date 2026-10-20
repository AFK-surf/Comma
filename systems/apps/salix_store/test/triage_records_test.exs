defmodule SalixStore.TriageRecordsTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  Code.require_file(
    "../priv/repo/migrations/20260826000102_add_triage_record_body_bytes.exs",
    __DIR__
  )

  alias SalixStore.{
    CasRecord,
    Crypto,
    Lease,
    Repo,
    S3,
    TriageKeys,
    TriageRecords,
    TriageTransactions
  }

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, TriageRecords)

    Repo.query!("""
    TRUNCATE
      triage_companion_reaction_obligations,
      triage_product_effect_attempts,
      triage_product_obligations,
      triage_context_entries,
      triage_patrol_cursors,
      triage_projection_obligations,
      triage_recovery_leases,
      triage_intent_settlements,
      triage_late_results,
      triage_lifecycle_events,
      triage_activity_index_entries,
      triage_time_index_entries,
      triage_correlation_entries,
      triage_record_body_sizes,
      triage_replays,
      triage_runs,
      triage_run_fences,
      triage_buckets,
      triage_bucket_memberships,
      triage_recipient_aliases,
      triage_ambient_aliases,
      triage_receipt_projections
    """)

    S3.Fake.reset()

    on_exit(fn ->
      if previous_backend do
        SystemsRuntime.put_env(:salix_store, :triage_record_backend, previous_backend)
      else
        SystemsRuntime.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "mutable bucket writes preserve create-once and revision-fenced CAS" do
    key = TriageKeys.ctl_im_triage_bucket("typed-cas", "scope-a")
    first = bucket("scope-a", "generation-a")
    second = %{first | "open_generation" => "generation-b"}

    assert {:ok, %{etag: first_etag}} =
             TriageRecords.put(key, Jason.encode!(first), if_none_match: "*")

    assert {:error, :precondition_failed} =
             TriageRecords.put(key, Jason.encode!(second), if_none_match: "*")

    assert {:ok, %{body: body, etag: ^first_etag}} = TriageRecords.get(key)
    assert Jason.decode!(body) == first

    assert {:ok, %{etag: second_etag}} =
             TriageRecords.put(key, Jason.encode!(second), if_match: first_etag)

    refute second_etag == first_etag

    assert {:error, :precondition_failed} =
             TriageRecords.put(key, Jason.encode!(first), if_match: first_etag)

    assert {:ok, %{body: body, etag: ^second_etag}} = TriageRecords.get(key)
    assert Jason.decode!(body) == second
  end

  test "evidence tables reject update and delete even for the table owner" do
    run_id = "run-immutable"
    key = TriageKeys.ctl_im_triage_ledger_run("immutable", run_id)
    run = run(run_id)

    assert {:ok, %{etag: etag}} =
             TriageRecords.put(key, Jason.encode!(run), if_none_match: "*")

    assert {:error, :precondition_failed} =
             TriageRecords.put(key, Jason.encode!(Map.put(run, "status", "changed")),
               if_match: etag
             )

    assert {:error, :invalid} = TriageRecords.delete(key, if_match: etag)

    assert_raise Postgrex.Error, ~r/native Triage evidence is append-only/, fn ->
      Repo.query!("UPDATE triage_runs SET body = body WHERE record_key = $1", [key])
    end
  end

  test "channel completion preserves exact source, pending batches and open arrivals atomically" do
    namespace = "channel-archive"
    first = channel_receipt("archive-first")
    persist_receipt!(first)
    admission = admission(namespace, first, :ambient)
    assert {:ok, %{durable: initial}} = TriageTransactions.admit_receipt(admission)
    bucket_key = TriageKeys.ctl_im_triage_bucket(namespace, admission.bucket_identity)

    sealed = %{
      "generation" => initial["open_generation"],
      "receipts" => [first],
      "sealed_at" => 1
    }

    second = channel_receipt("archive-second", "1711000000.000002")
    third = channel_receipt("archive-third", "1711000000.000003")
    other = %{"generation" => "pending-generation", "receipts" => [second], "sealed_at" => 2}

    pending = %{
      initial
      | "open_generation" => "next-generation",
        "open_receipts" => [third],
        "sealed_generations" => [sealed, other]
    }

    assert {:ok, %{etag: bucket_etag}} = TriageRecords.get(bucket_key)
    assert {:ok, _} = TriageRecords.put(bucket_key, Jason.encode!(pending), if_match: bucket_etag)

    commit = authoritative_commit(namespace, "run-channel-archive")

    fence_key =
      TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        admission.bucket_identity,
        sealed["generation"]
      )

    fence =
      Map.merge(commit.fence, %{
        "bucket_scope" => admission.bucket_identity,
        "generation" => sealed["generation"],
        "input_snapshot" => %{"source_authority" => %{"scope_kind" => "channel"}},
        "sealed_generation" => sealed
      })

    commit = %{
      commit
      | fence_key: fence_key,
        fence: fence,
        obligation: Map.put(commit.obligation, "fence_key", fence_key)
    }

    assert {:ok, %{etag: etag}} =
             TriageRecords.put(
               fence_key,
               Jason.encode!(
                 fence
                 |> Map.put("terminal", nil)
                 |> Map.delete("sealed_generation")
               ),
               if_none_match: "*"
             )

    commit = %{commit | expected_etag: etag}

    assert {:error, :conflict} =
             TriageTransactions.commit_authoritative(%{commit | expected_etag: "pg:999"})

    assert {:ok, %{body: unchanged}} = TriageRecords.get(bucket_key)
    assert Jason.decode!(unchanged) == pending
    assert {:error, :not_found} = TriageRecords.get(commit.run_key)

    tampered = put_in(commit, [:fence, "sealed_generation", "receipts"], [])
    assert {:error, :conflict} = TriageTransactions.commit_authoritative(tampered)
    assert {:ok, %{body: ^unchanged}} = TriageRecords.get(bucket_key)

    owner = SystemsRuntime.Proc.self()

    completion =
      SystemsRuntime.Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, result} = TriageTransactions.commit_authoritative(commit)

          SystemsRuntime.Proc.send(
            owner,
            {:channel_completion_staged, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
            :publish -> result
          after
            5_000 -> Repo.rollback(:completion_not_released)
          end
        end)
      end)

    assert_receive {:channel_completion_staged, completion_pid}

    duplicate =
      SystemsRuntime.Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          SystemsRuntime.Proc.send(owner, {:channel_duplicate_backend, backend_pid})
          TriageTransactions.admit_receipt(admission)
        end)
      end)

    assert_receive {:channel_duplicate_backend, backend_pid}
    assert wait_for_bucket_lock(backend_pid, 200)
    SystemsRuntime.Proc.send(completion_pid, :publish)
    assert {:ok, _} = SystemsRuntime.Task.await(completion, :infinity)

    assert {:ok, %{status: :duplicate, durable: duplicate_view}} =
             SystemsRuntime.Task.await(duplicate, :infinity)

    assert duplicate_view["open_receipts"] == [third]
    assert sealed in duplicate_view["sealed_generations"]

    assert {:ok, %{body: compacted}} = TriageRecords.get(bucket_key)
    assert Jason.decode!(compacted) == %{pending | "sealed_generations" => [other]}
    assert {:ok, %{body: archive}} = TriageRecords.get(fence_key)
    assert Jason.decode!(archive)["sealed_generation"] == sealed
    assert {:ok, _} = TriageTransactions.commit_authoritative(commit)
  end

  defp wait_for_bucket_lock(_backend_pid, 0), do: false

  defp wait_for_bucket_lock(backend_pid, attempts) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid]) do
      %{rows: [["Lock"]]} ->
        true

      _running ->
        SystemsRuntime.Proc.sleep(5)
        wait_for_bucket_lock(backend_pid, attempts - 1)
    end
  end

  defp channel_receipt(event_id, message_ts \\ "1711000000.000001") do
    admission_receipt(event_id, "connect-channel", message_ts: message_ts)
    |> put_in(["triage_event", "bucket", "scope_kind"], "channel")
    |> put_in(["triage_event", "fast_path"], false)
  end

  test "terminal fence, run, replay and projection obligation commit atomically and retry idempotently" do
    create_bucket("atomic")
    commit = authoritative_commit("atomic", "run-atomic")

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    commit = %{commit | expected_etag: open_etag}

    assert {:ok, %{fence_etag: terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    assert terminal_etag != open_etag
    assert {:ok, %{body: fence_body}} = TriageRecords.get(commit.fence_key)
    assert Jason.decode!(fence_body) == commit.fence
    assert {:ok, %{body: run_body}} = TriageRecords.get(commit.run_key)
    assert Jason.decode!(run_body) == commit.run
    assert {:ok, %{body: replay_body}} = TriageRecords.get(commit.replay_key)
    assert Jason.decode!(replay_body) == commit.replay

    assert {:ok, %{body: ^fence_body}} =
             TriageRecords.get_bounded(commit.fence_key, 1_000_000)

    assert {:ok, %{body: ^run_body}} = TriageRecords.get_bounded(commit.run_key, 1_000_000)

    assert {:ok, %{body: ^replay_body}} =
             TriageRecords.get_bounded(commit.replay_key, 1_000_000)

    assert {:ok, [%{run_id: "run-atomic", attempts: 0}]} =
             TriageTransactions.pending_projection_obligations(10)

    assert {:ok, %{fence_etag: ^terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    open_fence = Map.put(commit.fence, "terminal", nil)

    assert {:error, :invalid} =
             TriageRecords.put(commit.fence_key, Jason.encode!(open_fence),
               if_match: terminal_etag
             )

    assert_raise Postgrex.Error, ~r/native Triage fence terminal is monotonic/, fn ->
      Repo.query!("UPDATE triage_run_fences SET body = $2 WHERE record_key = $1", [
        commit.fence_key,
        open_fence
      ])
    end

    assert :ok =
             TriageTransactions.mark_projection_failed(
               namespace_key(commit.fence_key),
               "run-atomic",
               "projector offline"
             )

    assert {:ok, [%{run_id: "run-atomic", attempts: 1}]} =
             TriageTransactions.pending_projection_obligations(10)

    assert {:ok, %{body: run_body_after_failure}} = TriageRecords.get(commit.run_key)
    assert Jason.decode!(run_body_after_failure) == commit.run
  end

  test "product obligation joins the authoritative commit and exact retry" do
    create_bucket("product-atomic")

    commit =
      authoritative_commit("product-atomic", "run-product-atomic")
      |> then(fn commit ->
        obligation =
          commit
          |> product_obligation("product-atomic")
          |> Map.put("source_messages", [
            %{
              "actor_id" => "U_SOURCE",
              "actor_kind" => "human",
              "excerpt" => "Who owns the rollout?",
              "message_ts" => "1787900000.000001",
              "message_ts_us" => 1_787_900_000_000_001,
              "observed_version" => 3_575_800_000_000_002
            }
          ])

        %{commit | product_obligation: obligation}
      end)

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    commit = %{commit | expected_etag: open_etag}

    assert {:ok, %{fence_etag: terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    namespace_key = namespace_key(commit.fence_key)

    assert %{rows: [[payload, "pending", 0]]} =
             Repo.query!(
               """
               SELECT payload, state, attempts
               FROM triage_product_obligations
               WHERE namespace_key = $1 AND run_id = $2
               """,
               [namespace_key, "run-product-atomic"]
             )

    assert payload == commit.product_obligation

    assert {:ok, %{fence_etag: ^terminal_etag}} =
             TriageTransactions.commit_authoritative(commit)

    assert %{rows: [[1]]} =
             Repo.query!(
               """
               SELECT count(*)
               FROM triage_product_obligations
               WHERE namespace_key = $1 AND run_id = $2
               """,
               [namespace_key, "run-product-atomic"]
             )
  end

  @worker_expression %{
    "schema" => "comma.triage-expression-context.v1",
    "mode" => "project",
    "allow_reactions" => true,
    "allowed_emojis" => ["party_parrot"],
    "catalog" => %{
      "status" => "available",
      "complete?" => true,
      "custom_emojis" => ["party_parrot"]
    },
    "observed_reactions" => [],
    "guidance" => "Use the frozen palette."
  }
  @worker_context [
    %{
      "kind" => "retained_project_fact",
      "text" => "The project uses a staging workspace.",
      "source_ref" => "triage-context://project/fact"
    }
  ]

  for {name, extra} <- [
        {"expression", %{"expression_context" => @worker_expression}},
        {"context", %{"context_sources" => @worker_context}},
        {"both",
         %{"expression_context" => @worker_expression, "context_sources" => @worker_context}}
      ] do
  end

  test "any invalid authoritative component rolls the terminal fence back" do
    create_bucket("rollback")
    commit = authoritative_commit("rollback", "run-rollback")

    assert {:ok, %{etag: open_etag}} =
             TriageRecords.put(
               commit.fence_key,
               Jason.encode!(Map.put(commit.fence, "terminal", nil)),
               if_none_match: "*"
             )

    invalid =
      commit
      |> Map.put(:expected_etag, open_etag)
      |> put_in([:replay, "schema"], "invalid")

    assert {:error, :invalid} = TriageTransactions.commit_authoritative(invalid)
    assert {:ok, %{body: fence_body, etag: ^open_etag}} = TriageRecords.get(commit.fence_key)
    assert Jason.decode!(fence_body)["terminal"] == nil
    assert {:error, :not_found} = TriageRecords.get(commit.run_key)
    assert {:error, :not_found} = TriageRecords.get(commit.replay_key)
    assert {:ok, []} = TriageTransactions.pending_projection_obligations(10)
  end

  test "receipt admission refuses to create runnable membership before its S3 evidence exists" do
    receipt = admission_receipt("missing-evidence", "connect-a")

    assert {:error, :receipt_unavailable} =
             TriageTransactions.admit_receipt(admission("missing-evidence", receipt, :ambient))

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM triage_bucket_memberships")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM triage_recipient_aliases")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM triage_buckets")
  end

  test "recipient aliases admit one physical source once per addressed connect" do
    namespace = "recipient-fanout"
    first = admission_receipt("fanout-a", "connect-a")

    second =
      admission_receipt("fanout-b", "connect-b",
        message_ts: source_ts(first),
        generation: "01JQTRIAGEGENERATION000002"
      )

    persist_receipt!(first)
    persist_receipt!(second)

    assert {:ok, %{status: :accepted, lane: :directed, durable: first_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, first, :directed))

    assert {:ok, %{status: :accepted, lane: :directed, durable: second_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, second, :directed))

    assert first_bucket["open_receipts"] == [first]
    assert second_bucket["open_receipts"] == [second]

    namespace_key = TriageKeys.namespace_key(namespace)
    physical_source_key = Crypto.hex(physical_source(first))

    assert %{rows: rows} =
             Repo.query!(
               "SELECT recipient_key FROM triage_recipient_aliases WHERE namespace_key = $1 AND physical_source_key = $2 ORDER BY recipient_key",
               [namespace_key, physical_source_key]
             )

    assert rows ==
             Enum.sort([
               [Crypto.hex("connect-a")],
               [Crypto.hex("connect-b")]
             ])
  end

  test "a later directed copy upgrades one membership and returns its fast-path bucket" do
    namespace = "owner-addressed-late"

    ambient =
      admission_receipt("owner-ambient-first", "connect-a")
      |> put_in(["triage_event", "actor_kind"], "human")
      |> put_in(["triage_event", "addressing_kind"], "ambient")
      |> put_in(["triage_event", "trigger_kind"], "none")
      |> put_in(["triage_event", "fast_path"], false)
      |> update_in(["triage_event"], &Map.delete(&1, "addressed_connect"))

    directed =
      admission_receipt("owner-directed-second", "connect-a", message_ts: source_ts(ambient))

    persist_receipt!(ambient)
    persist_receipt!(directed)

    assert {:ok, %{status: :accepted, lane: :ambient, durable: first_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, ambient, :ambient))

    refute first_bucket["open_fast_path"]

    assert {:ok, %{status: :duplicate, lane: :both, durable: upgraded_bucket}} =
             TriageTransactions.admit_receipt(admission(namespace, directed, :directed))

    assert upgraded_bucket["open_fast_path"]

    assert Enum.map(upgraded_bucket["open_receipts"], & &1["receipt_ref"]) |> Enum.sort() ==
             Enum.sort([ambient["receipt_ref"], directed["receipt_ref"]])

    namespace_key = TriageKeys.namespace_key(namespace)
    physical_source_key = Crypto.hex(physical_source(ambient))
    recipient_key = Crypto.hex("connect-a")

    assert %{rows: [["both"]]} =
             Repo.query!(
               "SELECT lane FROM triage_bucket_memberships WHERE namespace_key = $1 AND physical_source_key = $2 AND recipient_key = $3",
               [namespace_key, physical_source_key, recipient_key]
             )

    ambient_receipt_ref = ambient["receipt_ref"]

    assert %{rows: [[^ambient_receipt_ref]]} =
             Repo.query!(
               "SELECT canonical_receipt_ref FROM triage_recipient_aliases WHERE namespace_key = $1 AND physical_source_key = $2 AND recipient_key = $3",
               [namespace_key, physical_source_key, recipient_key]
             )
  end

  test "a foreign ambient winner cannot suppress an explicitly addressed recipient" do
    namespace = "ambient-plus-directed"
    ambient = admission_receipt("ambient-winner", "connect-a")
    directed = admission_receipt("directed-peer", "connect-b", message_ts: source_ts(ambient))
    persist_receipt!(ambient)
    persist_receipt!(directed)

    assert {:ok, %{status: :accepted, lane: :ambient}} =
             TriageTransactions.admit_receipt(admission(namespace, ambient, :ambient))

    assert {:ok, %{status: :accepted, lane: :directed}} =
             TriageTransactions.admit_receipt(admission(namespace, directed, :both))

    namespace_key = TriageKeys.namespace_key(namespace)
    physical_source_key = Crypto.hex(physical_source(ambient))

    assert %{rows: rows} =
             Repo.query!(
               "SELECT recipient_key, lane FROM triage_bucket_memberships WHERE namespace_key = $1 AND physical_source_key = $2 ORDER BY recipient_key",
               [namespace_key, physical_source_key]
             )

    assert rows ==
             Enum.sort([
               [Crypto.hex("connect-a"), "ambient"],
               [Crypto.hex("connect-b"), "directed"]
             ])
  end

  test "intent settlement is a separate append-only exact record" do
    settlement = %{
      "schema" => "comma.slack-intent-settlement.v1",
      "connect_id" => "connect-a",
      "event_id" => "event-without-principal",
      "reason" => "missing_actor_id",
      "admission_ref" => "s3://ctl/im/receipts/slack/connect-a/event.json"
    }

    assert {:ok, :created} = TriageTransactions.record_intent_settlement(settlement)
    assert {:ok, :duplicate} = TriageTransactions.record_intent_settlement(settlement)

    assert {:error, :conflict} =
             TriageTransactions.record_intent_settlement(%{
               settlement
               | "reason" => "unsupported_message_shape"
             })

    assert_raise Postgrex.Error, ~r/native Triage evidence is append-only/, fn ->
      Repo.query!("DELETE FROM triage_intent_settlements")
    end
  end

  defp authoritative_commit(namespace, run_id) do
    fence_key = TriageKeys.ctl_im_triage_bucket_seal(namespace, "scope-a", "generation-a")
    run_key = TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)
    replay_key = TriageKeys.ctl_im_triage_replay(namespace, run_id)

    %{
      fence_key: fence_key,
      expected_etag: "pg:1",
      fence: %{
        "schema" => "comma.triage-bucket-fence.v1",
        "run_id" => run_id,
        "terminal" => %{"status" => "replied"}
      },
      run_key: run_key,
      run: run(run_id),
      replay_key: replay_key,
      replay: %{
        "schema" => "comma.triage-replay.v1",
        "run_id" => run_id,
        "ledger_ref" => "triage-record://" <> run_key,
        "run_sha256" => String.duplicate("a", 64)
      },
      obligation: %{
        "schema" => "comma.triage-projection-obligation.v1",
        "namespace" => namespace,
        "fence_key" => fence_key,
        "run_id" => run_id,
        "correlations" => [],
        "activity_required" => false,
        "time_required" => true
      },
      product_obligation: nil
    }
  end

  defp product_obligation(commit, namespace) do
    %{
      "schema" => "comma.triage-product-obligation.v1",
      "obligation_id" => "triage-product-" <> String.duplicate("a", 64),
      "namespace" => namespace,
      "fence_key" => commit.fence_key,
      "run_id" => commit.run["run_id"],
      "target" => %{
        "workspace_id" => "T-product",
        "channel_id" => "C-product",
        "thread_ts" => "1787900000.000001"
      },
      "product_identity" => %{"agent_id" => "agent-product"},
      "communication" => %{"action" => "silence", "reason" => "no_reply_needed"},
      "context_candidates" => [],
      "delegations" => [],
      "target_cutoff" => %{"latest_message_ts" => "1787900000.000001"},
      "settled_at" => 1_787_900_000_001
    }
  end

  defp admission(namespace, receipt, lane) do
    %{
      namespace: namespace,
      physical_source: physical_source(receipt),
      recipient: receipt["connect_id"],
      bucket_identity:
        Enum.join(
          [
            receipt["connect_generation"],
            get_in(receipt, ["triage_event", "bucket", "workspace_id"]),
            get_in(receipt, ["triage_event", "bucket", "channel_id"]),
            get_in(receipt, ["triage_event", "bucket", "thread_ts"])
          ],
          ":"
        ),
      lane: lane,
      receipt: receipt
    }
  end

  defp persist_receipt!(receipt) do
    "s3://" <> key = receipt["receipt_ref"]
    assert {:ok, _result} = S3.put(key, Jason.encode!(receipt), if_none_match: "*")
  end

  defp admission_receipt(event_id, connect_id, opts \\ []) do
    generation = Keyword.get(opts, :generation, "01JQTRIAGEGENERATION000001")
    message_ts = Keyword.get(opts, :message_ts, "1787019000.000001")
    root_ts = "1787019000.000000"
    key = "ctl/im/receipts/slack/#{connect_id}/#{event_id}.json"

    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => connect_id,
      "event_id" => event_id,
      "connect_generation" => generation,
      "created_at" => 100,
      "receipt_ref" => "s3://" <> key,
      "source_message_ref" =>
        Enum.join([generation, "T_WORKSPACE", "C_CHANNEL", root_ts, message_ts], ":"),
      "triage_event" => %{
        "event_id" => event_id,
        "connect_generation" => generation,
        "message_ts" => message_ts,
        "actor_id" => "U_ACTOR",
        "actor_kind" => "agent",
        "text" => "review this",
        "event_type" => "message",
        "addressing_kind" => "directed",
        "trigger_kind" => "mention",
        "fast_path" => true,
        "addressed_connect" => connect_id,
        "bucket" => %{
          "workspace_id" => "T_WORKSPACE",
          "channel_id" => "C_CHANNEL",
          "thread_ts" => root_ts
        },
        "endpoint_provenance" => %{},
        "source_mode" => "callback"
      }
    }
  end

  defp physical_source(receipt) do
    event = receipt["triage_event"]
    bucket = event["bucket"]

    Enum.join(
      [bucket["workspace_id"], bucket["channel_id"], bucket["thread_ts"], event["message_ts"]],
      ":"
    )
  end

  defp source_ts(receipt), do: get_in(receipt, ["triage_event", "message_ts"])

  defp create_bucket(namespace) do
    key = TriageKeys.ctl_im_triage_bucket(namespace, "scope-a")

    assert {:ok, _result} =
             TriageRecords.put(key, Jason.encode!(bucket("scope-a", "generation-a")),
               if_none_match: "*"
             )
  end

  defp bucket(scope, generation) do
    %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => generation,
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => []
    }
  end

  defp run(run_id) do
    %{
      "schema" => "comma.triage-run.v1",
      "run_id" => run_id,
      "authoritative" => true,
      "created_at" => 1,
      "status" => "replied"
    }
  end

  defp namespace_key(key) do
    [_, namespace_key, _path] =
      Regex.run(~r/\Atriage\/engine-v2\/([0-9a-f]{64})\/(.+)\z/, key)

    namespace_key
  end
end
