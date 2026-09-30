defmodule SalixCluster.S3Lease do
  @moduledoc """
  Singleton leadership via S3 conditional writes:
  `ctl/singletons/{name}.json` holds `{holder, epoch, lease_until}`, acquired and
  renewed by CAS, with stale takeover at 2× the renew interval.

  Fail-closed: a renewal that 412s or cannot reach S3 means leadership is
  lost — the caller must stop acting as leader immediately. Safety never depends
  on the clock; the ETag is the authority. `lease_until` only gates *steal
  eligibility*.

  Returns a `t()` token carrying the live ETag; pass it back to `renew/1` /
  `release/1`.

  Modeled in tla/salix/Lease.tla; note the checked caveat there:
  epochs reset across release/recreate — fence by ETag only. Precondition:
  `holder` must uniquely identify one live contending process (acquire's
  mine-branch and renew's ambiguity verify compare holder only).
  """

  alias SalixStore.{S3, Keys}

  @type name :: :recovery | :metering | :migration | :timers | :schedules
  @type t :: %__MODULE__{
          name: name(),
          holder: String.t(),
          epoch: non_neg_integer(),
          etag: String.t(),
          lease_until: integer()
        }
  defstruct [:name, :holder, :epoch, :etag, :lease_until]

  @default_ttl 30_000

  @doc """
  Try to acquire (or steal-if-stale) the named singleton. Returns
  `{:ok, token}` if we hold it, `{:error, {:held_by, holder, until}}` otherwise.
  """
  @spec acquire(name(), String.t(), keyword()) ::
          {:ok, t()} | {:error, {:held_by, String.t() | nil, integer() | nil}} | {:error, term()}
  def acquire(name, holder, opts \\ []) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @default_ttl
    key = Keys.singleton(name)

    case S3.get(key) do
      {:error, :not_found} ->
        create(name, holder, key, now, ttl)

      {:ok, %{body: body, etag: etag}} ->
        cur = Jason.decode!(body)

        cond do
          cur["holder"] == holder ->
            cas_take(name, holder, key, etag, cur["epoch"], now, ttl)

          stale?(cur, now) ->
            cas_take(name, holder, key, etag, cur["epoch"], now, ttl)

          true ->
            {:error, {:held_by, cur["holder"], cur["lease_until"]}}
        end

      other ->
        other
    end
  end

  @doc "Renew the lease by CAS. `{:error, :lost}` ⇒ fail-closed: stop leading."
  @spec renew(t(), keyword()) :: {:ok, t()} | {:error, :lost} | {:error, term()}
  def renew(%__MODULE__{} = token, opts \\ []) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @default_ttl
    key = Keys.singleton(token.name)

    body = Jason.encode!(%{holder: token.holder, epoch: token.epoch, lease_until: now + ttl})

    case S3.put(key, body, if_match: token.etag) do
      {:ok, %{etag: etag}} -> {:ok, %{token | etag: etag, lease_until: now + ttl}}
      {:error, :precondition_failed} -> {:error, :lost}
      {:error, {:ambiguous, _}} -> verify(token, now + ttl)
      other -> other
    end
  end

  @doc "Release the lease (best-effort CAS clear)."
  @spec release(t()) :: :ok
  def release(%__MODULE__{} = token) do
    _ = S3.delete(Keys.singleton(token.name), if_match: token.etag)
    :ok
  end

  # ---- internal ----

  defp create(name, holder, key, now, ttl) do
    body = Jason.encode!(%{holder: holder, epoch: 1, lease_until: now + ttl})

    case S3.put(key, body, if_none_match: "*") do
      {:ok, %{etag: etag}} ->
        {:ok,
         %__MODULE__{name: name, holder: holder, epoch: 1, etag: etag, lease_until: now + ttl}}

      {:error, :precondition_failed} ->
        # Lost the create race; re-evaluate.
        acquire(name, holder, now: now, ttl_ms: ttl)

      other ->
        other
    end
  end

  defp cas_take(name, holder, key, etag, prev_epoch, now, ttl) do
    epoch = (prev_epoch || 0) + 1
    body = Jason.encode!(%{holder: holder, epoch: epoch, lease_until: now + ttl})

    case S3.put(key, body, if_match: etag) do
      {:ok, %{etag: new_etag}} ->
        {:ok,
         %__MODULE__{
           name: name,
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
    case S3.get(Keys.singleton(token.name)) do
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
end
