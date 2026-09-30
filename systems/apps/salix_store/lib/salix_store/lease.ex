defmodule SalixStore.Lease do
  @moduledoc """
  Generic fail-closed lease on an arbitrary conditional-record key.
  The same CAS protocol as the singleton lease but keyed by any string, used for
  `(tenant, platform)` bridge leadership: acquire/renew/release via conditional
  writes, stale takeover, and surrender on any failed ownership proof. Native
  Triage addresses are resolved through its PostgreSQL record store; all other
  addresses retain the existing S3 backend.

  Safety is the ETag, never the clock; `lease_until` only gates steal eligibility.

  Modeled in tla/salix/Lease.tla (with S3Lease); note the checked
  caveat there: epochs reset across release/recreate — fence by ETag only.
  Precondition: `holder` must uniquely identify one live contending process
  (acquire's mine-branch and renew's ambiguity verify compare holder only).
  """

  alias SalixStore.{S3, TriageRecordStore}

  @type t :: %__MODULE__{
          key: String.t(),
          holder: String.t(),
          epoch: non_neg_integer(),
          etag: String.t(),
          lease_until: integer()
        }
  defstruct [:key, :holder, :epoch, :etag, :lease_until]

  @default_ttl 30_000

  @spec acquire(String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, {:held_by, String.t() | nil, integer() | nil}} | {:error, term()}
  def acquire(key, holder, opts \\ []) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @default_ttl

    case store(key).get(key) do
      {:error, :not_found} ->
        create(key, holder, now, ttl)

      {:ok, %{body: body, etag: etag}} ->
        cur = Jason.decode!(body)

        cond do
          cur["holder"] == holder -> cas_take(key, holder, etag, cur["epoch"], now, ttl)
          stale?(cur, now) -> cas_take(key, holder, etag, cur["epoch"], now, ttl)
          true -> {:error, {:held_by, cur["holder"], cur["lease_until"]}}
        end

      other ->
        other
    end
  end

  @spec renew(t(), keyword()) :: {:ok, t()} | {:error, :lost} | {:error, term()}
  def renew(%__MODULE__{} = token, opts \\ []) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @default_ttl
    body = Jason.encode!(%{holder: token.holder, epoch: token.epoch, lease_until: now + ttl})

    case store(token.key).put(token.key, body, if_match: token.etag) do
      {:ok, %{etag: etag}} -> {:ok, %{token | etag: etag, lease_until: now + ttl}}
      {:error, :precondition_failed} -> {:error, :lost}
      {:error, {:ambiguous, _}} -> verify(token, now + ttl)
      other -> other
    end
  end

  @doc """
  Checks ownership without rewriting a lease that has enough time remaining.

  `min_remaining_ms` must cover the caller's next bounded work phase and its
  request margin. It defaults to half the requested TTL. The clock selects
  HEAD versus conditional PUT; only the remote ETag proves ownership. A lost
  or unreadable object still fails closed before the caller starts work.
  """
  @spec renew_if_due(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def renew_if_due(%__MODULE__{} = token, opts \\ []) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @default_ttl
    min_remaining = Keyword.get(opts, :min_remaining_ms, div(ttl, 2))

    if token.lease_until - now <= min_remaining do
      renew(token, opts)
    else
      with :ok <- assert_owner(token) do
        # A slow HEAD can consume the phase's headroom too.
        if token.lease_until - (opts[:now] || now_ms()) <= min_remaining,
          do: renew(token, opts),
          else: {:ok, token}
      end
    end
  end

  @doc """
  Proves that `token` still names the live lease object without mutating it.

  Lease ownership is the exact object ETag, not the holder's local clock. Any
  replacement, deletion, or object-store read failure therefore loses the
  proof and fails closed.
  """
  @spec assert_owner(t()) :: :ok | {:error, :lost}
  def assert_owner(%__MODULE__{} = token) do
    case store(token.key).head(token.key) do
      {:ok, %{etag: etag}} when etag == token.etag -> :ok
      _ -> {:error, :lost}
    end
  end

  @spec release(t()) :: :ok
  def release(%__MODULE__{} = token) do
    _ = store(token.key).delete(token.key, if_match: token.etag)
    :ok
  end

  # ---- internal ----

  defp create(key, holder, now, ttl) do
    body = Jason.encode!(%{holder: holder, epoch: 1, lease_until: now + ttl})

    case store(key).put(key, body, if_none_match: "*") do
      {:ok, %{etag: etag}} ->
        {:ok, %__MODULE__{key: key, holder: holder, epoch: 1, etag: etag, lease_until: now + ttl}}

      {:error, :precondition_failed} ->
        acquire(key, holder, now: now, ttl_ms: ttl)

      other ->
        other
    end
  end

  defp cas_take(key, holder, etag, prev_epoch, now, ttl) do
    epoch = (prev_epoch || 0) + 1
    body = Jason.encode!(%{holder: holder, epoch: epoch, lease_until: now + ttl})

    case store(key).put(key, body, if_match: etag) do
      {:ok, %{etag: new_etag}} ->
        {:ok,
         %__MODULE__{
           key: key,
           holder: holder,
           epoch: epoch,
           etag: new_etag,
           lease_until: now + ttl
         }}

      {:error, :precondition_failed} ->
        {:error, {:held_by, :unknown, nil}}

      other ->
        other
    end
  end

  defp verify(token, expected_until) do
    case store(token.key).get(token.key) do
      {:ok, %{body: body, etag: etag}} ->
        cur = Jason.decode!(body)

        if cur["holder"] == token.holder,
          do: {:ok, %{token | etag: etag, lease_until: expected_until}},
          else: {:error, :lost}

      _ ->
        {:error, :lost}
    end
  end

  defp stale?(cur, now), do: is_nil(cur["lease_until"]) or cur["lease_until"] <= now
  defp now_ms, do: System.system_time(:millisecond)

  defp store(key) do
    if TriageRecordStore.owned?(key), do: TriageRecordStore, else: S3
  end
end
