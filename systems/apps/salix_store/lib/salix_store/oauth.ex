defmodule SalixStore.OAuth do
  @moduledoc """
  OAuth connection storage with refresh serialized by storage CAS rather than
  process-local locks.

  A connection record lives at `ctl/oauth/connections/{id}.json` with
  `{access_token, expires_at, refresh_token, version}`. `valid_token/3` reads
  the record and, if it's stale, takes a refresh lease on it with an
  `If-Match` write, performs the token exchange (an injected `refresher`
  function) and writes the new token with `If-Match`. Only the lease holder
  exchanges the refresh token, so concurrent refreshers across nodes spend it
  once: providers that rotate refresh tokens (Linear, X, Feishu/Lark) refuse a
  second exchange with `invalid_grant`, which would read as a revoked grant.
  No process-local lock needed.
  """

  alias SalixStore.{S3, Keys}

  # Longer than a token exchange takes, request retries included.
  @refresh_lease_ms 60_000
  @attempts 3

  @type conn_record :: %{optional(String.t()) => any()}

  @doc "Create (or overwrite) a connection record."
  @spec put(String.t(), conn_record()) :: :ok | {:error, term()}
  def put(id, record) do
    case S3.put(Keys.oauth_connection(id), Jason.encode!(record)) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @doc "Read a connection record."
  @spec get(String.t()) :: {:ok, conn_record()} | {:error, :not_found} | {:error, term()}
  def get(id) do
    case S3.get(Keys.oauth_connection(id)) do
      {:ok, %{body: body}} -> {:ok, Jason.decode!(body)}
      {:error, :not_found} -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Return a valid access token, refreshing it when it expires within
  `leeway_ms`. `refresher` is
  `fn record -> {:ok, %{"access_token" => ..., "expires_at" => ..., "refresh_token" => ...}}` —
  it performs the actual token-endpoint exchange. `now` injects the clock.

  The caller that takes the refresh lease exchanges; a caller that finds the
  lease held returns the current token while it has not expired, and
  `{:error, :refresh_in_progress}` (retryable, not a revoked grant) once it
  has. A lease whose holder died runs out after 60 s.
  """
  @spec valid_token(String.t(), (conn_record() -> {:ok, map()} | {:error, term()}), keyword()) ::
          {:ok, String.t()} | {:error, :refresh_in_progress} | {:error, term()}
  def valid_token(id, refresher, opts \\ []) do
    now = opts[:now] || SystemsClock.system_time(:millisecond)
    refresh(id, refresher, now, opts[:leeway_ms] || 0, @attempts)
  end

  @doc """
  Rewrite a stored record with an `If-Match` write. `fun` returns
  `{:ok, record}` to write, or `:skip` to leave the record as it is. A
  concurrent writer, such as a token refresh, makes it retry on the fresh
  record, so neither write loses the other's fields.
  """
  @spec update(String.t(), (conn_record() -> {:ok, conn_record()} | :skip), pos_integer()) ::
          {:ok, conn_record()} | :skipped | {:error, term()}
  def update(id, fun, attempts \\ 3) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(Keys.oauth_connection(id)) do
      case fun.(Jason.decode!(body)) do
        :skip ->
          :skipped

        {:ok, record} ->
          case S3.put(Keys.oauth_connection(id), Jason.encode!(record), if_match: etag) do
            {:ok, _} -> {:ok, record}
            {:error, :precondition_failed} when attempts > 1 -> update(id, fun, attempts - 1)
            {:error, _} = error -> error
          end
      end
    end
  end

  @doc """
  Mark a connection as needing reauthorization after a refresh with `seen`'s
  refresh token failed. Skipped when the stored record holds a different
  refresh token by now (another refresher rotated it, or the person
  reauthorized), since that one is not known to be bad. Written with
  `If-Match`, so it never overwrites a concurrent token write.
  """
  @spec mark_reauthorization_required(String.t(), conn_record() | nil) ::
          :ok | {:error, term()}
  def mark_reauthorization_required(id, seen \\ nil) do
    update(id, fn record ->
      if is_map(seen) and record["refresh_token"] != seen["refresh_token"] do
        :skip
      else
        {:ok, Map.put(record, "status", "reauthorization_required")}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      :skipped -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp refresh(id, refresher, now, leeway_ms, attempts) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(Keys.oauth_connection(id)) do
      record = Jason.decode!(body)

      cond do
        fresh?(record, now + leeway_ms) ->
          {:ok, record["access_token"]}

        leased?(record, now) ->
          # Another caller is exchanging; the current token serves until it
          # actually expires.
          if fresh?(record, now),
            do: {:ok, record["access_token"]},
            else: {:error, :refresh_in_progress}

        true ->
          leased = Map.put(record, "refresh_lease_until", now + @refresh_lease_ms)

          case S3.put(Keys.oauth_connection(id), Jason.encode!(leased), if_match: etag) do
            {:ok, %{etag: leased_etag}} ->
              exchange(id, record, leased, leased_etag, refresher, now)

            {:error, :precondition_failed} when attempts > 1 ->
              refresh(id, refresher, now, leeway_ms, attempts - 1)

            {:error, :precondition_failed} ->
              {:error, :refresh_in_progress}

            other ->
              other
          end
      end
    end
  end

  defp exchange(id, record, leased, etag, refresher, now) do
    case refresher.(record) do
      {:ok, refreshed} ->
        write_refreshed(id, leased, etag, refreshed, record, @attempts)

      {:error, _} = error ->
        release_lease(id, leased["refresh_lease_until"])

        # A holder whose lease ran out mid-exchange can be refused because the
        # next holder already spent and rotated the refresh token.
        case get(id) do
          {:ok, current} ->
            if refreshed_since?(current, record) and fresh?(current, now),
              do: {:ok, current["access_token"]},
              else: error

          _ ->
            error
        end
    end
  end

  defp write_refreshed(id, record, etag, refreshed, read, attempts) do
    new_record =
      record
      |> Map.merge(refreshed)
      |> Map.delete("refresh_lease_until")
      |> Map.update("version", 1, &(&1 + 1))
      |> clear_reauthorization()

    case S3.put(Keys.oauth_connection(id), Jason.encode!(new_record), if_match: etag) do
      {:ok, _} ->
        {:ok, new_record["access_token"]}

      {:error, :precondition_failed} ->
        case S3.get(Keys.oauth_connection(id)) do
          {:ok, %{body: body, etag: current_etag}} ->
            current = Jason.decode!(body)

            cond do
              refreshed_since?(current, read) ->
                # Our lease ran out and someone else refreshed; use their token.
                {:ok, current["access_token"]}

              attempts > 1 ->
                # The record changed for another reason (such as a status
                # mark), and the spent refresh token may be dead, so keep ours.
                write_refreshed(id, current, current_etag, refreshed, read, attempts - 1)

              true ->
                {:error, :precondition_failed}
            end

          other ->
            other
        end

      other ->
        other
    end
  end

  defp release_lease(id, lease) do
    _ =
      update(id, fn record ->
        if record["refresh_lease_until"] == lease,
          do: {:ok, Map.delete(record, "refresh_lease_until")},
          else: :skip
      end)

    :ok
  end

  defp leased?(record, now) do
    case record["refresh_lease_until"] do
      until when is_integer(until) -> until > now
      _ -> false
    end
  end

  # Another refresh (a version bump) or a new authorization (a new refresh
  # token) replaced the tokens `read` held.
  defp refreshed_since?(current, read) do
    current["version"] != read["version"] or current["refresh_token"] != read["refresh_token"]
  end

  defp clear_reauthorization(%{"status" => "reauthorization_required"} = record),
    do: Map.put(record, "status", "active")

  defp clear_reauthorization(record), do: record

  defp fresh?(record, now) do
    case record["expires_at"] do
      nil -> false
      exp when is_integer(exp) -> exp > now
      _ -> false
    end
  end
end
