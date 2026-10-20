defmodule SalixIM.Triage.LedgerTest do
  use SystemsClock.Case, async: false

  alias SalixIM.Triage.{CanonicalJSON, Ledger}
  alias SalixIM.Triage.Ledger.IdentityActivity
  alias SalixStore.{CasRecord, S3, ULID}

  setup do
    previous_triage_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()

    on_exit(fn ->
      if previous_triage_backend do
        SystemsRuntime.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      else
        SystemsRuntime.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "persists one positive-projected non-authoritative late result" do
    namespace = "triage-ledger-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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

  test "rejects a raw identity fence that has not been authorized by RunFence" do
    namespace = "triage-ledger-raw-fence-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
        "settled_at" => SystemsClock.system_time(:millisecond)
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
    namespace = "triage-ledger-activity-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    run_id = ULID.generate()
    created_at = SystemsClock.system_time(:millisecond)
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
