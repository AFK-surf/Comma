defmodule SalixStore.S3 do
  @moduledoc """
  The narrow S3 interface the whole storage kernel is built on.

  The contract (per-object linearizable conditional writes, content-hash
  ETags, ambiguous outcomes) is modeled in tla/salix/S3.tla; changes
  to conditional-write or ETag semantics must move that module.

  This module is both the **behaviour** every backend implements and the
  **public dispatcher** that routes to the configured backend
  (`SalixStore.Config.backend/0`). Two backends exist:

    * `SalixStore.S3.AWS`  — real S3 / MinIO over Finch + SigV4
    * `SalixStore.S3.Fake` — in-memory, fault-injecting, for property tests

  ## Conditional-write contract (the design's linchpin)

  All mutating ops support backend-native conditional operations and normalize
  the failure into a single tagged error so callers can branch deterministically.
  The `etag` value is an opaque object version token: an S3 ETag in normal mode,
  or a GCS generation in `storage.atomic_operations = "gcp"` mode.

    * `put/3` with `if_none_match: "*"` → create-once. Returns
      `{:error, :precondition_failed}` (HTTP 412) if the key already exists.
    * `put/3` with `if_match: etag` → compare-and-swap. Returns
      `{:error, :precondition_failed}` if the live object token differs.
    * `delete/2` with `if_match: etag` → conditional delete.

  A clean `{:error, :precondition_failed}` is guaranteed to be a genuine
  conflict with someone else's write — callers may safely re-read and
  re-run CAS logic against it — with one crucial carve-out: when the
  backend transport retried a CONDITIONAL mutation (PUT or DELETE) and the
  retry answered 412, attempt 1 may itself have landed and be the very
  version the retry conflicts with. The adapter (the only layer that knows
  the retry history) classifies that case as
  `{:error, {:ambiguous, :conditional_retry_412}}`, never as a clean
  conflict.

  Other ambiguous outcomes (timeout / 5xx / closed connection, where the
  write may or may not have landed) surface as
  `{:error, {:ambiguous, reason}}`. On any ambiguous result the caller must
  settle by read-back (e.g. `SalixStore.CasDirectory`'s op-token ring)
  before treating the operation as failed OR succeeded.
  """

  @type key :: String.t()
  @type etag :: String.t()
  @type put_opt ::
          {:if_none_match, String.t()}
          | {:if_match, etag()}
          | {:content_type, String.t()}
          | {:content_length, non_neg_integer()}
          | {:meta, %{optional(String.t()) => String.t()}}
  @type get_opt ::
          {:range, {non_neg_integer(), non_neg_integer()}}
          | {:if_none_match, etag()}
  @type object_meta :: %{
          key: key(),
          etag: etag(),
          size: non_neg_integer(),
          last_modified: String.t()
        }

  @callback put(key(), iodata(), [put_opt()]) ::
              {:ok, %{etag: etag()}}
              | {:error, :precondition_failed}
              | {:error, {:ambiguous, term()}}
              | {:error, term()}
  @callback put_stream(key(), Enumerable.t(), [put_opt()]) ::
              {:ok, %{etag: etag()}}
              | {:error, :precondition_failed}
              | {:error, {:ambiguous, term()}}
              | {:error, term()}
  @callback multipart_create(key(), [put_opt()]) ::
              {:ok, String.t()}
              | {:error, :precondition_failed}
              | {:error, {:ambiguous, term()}}
              | {:error, term()}
  @callback multipart_upload_part(key(), String.t(), pos_integer(), binary()) ::
              {:ok, %{etag: etag()}}
              | {:error, {:ambiguous, term()}}
              | {:error, term()}
  @callback multipart_complete(key(), String.t(), [%{part_number: pos_integer(), etag: etag()}]) ::
              {:ok, %{etag: etag()}}
              | {:error, {:ambiguous, term()}}
              | {:error, term()}
  @callback multipart_abort(key(), String.t()) :: :ok | {:error, term()}
  @callback multipart_uploads(key(), keyword()) ::
              {:ok,
               %{
                 uploads: [%{key: key(), upload_id: String.t()}],
                 next: map() | nil
               }}
              | {:error, term()}
  @callback get(key(), [get_opt()]) ::
              {:ok, %{body: binary(), etag: etag(), meta: map()}}
              | {:error, :not_found}
              | {:error, :not_modified}
              | {:error, term()}
  @callback stream(key(), [get_opt()]) ::
              {:ok, Enumerable.t()}
              | {:error, :not_found}
              | {:error, :not_modified}
              | {:error, term()}
  @callback head(key()) ::
              {:ok, object_meta()} | {:error, :not_found} | {:error, term()}
  @callback delete(key(), [{:if_match, etag()}]) ::
              :ok
              | {:error, :precondition_failed}
              | {:error, :not_found}
              | {:error, {:ambiguous, term()}}
              | {:error, term()}
  @callback list(key(), keyword()) ::
              {:ok,
               %{
                 objects: [object_meta()],
                 common_prefixes: [key()],
                 next: String.t() | nil
               }}
              | {:error, term()}

  @optional_callbacks multipart_uploads: 2

  # ---- public dispatch ----

  @spec put(key(), iodata(), [put_opt()]) :: term()
  def put(key, body, opts \\ []),
    do: observe("store_put", fn -> backend().put(key, body, opts) end)

  @spec put_stream(key(), Enumerable.t(), [put_opt()]) :: term()
  def put_stream(key, stream, opts \\ []), do: backend().put_stream(key, stream, opts)

  @spec multipart_create(key(), [put_opt()]) :: term()
  def multipart_create(key, opts \\ []), do: backend().multipart_create(key, opts)

  @spec multipart_upload_part(key(), String.t(), pos_integer(), binary()) :: term()
  def multipart_upload_part(key, upload_id, part_number, body),
    do: backend().multipart_upload_part(key, upload_id, part_number, body)

  @spec multipart_complete(key(), String.t(), [%{part_number: pos_integer(), etag: etag()}]) ::
          term()
  def multipart_complete(key, upload_id, parts),
    do: backend().multipart_complete(key, upload_id, parts)

  @spec multipart_abort(key(), String.t()) :: term()
  def multipart_abort(key, upload_id), do: backend().multipart_abort(key, upload_id)

  @doc "List a bounded page of incomplete multipart uploads under an exact key prefix."
  @spec multipart_uploads(key(), keyword()) :: term()
  def multipart_uploads(prefix, opts \\ []) do
    backend = backend()

    if function_exported?(backend, :multipart_uploads, 2) do
      backend.multipart_uploads(prefix, opts)
    else
      {:error, :unsupported}
    end
  end

  @spec get(key(), [get_opt()]) :: term()
  def get(key, opts \\ []), do: observe("store_get", fn -> backend().get(key, opts) end)

  @spec stream(key(), [get_opt()]) :: term()
  def stream(key, opts \\ []), do: backend().stream(key, opts)

  @spec head(key()) :: term()
  def head(key), do: backend().head(key)

  @spec delete(key(), [{:if_match, etag()}]) :: term()
  def delete(key, opts \\ []), do: backend().delete(key, opts)

  @spec list(key(), keyword()) :: term()
  def list(prefix, opts \\ []), do: observe("store_list", fn -> backend().list(prefix, opts) end)

  @doc "List every object under a prefix, following continuation tokens."
  @spec list_all(key(), keyword()) :: {:ok, [object_meta()]} | {:error, term()}
  def list_all(prefix, opts \\ []) do
    do_list_all(prefix, opts, [])
  end

  defp do_list_all(prefix, opts, acc) do
    case list(prefix, opts) do
      {:ok, %{objects: objs, next: nil}} ->
        {:ok, acc ++ objs}

      {:ok, %{objects: objs, next: token}} ->
        do_list_all(prefix, Keyword.put(opts, :continuation_token, token), acc ++ objs)

      {:error, _} = err ->
        err
    end
  end

  defp backend, do: SalixStore.Config.backend()

  defp observe(operation, fun) do
    SalixStore.Inflight.track(operation, fn -> observe_terminal(operation, fun) end)
  end

  # Duration/outcome are terminal-state observations; the surrounding
  # Inflight.track is what keeps a still-running operation visible.
  defp observe_terminal(operation, fun) do
    started = System.monotonic_time()

    try do
      result = fun.()

      :telemetry.execute(
        [:salix, :operation, :stop],
        %{duration: System.monotonic_time() - started},
        %{
          component: "salix_store",
          operation: operation,
          surface: SystemsObservability.Context.current_surface(),
          outcome: outcome(result)
        }
      )

      result
    rescue
      exception ->
        :telemetry.execute(
          [:salix, :operation, :stop],
          %{duration: System.monotonic_time() - started},
          %{
            component: "salix_store",
            operation: operation,
            surface: SystemsObservability.Context.current_surface(),
            outcome: "error"
          }
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp outcome({:error, :precondition_failed}), do: "conflict"
  defp outcome({:error, :not_found}), do: "ok"
  defp outcome({:error, :timeout}), do: "timeout"
  defp outcome({:error, :unavailable}), do: "unavailable"
  defp outcome({:error, _reason}), do: "error"
  defp outcome(_result), do: "ok"
end
