defmodule SalixSignal.Account.PreKeyService do
  @moduledoc """
  Pre-key upload, count and consistency check on the service
  (CRS-03 §9.2 to §9.4), and one maintenance pass over a local
  `SalixSignalProto.PreKeys.Store` (CRS-03 §10).

  Every request uses the account's authenticated transport and selects the
  identity with `identity=aci` or `identity=pni`.
  """

  require Logger

  alias SalixSignal.Account.{KemSupport, Transport}
  alias SalixSignal.Service.Response
  alias SalixSignalProto.PreKeys
  alias SalixSignalProto.PreKeys.Store

  @type kind :: :aci | :pni
  @type error ::
          :invalid_request
          | :malformed
          | :unauthorized
          | {:rate_limited, non_neg_integer() | nil}
          | {:unavailable, non_neg_integer()}
          | {:http_error, non_neg_integer()}
          | {:transport, term()}
          | {:persist, term()}
          | :kem_unsupported

  @doc "The one-time EC and KEM pre-keys the service holds for this device (`GET /v2/keys`)."
  @spec counts(Transport.t(), kind()) :: {:ok, Store.counts()} | {:error, error()}
  def counts(transport, kind) do
    case Transport.request(transport, "GET", path(kind), []) do
      {:ok, %Response{status: 200} = response} ->
        response |> Transport.json_object() |> PreKeys.parse_counts()

      other ->
        failure(other)
    end
  end

  @doc """
  Uploads a `PUT /v2/keys` body. `{:error, :invalid_request}` is a 422: a
  signature did not verify with the stored identity key, and nothing was
  stored (CRS-03 §9.2).
  """
  @spec upload(Transport.t(), kind(), map()) :: :ok | {:error, error()}
  def upload(transport, kind, body) when is_map(body) do
    case Transport.request(transport, "PUT", path(kind), json: body) do
      {:ok, %Response{status: status}} when status in 200..299 -> :ok
      other -> failure(other)
    end
  end

  @doc """
  Runs the consistency check (`POST /v2/keys/check`). `:mismatch` means the
  service holds a different identity key, signed EC pre-key or last-resort
  KEM pre-key for this device (409).
  """
  @spec check(Transport.t(), kind(), Store.t()) :: :ok | :mismatch | {:error, error()}
  def check(transport, kind, %Store{} = store) do
    case Transport.request(transport, "POST", "/v2/keys/check",
           json: Store.check_body(store, kind)
         ) do
      {:ok, %Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Response{status: 409}} -> :mismatch
      other -> failure(other)
    end
  end

  @doc """
  One maintenance pass for identity `kind` at `now_ms`.

  1. With `check: true`, runs the consistency check first; a mismatch
     replaces every published key (`SalixSignalProto.PreKeys.Store.rotate_all/2`).
  2. Otherwise reads the service counts and applies the store policy
     (`SalixSignalProto.PreKeys.Store.refresh/3`).
  3. When keys changed, calls `persist.(store)` before the upload, uploads,
     then calls `persist.(store)` again with the confirmed store.

  `persist` returns `:ok` or `{:error, reason}`; the pass stops on an error.
  When the first write fails, the original store is returned and nothing is
  uploaded.
  A node without constant-time KEM support makes no keys and returns
  `:kem_unsupported` (`SalixSignal.Account.KemSupport`). Returns the store to
  keep. After a failed upload the returned store still
  holds the pending body, and the next pass sends it again, except after a
  400 or 422: the service stored nothing and would reject the body again,
  so the pass drops it, stores the store without it, and falls back to the
  consistency check and the counts in the same pass.
  """
  @spec maintain(
          Transport.t(),
          kind(),
          Store.t(),
          integer(),
          (Store.t() -> :ok | {:error, term()}),
          keyword()
        ) ::
          {:ok, Store.t()} | {:error, error(), Store.t()}
  def maintain(transport, kind, %Store{} = store, now_ms, persist, opts \\ []) do
    with :ok <- KemSupport.check(),
         {:ok, {planned, body}} <- plan(transport, kind, store, now_ms, opts) do
      case publish(transport, kind, store, planned, body, persist) do
        {:error, :invalid_request, rejected} ->
          fall_back(transport, kind, rejected, now_ms, persist)

        result ->
          result
      end
    else
      {:error, reason} -> {:error, reason, store}
    end
  end

  # Owner decision: the service stored nothing of a body it rejected as
  # invalid (400 or 422, CRS-03 §9.2), and it would reject the same body
  # again. The pending body is dropped and stored without it, so no later
  # pass sends it. This pass then runs the consistency check and the counts,
  # which republish what the service lacks (CRS-03 §9.4). A body that this
  # fallback makes and the service rejects is dropped too; the next pass
  # starts again from the check and the counts.
  defp fall_back(transport, kind, rejected, now_ms, persist) do
    Logger.warning("signal pre-key upload rejected as invalid; dropping the pending body",
      identity: kind
    )

    dropped = Store.uploaded(rejected)

    with {:persist, :ok} <- {:persist, persisted(persist.(dropped))},
         {:ok, {planned, body}} <- plan(transport, kind, dropped, now_ms, check: true) do
      case publish(transport, kind, dropped, planned, body, persist) do
        {:error, :invalid_request, again} -> drop_rejected(again, persist)
        result -> result
      end
    else
      # The durable store still holds the rejected body; keep that one.
      {:persist, {:error, reason}} -> {:error, reason, rejected}
      {:error, reason} -> {:error, reason, dropped}
    end
  end

  defp drop_rejected(rejected, persist) do
    Logger.warning("signal pre-key upload rejected as invalid again; dropping it")
    dropped = Store.uploaded(rejected)

    case persisted(persist.(dropped)) do
      :ok -> {:error, :invalid_request, dropped}
      {:error, reason} -> {:error, reason, rejected}
    end
  end

  defp plan(transport, kind, store, now_ms, opts) do
    check_result =
      if Keyword.get(opts, :check, false) and store.pending == nil,
        do: check(transport, kind, store),
        else: :ok

    case check_result do
      :mismatch ->
        {:ok, Store.rotate_all(store, now_ms)}

      :ok ->
        counts =
          if store.pending == nil, do: counts(transport, kind), else: {:ok, nil}

        with {:ok, counts} <- counts, do: {:ok, Store.refresh(store, counts, now_ms)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Nothing to upload; pruning alone need not be stored at once.
  defp publish(_transport, _kind, _original, planned, nil, _persist), do: {:ok, planned}

  # New keys are durable before the upload. A failed write keeps the
  # original store: the new keys never left this process.
  defp publish(transport, kind, original, planned, body, persist) do
    case persisted(persist.(planned)) do
      :ok ->
        with :ok <- upload(transport, kind, body),
             confirmed = Store.uploaded(planned),
             :ok <- persisted(persist.(confirmed)) do
          {:ok, confirmed}
        else
          {:error, reason} -> {:error, reason, planned}
        end

      {:error, reason} ->
        {:error, reason, original}
    end
  end

  defp persisted(:ok), do: :ok
  defp persisted({:error, reason}), do: {:error, {:persist, reason}}

  defp path(kind), do: "/v2/keys?identity=" <> PreKeys.identity_param(kind)

  defp failure({:ok, %Response{status: 400}}), do: {:error, :invalid_request}
  defp failure({:ok, %Response{status: 422}}), do: {:error, :invalid_request}
  defp failure({:ok, %Response{status: 200}}), do: {:error, :malformed}
  defp failure({:ok, response}), do: {:error, Transport.error(response)}
  defp failure({:error, :malformed}), do: {:error, :malformed}
  defp failure({:error, reason}), do: {:error, {:transport, reason}}
end
