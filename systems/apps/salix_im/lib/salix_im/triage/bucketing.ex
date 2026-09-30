defmodule SalixIM.Triage.Bucketing do
  @moduledoc """
  Durable receipt projection, open-bucket owner, and generation seal for Triage.

  The provider receipt is the inbox truth. Marker, source alias, and bucket
  records are strict, immutable-or-CAS projections that may be rebuilt from it.

  The Runtime owns timers and scheduling. This module owns the durable bucket
  key, record bytes, compare-and-set append/load/seal effects, scope identity,
  receipt ordering and deduplication, debounce/max-wait deadlines, fast-path
  promotion, and generation transitions. Time remains an explicit input to the
  seal interface so replay and recovery use the same deterministic decision.

  Production recipient admission is owned by `SalixIM.Triage.Admission` and
  modeled in `tla/salix/TriageReceiptAdmission.tla`; this module's S3
  claim/append functions remain the explicit fault-injection compatibility
  backend. Sealed-generation reconciliation is modeled in
  `tla/salix/TriageBucketRecovery.tla`.
  """

  alias SalixIM.ProviderReceipts
  alias SalixStore.{CasRecord, ULID}

  @type policy :: %{
          required(:debounce_ms) => non_neg_integer(),
          required(:max_wait_ms) => non_neg_integer() | :infinity
        }

  @durable_bucket_keys ~w(
    schema bucket_scope open_generation open_first_at open_last_at open_fast_path
    open_receipts sealed_generations
  )
  @sealed_generation_keys ~w(generation receipts sealed_at)
  @max_batch_receipts 200

  def claim_receipt(namespace, receipt) when is_binary(namespace) and namespace != "" do
    with :ok <- validate_receipt(receipt),
         {:ok, projection_status} <- claim_projection(namespace, receipt),
         {:ok, source_status} <- claim_source_alias(namespace, receipt) do
      {:ok, projection_status, source_status}
    end
  end

  def claim_receipt(_namespace, _receipt), do: {:error, :invalid_triage_receipt}

  @doc """
  Appends one canonical receipt to the open generation of its bucket.

  `:appended` means the receipt holds open membership after the effect;
  `:duplicate` means the exact receipt is already durable in a sealed
  generation and therefore never re-enters an open one.
  """
  @spec append(String.t(), map()) :: {:ok, :appended | :duplicate} | {:error, term()}
  def append(namespace, receipt) do
    with {:ok, status, _bucket} <- append_membership(namespace, receipt), do: {:ok, status}
  end

  @doc """
  Appends one canonical receipt and returns the durable bucket it landed in.

  The append CAS already read the post-effect bucket, so a caller that needs to
  know the receipt's membership gets it here instead of paying a second storage
  round trip for the record it just wrote.
  """
  @spec append_membership(String.t(), map()) ::
          {:ok, :appended | :duplicate, map()} | {:error, term()}
  def append_membership(namespace, receipt) when is_binary(namespace) and namespace != "" do
    with :ok <- validate_receipt(receipt),
         scope <- scope_key(receipt),
         key <- SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
         {:ok, bucket} <-
           CasRecord.update(key, fn current ->
             append_durable(current, receipt, ULID.generate())
           end),
         :ok <- validate_durable_bucket(bucket, scope) do
      if open_member?(bucket, receipt["receipt_ref"]),
        do: {:ok, :appended, bucket},
        else: {:ok, :duplicate, bucket}
    end
  end

  def append_membership(_namespace, _receipt), do: {:error, :invalid_triage_receipt}

  @doc "Reads one durable bucket record without exposing bucket storage keys."
  @spec load(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load(namespace, scope) when is_binary(namespace) and namespace != "" and is_binary(scope),
    do: CasRecord.get(SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope))

  def load(_namespace, _scope), do: {:error, :invalid_triage_bucket}

  @spec load!(String.t(), String.t()) :: map()
  def load!(namespace, scope) do
    case load(namespace, scope) do
      {:ok, bucket} -> bucket
      {:error, reason} -> raise "triage durable bucket unavailable: #{inspect(reason)}"
    end
  end

  @doc "Loads one exact sealed generation without exposing bucket storage keys."
  @spec load_sealed_generation(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :invalid_bucket | term()}
  def load_sealed_generation(namespace, scope, generation) do
    with {:ok, bucket} <- load(namespace, scope),
         true <- bucket["schema"] == "comma.triage-durable-bucket.v1",
         true <- bucket["bucket_scope"] == scope,
         sealed_generations when is_list(sealed_generations) <- bucket["sealed_generations"],
         %{} = sealed <- Enum.find(sealed_generations, &(&1["generation"] == generation)),
         true <- well_formed_sealed_generation?(sealed) do
      {:ok, sealed}
    else
      nil -> load_archived_generation(namespace, scope, generation)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_bucket}
    end
  end

  defp load_archived_generation(namespace, scope, generation) do
    key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    with {:ok, %{body: bytes}} <- SalixStore.TriageRecordStore.get(key),
         {:ok, fence} <- Jason.decode(bytes),
         true <- fence["bucket_scope"] == scope and fence["generation"] == generation,
         true <- is_map(fence["terminal"]),
         %{} = sealed <- fence["sealed_generation"],
         true <- sealed["generation"] == generation and valid_sealed_generation?(sealed, scope) do
      {:ok, sealed}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_bucket}
    end
  end

  @doc """
  Seals the exact open generation once its debounce/max-wait deadline is due.

  The compare-and-set aborts with the `{:unchanged, record}` idiom whenever the
  generation is not the open one or the deadline has not been reached, so a
  stale timer and a recovery lane can both call this without writing.
  """
  @spec seal(String.t(), String.t(), String.t(), policy(), integer()) ::
          {:ok, map() | {:wait, pos_integer()} | :stale} | {:error, term()}
  def seal(namespace, scope, expected_generation, policy, now_ms)
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_binary(expected_generation) and expected_generation != "" and
             is_integer(now_ms) do
    key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    with :ok <- validate_policy(policy),
         {:ok, bucket} <-
           CasRecord.update(key, fn current ->
             seal_durable(
               current,
               expected_generation,
               now_ms,
               policy,
               ULID.generate(expected_generation)
             )
           end),
         :ok <- validate_durable_bucket(bucket, scope) do
      {:ok, sealed_or_wait(bucket, expected_generation, policy, now_ms)}
    end
  end

  def seal(_namespace, _scope, _generation, _policy, _now_ms),
    do: {:error, :invalid_triage_bucket}

  def scope_key(receipt) do
    event = receipt["triage_event"]
    bucket = event["bucket"]

    Enum.join(
      [
        event["connect_generation"],
        bucket["workspace_id"],
        bucket["channel_id"],
        if(bucket["scope_kind"] == "channel", do: "__channel__", else: bucket["thread_ts"])
      ],
      ":"
    )
  end

  @doc """
  Canonical admission identity for one receipt.

  Ordinary callback and patrol receipts use the generation-free physical Slack
  root, so duplicates cannot re-enter through a peer connect. A scheduled
  recheck is an intentional later observation of that same root and therefore
  uses its deterministic schedule-occurrence event id as a logical source.
  """
  def source_key(%{
        "triage_event" => %{
          "source_mode" => "scheduled_recheck",
          "event_id" => event_id
        }
      }) do
    "scheduled_recheck:" <> event_id
  end

  def source_key(receipt) do
    event = receipt["triage_event"]
    bucket = event["bucket"]

    Enum.join(
      [
        bucket["workspace_id"],
        bucket["channel_id"],
        bucket["thread_ts"],
        event["message_ts"]
      ],
      ":"
    )
  end

  @doc """
  Folds one receipt into the Runtime's process-local view of the open bucket.

  A local view whose generation no longer matches the durable open generation
  is rebuilt from the durable record, so a seal that happened elsewhere always
  wins over stale in-memory state.
  """
  @spec merge_local(map(), map() | nil, map(), integer(), term()) :: map()
  def merge_local(durable, current, receipt, received_at, token) do
    generation = durable["open_generation"]

    bucket =
      case current do
        %{generation: ^generation} = current ->
          current

        _other ->
          %{
            token: token,
            generation: generation,
            first_at: durable["open_first_at"] || received_at,
            last_at: durable["open_last_at"] || received_at,
            fast_path?: durable["open_fast_path"] || false,
            receipts: durable["open_receipts"] || []
          }
      end

    %{
      bucket
      | first_at: min(bucket.first_at, received_at),
        last_at: max(bucket.last_at, received_at),
        fast_path?: bucket.fast_path? or get_in(receipt, ["triage_event", "fast_path"]),
        receipts: append_receipt_once(bucket.receipts, receipt)
    }
  end

  @doc """
  Trailing debounce with an optional max wait; a fast-path bucket is due now.

  Without a time ceiling, the source reader's 200-message capacity still bounds
  an open batch. Continuous activity can postpone a smaller batch until quiet.

  Both timestamps come from receipt `created_at`, which is a REMOTE clock. A
  forward-skewed one used to push `first_at + max_wait_ms` past the ceiling it
  is supposed to enforce — the guarantee "no bucket waits longer than max_wait
  from now" only holds if the inputs are clamped to local now.
  """
  @spec due_at(map(), policy(), integer()) :: integer()
  def due_at(%{fast_path?: true}, _policy, now_ms), do: now_ms

  def due_at(%{receipts: receipts}, %{max_wait_ms: :infinity}, now_ms)
      when length(receipts) >= @max_batch_receipts,
      do: now_ms

  def due_at(bucket, %{max_wait_ms: :infinity} = policy, now_ms),
    do: min(bucket.last_at, now_ms) + policy.debounce_ms

  def due_at(bucket, policy, now_ms) do
    min(
      min(bucket.last_at, now_ms) + policy.debounce_ms,
      min(bucket.first_at, now_ms) + policy.max_wait_ms
    )
  end

  @spec flush_delay(map(), policy(), integer()) :: non_neg_integer()
  def flush_delay(bucket, policy, now_ms),
    do: max(0, due_at(bucket, policy, now_ms) - now_ms)

  def validate_receipt(receipt) when is_map(receipt) do
    case ProviderReceipts.normalize_slack_triage_receipt(receipt) do
      {:ok, _normalized} -> :ok
      _invalid -> {:error, :invalid_triage_receipt}
    end
  end

  def validate_receipt(_receipt), do: {:error, :invalid_triage_receipt}

  defp claim_projection(namespace, receipt) do
    key = SalixStore.TriageKeys.ctl_im_triage_projection_marker(namespace, receipt["receipt_ref"])

    marker = %{
      "schema" => "comma.triage-receipt-projection.v1",
      "receipt_ref" => receipt["receipt_ref"],
      "event_id" => receipt["event_id"]
    }

    create_or_exact(key, marker, :accepted, :duplicate, :triage_projection_conflict)
  end

  # Ordinary alias keys are generation-free (`source_key/1`): one physical
  # Slack root message owns at most one canonical admission across connect
  # generations and peer connects. Scheduled rechecks instead use the stable
  # schedule occurrence event id, allowing one later observation while still
  # deduplicating retries of that occurrence.
  defp claim_source_alias(namespace, receipt) do
    key = SalixStore.TriageKeys.ctl_im_triage_source_alias(namespace, source_key(receipt))

    desired = %{
      "schema" => "comma.triage-source-alias.v1",
      "source_message_ref" => receipt["source_message_ref"],
      "canonical_receipt_ref" => receipt["receipt_ref"]
    }

    case CasRecord.create(key, desired) do
      {:ok, ^desired} ->
        {:ok, :canonical}

      {:ok, _unexpected} ->
        {:error, :triage_source_alias_conflict}

      {:error, :exists} ->
        resolve_source_alias(key, desired)

      {:error, _reason} ->
        resolve_source_alias(key, desired)
    end
  end

  defp resolve_source_alias(key, desired) do
    case CasRecord.get(key) do
      {:ok, ^desired} ->
        {:ok, :canonical}

      {:ok, existing} ->
        if valid_source_alias?(existing),
          do: {:ok, :superseded},
          else: {:error, :triage_source_alias_conflict}

      {:error, _reason} ->
        {:error, :triage_source_alias_unavailable}
    end
  end

  defp valid_source_alias?(alias_record) do
    is_map(alias_record) and
      exact_keys?(alias_record, ~w(schema source_message_ref canonical_receipt_ref)) and
      alias_record["schema"] == "comma.triage-source-alias.v1" and
      canonical_nonblank?(alias_record["source_message_ref"]) and
      canonical_nonblank?(alias_record["canonical_receipt_ref"])
  end

  defp create_or_exact(key, desired, created_status, existing_status, conflict) do
    case CasRecord.create(key, desired) do
      {:ok, ^desired} ->
        {:ok, created_status}

      {:ok, _unexpected} ->
        {:error, conflict}

      {:error, :exists} ->
        case CasRecord.get(key) do
          {:ok, ^desired} -> {:ok, existing_status}
          {:ok, _other} -> {:error, conflict}
          {:error, _reason} -> {:error, :triage_projection_unavailable}
        end

      {:error, _reason} ->
        case CasRecord.get(key) do
          {:ok, ^desired} -> {:ok, created_status}
          {:ok, _other} -> {:error, conflict}
          {:error, _reason} -> {:error, :triage_projection_unavailable}
        end
    end
  end

  @spec append_durable(map() | nil, map(), String.t()) ::
          map() | {:unchanged, map()} | {:error, :invalid_triage_bucket}
  def append_durable(nil, receipt, initial_generation) do
    %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope_key(receipt),
      "open_generation" => initial_generation,
      "open_first_at" => receipt["created_at"],
      "open_last_at" => receipt["created_at"],
      "open_fast_path" => receipt["triage_event"]["fast_path"],
      "open_receipts" => [receipt],
      "sealed_generations" => []
    }
  end

  def append_durable(current, receipt, _initial_generation) when is_map(current) do
    scope = scope_key(receipt)

    with :ok <- validate_durable_bucket(current, scope) do
      if seen_receipt?(current, receipt["receipt_ref"]) do
        {:unchanged, current}
      else
        current
        |> Map.put(
          "open_first_at",
          min_timestamp(current["open_first_at"], receipt["created_at"])
        )
        |> Map.put("open_last_at", max_timestamp(current["open_last_at"], receipt["created_at"]))
        |> Map.put(
          "open_fast_path",
          current["open_fast_path"] or receipt["triage_event"]["fast_path"]
        )
        |> Map.update!("open_receipts", &append_receipt_once(&1, receipt))
      end
    end
  end

  def append_durable(_current, _receipt, _generation),
    do: {:error, :invalid_triage_bucket}

  @doc """
  Moves the exact open generation into `sealed_generations` once it is due.

  Not due, not the open generation, or an empty open generation all abort the
  compare-and-set with `{:unchanged, record}` and write nothing.
  """
  @spec seal_durable(map() | nil, String.t(), integer(), policy(), String.t()) ::
          map() | {:unchanged, map()} | {:error, :missing_bucket}
  def seal_durable(
        %{"open_receipts" => [_ | _], "open_generation" => expected_generation} = current,
        expected_generation,
        now_ms,
        policy,
        next_generation
      ) do
    if now_ms < durable_due_at(current, policy, now_ms) do
      {:unchanged, current}
    else
      sealed = %{
        "generation" => expected_generation,
        "receipts" => current["open_receipts"],
        "sealed_at" => now_ms
      }

      current
      |> Map.put("open_generation", next_generation)
      |> Map.put("open_first_at", nil)
      |> Map.put("open_last_at", nil)
      |> Map.put("open_fast_path", false)
      |> Map.put("open_receipts", [])
      |> Map.update("sealed_generations", [sealed], &(&1 ++ [sealed]))
    end
  end

  def seal_durable(%{} = current, _expected, _now_ms, _policy, _next), do: {:unchanged, current}

  def seal_durable(nil, _expected, _now_ms, _policy, _next), do: {:error, :missing_bucket}

  @doc "Reads the seal outcome of one CAS: the sealed entry, a wait, or staleness."
  @spec sealed_or_wait(map(), String.t(), policy(), integer()) ::
          map() | {:wait, pos_integer()} | :stale
  def sealed_or_wait(bucket, expected_generation, policy, now_ms) do
    case Enum.find(bucket["sealed_generations"] || [], &(&1["generation"] == expected_generation)) do
      %{} = sealed ->
        sealed

      nil ->
        if bucket["open_generation"] == expected_generation,
          do: {:wait, max(1, durable_due_at(bucket, policy, now_ms) - now_ms)},
          else: :stale
    end
  end

  @doc "Durable-record form of `due_at/3`, used by the seal compare-and-set."
  @spec durable_due_at(map(), policy(), integer()) :: integer()
  def durable_due_at(%{"open_fast_path" => true}, _policy, now_ms), do: now_ms

  # An open generation with no receipts has no deadline of its own; callers ask
  # again after one debounce window rather than reading nil timestamps.
  def durable_due_at(%{"open_receipts" => []}, policy, now_ms),
    do: now_ms + max(1, policy.debounce_ms)

  def durable_due_at(bucket, policy, now_ms) do
    due_at(
      %{
        first_at: bucket["open_first_at"],
        last_at: bucket["open_last_at"],
        receipts: bucket["open_receipts"],
        fast_path?: bucket["open_fast_path"]
      },
      policy,
      now_ms
    )
  end

  @doc "Validates one self-identifying durable bucket as both readers and writers persist it."
  @spec validate_durable_bucket(term()) :: :ok | {:error, :invalid_triage_bucket}
  def validate_durable_bucket(%{"bucket_scope" => scope} = bucket) do
    if canonical_nonblank?(scope),
      do: validate_durable_bucket(bucket, scope),
      else: {:error, :invalid_triage_bucket}
  end

  def validate_durable_bucket(_bucket), do: {:error, :invalid_triage_bucket}

  defp validate_durable_bucket(bucket, scope) when is_map(bucket) do
    sealed_generations = bucket["sealed_generations"]

    valid? =
      exact_keys?(bucket, @durable_bucket_keys) and
        bucket["schema"] == "comma.triage-durable-bucket.v1" and
        bucket["bucket_scope"] == scope and canonical_nonblank?(bucket["open_generation"]) and
        is_boolean(bucket["open_fast_path"]) and is_list(bucket["open_receipts"]) and
        is_list(sealed_generations) and
        Enum.all?(sealed_generations, &valid_sealed_generation?(&1, scope)) and
        unique_generations?(bucket, sealed_generations) and
        Enum.all?(bucket["open_receipts"], &(validate_receipt(&1) == :ok)) and
        Enum.all?(bucket["open_receipts"], &(scope_key(&1) == scope)) and
        valid_open_timestamps?(bucket)

    if valid?, do: :ok, else: {:error, :invalid_triage_bucket}
  end

  defp validate_durable_bucket(_bucket, _scope), do: {:error, :invalid_triage_bucket}

  # A sealed generation is immutable evidence of one closed debounce window:
  # exactly three fields, a non-empty ordered receipt set that still belongs to
  # this scope, and the wall-clock instant the seal committed.
  defp valid_sealed_generation?(sealed, scope) do
    well_formed_sealed_generation?(sealed) and
      Enum.all?(sealed["receipts"], &(validate_receipt(&1) == :ok)) and
      Enum.all?(sealed["receipts"], &(scope_key(&1) == scope))
  end

  # Structural shape only. Readers of an already durable seal — the run fence
  # reconstructing its winning input, recovery reconciling generations — apply
  # their own authority checks to the receipts they read, so this stays a
  # record-shape gate rather than a second receipt admission.
  defp well_formed_sealed_generation?(sealed) when is_map(sealed) do
    exact_keys?(sealed, @sealed_generation_keys) and
      canonical_nonblank?(sealed["generation"]) and
      is_integer(sealed["sealed_at"]) and sealed["sealed_at"] > 0 and
      is_list(sealed["receipts"]) and sealed["receipts"] != []
  end

  defp well_formed_sealed_generation?(_sealed), do: false

  defp unique_generations?(bucket, sealed_generations) do
    generations = Enum.map(sealed_generations, & &1["generation"])
    all = [bucket["open_generation"] | generations]
    all == Enum.uniq(all)
  end

  # Both windows may be zero: that is the "seal on the next wake" policy, not a
  # missing one.
  defp validate_policy(%{debounce_ms: debounce_ms, max_wait_ms: max_wait_ms})
       when is_integer(debounce_ms) and debounce_ms >= 0 and
              (max_wait_ms == :infinity or (is_integer(max_wait_ms) and max_wait_ms >= 0)),
       do: :ok

  defp validate_policy(_policy), do: {:error, :invalid_triage_bucket_policy}

  defp valid_open_timestamps?(%{"open_receipts" => []} = bucket),
    do: is_nil(bucket["open_first_at"]) and is_nil(bucket["open_last_at"])

  defp valid_open_timestamps?(bucket) do
    is_integer(bucket["open_first_at"]) and is_integer(bucket["open_last_at"]) and
      bucket["open_first_at"] <= bucket["open_last_at"]
  end

  defp append_receipt_once(receipts, receipt) do
    if Enum.any?(receipts, &(&1["receipt_ref"] == receipt["receipt_ref"])) do
      receipts
    else
      Enum.sort_by([receipt | receipts], fn item ->
        {item["created_at"], get_in(item, ["triage_event", "message_ts"]), item["event_id"]}
      end)
    end
  end

  # A receipt that already reached a sealed generation never re-enters an open
  # one: its evidence is immutable and its evaluation is already owned.
  defp seen_receipt?(current, receipt_ref) do
    member?(current, receipt_ref)
  end

  @doc "Whether one receipt has ever held durable membership in this canonical bucket."
  @spec member?(map(), String.t()) :: boolean()
  def member?(bucket, receipt_ref) when is_map(bucket) do
    open_member?(bucket, receipt_ref) or
      Enum.any?(bucket["sealed_generations"] || [], fn generation ->
        Enum.any?(generation["receipts"] || [], &(&1["receipt_ref"] == receipt_ref))
      end)
  end

  def member?(_bucket, _receipt_ref), do: false

  @doc "Whether one receipt currently holds membership in the open generation."
  @spec open_member?(map(), String.t()) :: boolean()
  def open_member?(bucket, receipt_ref) when is_map(bucket),
    do: Enum.any?(bucket["open_receipts"] || [], &(&1["receipt_ref"] == receipt_ref))

  def open_member?(_bucket, _receipt_ref), do: false

  defp exact_keys?(value, keys),
    do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)

  defp min_timestamp(nil, right), do: right
  defp min_timestamp(left, right), do: min(left, right)
  defp max_timestamp(nil, right), do: right
  defp max_timestamp(left, right), do: max(left, right)
end
