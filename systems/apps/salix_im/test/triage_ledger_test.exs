defmodule SalixIM.Triage.LedgerTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.{CanonicalJSON, Ledger}
  alias SalixIM.Triage.Ledger.IdentityActivity
  alias SalixStore.{CasRecord, S3, ULID}

  setup do
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()

    on_exit(fn ->
      if previous_triage_backend do
        Application.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      else
        Application.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "run records are hashed from canonical bytes, not from map iteration order" do
    namespace = "triage-ledger-canonical-#{System.unique_integer([:positive])}"
    run_id = ULID.generate()
    now = System.system_time(:millisecond)

    # Above the 32-key flatmap boundary a map iterates in HAMT order, which is
    # an OTP implementation detail. `Jason.encode!/1` follows it; canonical JSON
    # sorts. A record hashed through Jason would therefore change its identity
    # on an OTP upgrade and invalidate the whole historical ledger.
    wide_input =
      1..40
      |> Map.new(fn ordinal -> {"field_#{ordinal}", "value-#{ordinal}"} end)
      |> Map.put("schema", "comma.triage-input-snapshot.v1")
      |> Map.put("receipt_refs", ["receipt-1"])

    refute Jason.encode!(wide_input) == CanonicalJSON.encode!(wide_input)

    fence = %{
      "schema" => "comma.triage-bucket-fence.v1",
      "bucket_scope" => "canonical-scope",
      "generation" => ULID.generate(),
      "run_id" => run_id,
      "created_at" => now,
      "deadline_at" => now,
      "input_snapshot" => wide_input,
      "terminal" => %{
        "terminal_id" => ULID.generate(),
        "status" => "failed",
        "decision" => %{"action" => "silence", "reason" => "canonical-hash-probe"},
        "evaluator" => %{},
        "settled_at" => now
      }
    }

    assert :ok = Ledger.persist(namespace, fence)

    assert {:ok, run} =
             CasRecord.get(SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id))

    assert {:ok, replay} =
             CasRecord.get(SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id))

    assert run["input_snapshot_sha256"] == sha256(wide_input)

    assert replay["ledger_ref"] ==
             "triage-record://" <>
               SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)

    assert replay["run_sha256"] == sha256(run)

    # And the verifier agrees with the writer, so the record stays readable.
    assert {:ok, ^run} = Ledger.fetch(namespace, run_id)
  end

  # `fetch/2` re-derives the run hash and refuses a run its replay record no
  # longer agrees with. `list/1` returned the same objects with no verification
  # at all, so an operator reading the listing saw a decision no consumer could
  # replay and had no way to tell.
  test "listing drops a run whose replay record no longer agrees with it" do
    namespace = "triage-ledger-listing-#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)
    tampered_run_id = ULID.generate()
    intact_run_id = ULID.generate()

    for run_id <- [tampered_run_id, intact_run_id] do
      assert :ok = Ledger.persist(namespace, legacy_fence(run_id, now))
    end

    run_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, tampered_run_id)

    assert {:ok, _tampered} =
             CasRecord.update(run_key, fn current ->
               put_in(current, ["decision", "reason"], "rewritten-after-the-fact")
             end)

    # The single-object check still catches it on the direct read...
    assert {:error, :invalid_replay} = Ledger.fetch(namespace, tampered_run_id)

    # ...and now the listing refuses to present it as history either.
    assert {:ok, records} = Ledger.list(namespace)
    assert Enum.map(records, & &1["run_id"]) == [intact_run_id]
  end

  defp legacy_fence(run_id, now) do
    %{
      "schema" => "comma.triage-bucket-fence.v1",
      "bucket_scope" => "listing-scope-#{run_id}",
      "generation" => ULID.generate(),
      "run_id" => run_id,
      "created_at" => now,
      "deadline_at" => now,
      "input_snapshot" => %{
        "schema" => "comma.triage-input-snapshot.v1",
        "receipt_refs" => ["receipt-#{run_id}"]
      },
      "terminal" => %{
        "terminal_id" => ULID.generate(),
        "status" => "failed",
        "decision" => %{"action" => "silence", "reason" => "listing-probe"},
        "evaluator" => %{},
        "settled_at" => now
      }
    }
  end

  test "persists one positive-projected non-authoritative late result" do
    namespace = "triage-ledger-#{System.unique_integer([:positive])}"
    run_id = SalixStore.ULID.generate()

    assert :ok =
             Ledger.persist_late(
               namespace,
               %{run_id: run_id, authority_status: "failed"},
               {"failed", %{"action" => "silence", "reason" => "identity_decision_invalid"}, %{}}
             )

    assert {:ok, [record]} = Ledger.list(namespace)

    assert Map.keys(record) |> Enum.sort() ==
             ~w(authoritative authority_status created_at decision evaluator linked_run_id observation_id schema status)

    assert record["schema"] == "comma.triage-late-result.v1"
    assert record["linked_run_id"] == run_id
    assert record["authoritative"] == false
    assert record["status"] == "failed"
    assert record["authority_status"] == "failed"
  end

  # The late record is the only durable evidence that a worker answered after
  # its fence had settled. Discarding the CAS result reported `:ok` while that
  # evidence silently vanished, so the caller had nothing to retry and no signal
  # to log.
  test "a failed late-result write is reported to the caller instead of swallowed" do
    namespace = "triage-ledger-late-failure-#{System.unique_integer([:positive])}"
    run_id = ULID.generate()

    :ok =
      S3.Fake.blackhole(
        {:fail, 503, :put,
         {:prefix, SalixStore.TriageKeys.ctl_im_triage_late_results_prefix(namespace)}}
      )

    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:error, _reason} =
             Ledger.persist_late(
               namespace,
               %{run_id: run_id, authority_status: "failed"},
               {"failed", %{"action" => "silence", "reason" => "identity_decision_invalid"}, %{}}
             )

    assert {:ok, []} = Ledger.list(namespace)
  end

  # A retry must re-`create` the SAME object, not observe the same event twice.
  test "a pinned late observation makes the retry idempotent" do
    namespace = "triage-ledger-late-retry-#{System.unique_integer([:positive])}"
    run_id = ULID.generate()
    observation = Ledger.late_observation()
    parts = {"failed", %{"action" => "silence", "reason" => "identity_decision_invalid"}, %{}}
    authority = %{run_id: run_id, authority_status: "failed"}

    assert :ok = Ledger.persist_late(namespace, authority, parts, observation)
    assert :ok = Ledger.persist_late(namespace, authority, parts, observation)

    assert {:ok, [record]} = Ledger.list(namespace)
    assert record["observation_id"] == observation.observation_id
    assert record["created_at"] == observation.created_at
  end

  test "rejects an unprojected late-result authority map without writing" do
    namespace = "triage-ledger-private-#{System.unique_integer([:positive])}"

    assert {:error, :invalid_late_result_projection} =
             Ledger.persist_late(
               namespace,
               %{
                 run_id: SalixStore.ULID.generate(),
                 authority_status: "failed",
                 identity_winning_input: %{"raw" => "U_PRIVATE"}
               },
               {"failed", %{"action" => "silence"}, %{}}
             )

    assert {:ok, []} = Ledger.list(namespace)
    refute inspect(S3.Fake.put_log()) =~ "U_PRIVATE"
  end

  test "rejects a raw identity fence that has not been authorized by RunFence" do
    namespace = "triage-ledger-raw-fence-#{System.unique_integer([:positive])}"

    raw_fence = %{
      "schema" => "comma.triage-bucket-fence.v2",
      "bucket_scope" => "private-scope",
      "public_bucket_ref" => "bucket://run/scope",
      "generation" => SalixStore.ULID.generate(),
      "run_id" => SalixStore.ULID.generate(),
      "terminal" => %{
        "status" => "failed",
        "decision" => %{"action" => "silence"},
        "evaluator" => %{},
        "settled_at" => System.system_time(:millisecond)
      },
      "input_snapshot" => %{
        "schema" => "comma.triage-ledger-input-projection.v2",
        "receipt_refs" => []
      },
      "identity_observation" => nil
    }

    assert {:error, :invalid_authoritative_projection} =
             Ledger.persist(namespace, raw_fence)

    assert {:ok, []} = Ledger.list(namespace)
    assert S3.Fake.put_log() == []
  end

  test "reads one recent identity-scoped public activity with a fixed key budget" do
    namespace = "triage-ledger-activity-#{System.unique_integer([:positive])}"
    run_id = ULID.generate()
    created_at = System.system_time(:millisecond)
    bundle = identity_bundle("project-current")
    identity_scope_sha256 = identity_scope_sha256(bundle)

    run = %{
      "schema" => "comma.triage-run.v2",
      "run_id" => run_id,
      "bucket" => "bucket://run/scope",
      "authoritative" => true,
      "created_at" => created_at
    }

    run_sha256 = sha256(run)
    run_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)

    assert {:ok, ^run} = CasRecord.create(run_key, run)

    assert {:ok, _replay} =
             CasRecord.create(SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id), %{
               "schema" => "comma.triage-replay.v1",
               "run_id" => run_id,
               "ledger_ref" => "ledger://run/authoritative",
               "run_sha256" => run_sha256
             })

    reverse_created_at =
      (9_999_999_999_999 - created_at)
      |> Integer.to_string()
      |> String.pad_leading(13, "0")

    activity_key =
      SalixStore.TriageKeys.ctl_im_triage_activity_index_entry(
        namespace,
        identity_scope_sha256,
        reverse_created_at,
        run_id
      )

    assert {:ok, _entry} =
             CasRecord.create(activity_key, %{
               "schema" => "comma.triage-activity-index-entry.v1",
               "identity_scope_sha256" => identity_scope_sha256,
               "identity_revision_sha256" => String.duplicate("a", 64),
               "run_id" => run_id,
               "run_sha256" => run_sha256,
               "created_at" => created_at
             })

    assert :ok = S3.Fake.reset_read_log()

    assert {:ok, %IdentityActivity{run: ^run, identity_revision_sha256: revision}} =
             Ledger.recent_identity_activity(namespace, bundle, ULID.generate())

    assert revision == String.duplicate("a", 64)

    reads = S3.Fake.read_log()

    assert [{:list, prefix, [max_keys: 2]}] =
             Enum.filter(reads, &match?({:list, _, _}, &1))

    assert prefix ==
             SalixStore.TriageKeys.ctl_im_triage_activity_index_prefix(
               namespace,
               identity_scope_sha256
             )

    assert Enum.count(reads, &match?({:get, _}, &1)) == 3
    refute Enum.any?(reads, &(inspect(&1) =~ "/seals/"))

    assert :ok = S3.Fake.reset_read_log()

    assert {:error, :not_found} =
             Ledger.recent_identity_activity(
               namespace,
               identity_bundle("project-foreign"),
               ULID.generate()
             )

    assert [{:list, foreign_prefix, [max_keys: 2]}] = S3.Fake.read_log()
    refute foreign_prefix == prefix
  end

  defp identity_bundle(project_id) do
    %{
      "connect_identity" => %{
        "tenant_id" => "tenant-current",
        "group_id" => "group-current"
      },
      "product_identity" => %{
        "project_id" => project_id,
        "agent_id" => "agent-current",
        "salix_agent_id" => "router-current",
        "agent_role" => "router"
      },
      "raw_identity_context" => %{
        "self_agent" => %{
          "identity_revision_sha256" => String.duplicate("a", 64)
        }
      }
    }
  end

  defp identity_scope_sha256(bundle) do
    %{
      "schema" => "comma.triage-activity-scope.v1",
      "tenant_id" => get_in(bundle, ["connect_identity", "tenant_id"]),
      "group_id" => get_in(bundle, ["connect_identity", "group_id"]),
      "project_id" => get_in(bundle, ["product_identity", "project_id"]),
      "agent_id" => get_in(bundle, ["product_identity", "agent_id"]),
      "salix_agent_id" => get_in(bundle, ["product_identity", "salix_agent_id"]),
      "agent_role" => get_in(bundle, ["product_identity", "agent_role"])
    }
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp sha256(value) do
    value
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end
end
