defmodule SalixStore.TriageTransactions do
  @moduledoc """
  Authoritative PostgreSQL transactions for native Triage.

  A terminal fence, immutable run, immutable replay and durable projection
  obligation share one commit point. Derived query projections are deliberately
  absent from this transaction; their bounded projector converges the obligation
  later and therefore cannot make an authoritative terminal fail.

  Compound reply/reaction materialization is modeled in
  `tla/salix/TriageCompoundCommunication.tla`.
  """

  alias SalixStore.{Crypto, Repo, S3, TriageKeys, ULID}

  @root ~r/\Atriage\/engine-v2\/([0-9a-f]{64})\/(.+)\z/
  @max_projection_batch 100
  @max_archived_generations 50

  @admission_keys ~w(namespace physical_source recipient bucket_identity lane receipt)a
  @admission_lanes [:ambient, :directed, :both]
  @settlement_keys ~w(schema connect_id event_id reason admission_ref)
  @ambient_alias_keys ~w(schema source_message_ref canonical_receipt_ref)
  @ambient_alias_recipient_keys @ambient_alias_keys ++ ["recipient_key"]
  @durable_bucket_keys ~w(
    schema bucket_scope open_generation open_first_at open_last_at open_fast_path
    open_receipts sealed_generations
  )

  @type admission :: %{
          required(:namespace) => String.t(),
          required(:physical_source) => String.t(),
          required(:recipient) => String.t(),
          required(:bucket_identity) => String.t(),
          required(:lane) => :ambient | :directed | :both,
          required(:receipt) => map()
        }

  @doc """
  Atomically projects one already-durable provider receipt into native Triage.

  The S3 receipt is read and matched before PostgreSQL may create any runnable
  membership. Ambient arbitration is global per physical source; explicitly
  addressed work is independently unique per `{physical_source, recipient}`.
  A recipient holding both roles gets one monotonically merged membership.
  """
  @spec admit_receipt(admission()) ::
          {:ok,
           %{
             status: :accepted | :duplicate,
             lane: :ambient | :directed | :both | nil,
             durable: map() | nil
           }}
          | {:error, :conflict | :invalid | :receipt_unavailable | :unavailable}
  def admit_receipt(admission) when is_map(admission) do
    with :ok <- validate_admission(admission),
         :ok <- verify_receipt_handoff(admission.receipt) do
      identity = admission_identity(admission)

      admission
      |> run_admission_transaction(identity)
      |> normalize_admission_transaction()
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def admit_receipt(_admission), do: {:error, :invalid}

  @doc "Records one create-once settlement for a directed intent with no admissible message shape."
  @spec record_intent_settlement(map()) ::
          {:ok, :created | :duplicate} | {:error, :conflict | :invalid | :unavailable}
  def record_intent_settlement(settlement) when is_map(settlement) do
    if valid_settlement?(settlement) do
      event_key = Crypto.hex(settlement["event_id"])

      case Repo.query(
             """
             INSERT INTO triage_intent_settlements (connect_id, event_key, body)
             VALUES ($1, $2, $3)
             ON CONFLICT DO NOTHING
             RETURNING 1
             """,
             [settlement["connect_id"], event_key, settlement]
           ) do
        {:ok, %{rows: [[1]]}} ->
          {:ok, :created}

        {:ok, %{rows: []}} ->
          resolve_intent_settlement(settlement["connect_id"], event_key, settlement)

        {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
          {:error, :invalid}

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def record_intent_settlement(_settlement), do: {:error, :invalid}

  @type commit :: %{
          required(:fence_key) => String.t(),
          required(:expected_etag) => String.t(),
          required(:fence) => map(),
          required(:run_key) => String.t(),
          required(:run) => map(),
          required(:replay_key) => String.t(),
          required(:replay) => map(),
          required(:obligation) => map(),
          required(:product_obligation) => map() | nil,
          optional(:companion_product_obligation) => map() | nil
        }

  @spec commit_authoritative(commit()) ::
          {:ok, %{fence_etag: String.t()}} | {:error, :conflict | :invalid | :unavailable}
  def commit_authoritative(commit) when is_map(commit) do
    with {:ok, namespace_key, bucket_key, _generation_key} <-
           fence_identity(commit[:fence_key]),
         {:ok, ^namespace_key, run_id} <- run_identity(commit[:run_key], "ledger/runs/"),
         {:ok, ^namespace_key, ^run_id} <- run_identity(commit[:replay_key], "replay/"),
         {:ok, expected_revision} <- revision(commit[:expected_etag]),
         true <- valid_commit_shape?(commit, namespace_key, run_id) do
      transaction_result =
        Repo.transaction(fn ->
          with :ok <- archive_completed_bucket(commit, namespace_key, bucket_key),
               {:ok, fence_revision} <-
                 commit_fence(
                   commit.fence_key,
                   commit.fence,
                   expected_revision
                 ),
               :ok <-
                 insert_evidence_exact(
                   "triage_runs",
                   ["record_key", "namespace_key", "run_id", "body"],
                   [commit.run_key, namespace_key, run_id, commit.run]
                 ),
               :ok <-
                 insert_evidence_exact(
                   "triage_replays",
                   ["record_key", "namespace_key", "run_id", "body"],
                   [commit.replay_key, namespace_key, run_id, commit.replay]
                 ),
               :ok <- insert_obligation_exact(namespace_key, run_id, commit.obligation),
               :ok <-
                 insert_product_obligation_exact(
                   namespace_key,
                   run_id,
                   commit.product_obligation
                 ),
               :ok <-
                 insert_companion_product_obligation_exact(
                   namespace_key,
                   run_id,
                   commit[:companion_product_obligation]
                 ) do
            %{fence_etag: etag(fence_revision)}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      normalize_transaction(transaction_result)
    else
      _invalid -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def commit_authoritative(_commit), do: {:error, :invalid}

  # The completed fence owns the exact sealed source after this transaction.
  # Copy validation and removal share the terminal commit, so a failed commit
  # leaves all pending source material in the active bucket.
  #
  # A channel fence must carry its exact sealed copy. A thread bucket archives
  # what it can prove: the committing generation when its fence carries the
  # exact copy, and earlier generations named in `archived_generations` whose
  # committed fences are terminal and carry the exact copy. Thread buckets used
  # to keep every generation, and hourly scheduled rechecks grew them without
  # bound. Before a generation leaves the bucket, its receipt memberships learn
  # the generation, so a late duplicate resolves through the archive instead
  # of re-entering the bucket.
  defp archive_completed_bucket(commit, namespace_key, bucket_key) do
    fence = commit.fence
    channel? = fence_scope_kind(fence) == "channel"
    archived = fence["sealed_generation"]
    exact? = is_map(archived) and archived["generation"] == fence["generation"]
    candidates = Map.get(commit, :archived_generations, [])

    cond do
      channel? and not exact? -> {:error, :conflict}
      not channel? and not exact? and candidates == [] -> :ok
      true -> archive_bucket_generations(commit, namespace_key, bucket_key, channel?, exact?)
    end
  end

  defp archive_bucket_generations(commit, namespace_key, bucket_key, channel?, exact?) do
    fence = commit.fence

    with {:ok, %{rows: [[record_key, bucket]]}} <-
           Repo.query(
             "SELECT record_key, body FROM triage_buckets WHERE namespace_key = $1 AND bucket_key = $2 FOR UPDATE",
             [namespace_key, bucket_key]
           ),
         true <- bucket["bucket_scope"] == fence["bucket_scope"],
         {:ok, current} <- committing_generation(commit, bucket, channel?, exact?),
         {:ok, backlog} <- terminal_backlog(commit, namespace_key, bucket_key, bucket) do
      case current ++ backlog do
        [] ->
          :ok

        generations ->
          with :ok <-
                 record_archived_memberships(commit, namespace_key, bucket_key, generations) do
            updated =
              Map.update!(
                bucket,
                "sealed_generations",
                &Enum.reject(&1, fn g -> g in generations end)
              )

            case Repo.query(
                   "UPDATE triage_buckets SET body = $2, revision = revision + 1, updated_at = now() WHERE record_key = $1 RETURNING 1",
                   [record_key, updated]
                 ) do
              {:ok, %{rows: [[1]]}} -> :ok
              _failure -> {:error, :unavailable}
            end
          end
      end
    else
      {:error, reason} when reason in [:conflict, :unavailable] -> {:error, reason}
      _invalid -> if channel?, do: {:error, :conflict}, else: :ok
    end
  end

  defp committing_generation(_commit, _bucket, _channel?, false), do: {:ok, []}

  defp committing_generation(commit, bucket, channel?, true) do
    fence = commit.fence
    archived = fence["sealed_generation"]

    case Enum.find(bucket["sealed_generations"], &(&1["generation"] == fence["generation"])) do
      ^archived ->
        {:ok, [archived]}

      nil when channel? ->
        case Repo.query("SELECT body FROM triage_run_fences WHERE record_key = $1", [
               commit.fence_key
             ]) do
          {:ok, %{rows: [[^fence]]}} -> {:ok, []}
          _missing -> {:error, :conflict}
        end

      nil ->
        {:ok, []}

      _different when channel? ->
        {:error, :conflict}

      _different ->
        {:ok, []}
    end
  end

  # An earlier generation leaves only with a committed terminal fence that
  # holds the same sealed copy the bucket holds. A terminal fence committed
  # before copies were written receives the copy here when the caller offers
  # exactly the bucket's entry; the caller has checked it against the fence.
  defp terminal_backlog(commit, namespace_key, bucket_key, bucket) do
    current = commit.fence["generation"]

    candidates =
      commit
      |> Map.get(:archived_generations, [])
      |> Enum.reject(&(&1.generation == current))
      |> Map.new(&{&1.generation, &1})

    if candidates == %{} do
      {:ok, []}
    else
      case Repo.query(
             """
             SELECT generation_key, record_key, body -> 'sealed_generation'
             FROM triage_run_fences
             WHERE namespace_key = $1 AND bucket_key = $2 AND generation_key = ANY($3)
               AND body -> 'terminal' IS NOT NULL AND body -> 'terminal' <> 'null'::jsonb
             """,
             [namespace_key, bucket_key, candidates |> Map.keys() |> Enum.map(&Crypto.hex/1)]
           ) do
        {:ok, %{rows: rows}} ->
          fences =
            Map.new(rows, fn [generation_key, key, copy] -> {generation_key, {key, copy}} end)

          bucket["sealed_generations"]
          |> Enum.filter(&Map.has_key?(candidates, &1["generation"]))
          |> Enum.reduce_while({:ok, []}, fn sealed, {:ok, archived} ->
            candidate = candidates[sealed["generation"]]

            case settle_backlog_copy(fences[Crypto.hex(sealed["generation"])], sealed, candidate) do
              :archive -> {:cont, {:ok, [sealed | archived]}}
              :keep -> {:cont, {:ok, archived}}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, archived} -> {:ok, Enum.reverse(archived)}
            error -> error
          end

        {:error, _reason} ->
          {:error, :unavailable}
      end
    end
  end

  defp settle_backlog_copy({_key, sealed}, sealed, _candidate), do: :archive

  defp settle_backlog_copy({key, nil}, sealed, %{attach: sealed}) do
    case Repo.query(
           """
           UPDATE triage_run_fences
           SET body = jsonb_set(body, '{sealed_generation}', $2::jsonb),
               revision = revision + 1, updated_at = now()
           WHERE record_key = $1 AND NOT body ? 'sealed_generation'
           RETURNING 1
           """,
           [key, sealed]
         ) do
      {:ok, %{rows: [[1]]}} -> :archive
      {:ok, _raced} -> :keep
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp settle_backlog_copy(_fence, _sealed, _candidate), do: :keep

  # Only a membership whose canonical receipt is in the archived copy learns
  # that generation. A wrong source key therefore matches nothing.
  defp record_archived_memberships(commit, namespace_key, bucket_key, generations) do
    sources =
      commit
      |> Map.get(:archived_generations, [])
      |> Enum.reduce(%{}, fn entry, acc -> Map.merge(acc, entry.sources) end)

    rows =
      for sealed <- generations,
          receipt <- sealed["receipts"],
          source_key = Map.get(sources, receipt["receipt_ref"]),
          is_binary(source_key),
          do: [source_key, receipt["receipt_ref"], sealed["generation"]]

    if rows == [] do
      :ok
    else
      [source_keys, receipt_refs, generation_ids] = Enum.zip_with(rows, & &1)

      case Repo.query(
             """
             UPDATE triage_bucket_memberships AS m
             SET generation = archived.generation, updated_at = now()
             FROM unnest($2::text[], $3::text[], $4::text[])
               AS archived(source_key, receipt_ref, generation)
             WHERE m.namespace_key = $1
               AND m.physical_source_key = archived.source_key
               AND m.canonical_receipt_ref = archived.receipt_ref
               AND m.bucket_key = $5
               AND m.generation IS NULL
             """,
             [namespace_key, source_keys, receipt_refs, generation_ids, bucket_key]
           ) do
        {:ok, _result} -> :ok
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  defp fence_scope_kind(fence) do
    input = fence["input_snapshot"] || %{}

    authority =
      get_in(input, ["snapshot", "source_authority"]) || input["source_authority"] || %{}

    authority["scope_kind"]
  end

  defp run_admission_transaction(admission, identity) do
    Repo.transaction(fn ->
      with {:ok, projection_status} <- claim_receipt_projection(admission, identity),
           {:ok, ambient_status} <- claim_ambient_alias(admission, identity),
           effective_lane <- effective_lane(admission.lane, ambient_status),
           {:ok, result} <-
             admit_recipient(admission, identity, effective_lane, projection_status) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp claim_receipt_projection(admission, identity) do
    receipt = admission.receipt

    desired = %{
      "schema" => "comma.triage-receipt-projection.v1",
      "receipt_ref" => receipt["receipt_ref"],
      "event_id" => receipt["event_id"]
    }

    key = TriageKeys.ctl_im_triage_projection_marker(admission.namespace, receipt["receipt_ref"])

    case Repo.query(
           """
           INSERT INTO triage_receipt_projections
             (record_key, namespace_key, receipt_key, receipt_ref, body)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT DO NOTHING
           RETURNING 1
           """,
           [
             key,
             identity.namespace_key,
             Crypto.hex(receipt["receipt_ref"]),
             receipt["receipt_ref"],
             desired
           ]
         ) do
      {:ok, %{rows: [[1]]}} ->
        {:ok, :created}

      {:ok, %{rows: []}} ->
        case Repo.query("SELECT body FROM triage_receipt_projections WHERE record_key = $1", [
               key
             ]) do
          {:ok, %{rows: [[^desired]]}} -> {:ok, :duplicate}
          {:ok, _other} -> {:error, :conflict}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp claim_ambient_alias(%{lane: :directed}, _identity), do: {:ok, :not_requested}

  defp claim_ambient_alias(admission, identity) do
    receipt = admission.receipt

    desired = %{
      "schema" => "comma.triage-source-alias.v1",
      "source_message_ref" => receipt["source_message_ref"],
      "canonical_receipt_ref" => receipt["receipt_ref"],
      "recipient_key" => identity.recipient_key
    }

    key = TriageKeys.ctl_im_triage_source_alias(admission.namespace, admission.physical_source)

    case Repo.query(
           """
           INSERT INTO triage_ambient_aliases
             (record_key, namespace_key, physical_source_key, body)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT DO NOTHING
           RETURNING 1
           """,
           [key, identity.namespace_key, identity.physical_source_key, desired]
         ) do
      {:ok, %{rows: [[1]]}} ->
        {:ok, :owned}

      {:ok, %{rows: []}} ->
        resolve_ambient_alias(key, identity.recipient_key)

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp resolve_ambient_alias(key, recipient_key) do
    case Repo.query("SELECT body FROM triage_ambient_aliases WHERE record_key = $1", [key]) do
      {:ok, %{rows: [[body]]}} ->
        cond do
          not valid_ambient_alias?(body) -> {:error, :conflict}
          body["recipient_key"] == recipient_key -> {:ok, :owned}
          true -> {:ok, :foreign}
        end

      {:ok, _other} ->
        {:error, :conflict}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp effective_lane(:ambient, :owned), do: :ambient
  defp effective_lane(:ambient, _not_owned), do: nil
  defp effective_lane(:directed, _ambient_status), do: :directed
  defp effective_lane(:both, :owned), do: :both
  defp effective_lane(:both, _not_owned), do: :directed

  defp admit_recipient(_admission, _identity, nil, _projection_status) do
    {:ok, %{status: :duplicate, lane: nil, durable: nil}}
  end

  defp admit_recipient(admission, identity, lane, projection_status) do
    receipt = admission.receipt

    case Repo.query(
           """
           INSERT INTO triage_recipient_aliases
             (namespace_key, physical_source_key, recipient_key,
              receipt_key, canonical_receipt_ref)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT DO NOTHING
           RETURNING canonical_receipt_ref
           """,
           [
             identity.namespace_key,
             identity.physical_source_key,
             identity.recipient_key,
             Crypto.hex(receipt["receipt_ref"]),
             receipt["receipt_ref"]
           ]
         ) do
      {:ok, %{rows: [[canonical_receipt_ref]]}} ->
        create_recipient_membership(
          admission,
          identity,
          lane,
          canonical_receipt_ref,
          projection_status
        )

      {:ok, %{rows: []}} ->
        resolve_recipient_membership(admission, identity, lane)

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp create_recipient_membership(admission, identity, lane, canonical_receipt_ref, _status) do
    with {:ok, durable} <- append_bucket(admission, identity),
         {:ok, :created} <-
           insert_membership(
             identity,
             canonical_receipt_ref,
             lane,
             durable["open_generation"]
           ) do
      {:ok, %{status: :accepted, lane: lane, durable: durable}}
    end
  end

  defp resolve_recipient_membership(admission, identity, requested_lane) do
    case Repo.query(
           """
           SELECT canonical_receipt_ref
           FROM triage_recipient_aliases
           WHERE namespace_key = $1 AND physical_source_key = $2 AND recipient_key = $3
           """,
           [identity.namespace_key, identity.physical_source_key, identity.recipient_key]
         ) do
      {:ok, %{rows: [[canonical_receipt_ref]]}} ->
        with {:ok, membership} <- load_membership(identity),
             true <- membership.canonical_receipt_ref == canonical_receipt_ref,
             merged_lane <-
               if(membership.bucket_key == identity.bucket_key,
                 do: merge_lane(membership.lane, requested_lane),
                 else: membership.lane
               ),
             :ok <- maybe_upgrade_membership(identity, membership.lane, merged_lane),
             {:ok, durable} <- membership_durable(admission, identity, membership) do
          {:ok, %{status: :duplicate, lane: merged_lane, durable: durable}}
        else
          false -> {:error, :conflict}
          {:error, _reason} = error -> error
        end

      {:ok, _other} ->
        {:error, :conflict}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp insert_membership(identity, canonical_receipt_ref, lane, generation) do
    case Repo.query(
           """
           INSERT INTO triage_bucket_memberships
             (namespace_key, physical_source_key, recipient_key, bucket_key,
              canonical_receipt_ref, lane, generation)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           ON CONFLICT DO NOTHING
           RETURNING 1
           """,
           [
             identity.namespace_key,
             identity.physical_source_key,
             identity.recipient_key,
             identity.bucket_key,
             canonical_receipt_ref,
             Atom.to_string(lane),
             generation
           ]
         ) do
      {:ok, %{rows: [[1]]}} -> {:ok, :created}
      {:ok, %{rows: []}} -> {:error, :conflict}
      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} -> {:error, :invalid}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp load_membership(identity) do
    case Repo.query(
           """
           SELECT bucket_key, canonical_receipt_ref, lane, generation
           FROM triage_bucket_memberships
           WHERE namespace_key = $1 AND physical_source_key = $2 AND recipient_key = $3
           FOR UPDATE
           """,
           [identity.namespace_key, identity.physical_source_key, identity.recipient_key]
         ) do
      {:ok, %{rows: [[bucket_key, canonical_receipt_ref, lane, generation]]}}
      when lane in ["ambient", "directed", "both"] ->
        {:ok,
         %{
           bucket_key: bucket_key,
           canonical_receipt_ref: canonical_receipt_ref,
           generation: generation,
           lane: String.to_existing_atom(lane)
         }}

      {:ok, _other} ->
        {:error, :conflict}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp maybe_upgrade_membership(_identity, lane, lane), do: :ok

  defp maybe_upgrade_membership(identity, _current_lane, :both) do
    case Repo.query(
           """
           UPDATE triage_bucket_memberships
           SET lane = 'both', updated_at = now()
           WHERE namespace_key = $1 AND physical_source_key = $2 AND recipient_key = $3
           RETURNING 1
           """,
           [identity.namespace_key, identity.physical_source_key, identity.recipient_key]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, _other} -> {:error, :conflict}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp merge_lane(lane, lane), do: lane
  defp merge_lane(_left, _right), do: :both

  defp append_bucket(admission, identity) do
    receipt = admission.receipt
    key = TriageKeys.ctl_im_triage_bucket(admission.namespace, admission.bucket_identity)

    initial = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => admission.bucket_identity,
      "open_generation" => ULID.generate(),
      "open_first_at" => receipt["created_at"],
      "open_last_at" => receipt["created_at"],
      "open_fast_path" => get_in(receipt, ["triage_event", "fast_path"]),
      "open_receipts" => [receipt],
      "sealed_generations" => []
    }

    case Repo.query(
           """
           INSERT INTO triage_buckets
             (record_key, namespace_key, bucket_key, body)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT DO NOTHING
           RETURNING body
           """,
           [key, identity.namespace_key, identity.bucket_key, initial]
         ) do
      {:ok, %{rows: [[^initial]]}} ->
        {:ok, initial}

      {:ok, %{rows: []}} ->
        append_existing_bucket(key, admission.bucket_identity, receipt)

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp append_existing_bucket(key, bucket_identity, receipt) do
    case Repo.query("SELECT body FROM triage_buckets WHERE record_key = $1 FOR UPDATE", [key]) do
      {:ok, %{rows: [[current]]}} ->
        with true <- valid_bucket_for_append?(current, bucket_identity) do
          cond do
            seen_receipt?(current, receipt["receipt_ref"]) ->
              {:ok, current}

            channel_receipt?(receipt) and
                (length(current["open_receipts"]) >= 200 or
                   length(current["sealed_generations"]) >= 10) ->
              {:error, :unavailable}

            true ->
              updated = append_bucket_receipt(current, receipt)

              case Repo.query(
                     """
                     UPDATE triage_buckets
                     SET body = $2, revision = revision + 1, updated_at = now()
                     WHERE record_key = $1
                     RETURNING body
                     """,
                     [key, updated]
                   ) do
                {:ok, %{rows: [[^updated]]}} ->
                  {:ok, updated}

                {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
                  {:error, :invalid}

                {:error, _reason} ->
                  {:error, :unavailable}
              end
          end
        else
          false -> {:error, :conflict}
        end

      {:ok, _other} ->
        {:error, :conflict}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp membership_durable(admission, identity, membership) do
    case Repo.query(
           "SELECT record_key, body FROM triage_buckets WHERE namespace_key = $1 AND bucket_key = $2 FOR UPDATE",
           [identity.namespace_key, membership.bucket_key]
         ) do
      {:ok, %{rows: [[record_key, current]]}} ->
        if current["bucket_scope"] == admission.bucket_identity do
          if is_binary(membership.generation) and
               membership.generation != current["open_generation"] and
               not Enum.any?(
                 current["sealed_generations"],
                 &(&1["generation"] == membership.generation)
               ) do
            archived_membership_bucket(admission, membership, current)
          else
            append_existing_bucket(record_key, admission.bucket_identity, admission.receipt)
          end
        else
          # Recipient aliases remain stable across connect rotations. A later
          # callback copy from a new generation is durable receipt evidence,
          # but it cannot move the canonical membership into another bucket.
          # Returning the existing bucket settles the copy as a duplicate
          # without arming it because that receipt is not an open member.
          scope = current["bucket_scope"]

          if canonical_nonblank?(scope) and valid_bucket_for_append?(current, scope),
            do: {:ok, current},
            else: {:error, :conflict}
        end

      {:ok, _other} ->
        {:error, :conflict}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp archived_membership_bucket(admission, membership, current) do
    key =
      TriageKeys.ctl_im_triage_bucket_seal(
        admission.namespace,
        current["bucket_scope"],
        membership.generation
      )

    with {:ok, %{rows: [[fence]]}} <-
           Repo.query("SELECT body FROM triage_run_fences WHERE record_key = $1", [key]),
         true <- is_map(fence["terminal"]),
         %{} = archived <- fence["sealed_generation"],
         true <- archived["generation"] == membership.generation,
         true <-
           Enum.any?(
             archived["receipts"],
             &(&1["receipt_ref"] == membership.canonical_receipt_ref)
           ) do
      # A read-only membership view lets ingress recognize an old canonical
      # receipt without restoring completed history to the active record.
      {:ok, Map.update!(current, "sealed_generations", &[archived | &1])}
    else
      _invalid -> {:error, :conflict}
    end
  end

  defp channel_receipt?(receipt),
    do: get_in(receipt, ["triage_event", "bucket", "scope_kind"]) == "channel"

  defp append_bucket_receipt(current, receipt) do
    receipts =
      [receipt | current["open_receipts"]]
      |> Enum.uniq_by(& &1["receipt_ref"])
      |> Enum.sort_by(fn item ->
        {item["created_at"], get_in(item, ["triage_event", "message_ts"]), item["event_id"]}
      end)

    current
    |> Map.put("open_first_at", min_timestamp(current["open_first_at"], receipt["created_at"]))
    |> Map.put("open_last_at", max_timestamp(current["open_last_at"], receipt["created_at"]))
    |> Map.put(
      "open_fast_path",
      current["open_fast_path"] or get_in(receipt, ["triage_event", "fast_path"])
    )
    |> Map.put("open_receipts", receipts)
  end

  defp seen_receipt?(bucket, receipt_ref) do
    Enum.any?(bucket["open_receipts"] || [], &(&1["receipt_ref"] == receipt_ref)) or
      Enum.any?(bucket["sealed_generations"] || [], fn generation ->
        Enum.any?(generation["receipts"] || [], &(&1["receipt_ref"] == receipt_ref))
      end)
  end

  defp valid_bucket_for_append?(bucket, bucket_identity) do
    is_map(bucket) and exact_keys?(bucket, @durable_bucket_keys) and
      bucket["schema"] == "comma.triage-durable-bucket.v1" and
      bucket["bucket_scope"] == bucket_identity and is_list(bucket["open_receipts"]) and
      is_list(bucket["sealed_generations"]) and is_boolean(bucket["open_fast_path"])
  end

  defp validate_admission(admission) do
    receipt = admission[:receipt]

    valid? =
      exact_keys?(admission, @admission_keys) and admission[:lane] in @admission_lanes and
        Enum.all?(
          [
            admission[:namespace],
            admission[:physical_source],
            admission[:recipient],
            admission[:bucket_identity]
          ],
          &canonical_nonblank?/1
        ) and is_map(receipt) and
        Enum.all?(
          [receipt["receipt_ref"], receipt["source_message_ref"], receipt["event_id"]],
          &canonical_nonblank?/1
        ) and is_integer(receipt["created_at"]) and receipt["created_at"] >= 0 and
        is_boolean(get_in(receipt, ["triage_event", "fast_path"]))

    if valid?, do: :ok, else: {:error, :invalid}
  end

  defp verify_receipt_handoff(%{"receipt_ref" => "s3://" <> key} = receipt) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, stored} ->
            if receipt_evidence_matches?(stored, receipt),
              do: :ok,
              else: {:error, :receipt_unavailable}

          _invalid ->
            {:error, :receipt_unavailable}
        end

      {:error, _reason} ->
        {:error, :receipt_unavailable}
    end
  end

  defp verify_receipt_handoff(_receipt), do: {:error, :invalid}

  defp receipt_evidence_matches?(stored, receipt) when is_map(stored) do
    stored == receipt or normalize_v1_receipt_for_handoff(stored) == receipt
  end

  defp receipt_evidence_matches?(_stored, _receipt), do: false

  # A v1 receipt can cross the rolling-deploy handoff only through the one
  # lossless interpretation its original route admitted: an ambient human
  # message. Compare the complete normalized record, not just identity fields,
  # so PostgreSQL can never project evidence that differs from the durable S3
  # bytes in text, provenance, bucket, trigger or fast-path state.
  defp normalize_v1_receipt_for_handoff(
         %{
           "schema" => "comma.slack-triage-event-receipt.v1",
           "triage_event" => event
         } = receipt
       )
       when is_map(event) do
    trigger_kind = if direct_question?(event["text"]), do: "question_heuristic", else: "none"

    receipt
    |> Map.put("schema", "comma.slack-triage-event-receipt.v2")
    |> Map.put(
      "triage_event",
      event
      |> Map.put("actor_kind", "human")
      |> Map.put("event_type", "message")
      |> Map.put("addressing_kind", "ambient")
      |> Map.put("trigger_kind", trigger_kind)
    )
  end

  defp normalize_v1_receipt_for_handoff(_receipt), do: nil

  defp admission_identity(admission) do
    %{
      namespace_key: TriageKeys.namespace_key(admission.namespace),
      physical_source_key: Crypto.hex(admission.physical_source),
      recipient_key: Crypto.hex(admission.recipient),
      bucket_key: Crypto.hex(admission.bucket_identity)
    }
  end

  defp valid_ambient_alias?(body) do
    is_map(body) and
      (exact_keys?(body, @ambient_alias_keys) or
         exact_keys?(body, @ambient_alias_recipient_keys)) and
      body["schema"] == "comma.triage-source-alias.v1" and
      Enum.all?(
        [body["source_message_ref"], body["canonical_receipt_ref"]],
        &canonical_nonblank?/1
      ) and
      (is_nil(body["recipient_key"]) or
         (is_binary(body["recipient_key"]) and
            Regex.match?(~r/\A[0-9a-f]{64}\z/, body["recipient_key"])))
  end

  defp valid_settlement?(settlement) do
    exact_keys?(settlement, @settlement_keys) and
      settlement["schema"] == "comma.slack-intent-settlement.v1" and
      Enum.all?(
        ~w(connect_id event_id reason admission_ref),
        &canonical_nonblank?(settlement[&1])
      )
  end

  defp resolve_intent_settlement(connect_id, event_key, desired) do
    case Repo.query(
           "SELECT body FROM triage_intent_settlements WHERE connect_id = $1 AND event_key = $2",
           [connect_id, event_key]
         ) do
      {:ok, %{rows: [[^desired]]}} -> {:ok, :duplicate}
      {:ok, _other} -> {:error, :conflict}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp normalize_admission_transaction({:ok, result}), do: {:ok, result}

  defp normalize_admission_transaction({:error, reason})
       when reason in [:conflict, :invalid, :unavailable],
       do: {:error, reason}

  defp normalize_admission_transaction({:error, _reason}), do: {:error, :unavailable}

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)

  defp min_timestamp(nil, right), do: right
  defp min_timestamp(left, right), do: min(left, right)
  defp max_timestamp(nil, right), do: right
  defp max_timestamp(left, right), do: max(left, right)

  defp direct_question?(text) when is_binary(text), do: String.ends_with?(text, ["?", "？"])
  defp direct_question?(_text), do: false

  @doc "Returns a bounded oldest-first page of durable projection obligations."
  @spec pending_projection_obligations(pos_integer()) ::
          {:ok, [map()]} | {:error, :invalid | :unavailable}
  def pending_projection_obligations(limit)
      when is_integer(limit) and limit > 0 and limit <= @max_projection_batch do
    case Repo.query(
           """
           SELECT namespace_key, run_id, payload, attempts
           FROM triage_projection_obligations
           WHERE state = 'pending'
           ORDER BY updated_at, namespace_key, run_id
           LIMIT $1
           """,
           [limit]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [namespace_key, run_id, payload, attempts] ->
           %{
             namespace_key: namespace_key,
             run_id: run_id,
             payload: payload,
             attempts: attempts
           }
         end)}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def pending_projection_obligations(_limit), do: {:error, :invalid}

  @doc "Returns a bounded oldest-first page for one exact namespace."
  @spec pending_projection_obligations(String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :invalid | :unavailable}
  def pending_projection_obligations(namespace_key, limit)
      when is_binary(namespace_key) and
             is_integer(limit) and limit > 0 and limit <= @max_projection_batch do
    case Repo.query(
           """
           SELECT namespace_key, run_id, payload, attempts
           FROM triage_projection_obligations
           WHERE namespace_key = $1 AND state = 'pending'
           ORDER BY updated_at, run_id
           LIMIT $2
           """,
           [namespace_key, limit]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [stored_namespace_key, run_id, payload, attempts] ->
           %{
             namespace_key: stored_namespace_key,
             run_id: run_id,
             payload: payload,
             attempts: attempts
           }
         end)}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def pending_projection_obligations(_namespace_key, _limit), do: {:error, :invalid}

  @doc "Marks one exact obligation applied after every derived projection is durable."
  @spec mark_projection_applied(String.t(), String.t()) ::
          :ok | {:error, :not_found | :unavailable}
  def mark_projection_applied(namespace_key, run_id)
      when is_binary(namespace_key) and is_binary(run_id) do
    case Repo.query(
           """
           UPDATE triage_projection_obligations
           SET state = 'applied', updated_at = now()
           WHERE namespace_key = $1 AND run_id = $2
           RETURNING 1
           """,
           [namespace_key, run_id]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def mark_projection_applied(_namespace_key, _run_id), do: {:error, :not_found}

  @doc "Records a failed projector attempt without changing authoritative evidence."
  @spec mark_projection_failed(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :unavailable}
  def mark_projection_failed(namespace_key, run_id, reason)
      when is_binary(namespace_key) and is_binary(run_id) and is_binary(reason) do
    case Repo.query(
           """
           UPDATE triage_projection_obligations
           SET attempts = attempts + 1, last_error = $3, updated_at = now()
           WHERE namespace_key = $1 AND run_id = $2 AND state = 'pending'
           RETURNING 1
           """,
           [namespace_key, run_id, String.slice(reason, 0, 1_000)]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def mark_projection_failed(_namespace_key, _run_id, _reason), do: {:error, :not_found}

  defp commit_fence(fence_key, desired, expected_revision) do
    case Repo.query(
           "SELECT body, revision FROM triage_run_fences WHERE record_key = $1 FOR UPDATE",
           [fence_key]
         ) do
      {:ok, %{rows: [[^desired, revision]]}} ->
        {:ok, revision}

      {:ok, %{rows: [[_current, ^expected_revision]]}} ->
        case Repo.query(
               """
               UPDATE triage_run_fences
               SET body = $2, revision = revision + 1, updated_at = now()
               WHERE record_key = $1 AND revision = $3
                 AND body -> 'terminal' = 'null'::jsonb
               RETURNING revision
               """,
               [fence_key, desired, expected_revision]
             ) do
          {:ok, %{rows: [[revision]]}} -> {:ok, revision}
          {:ok, %{rows: []}} -> {:error, :conflict}
          {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} -> {:error, :invalid}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:ok, %{rows: [[_current, _other_revision]]}} ->
        {:error, :conflict}

      {:ok, %{rows: []}} ->
        {:error, :conflict}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp insert_evidence_exact(table, columns, values) do
    placeholders = Enum.map_join(1..length(values), ", ", &"$#{&1}")
    body = List.last(values)
    record_key = hd(values)

    case Repo.query(
           "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders}) ON CONFLICT DO NOTHING RETURNING 1",
           values
         ) do
      {:ok, %{rows: [[1]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        case Repo.query("SELECT body FROM #{table} WHERE record_key = $1", [record_key]) do
          {:ok, %{rows: [[^body]]}} -> :ok
          {:ok, _other} -> {:error, :conflict}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp insert_obligation_exact(namespace_key, run_id, obligation) do
    case Repo.query(
           """
           INSERT INTO triage_projection_obligations (namespace_key, run_id, payload)
           VALUES ($1, $2, $3)
           ON CONFLICT DO NOTHING
           RETURNING 1
           """,
           [namespace_key, run_id, obligation]
         ) do
      {:ok, %{rows: [[1]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        case Repo.query(
               "SELECT payload FROM triage_projection_obligations WHERE namespace_key = $1 AND run_id = $2",
               [namespace_key, run_id]
             ) do
          {:ok, %{rows: [[^obligation]]}} -> :ok
          {:ok, _other} -> {:error, :conflict}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp insert_product_obligation_exact(_namespace_key, _run_id, nil), do: :ok

  defp insert_product_obligation_exact(namespace_key, run_id, obligation)
       when is_map(obligation) do
    case Repo.query(
           """
           INSERT INTO triage_product_obligations
             (namespace_key, run_id, obligation_id, payload)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT DO NOTHING
           RETURNING 1
           """,
           [namespace_key, run_id, obligation["obligation_id"], obligation]
         ) do
      {:ok, %{rows: [[1]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        case Repo.query(
               "SELECT payload FROM triage_product_obligations WHERE namespace_key = $1 AND run_id = $2",
               [namespace_key, run_id]
             ) do
          {:ok, %{rows: [[^obligation]]}} -> :ok
          {:ok, _other} -> {:error, :conflict}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp insert_companion_product_obligation_exact(_namespace_key, _run_id, nil), do: :ok

  defp insert_companion_product_obligation_exact(namespace_key, run_id, obligation)
       when is_map(obligation) do
    case Repo.query(
           """
           INSERT INTO triage_companion_reaction_obligations
             (namespace_key, run_id, obligation_id, payload)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT DO NOTHING
           RETURNING 1
           """,
           [namespace_key, run_id, obligation["obligation_id"], obligation]
         ) do
      {:ok, %{rows: [[1]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        case Repo.query(
               "SELECT payload FROM triage_companion_reaction_obligations WHERE namespace_key = $1 AND run_id = $2",
               [namespace_key, run_id]
             ) do
          {:ok, %{rows: [[^obligation]]}} -> :ok
          {:ok, _other} -> {:error, :conflict}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp fence_identity(key) do
    with [_, namespace_key, path] <- Regex.run(@root, key),
         ["seals", bucket_key, generation_file] <- String.split(path, "/"),
         {:ok, generation_key} <- leaf(generation_file) do
      {:ok, namespace_key, bucket_key, generation_key}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp run_identity(key, prefix) do
    with [_, namespace_key, path] <- Regex.run(@root, key),
         true <- String.starts_with?(path, prefix),
         {:ok, run_id} <- path |> String.replace_prefix(prefix, "") |> leaf() do
      {:ok, namespace_key, run_id}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp leaf(value) do
    case String.split(value, ".json", parts: 2) do
      [leaf, ""] when leaf != "" -> {:ok, leaf}
      _invalid -> {:error, :invalid}
    end
  end

  defp valid_commit_shape?(commit, namespace_key, run_id) do
    valid_authoritative_commit_keys?(commit) and
      is_map(commit.fence) and commit.fence["run_id"] == run_id and
      not is_nil(commit.fence["terminal"]) and
      is_map(commit.run) and commit.run["run_id"] == run_id and
      is_map(commit.replay) and commit.replay["run_id"] == run_id and
      valid_obligation?(commit.obligation, namespace_key, run_id, commit.fence_key) and
      valid_product_obligation?(
        commit.product_obligation,
        namespace_key,
        run_id,
        commit.fence_key
      ) and
      valid_companion_product_obligation?(
        commit[:companion_product_obligation],
        namespace_key,
        run_id,
        commit.fence_key
      )
  end

  defp valid_authoritative_commit_keys?(commit) do
    base =
      ~w(
        fence_key expected_etag fence run_key run replay_key replay obligation
        product_obligation
      )a

    optional = [:companion_product_obligation, :archived_generations]
    keys = Map.keys(commit)

    Enum.all?(base, &(&1 in keys)) and Enum.all?(keys, &(&1 in base or &1 in optional)) and
      valid_archived_generations?(Map.get(commit, :archived_generations, []))
  end

  # At most one bounded backlog per commit. Each entry names one generation and
  # the physical source key of each receipt in it.
  defp valid_archived_generations?(entries) do
    is_list(entries) and length(entries) <= @max_archived_generations + 1 and
      Enum.all?(entries, fn
        %{generation: generation, sources: sources, attach: attach}
        when is_binary(generation) and is_map(sources) and (is_nil(attach) or is_map(attach)) ->
          Enum.all?(sources, fn {ref, key} ->
            is_binary(ref) and is_binary(key) and key =~ ~r/\A[0-9a-f]{64}\z/
          end)

        _invalid ->
          false
      end)
  end

  defp valid_product_obligation?(nil, _namespace_key, _run_id, _fence_key), do: true

  defp valid_product_obligation?(obligation, namespace_key, run_id, fence_key)
       when is_map(obligation) do
    namespace = obligation["namespace"]
    obligation_id = obligation["obligation_id"]

    base_keys =
      ~w(
        schema obligation_id namespace fence_key run_id target product_identity communication
        context_candidates delegations target_cutoff settled_at
      )

    accepted_keys = [
      base_keys,
      ["source_messages" | base_keys],
      ["source_authority", "source_messages" | base_keys],
      ["reaction_authority" | base_keys],
      ["reaction_authority", "source_messages" | base_keys],
      ["reaction_authority", "source_authority", "source_messages" | base_keys]
    ]

    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["recheck_event_ids" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["recheck_context_refs" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["source_window" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["context_sources" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["expression_context" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["ordinary_worker_assignment" | &1])
    recheck_event_ids = Map.get(obligation, "recheck_event_ids", [])
    recheck_context_refs = Map.get(obligation, "recheck_context_refs", [])

    Enum.any?(accepted_keys, &exact_keys?(obligation, &1)) and
      (not Map.has_key?(obligation, "ordinary_worker_assignment") or
         obligation["ordinary_worker_assignment"] == true) and
      valid_product_context_sources?(Map.get(obligation, "context_sources", [])) and
      (not Map.has_key?(obligation, "expression_context") or
         (is_map(obligation["expression_context"]) and
            valid_product_reaction_authority?(obligation["expression_context"]))) and
      valid_product_source_window?(Map.get(obligation, "source_window")) and
      is_list(recheck_event_ids) and length(recheck_event_ids) <= 200 and
      Enum.all?(recheck_event_ids, &(is_binary(&1) and String.starts_with?(&1, "recheck:"))) and
      is_list(recheck_context_refs) and length(recheck_context_refs) <= 200 and
      Enum.all?(recheck_context_refs, fn
        nil -> true
        "triage-context://" <> id -> byte_size(id) in 1..2000
        _ -> false
      end) and
      obligation["schema"] == "comma.triage-product-obligation.v1" and
      obligation["run_id"] == run_id and obligation["fence_key"] == fence_key and
      is_binary(namespace) and namespace != "" and
      TriageKeys.namespace_key(namespace) == namespace_key and
      is_binary(obligation_id) and String.starts_with?(obligation_id, "triage-product-") and
      byte_size(obligation_id) == byte_size("triage-product-") + 64 and
      is_map(obligation["target"]) and is_map(obligation["product_identity"]) and
      valid_product_source_messages?(Map.get(obligation, "source_messages", [])) and
      valid_product_reaction_authority?(Map.get(obligation, "reaction_authority")) and
      valid_product_source_authority?(Map.get(obligation, "source_authority", [])) and
      is_map(obligation["communication"]) and is_list(obligation["context_candidates"]) and
      is_list(obligation["delegations"]) and is_map(obligation["target_cutoff"]) and
      is_integer(obligation["settled_at"]) and obligation["settled_at"] > 0
  end

  defp valid_product_obligation?(_obligation, _namespace_key, _run_id, _fence_key), do: false

  defp valid_companion_product_obligation?(nil, _namespace_key, _run_id, _fence_key), do: true

  defp valid_companion_product_obligation?(obligation, namespace_key, run_id, fence_key) do
    valid_product_obligation?(obligation, namespace_key, run_id, fence_key) and
      get_in(obligation, ["communication", "kind"]) == "reaction" and
      obligation["context_candidates"] == [] and obligation["delegations"] == []
  end

  # The IM owner validates policy and attribution before this transaction.
  # Storage preserves the bounded frozen context with the assignment payload.
  defp valid_product_context_sources?(sources) when is_list(sources) and length(sources) <= 20 do
    Enum.all?(sources, fn source ->
      is_map(source) and exact_keys?(source, ~w(kind text source_ref)) and
        source["kind"] in ~w(retained_project_fact retained_decision retained_follow_up) and
        is_binary(source["text"]) and byte_size(source["text"]) <= 16_000 and
        is_binary(source["source_ref"]) and
        String.starts_with?(source["source_ref"], "triage-context://")
    end)
  end

  defp valid_product_context_sources?(_sources), do: false

  defp valid_product_source_window?(nil), do: true

  defp valid_product_source_window?(
         %{
           "oldest_ts_us" => oldest,
           "latest_ts_us" => latest,
           "thread_roots" => roots
         } = window
       ) do
    exact_keys?(window, ~w(oldest_ts_us latest_ts_us thread_roots)) and
      is_integer(oldest) and oldest >= 0 and is_integer(latest) and latest >= oldest and
      is_list(roots) and length(roots) in 1..200 and roots == Enum.sort(Enum.uniq(roots)) and
      Enum.all?(roots, &(is_binary(&1) and Regex.match?(~r/\A[0-9]{1,12}\.[0-9]{1,6}\z/, &1)))
  end

  defp valid_product_source_window?(_invalid), do: false

  defp valid_product_reaction_authority?(nil), do: true

  defp valid_product_reaction_authority?(
         %{
           "schema" => "comma.triage-expression-context.v1",
           "mode" => mode,
           "allow_reactions" => true,
           "allowed_emojis" => allowed_emojis,
           "catalog" => catalog,
           "observed_reactions" => observed_reactions,
           "guidance" => guidance
         } = authority
       ) do
    exact_keys?(
      authority,
      ~w(schema mode allow_reactions allowed_emojis catalog observed_reactions guidance)
    ) and mode in ~w(project social) and is_list(allowed_emojis) and
      length(allowed_emojis) <= 266 and is_map(catalog) and is_list(observed_reactions) and
      length(observed_reactions) <= 32 and is_binary(guidance)
  end

  defp valid_product_reaction_authority?(_authority), do: false

  defp valid_product_source_messages?(messages) when is_list(messages) do
    length(messages) <= 3 and
      Enum.all?(messages, fn
        %{
          "actor_kind" => actor_kind,
          "message_ts" => message_ts,
          "excerpt" => excerpt
        } = message ->
          actor_id = Map.get(message, "actor_id")
          source_shape = Map.delete(message, "file_attachments")

          (exact_keys?(source_shape, ~w(actor_kind message_ts excerpt)) or
             (exact_keys?(source_shape, ~w(actor_id actor_kind message_ts excerpt)) and
                is_binary(actor_id) and byte_size(actor_id) <= 128) or
             (exact_keys?(
                source_shape,
                ~w(actor_id actor_kind message_ts message_ts_us observed_version excerpt)
              ) and is_binary(actor_id) and byte_size(actor_id) <= 128 and
                is_integer(message["message_ts_us"]) and message["message_ts_us"] >= 0 and
                is_integer(message["observed_version"]) and message["observed_version"] >= 0)) and
            (not Map.has_key?(message, "file_attachments") or
               valid_product_file_attachments?(message["file_attachments"])) and
            actor_kind in ~w(agent human system unknown) and is_binary(message_ts) and
            message_ts != "" and is_binary(excerpt) and String.length(excerpt) <= 280

        _invalid ->
          false
      end)
  end

  defp valid_product_source_messages?(_messages), do: false

  # Storage DTO shape only; the IM owner selects and sanitizes Slack metadata.
  defp valid_product_file_attachments?(
         %{"items" => items, "total_count" => count, "truncated" => truncated} = catalogue
       )
       when is_list(items) and is_integer(count) and is_boolean(truncated) do
    exact_keys?(catalogue, ~w(items total_count truncated)) and length(items) <= 10 and
      count >= length(items) and (count == length(items) or truncated) and
      Enum.all?(items, fn
        %{"name" => name, "kind" => kind} = item ->
          exact_keys?(item, ~w(kind name)) and is_binary(name) and byte_size(name) <= 512 and
            kind in ~w(text image audio video pdf file)

        _ ->
          false
      end)
  end

  defp valid_product_file_attachments?(_catalogue), do: false

  defp valid_product_source_authority?(messages) when is_list(messages) do
    length(messages) <= 200 and
      Enum.all?(messages, fn
        %{"message_ts" => message_ts} = message ->
          (exact_keys?(message, ~w(message_ts)) or
             (exact_keys?(message, ~w(message_ts message_ts_us observed_version)) and
                is_integer(message["message_ts_us"]) and message["message_ts_us"] >= 0 and
                is_integer(message["observed_version"]) and message["observed_version"] >= 0)) and
            is_binary(message_ts) and message_ts != ""

        _invalid ->
          false
      end)
  end

  defp valid_product_source_authority?(_messages), do: false

  defp valid_obligation?(obligation, namespace_key, run_id, fence_key)
       when is_map(obligation) do
    namespace = obligation["namespace"]

    exact_keys?(
      obligation,
      ~w(schema namespace fence_key run_id correlations activity_required time_required)
    ) and
      obligation["schema"] == "comma.triage-projection-obligation.v1" and
      obligation["run_id"] == run_id and obligation["fence_key"] == fence_key and
      is_binary(namespace) and namespace != "" and
      SalixStore.TriageKeys.namespace_key(namespace) == namespace_key and
      is_list(obligation["correlations"]) and is_boolean(obligation["activity_required"]) and
      obligation["time_required"] == true
  end

  defp valid_obligation?(_obligation, _namespace_key, _run_id, _fence_key), do: false

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp normalize_transaction({:ok, result}), do: {:ok, result}

  defp normalize_transaction({:error, reason}) when reason in [:conflict, :invalid, :unavailable],
    do: {:error, reason}

  defp normalize_transaction({:error, _reason}), do: {:error, :unavailable}

  defp etag(revision), do: "pg:#{revision}"

  defp revision("pg:" <> encoded) do
    case Integer.parse(encoded) do
      {value, ""} when value > 0 -> {:ok, value}
      _invalid -> {:error, :invalid}
    end
  end

  defp revision(_etag), do: {:error, :invalid}
end
