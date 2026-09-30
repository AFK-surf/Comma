defmodule SalixIM.Triage.ActivityProjection do
  @moduledoc """
  Bounded current-Router activity projection over authoritative Ledger/replay.

  Private identity bundles are used only to enforce the same tenant, project,
  Router principal, and revision relationship. Returned authorization contains
  only the closed model-safe summary and one opaque run target. Ledger/replay
  remains the activity source of truth.

  Review lifecycle projection is intentionally limited to review and
  supersession evidence. Product effects are owned by `TriageProductRuntime`
  and direct provider ports; Router Conversation delivery records are not a
  Triage effect source.
  """

  alias SalixIM.Triage.{CanonicalJSON, Ledger}
  alias SalixIM.Triage.Ledger.IdentityActivity
  alias SalixStore.{CasRecord, ULID}

  @review_artifact_keys ~w(
    artifact_id decision delivery_mode executed_actions proposed_slack_request readback schema
    target
  )

  def authorize(namespace, fence, run_id, raw_bundle) do
    with {:ok,
          %IdentityActivity{
            run: prior_run,
            identity_revision_sha256: prior_identity_revision_sha256
          }} <- Ledger.recent_identity_activity(namespace, raw_bundle, fence["run_id"]),
         {:ok, target} <-
           identity_history_target(
             namespace,
             prior_run,
             prior_identity_revision_sha256,
             raw_bundle
           ),
         summary = %{
           "schema" => "comma.triage-activity-summary.v1",
           "as_of_ms" => fence["created_at"],
           "items" => [Map.fetch!(target, "summary")]
         },
         authorization = %{
           "schema" => "comma.triage-history-read-authorization.v1",
           "tool_name" => "triage_run.get",
           "agent_id" => get_in(raw_bundle, ["product_identity", "salix_agent_id"]),
           "session_id" => run_id,
           "tenant_id" => get_in(raw_bundle, ["connect_identity", "tenant_id"]),
           "group_id" => get_in(raw_bundle, ["connect_identity", "group_id"]),
           "role" => get_in(raw_bundle, ["product_identity", "agent_role"]),
           "runtime_kind" => "internal",
           "history_summary" => summary,
           "history_targets" => [target]
         },
         true <- valid_identity_history_authorization?(authorization) do
      {:ok, authorization}
    else
      _unavailable -> {:ok, nil}
    end
  end

  defp identity_history_target(
         namespace,
         prior_run,
         prior_identity_revision_sha256,
         current_bundle
       ) do
    current_revision =
      get_in(current_bundle, ["raw_identity_context", "self_agent", "identity_revision_sha256"])

    prior_revision = prior_identity_revision_sha256

    run_ref = "triage-run://current/r001"

    with true <- valid_sha256?(current_revision),
         true <- valid_sha256?(prior_revision) do
      revision_relation = if current_revision == prior_revision, do: "current", else: "prior"

      case verified_review_artifact(prior_run) do
        {:ok, _artifact} ->
          identity_proposal_history_target(namespace, prior_run, run_ref, revision_relation)

        :none ->
          identity_source_observed_history_target(
            namespace,
            prior_run,
            run_ref,
            revision_relation
          )

        :error ->
          {:error, :identity_fence_denied}
      end
    else
      _invalid_revision -> {:error, :identity_fence_denied}
    end
  end

  # Branching on the artifact's SHAPE ignored the hash the run stores next to
  # it, so a rewritten artifact whose readback still read `review_only_not_sent`
  # decided this projection's lifecycle claim. Dispatch on the schema string and
  # the exact key set like every other consumer, and re-derive the hash before
  # any of it is used: an identity-mode prior run always carries the v2
  # artifact, so a v1 artifact here is interchange, not history.
  defp verified_review_artifact(prior_run) do
    case {Map.fetch(prior_run, "review_artifact"), Map.fetch(prior_run, "review_artifact_sha256")} do
      {:error, :error} ->
        :none

      {{:ok, artifact}, {:ok, sha256}} ->
        if exact_review_artifact?(artifact, sha256), do: {:ok, artifact}, else: :error

      _partial ->
        :error
    end
  end

  defp exact_review_artifact?(artifact, sha256) when is_map(artifact) and is_binary(sha256) do
    with true <- Enum.sort(Map.keys(artifact)) == Enum.sort(@review_artifact_keys),
         "comma.triage-review-artifact.v2" <- artifact["schema"],
         {:ok, bytes} <- CanonicalJSON.encode(artifact),
         true <- CanonicalJSON.sha256(bytes) == sha256,
         %{"status" => "review_only_not_sent"} <- artifact["readback"],
         [] <- artifact["executed_actions"] do
      true
    else
      _invalid -> false
    end
  end

  defp exact_review_artifact?(_artifact, _sha256), do: false

  defp identity_proposal_history_target(
         namespace,
         prior_run,
         run_ref,
         revision_relation
       ) do
    decision = prior_run["decision"]

    with true <- is_map(decision),
         true <- decision["action"] in ~w(silence reply react delegate remember),
         {:ok, lifecycle} <- identity_history_lifecycle(namespace, prior_run) do
      summary =
        identity_history_summary(run_ref, lifecycle, revision_relation)

      result =
        %{
          "schema" => "comma.triage-run-history-result.v1",
          "run_ref" => run_ref,
          "lifecycle_state" => summary["lifecycle_state"],
          "review_state" => summary["review_state"],
          "effect_state" => summary["effect_state"],
          "source_relation" => summary["source_relation"],
          "revision_relation" => summary["revision_relation"],
          "proposal" => %{
            "action" => decision["action"],
            "text" => decision["text"]
          }
        }
        |> maybe_put_history_effect(lifecycle)

      {:ok, build_identity_history_target(run_ref, prior_run["run_id"], summary, result)}
    else
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp identity_source_observed_history_target(
         namespace,
         prior_run,
         run_ref,
         revision_relation
       ) do
    lifecycle = %{
      "lifecycle_state" => "source_observed",
      "review_state" => "not_reviewed",
      "effect_state" => "not_executed"
    }

    with "failed" <- prior_run["status"],
         %{"action" => "silence", "reason" => reason} <- prior_run["decision"],
         true <- nonempty?(reason),
         %{} = evaluator <- prior_run["evaluator"],
         true <- map_size(evaluator) == 0,
         source_refs when is_list(source_refs) and source_refs != [] <- prior_run["source_refs"],
         true <- Enum.all?(source_refs, &nonempty?/1),
         :ok <- identity_history_events_absent(namespace, prior_run["run_id"]) do
      summary = identity_history_summary(run_ref, lifecycle, revision_relation)

      result = %{
        "schema" => "comma.triage-run-history-result.v1",
        "run_ref" => run_ref,
        "lifecycle_state" => summary["lifecycle_state"],
        "review_state" => summary["review_state"],
        "effect_state" => summary["effect_state"],
        "source_relation" => summary["source_relation"],
        "revision_relation" => summary["revision_relation"]
      }

      {:ok, build_identity_history_target(run_ref, prior_run["run_id"], summary, result)}
    else
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp identity_history_summary(run_ref, lifecycle, revision_relation) do
    %{
      "run_ref" => run_ref,
      "lifecycle_state" => lifecycle["lifecycle_state"],
      "review_state" => lifecycle["review_state"],
      "effect_state" => lifecycle["effect_state"],
      "source_relation" => "same_project_router",
      "revision_relation" => revision_relation
    }
  end

  defp build_identity_history_target(run_ref, private_run_id, summary, result) do
    %{
      "run_ref" => run_ref,
      "private_run_id" => private_run_id,
      "summary" => summary,
      "result" => result
    }
  end

  defp identity_history_events_absent(namespace, run_id) do
    prefix = SalixStore.TriageKeys.ctl_im_triage_lifecycle_events_prefix(namespace, run_id)

    case SalixStore.TriageRecordStore.list(prefix, max_keys: 1) do
      {:ok, %{objects: [], next: nil}} -> :ok
      _present_or_unavailable -> {:error, :identity_fence_denied}
    end
  end

  defp identity_history_lifecycle(namespace, prior_run) do
    prefix =
      SalixStore.TriageKeys.ctl_im_triage_lifecycle_events_prefix(namespace, prior_run["run_id"])

    with {:ok, %{objects: objects, next: nil}} <-
           SalixStore.TriageRecordStore.list(prefix, max_keys: 3),
         true <- length(objects) <= 2,
         {:ok, events} <- read_identity_lifecycle_events(objects),
         {:ok, lifecycle} <-
           project_identity_lifecycle(events, prior_run, namespace) do
      {:ok, lifecycle}
    else
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp read_identity_lifecycle_events(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, events} ->
      case CasRecord.get(key) do
        {:ok, event} -> {:cont, {:ok, [{key, event} | events]}}
        _invalid -> {:halt, {:error, :identity_fence_denied}}
      end
    end)
    |> case do
      {:ok, events} ->
        {:ok,
         Enum.sort_by(events, fn {_key, event} ->
           {event["observed_at_ms"] || 0, event["event_id"] || ""}
         end)}

      error ->
        error
    end
  end

  defp project_identity_lifecycle([], _prior_run, _namespace) do
    {:ok,
     %{
       "lifecycle_state" => "decision_proposed",
       "review_state" => "not_reviewed",
       "effect_state" => "not_executed"
     }}
  end

  defp project_identity_lifecycle(
         [{review_key, review_event}],
         prior_run,
         namespace
       ) do
    with {:ok, review_state} <-
           validate_review_event(review_key, review_event, prior_run, namespace) do
      {:ok,
       %{
         "lifecycle_state" => review_state,
         "review_state" => review_state,
         "effect_state" => "not_executed"
       }}
    end
  end

  defp project_identity_lifecycle(
         [
           {review_key, review_event},
           {supersession_key, %{"event_type" => "proposal_superseded"} = supersession_event}
         ],
         prior_run,
         namespace
       ) do
    with :ok <- validate_review_approved_event(review_key, review_event, prior_run, namespace),
         {:ok, supersession_receipt} <-
           validate_supersession_event(
             supersession_key,
             supersession_event,
             review_event,
             prior_run,
             namespace
           ) do
      {:ok,
       %{
         "lifecycle_state" => "superseded",
         "review_state" => "review_approved",
         "effect_state" => "not_executed",
         "supersession_receipt" => supersession_receipt
       }}
    end
  end

  defp project_identity_lifecycle(_events, _prior_run, _namespace),
    do: {:error, :identity_fence_denied}

  defp validate_review_approved_event(key, event, prior_run, namespace) do
    case validate_review_event(key, event, prior_run, namespace) do
      {:ok, "review_approved"} -> :ok
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp validate_review_event(key, event, prior_run, namespace) do
    receipt = event["receipt"]

    review_state =
      case {event["event_type"], is_map(receipt) && receipt["status"]} do
        {"review_approved", "approved"} -> "review_approved"
        {"review_rejected", "rejected"} -> "review_rejected"
        _invalid -> nil
      end

    valid? =
      exact_map_keys?(
        event,
        ~w(schema event_id run_id run_sha256 proposal_sha256 event_type causal_event_id receipt observed_at_ms)
      ) and event["schema"] == "comma.triage-lifecycle-event.v1" and
        ULID.valid?(event["event_id"]) and event["run_id"] == prior_run["run_id"] and
        event["run_sha256"] == sha256(prior_run) and
        event["proposal_sha256"] == sha256(prior_run["decision"]) and
        not is_nil(review_state) and is_nil(event["causal_event_id"]) and
        key ==
          SalixStore.TriageKeys.ctl_im_triage_lifecycle_event(
            namespace,
            event["run_id"],
            event["event_id"]
          ) and
        exact_map_keys?(receipt, ~w(schema status reviewer_ref reviewed_at_ms)) and
        receipt["schema"] == "comma.triage-review-receipt.v1" and
        nonempty?(receipt["reviewer_ref"]) and
        positive_integer?(receipt["reviewed_at_ms"]) and
        event["observed_at_ms"] == receipt["reviewed_at_ms"]

    if valid?, do: {:ok, review_state}, else: {:error, :identity_fence_denied}
  end

  defp validate_supersession_event(key, event, review_event, prior_run, namespace) do
    receipt = event["receipt"]

    valid? =
      valid_lifecycle_event_envelope?(
        key,
        event,
        review_event,
        prior_run,
        namespace,
        "proposal_superseded"
      ) and
        exact_map_keys?(
          receipt,
          ~w(schema status successor_proposal_ref successor_proposal_sha256 superseded_at_ms)
        ) and receipt["schema"] == "comma.triage-supersession-receipt.v1" and
        receipt["status"] == "superseded" and
        receipt["successor_proposal_ref"] == "triage-proposal://current/p002" and
        valid_sha256?(receipt["successor_proposal_sha256"]) and
        receipt["successor_proposal_sha256"] != event["proposal_sha256"] and
        positive_integer?(receipt["superseded_at_ms"]) and
        event["observed_at_ms"] == receipt["superseded_at_ms"] and
        event["observed_at_ms"] >= review_event["observed_at_ms"]

    if valid? do
      {:ok,
       %{
         "schema" => receipt["schema"],
         "status" => receipt["status"],
         "successor_proposal_ref" => receipt["successor_proposal_ref"],
         "successor_proposal_sha256" => receipt["successor_proposal_sha256"],
         "observed_at_ms" => receipt["superseded_at_ms"]
       }}
    else
      {:error, :identity_fence_denied}
    end
  end

  defp valid_lifecycle_event_envelope?(
         key,
         event,
         review_event,
         prior_run,
         namespace,
         event_type
       ) do
    exact_map_keys?(
      event,
      ~w(schema event_id run_id run_sha256 proposal_sha256 event_type causal_event_id receipt observed_at_ms)
    ) and event["schema"] == "comma.triage-lifecycle-event.v1" and
      ULID.valid?(event["event_id"]) and event["run_id"] == prior_run["run_id"] and
      event["run_sha256"] == sha256(prior_run) and
      event["proposal_sha256"] == sha256(prior_run["decision"]) and
      event["event_type"] == event_type and
      event["causal_event_id"] == review_event["event_id"] and
      key ==
        SalixStore.TriageKeys.ctl_im_triage_lifecycle_event(
          namespace,
          event["run_id"],
          event["event_id"]
        )
  end

  defp maybe_put_history_effect(result, %{"supersession_receipt" => receipt}),
    do: Map.put(result, "supersession_receipt", receipt)

  defp maybe_put_history_effect(result, _lifecycle), do: result

  defp valid_identity_history_authorization?(authorization) do
    exact_map_keys?(
      authorization,
      ~w(schema tool_name agent_id session_id tenant_id group_id role runtime_kind history_summary history_targets)
    ) and authorization["schema"] == "comma.triage-history-read-authorization.v1" and
      authorization["tool_name"] == "triage_run.get" and
      authorization["runtime_kind"] == "internal" and
      Enum.all?(~w(agent_id session_id tenant_id group_id role), &nonempty?(authorization[&1])) and
      match?(
        %{"schema" => "comma.triage-activity-summary.v1", "items" => [_]},
        authorization["history_summary"]
      ) and
      match?([%{"run_ref" => "triage-run://current/r001"}], authorization["history_targets"])
  end

  defp exact_map_keys?(map, keys) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_map_keys?(_map, _keys), do: false
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  # Record hashes must be reproducible across OTP releases. Jason follows the
  # map's own iteration order, which above the 32-key flatmap boundary is a HAMT
  # implementation detail, so an OTP upgrade would silently invalidate every
  # historical hash. CanonicalJSON sorts keys, so the bytes are the record's.
  defp sha256(value) do
    value
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end
end
