defmodule SalixIM.Triage.Ledger do
  @moduledoc """
  Positive projection and durable storage for authoritative Triage runs.

  RunFence decides whether an identity fence may be published. This module
  receives an already-authorized projection, constructs only the public
  run/replay schemas, and makes those writes idempotent. Frozen v1 callers keep
  their legacy compatibility path.

  ## Threat model

  What every read here detects: a run record edited on its own. The replay
  record holds `run_sha256`, so changing a decision, status, proof, or timestamp
  in the run without also rewriting its replay record makes the pair disagree,
  and `fetch/2` and `list/1` both refuse the run.

  What it does NOT detect:

    * A COORDINATED REWRITE. Anyone who can write both records can rewrite the
      run and recompute `run_sha256` in the replay record; the pair agrees and
      every consumer accepts it. There is no chain over runs, no per-namespace
      head, and no external anchor, so nothing ties one run to the runs before
      it.
    * DELETION. Nothing counts runs or links them in sequence, so removing a run
      and its replay record together leaves no gap for anyone to notice.
    * BACKDATING. `created_at` is a field of the run and is covered by the run
      hash, which the same rewrite recomputes; no independent clock witnesses it.

  In other words this is single-record integrity, not tamper-evidence against
  the storage writer. The durable guarantee is "no consumer reads a
  half-rewritten record", not "no operator can forge history".
  """

  require Logger

  alias SalixIM.Triage.{CanonicalJSON, Correlation, RunFence}
  alias SalixIM.Triage.RunFence.AuthorizedProjection
  alias SalixStore.{CasRecord, ULID}

  defmodule IdentityActivity do
    @moduledoc false

    @enforce_keys [:run, :identity_revision_sha256]
    defstruct [:run, :identity_revision_sha256]

    @opaque t :: %__MODULE__{run: map(), identity_revision_sha256: String.t()}
  end

  @run_schema "comma.triage-run.v1"
  @identity_read_tools ~w(web.read_pages triage.slack_read_permalink triage_run.get)
  @identity_activity_schema "comma.triage-activity-index-entry.v1"
  @identity_activity_scan_budget 2
  @max_activity_created_at 9_999_999_999_999

  @doc """
  Lists the durable Triage records for one namespace.

  Every authoritative run is re-verified through the same replay/run agreement
  `fetch/2` enforces, and a run that fails it is DROPPED from the listing rather
  than returned unverified: a listing is read as a statement about what
  happened, so an entry no consumer could replay must not appear in it. The drop
  is logged and the underlying records are left untouched for repair.

  Late results carry no replay record — they are explicitly non-authoritative
  observations — and are listed as stored. See the module "Threat model" for
  what this verification does and does not prove.
  """
  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(namespace) do
    with {:ok, authoritative} <-
           list_records(SalixStore.TriageKeys.ctl_im_triage_ledger_runs_prefix(namespace)),
         {:ok, late} <-
           list_records(SalixStore.TriageKeys.ctl_im_triage_late_results_prefix(namespace)) do
      {:ok,
       Enum.sort_by(
         verified_runs(namespace, authoritative) ++ late,
         &{&1["created_at"] || 0, &1["run_id"] || &1["observation_id"]}
       )}
    end
  end

  defp verified_runs(namespace, runs) do
    Enum.filter(runs, fn run ->
      case fetch(namespace, run["run_id"]) do
        {:ok, ^run} ->
          true

        _unverified ->
          Logger.error(
            "triage ledger listing dropped an unverified run: " <>
              "run_id=#{inspect(run["run_id"])}; its replay record does not agree with the " <>
              "stored run and no consumer can replay it"
          )

          false
      end
    end)
  end

  def fetch(namespace, run_id) do
    replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id)
    run_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)

    with {:ok, replay} <- CasRecord.get(replay_key),
         true <- replay["run_id"] == run_id,
         {:ok, run} <- CasRecord.get(run_key),
         true <- valid_replay_ledger_ref?(replay["ledger_ref"], run_key, run),
         true <- replay["run_sha256"] == sha256(run) do
      {:ok, run}
    else
      false -> {:error, :invalid_replay}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetches one replay/run pair while charging every decoded body to the byte budget."
  def fetch_bounded(namespace, run_id, max_bytes)
      when is_binary(namespace) and namespace != "" and is_binary(run_id) and run_id != "" and
             is_integer(max_bytes) and max_bytes > 0 do
    replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id)
    run_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)

    case CasRecord.get_bounded(replay_key, max_bytes) do
      {:ok, replay, replay_bytes} ->
        fetch_bounded_run(
          run_key,
          run_id,
          replay,
          replay_bytes,
          max_bytes - replay_bytes
        )

      {:error, reason, bytes} ->
        {:error, reason, bytes}
    end
  end

  def fetch_bounded(_namespace, _run_id, _max_bytes),
    do: {:error, :invalid_replay, 0}

  defp fetch_bounded_run(_run_key, _run_id, _replay, replay_bytes, remaining)
       when remaining <= 0,
       do: {:error, :too_large, replay_bytes}

  defp fetch_bounded_run(run_key, run_id, replay, replay_bytes, remaining) do
    case CasRecord.get_bounded(run_key, remaining) do
      {:ok, run, run_bytes} ->
        bytes = replay_bytes + run_bytes

        if replay["run_id"] == run_id and
             valid_replay_ledger_ref?(replay["ledger_ref"], run_key, run) and
             replay["run_sha256"] == sha256(run) do
          {:ok, run, bytes}
        else
          {:error, :invalid_replay, bytes}
        end

      {:error, reason, run_bytes} ->
        {:error, reason, replay_bytes + run_bytes}
    end
  end

  @doc "Returns at most one recent public run for the exact current Router identity."
  @spec recent_identity_activity(String.t(), map(), String.t()) ::
          {:ok, IdentityActivity.t()} | {:error, :not_found | :identity_activity_unavailable}
  def recent_identity_activity(namespace, raw_bundle, excluded_run_id)
      when is_binary(namespace) and namespace != "" and is_map(raw_bundle) and
             is_binary(excluded_run_id) and excluded_run_id != "" do
    with {:ok, binding} <- identity_activity_binding(raw_bundle),
         prefix =
           SalixStore.TriageKeys.ctl_im_triage_activity_index_prefix(
             namespace,
             binding.identity_scope_sha256
           ),
         {:ok, %{objects: objects}} <-
           SalixStore.TriageRecordStore.list(prefix, max_keys: @identity_activity_scan_budget),
         true <- length(objects) <= @identity_activity_scan_budget,
         {:ok, entries} <- read_identity_activity_entries(namespace, binding, objects),
         {:ok, entry} <- select_identity_activity_entry(entries, excluded_run_id),
         {:ok, run} <- fetch(namespace, entry["run_id"]),
         true <- run["authoritative"] == true,
         true <- run["created_at"] == entry["created_at"],
         true <- sha256(run) == entry["run_sha256"] do
      {:ok,
       %IdentityActivity{
         run: run,
         identity_revision_sha256: entry["identity_revision_sha256"]
       }}
    else
      {:error, :not_found} -> {:error, :not_found}
      _unavailable -> {:error, :identity_activity_unavailable}
    end
  end

  def recent_identity_activity(_namespace, _raw_bundle, _excluded_run_id),
    do: {:error, :identity_activity_unavailable}

  def persist(namespace, %AuthorizedProjection{fence: fence, correlations: correlations}),
    do: persist_fence(namespace, fence, correlations)

  # Frozen legacy writers keep their existing compatibility path. Identity v2
  # publication must arrive through RunFence's authorized projection value.
  def persist(namespace, %{"schema" => "comma.triage-bucket-fence.v1"} = fence),
    do: persist_fence(namespace, fence, [])

  def persist(_namespace, _fence), do: {:error, :invalid_authoritative_projection}

  @doc "Builds immutable run/replay evidence and a durable projector obligation."
  @spec prepare_authoritative(String.t(), AuthorizedProjection.t() | map()) ::
          {:ok, map()} | {:error, term()}
  def prepare_authoritative(
        namespace,
        %AuthorizedProjection{fence: fence, correlations: correlations}
      ),
      do: prepare_fence_records(namespace, fence, correlations)

  def prepare_authoritative(namespace, %{"schema" => "comma.triage-bucket-fence.v1"} = fence),
    do: prepare_fence_records(namespace, fence, [])

  def prepare_authoritative(_namespace, _projection),
    do: {:error, :invalid_authoritative_projection}

  @doc "Idempotently materializes every derived projection for one committed run."
  @spec project_derived(String.t(), AuthorizedProjection.t() | map(), map()) ::
          :ok | {:error, term()}
  def project_derived(
        namespace,
        %AuthorizedProjection{fence: fence, correlations: correlations},
        run
      )
      when is_binary(namespace) and namespace != "" and is_map(run) do
    project_derived(namespace, fence, correlations, run)
  end

  def project_derived(namespace, %{"schema" => "comma.triage-bucket-fence.v1"} = fence, run)
      when is_binary(namespace) and namespace != "" and is_map(run),
      do: project_derived(namespace, fence, [], run)

  def project_derived(_namespace, _projection, _run),
    do: {:error, :invalid_authoritative_projection}

  @doc "Declares the exact derived views one authorized projection must converge."
  @spec projection_requirements(AuthorizedProjection.t() | map()) ::
          {:ok, %{activity_required: boolean(), time_required: true}}
          | {:error, :invalid_authoritative_projection}
  def projection_requirements(%AuthorizedProjection{fence: fence}),
    do: projection_requirements(fence)

  def projection_requirements(%{"schema" => schema} = fence)
      when schema in ["comma.triage-bucket-fence.v1", "comma.triage-bucket-fence.v2"] do
    {:ok,
     %{
       activity_required: identity_activity_required?(fence),
       time_required: true
     }}
  end

  def projection_requirements(_projection),
    do: {:error, :invalid_authoritative_projection}

  defp persist_fence(namespace, fence, correlations) do
    with {:ok, prepared} <- prepare_fence_records(namespace, fence, correlations),
         :ok <- create_or_same(prepared.run_key, prepared.run),
         :ok <- create_or_same(prepared.replay_key, prepared.replay),
         :ok <- project_derived(namespace, fence, correlations, prepared.run) do
      :ok
    end
  end

  defp project_derived(namespace, fence, correlations, run) do
    with true <- run["authoritative"] == true,
         true <- fence["run_id"] == run["run_id"],
         :ok <- maybe_persist_identity_activity_index(namespace, fence, run),
         :ok <- Correlation.persist(namespace, correlations, run) do
      :ok
    else
      false -> {:error, :invalid_authoritative_projection}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_fence_records(namespace, fence, correlations) do
    identity_diagnostic? = fence["schema"] == "comma.triage-bucket-fence.v2"
    terminal = fence["terminal"]
    input = fence["input_snapshot"]

    bucket =
      if identity_diagnostic?, do: fence["public_bucket_ref"], else: fence["bucket_scope"]

    ledger_ref =
      if identity_diagnostic?,
        do: "ledger://run/authoritative",
        else:
          "triage-record://" <>
            SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, fence["run_id"])

    input_receipt_refs =
      case input do
        %{"schema" => "comma.triage-model-input.v3", "snapshot" => snapshot} ->
          snapshot["receipt_refs"]

        _other ->
          input["receipt_refs"]
      end

    base_run =
      %{
        "schema" => @run_schema,
        "run_id" => fence["run_id"],
        "bucket" => bucket,
        "generation" => fence["generation"],
        "authoritative" => true,
        "created_at" => terminal["settled_at"],
        "status" => terminal["status"],
        "input_receipt_refs" => input_receipt_refs,
        "input_snapshot" => input,
        "input_snapshot_sha256" => sha256(input),
        "decision" => terminal["decision"],
        "evaluator" => terminal["evaluator"]
      }
      |> enrich_native_run(input, terminal["evaluator"])

    run_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, fence["run_id"])
    replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, fence["run_id"])

    with {:ok, run} <-
           maybe_put_committed_read_tool_observation(base_run, fence["identity_observation"]) do
      replay = %{
        "schema" => "comma.triage-replay.v1",
        "run_id" => fence["run_id"],
        "ledger_ref" => ledger_ref,
        "run_sha256" => sha256(run)
      }

      obligation = %{
        "schema" => "comma.triage-projection-obligation.v1",
        "run_id" => fence["run_id"],
        "correlations" => correlations,
        "activity_required" => identity_activity_required?(fence),
        "time_required" => true
      }

      {:ok,
       %{
         fence: fence,
         correlations: correlations,
         run_key: run_key,
         run: run,
         replay_key: replay_key,
         replay: replay,
         obligation: obligation
       }}
    end
  end

  @doc """
  Persists one non-authoritative late observation and returns the CAS outcome.

  The late record is the only durable evidence that a worker's answer arrived
  after its fence had already settled, so a discarded storage error here
  silently deletes that evidence instead of failing. Callers own a bounded
  retry; `observation` pins the record's identity (id and timestamp) across
  those retries, so a retry is an idempotent re-`create` of the same record
  rather than a second observation of the same event.
  """
  @spec persist_late(String.t(), map(), {String.t(), map(), map()}, map() | nil) ::
          :ok | {:error, term()}
  def persist_late(namespace, authority, result_parts, observation \\ nil)

  def persist_late(
        namespace,
        %{run_id: run_id, authority_status: authority_status} = authority,
        {status, decision, evaluator},
        observation
      )
      when is_binary(namespace) and namespace != "" and map_size(authority) == 2 and
             is_binary(run_id) and run_id != "" and is_binary(authority_status) and
             authority_status != "" and is_binary(status) and status != "" and is_map(decision) and
             is_map(evaluator) do
    {observation_id, created_at} = late_observation(observation)

    record = %{
      "schema" => "comma.triage-late-result.v1",
      "observation_id" => observation_id,
      "linked_run_id" => run_id,
      "authoritative" => false,
      "created_at" => created_at,
      "status" => status,
      "decision" => decision,
      "evaluator" => evaluator,
      "authority_status" => authority_status
    }

    create_or_same(
      SalixStore.TriageKeys.ctl_im_triage_late_result(namespace, run_id, observation_id),
      record
    )
  end

  def persist_late(_namespace, _authority, _result_parts, _observation),
    do: {:error, :invalid_late_result_projection}

  @doc "A fresh pinned identity for one late observation, stable across retries."
  @spec late_observation() :: %{observation_id: String.t(), created_at: integer()}
  def late_observation,
    do: %{observation_id: ULID.generate(), created_at: System.system_time(:millisecond)}

  defp late_observation(%{observation_id: observation_id, created_at: created_at})
       when is_binary(observation_id) and observation_id != "" and is_integer(created_at),
       do: {observation_id, created_at}

  defp late_observation(_unpinned), do: {ULID.generate(), System.system_time(:millisecond)}

  defp valid_replay_ledger_ref?("ledger://run/authoritative", _run_key, %{
         "bucket" => "bucket://run/scope"
       }),
       do: true

  defp valid_replay_ledger_ref?(ledger_ref, run_key, _run),
    do: ledger_ref in ["triage-record://" <> run_key, "s3://" <> run_key]

  defp identity_activity_required?(%{
         "schema" => "comma.triage-bucket-fence.v2",
         "identity_observation" => %{"private_projection" => private_projection}
       })
       when is_map(private_projection),
       do: true

  defp identity_activity_required?(_fence), do: false

  defp enrich_native_run(
         run,
         %{
           "schema" => model_input_schema,
           "canonical_snapshot_bytes" => snapshot_bytes,
           "canonical_snapshot_sha256" => snapshot_sha256,
           "source_refs" => source_refs,
           "source_refs_canonical_bytes" => source_refs_bytes,
           "source_refs_sha256" => source_refs_sha256
         },
         evaluator
       )
       when model_input_schema in [
              "comma.triage-model-input.v1",
              "comma.triage-model-input.v2",
              "comma.triage-model-input.v3"
            ] do
    run =
      run
      |> Map.put("schema", "comma.triage-run.v2")
      |> Map.put("canonical_snapshot_bytes", snapshot_bytes)
      |> Map.put("context_sha256", snapshot_sha256)
      |> Map.put("source_refs", source_refs)
      |> Map.put("source_refs_canonical_bytes", source_refs_bytes)
      |> Map.put("source_refs_sha256", source_refs_sha256)

    case evaluator do
      %{"schema" => "comma.triage-worker-assignment.v1"} = proof ->
        run |> Map.put("model_request_count", 0) |> maybe_put_review_artifact(proof)

      %{"schema" => schema} = proof
      when schema in [
             "comma.triage-model-proof.v1",
             "comma.triage-model-proof.v2",
             "comma.triage-model-proof.v3"
           ] ->
        run
        |> Map.put("provider", proof["provider"])
        |> Map.put("model", proof["model"])
        |> Map.put("provider_sha256", proof["provider_sha256"])
        |> Map.put("model_sha256", proof["model_sha256"])
        |> Map.put("prompt_sha256", proof["prompt_sha256"])
        |> Map.put("policy_sha256", proof["policy_sha256"])
        |> Map.put("provider_payload_bytes", proof["provider_payload_bytes"])
        |> Map.put("provider_payload_sha256", proof["provider_payload_sha256"])
        |> Map.put("provider_payload_observer_sha256", proof["observer_payload_sha256"])
        |> Map.put("provider_payload_transport_sha256", proof["transport_payload_sha256"])
        |> Map.put("model_request_count", proof["request_count"])
        |> Map.put("model_retry", proof["retry"])
        |> maybe_put_read_tool_evidence(proof)
        |> maybe_put_review_artifact(proof)

      _other ->
        run
    end
  end

  defp enrich_native_run(run, _input, _evaluator), do: run

  defp maybe_put_read_tool_evidence(run, %{
         "schema" => "comma.triage-model-proof.v2",
         "provider_payload_chain" => payload_chain,
         "tool_call_count" => 1,
         "tool_names" => [tool_name] = tool_names,
         "tool_receipts" => [_receipt] = tool_receipts
       })
       when tool_name in @identity_read_tools do
    run
    |> Map.put("provider_payload_chain", payload_chain)
    |> Map.put("tool_call_count", 1)
    |> Map.put("tool_names", tool_names)
    |> Map.put("tool_receipts", tool_receipts)
  end

  defp maybe_put_read_tool_evidence(run, %{"schema" => "comma.triage-model-proof.v3"} = proof) do
    Map.merge(
      run,
      Map.take(
        proof,
        ~w(provider_payload_chain tool_call_count tool_names tool_receipts participation_decision)
      )
    )
  end

  defp maybe_put_read_tool_evidence(run, _proof), do: run

  defp maybe_put_committed_read_tool_observation(run, observation)
       when is_map(run) and is_map(observation) do
    case Map.get(observation, "read_tool_result") do
      nil ->
        {:ok, run}

      %{"tool_name" => tool_name, "receipt" => receipt} = read_tool_observation
      when tool_name in @identity_read_tools ->
        committed_evidence = %{
          "tool_call_count" => 1,
          "tool_names" => [tool_name],
          "tool_receipts" => [receipt]
        }

        existing_evidence = Map.take(run, Map.keys(committed_evidence))

        cond do
          not RunFence.valid_read_tool_observation?(read_tool_observation) ->
            {:error, :identity_diagnostic_invalid_fence}

          existing_evidence == %{} ->
            {:ok, Map.merge(run, committed_evidence)}

          existing_evidence == committed_evidence ->
            {:ok, run}

          true ->
            {:error, :identity_diagnostic_invalid_fence}
        end

      _invalid ->
        {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp maybe_put_committed_read_tool_observation(run, nil) when is_map(run), do: {:ok, run}

  defp maybe_put_committed_read_tool_observation(_run, _observation),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp maybe_put_review_artifact(run, %{
         "review_artifact" => artifact,
         "review_artifact_sha256" => sha256
       })
       when is_map(artifact) and is_binary(sha256) and sha256 != "" do
    run
    |> Map.put("review_artifact", artifact)
    |> Map.put("review_artifact_sha256", sha256)
  end

  defp maybe_put_review_artifact(run, _proof), do: run

  defp maybe_persist_identity_activity_index(
         namespace,
         %{
           "schema" => "comma.triage-bucket-fence.v2",
           "identity_observation" => %{"private_projection" => private_projection}
         },
         run
       )
       when is_map(private_projection) do
    with raw_bundle_bytes when is_binary(raw_bundle_bytes) <-
           private_projection["raw_source_bundle_bytes"],
         {:ok, raw_bundle} <- Jason.decode(raw_bundle_bytes),
         {:ok, binding} <- identity_activity_binding(raw_bundle),
         created_at when is_integer(created_at) <- run["created_at"],
         true <- created_at > 0 and created_at <= @max_activity_created_at,
         true <- ULID.valid?(run["run_id"]) do
      reverse_created_at = reverse_activity_created_at(created_at)

      entry = %{
        "schema" => @identity_activity_schema,
        "identity_scope_sha256" => binding.identity_scope_sha256,
        "identity_revision_sha256" => binding.identity_revision_sha256,
        "run_id" => run["run_id"],
        "run_sha256" => sha256(run),
        "created_at" => created_at
      }

      key =
        SalixStore.TriageKeys.ctl_im_triage_activity_index_entry(
          namespace,
          binding.identity_scope_sha256,
          reverse_created_at,
          run["run_id"]
        )

      create_or_same(key, entry)
    else
      _invalid -> {:error, :invalid_identity_activity_projection}
    end
  end

  defp maybe_persist_identity_activity_index(
         _namespace,
         %{"schema" => "comma.triage-bucket-fence.v2"},
         _run
       ),
       do: :ok

  defp maybe_persist_identity_activity_index(_namespace, _legacy_fence, _run), do: :ok

  defp identity_activity_binding(raw_bundle) do
    connect = raw_bundle["connect_identity"]
    product = raw_bundle["product_identity"]

    identity_revision_sha256 =
      get_in(raw_bundle, ["raw_identity_context", "self_agent", "identity_revision_sha256"])

    with true <- is_map(connect),
         true <- is_map(product),
         true <- product["agent_role"] == "router",
         true <-
           Enum.all?(
             [
               connect["tenant_id"],
               connect["group_id"],
               product["project_id"],
               product["agent_id"],
               product["salix_agent_id"]
             ],
             &nonempty?/1
           ),
         true <- valid_sha256?(identity_revision_sha256) do
      identity_scope = %{
        "schema" => "comma.triage-activity-scope.v1",
        "tenant_id" => connect["tenant_id"],
        "group_id" => connect["group_id"],
        "project_id" => product["project_id"],
        "agent_id" => product["agent_id"],
        "salix_agent_id" => product["salix_agent_id"],
        "agent_role" => product["agent_role"]
      }

      {:ok,
       %{
         identity_scope_sha256:
           identity_scope |> CanonicalJSON.encode!() |> CanonicalJSON.sha256(),
         identity_revision_sha256: identity_revision_sha256
       }}
    else
      _invalid -> {:error, :invalid_identity_activity_projection}
    end
  end

  defp read_identity_activity_entries(namespace, binding, objects) do
    Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, entries} ->
      case CasRecord.get(key) do
        {:ok, entry} ->
          if valid_identity_activity_entry?(namespace, binding, key, entry) do
            {:cont, {:ok, [entry | entries]}}
          else
            {:halt, {:error, :identity_activity_unavailable}}
          end

        _unavailable ->
          {:halt, {:error, :identity_activity_unavailable}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp valid_identity_activity_entry?(namespace, binding, key, entry) do
    exact_map_keys?(
      entry,
      ~w(schema identity_scope_sha256 identity_revision_sha256 run_id run_sha256 created_at)
    ) and entry["schema"] == @identity_activity_schema and
      entry["identity_scope_sha256"] == binding.identity_scope_sha256 and
      valid_sha256?(entry["identity_revision_sha256"]) and ULID.valid?(entry["run_id"]) and
      valid_sha256?(entry["run_sha256"]) and is_integer(entry["created_at"]) and
      entry["created_at"] > 0 and entry["created_at"] <= @max_activity_created_at and
      key ==
        SalixStore.TriageKeys.ctl_im_triage_activity_index_entry(
          namespace,
          binding.identity_scope_sha256,
          reverse_activity_created_at(entry["created_at"]),
          entry["run_id"]
        )
  end

  defp select_identity_activity_entry(entries, excluded_run_id) do
    case Enum.find(entries, &(&1["run_id"] != excluded_run_id)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp reverse_activity_created_at(created_at) do
    (@max_activity_created_at - created_at)
    |> Integer.to_string()
    |> String.pad_leading(13, "0")
  end

  defp list_records(prefix) do
    with {:ok, objects} <- SalixStore.TriageRecordStore.list_all(prefix) do
      Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, records} ->
        case CasRecord.get(key) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end
    end
  end

  defp create_or_same(key, record) do
    case CasRecord.create(key, record) do
      {:ok, _created} ->
        :ok

      {:error, _reason} = error ->
        if match?({:ok, ^record}, CasRecord.get(key)), do: :ok, else: error
    end
  end

  defp exact_map_keys?(map, keys) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_map_keys?(_map, _keys), do: false
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
