defmodule SalixStore.S3.Settle do
  @moduledoc """
  The one ambiguity-settlement primitive for S3 object writes.

  Every conditional write in the internal-session storage plane funnels
  through here (docs/storage-search.md, #786
  round-3 structural contract): normal hot-object flush, archive object
  publication, migration backups, and fork target creation. An ambiguous
  transport response is never surfaced raw — it is settled by reading the
  object back, inside ONE bounded budget that also absorbs transient
  read-back failures (a landed write followed by one flaky GET must not
  report an ordinary error, or the caller would re-materialize records
  that carry no dedupe key).

  Two write modes:

  * `cas_put/4` — conditional overwrite (`if_match: etag`, or
    `if_none_match: "*"` when the base is nil). Settlement by read-back:
    our exact bytes ⇒ landed; the unchanged base ETag ⇒ the SAME bytes
    retry (never a re-materialization); anything else ⇒
    `{:error, :precondition_failed}` so both takeover outcomes share the
    caller's rebase path. A settlement read is NOT a fence against our own
    in-flight request: after any ambiguity, a later 412 is re-settled by
    read-back rather than reported as a conflict, because the original
    request may have landed between the read and the retry.

  * `create_once/3` — `if_none_match: "*"` where both `:precondition_failed`
    and an ambiguous response settle through a caller-supplied `settle_fn`
    that decides whether the object now at the key is our own landed write
    (`:own`) or a foreign one (`:foreign`). Deterministic materializations
    (the first archive append, backups) recognize themselves by byte
    equality; fork
    targets by persisted identity — settlement is by identity, never by
    recomputed bytes (#756).

  Budget exhaustion returns `{:error, :settlement_indeterminate}`. The
  caller MUST NOT blindly re-issue the materialization after that.
  `:final_readback_attempts` adds a read-only settlement budget against the
  original candidate bytes. It does not rebuild or re-encode the candidate.
  An unchanged base or initial absence remains indeterminate until another
  read proves the outcome. Neither observation fences an in-flight PUT.
  """

  alias SalixStore.S3

  @attempts 4

  @type read_back :: %{body: binary(), etag: String.t() | nil}
  @type verdict :: :own | :foreign
  @type settle_fn :: (read_back() -> verdict())

  @doc """
  Conditional overwrite with read-back settlement.

  Returns `:ok` (landed), `{:error, :precondition_failed}` (another writer
  holds the object — rebase), `{:error, :settlement_indeterminate}`
  (budget exhausted while the outcome is unknown), or the underlying
  transport error for a plainly failed PUT.
  """
  @spec cas_put(String.t(), binary(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def cas_put(key, body, base_etag, opts \\ []) do
    case cas_put_with_etag(key, body, base_etag, opts) do
      {:ok, _etag, _outcome} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Conditional overwrite that also returns the exact committed/read-back ETag.

  This is the cache-owner variant of `cas_put/4`: it avoids a second GET that
  could pair the committed body with a later writer's ETag. The outcome is
  `:ok` for an unambiguous PUT and `:ambiguous_settled` when exact-byte
  read-back proved that an ambiguous attempt landed.
  """
  @spec cas_put_with_etag(String.t(), binary(), String.t() | nil, keyword()) ::
          {:ok, String.t(), :ok | :ambiguous_settled} | {:error, term()}
  def cas_put_with_etag(key, body, base_etag, opts \\ []) do
    result =
      case do_cas_put(key, body, base_etag, Keyword.get(opts, :attempts, @attempts), false) do
        {:error, :settlement_indeterminate} ->
          final_cas_readback(key, body, base_etag, Keyword.get(opts, :final_readback_attempts, 0))

        result ->
          result
      end

    emit(:cas, result)
    result
  end

  defp do_cas_put(_key, _body, _base_etag, attempts, _in_flight?) when attempts <= 0,
    do: {:error, :settlement_indeterminate}

  defp do_cas_put(key, body, base_etag, attempts, in_flight?) do
    condition = if base_etag, do: [if_match: base_etag], else: [if_none_match: "*"]

    case S3.put(key, body, condition) do
      {:ok, %{etag: etag}} ->
        {:ok, etag, if(in_flight?, do: :ambiguous_settled, else: :ok)}

      # A 412 is proof of "did not land" ONLY when nothing of ours can still
      # be in flight. Once an attempt has come back ambiguous, the settlement
      # read is not a fence: the original request may land between that read
      # and this retry, and the retry then takes a stale 412 for OUR OWN
      # write. Re-settle instead of reporting a conflict the caller would
      # answer by re-running the reducer — which duplicates every record that
      # carries no dedupe key.
      {:error, :precondition_failed} = err ->
        if in_flight?, do: settle_cas(key, body, base_etag, attempts - 1, true), else: err

      {:error, {:ambiguous, _}} ->
        settle_cas(key, body, base_etag, attempts, true)

      {:error, _} = err ->
        err
    end
  end

  defp settle_cas(_key, _body, _base_etag, attempts, _in_flight?) when attempts <= 0,
    do: {:error, :settlement_indeterminate}

  defp settle_cas(key, body, base_etag, attempts, in_flight?) do
    case S3.get(key) do
      {:ok, %{body: ^body, etag: etag}} ->
        {:ok, etag, :ambiguous_settled}

      {:ok, %{etag: ^base_etag}} ->
        do_cas_put(key, body, base_etag, attempts - 1, in_flight?)

      {:ok, _other} ->
        {:error, :precondition_failed}

      {:error, :not_found} when is_nil(base_etag) ->
        do_cas_put(key, body, nil, attempts - 1, in_flight?)

      {:error, :not_found} ->
        {:error, :precondition_failed}

      {:error, _transient} ->
        settle_cas(key, body, base_etag, attempts - 1, in_flight?)
    end
  end

  defp final_cas_readback(_key, _body, _base, attempts) when attempts <= 0,
    do: {:error, :settlement_indeterminate}

  defp final_cas_readback(key, body, base, attempts) do
    case S3.get(key) do
      {:ok, %{body: ^body, etag: etag}} ->
        {:ok, etag, :ambiguous_settled}

      {:ok, %{etag: ^base}} ->
        final_cas_readback(key, body, base, attempts - 1)

      {:ok, _other} ->
        {:error, :precondition_failed}

      {:error, :not_found} when is_nil(base) ->
        final_cas_readback(key, body, base, attempts - 1)

      {:error, _reason} ->
        final_cas_readback(key, body, base, attempts - 1)
    end
  end

  @doc """
  Create-once with read-back settlement.

  Returns `:created` (our PUT landed first), `:landed` (the object exists
  and `settle_fn` recognized it as our own write), `{:exists, read_back}`
  (a foreign object holds the key — the caller decides whether that is
  convergence-divergence, a conflict, or an adoptable existing target),
  `{:error, :settlement_indeterminate}`, or the transport error.
  """
  @spec create_once(String.t(), binary(), settle_fn(), keyword()) ::
          :created | :landed | {:exists, read_back()} | {:error, term()}
  def create_once(key, body, settle_fn, opts \\ []) when is_function(settle_fn, 1) do
    key
    |> do_create_once(body, settle_fn, Keyword.get(opts, :attempts, @attempts))
    |> tap(&emit(:create_once, &1))
  end

  defp do_create_once(_key, _body, _settle_fn, attempts) when attempts <= 0,
    do: {:error, :settlement_indeterminate}

  defp do_create_once(key, body, settle_fn, attempts) do
    case S3.put(key, body, if_none_match: "*") do
      {:ok, _} -> :created
      {:error, :precondition_failed} -> settle_create(key, body, settle_fn, attempts)
      {:error, {:ambiguous, _}} -> settle_create(key, body, settle_fn, attempts)
      {:error, _} = err -> err
    end
  end

  defp settle_create(_key, _body, _settle_fn, attempts) when attempts <= 0,
    do: {:error, :settlement_indeterminate}

  defp settle_create(key, body, settle_fn, attempts) do
    case S3.get(key) do
      {:ok, %{body: got} = read_back} ->
        case settle_fn.(%{body: got, etag: Map.get(read_back, :etag)}) do
          :own -> :landed
          :foreign -> {:exists, %{body: got, etag: Map.get(read_back, :etag)}}
        end

      {:error, :not_found} ->
        do_create_once(key, body, settle_fn, attempts - 1)

      {:error, _transient} ->
        settle_create(key, body, settle_fn, attempts - 1)
    end
  end

  # Bounded mode/outcome observability: no ids, no dynamic reasons — the
  # settlement protocol is a real failure boundary and its outcomes must be
  # countable (metric: salix.storage.settlement.total).
  defp emit(mode, result) do
    outcome =
      case result do
        {:ok, _etag, _outcome} -> :ok
        :ok -> :ok
        :created -> :created
        :landed -> :landed
        {:exists, _} -> :exists
        {:error, :precondition_failed} -> :precondition_failed
        {:error, :settlement_indeterminate} -> :indeterminate
        {:error, _} -> :error
      end

    :telemetry.execute([:salix, :storage, :settlement], %{count: 1}, %{
      mode: mode,
      outcome: outcome
    })
  end

  @doc "The byte-equality settle for deterministic materializations."
  @spec byte_settle(binary()) :: settle_fn()
  def byte_settle(bytes), do: fn %{body: got} -> if got == bytes, do: :own, else: :foreign end
end
