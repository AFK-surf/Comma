defmodule SalixIM.Triage.ActivityProjectionTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.{ActivityProjection, CanonicalJSON}
  alias SalixStore.{CasRecord, S3, TriageKeys, ULID}

  @max_activity_created_at 9_999_999_999_999
  @review_artifact_keys ~w(
    artifact_id decision delivery_mode executed_actions proposed_slack_request readback schema
    target
  )

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

  test "returns no bounded self-history authorization when Ledger has no prior run" do
    namespace = "triage-activity-empty-#{System.unique_integer([:positive])}"
    run_id = SalixStore.ULID.generate()

    # A background reader shares this fake, but not this authorization request.
    assert {:ok, :buckets, [], _, _, 0} =
             Task.async(fn ->
               SalixIM.Triage.Recovery.step(
                 namespace <> "-background",
                 50,
                 SalixIM.Triage.Recovery.cursor()
               )
             end)
             |> Task.await()

    assert {:ok, nil} =
             ActivityProjection.authorize(
               namespace,
               %{"run_id" => run_id, "created_at" => System.system_time(:millisecond)},
               run_id,
               identity_bundle()
             )

    namespace_prefix = "triage/engine-v2/#{TriageKeys.namespace_key(namespace)}/"

    refute Enum.any?(S3.Fake.put_log(), &String.starts_with?(&1, namespace_prefix))

    assert [{:list, prefix, [max_keys: 2]}] = S3.Fake.read_log(self())
    assert prefix =~ "/ledger/activity/"
    refute prefix =~ "/seals/"
  end

  test "authorizes one bounded proposal history target from an intact prior run" do
    namespace = seed_prior_run(review_artifact())

    assert {:ok, authorization} = authorize(namespace)
    assert authorization["tool_name"] == "triage_run.get"
    assert [target] = authorization["history_targets"]
    assert target["run_ref"] == "triage-run://current/r001"
    assert target["result"]["lifecycle_state"] == "decision_proposed"
  end

  # The branch used to read the artifact's SHAPE and ignore the hash stored
  # beside it, so an artifact rewritten in place — still carrying a
  # `review_only_not_sent` readback — decided this projection's lifecycle claim.
  test "a review artifact that disagrees with its stored hash is refused" do
    tampered = put_in(review_artifact(), ["decision", "text"], "rewritten after the fact")
    namespace = seed_prior_run(tampered, sha256_of: review_artifact())

    assert {:ok, nil} = authorize(namespace)
  end

  # v1 and v2 artifacts share the readback shape this branch used to match on,
  # and an identity-mode prior run always carries v2. A v1 artifact here is
  # schema interchange, not history.
  test "a v1 review artifact is refused instead of read as identity history" do
    v1_artifact = Map.put(review_artifact(), "schema", "comma.triage-review-artifact.v1")
    namespace = seed_prior_run(v1_artifact)

    assert {:ok, nil} = authorize(namespace)
  end

  test "a review artifact with an unexpected extra key is refused" do
    extra = Map.put(review_artifact(), "delivered_at", 1)
    namespace = seed_prior_run(extra)

    assert {:ok, nil} = authorize(namespace)
  end

  defp authorize(namespace) do
    current_run_id = ULID.generate()

    ActivityProjection.authorize(
      namespace,
      %{"run_id" => current_run_id, "created_at" => System.system_time(:millisecond)},
      current_run_id,
      identity_bundle()
    )
  end

  # Writes the exact durable objects `Ledger.recent_identity_activity/3` reads:
  # one authoritative run, its agreeing replay record, and one activity index
  # entry for this Router identity scope.
  defp seed_prior_run(artifact, opts \\ []) do
    namespace = "triage-activity-prior-#{System.unique_integer([:positive])}"
    run_id = ULID.generate()
    created_at = System.system_time(:millisecond)
    hashed = Keyword.get(opts, :sha256_of, artifact)

    run =
      %{
        "schema" => "comma.triage-run.v2",
        "run_id" => run_id,
        "bucket" => "bucket://run/scope",
        "generation" => ULID.generate(),
        "authoritative" => true,
        "created_at" => created_at,
        "status" => "evaluated",
        "decision" => %{"action" => "reply", "text" => "the spec is in the thread"},
        "evaluator" => %{"schema" => "comma.triage-model-proof.v1"},
        "review_artifact" => artifact,
        "review_artifact_sha256" => sha256(hashed)
      }

    assert {:ok, ^run} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id),
               run
             )

    replay = %{
      "schema" => "comma.triage-replay.v1",
      "run_id" => run_id,
      "ledger_ref" => "ledger://run/authoritative",
      "run_sha256" => sha256(run)
    }

    assert {:ok, ^replay} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id),
               replay
             )

    entry = %{
      "schema" => "comma.triage-activity-index-entry.v1",
      "identity_scope_sha256" => identity_scope_sha256(),
      "identity_revision_sha256" => String.duplicate("a", 64),
      "run_id" => run_id,
      "run_sha256" => sha256(run),
      "created_at" => created_at
    }

    key =
      SalixStore.TriageKeys.ctl_im_triage_activity_index_entry(
        namespace,
        identity_scope_sha256(),
        reverse_created_at(created_at),
        run_id
      )

    assert {:ok, ^entry} = CasRecord.create(key, entry)

    namespace
  end

  defp review_artifact do
    artifact = %{
      "schema" => "comma.triage-review-artifact.v2",
      "delivery_mode" => "review",
      "target" => %{
        "provider" => "slack",
        "workspace_id" => "T_ATLAS",
        "channel_id" => "C_ATLAS",
        "thread_ts" => "1787019000.000000"
      },
      "decision" => %{"action" => "reply", "text" => "the spec is in the thread"},
      "proposed_slack_request" => nil,
      "executed_actions" => [],
      "readback" => %{
        "status" => "review_only_not_sent",
        "slack_writes" => 0,
        "worker_starts" => 0,
        "memory_writes" => 0
      }
    }

    artifact = Map.put(artifact, "artifact_id", "triage-review-" <> sha256(artifact))
    assert Enum.sort(Map.keys(artifact)) == Enum.sort(@review_artifact_keys)
    artifact
  end

  defp identity_scope_sha256 do
    sha256(%{
      "schema" => "comma.triage-activity-scope.v1",
      "tenant_id" => "tenant-current",
      "group_id" => "group-current",
      "project_id" => "project-current",
      "agent_id" => "agent-current",
      "salix_agent_id" => "router-current",
      "agent_role" => "router"
    })
  end

  defp reverse_created_at(created_at) do
    (@max_activity_created_at - created_at)
    |> Integer.to_string()
    |> String.pad_leading(13, "0")
  end

  defp sha256(value), do: value |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

  defp identity_bundle do
    %{
      "connect_identity" => %{
        "tenant_id" => "tenant-current",
        "group_id" => "group-current"
      },
      "product_identity" => %{
        "project_id" => "project-current",
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
end
