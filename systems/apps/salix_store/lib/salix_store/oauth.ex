defmodule SalixStore.OAuth do
  @moduledoc """
  OAuth connection storage with refresh serialized by storage CAS rather than
  process-local locks.

  A connection record lives at `ctl/oauth/connections/{id}.json` with
  `{access_token, expires_at, refresh_token, version}`. `refresh/3` reads the
  record and, if it's stale, performs the token exchange (an injected
  `refresher` function) and writes the new token with `If-Match` — so under
  concurrent refreshers across nodes exactly one write wins; the losers re-read
  and observe the already-refreshed token. No process-local lock needed.
  """

  alias SalixStore.{S3, Keys}

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
  Return a valid access token, refreshing via CAS if expired. `refresher` is
  `fn record -> {:ok, %{"access_token" => ..., "expires_at" => ..., "refresh_token" => ...}}` —
  it performs the actual token-endpoint exchange. `now` injects the clock.

  Concurrent callers serialize on the `If-Match` write; a CAS loser re-reads and
  returns the freshly-refreshed token without calling `refresher` again.
  """
  @spec valid_token(String.t(), (conn_record() -> {:ok, map()} | {:error, term()}), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def valid_token(id, refresher, opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    case S3.get(Keys.oauth_connection(id)) do
      {:ok, %{body: body, etag: etag}} ->
        record = Jason.decode!(body)

        if fresh?(record, now) do
          {:ok, record["access_token"]}
        else
          cas_refresh(id, record, etag, refresher)
        end

      other ->
        other
    end
  end

  defp cas_refresh(id, record, etag, refresher) do
    with {:ok, refreshed} <- refresher.(record) do
      new_record =
        record
        |> Map.merge(refreshed)
        |> Map.update("version", 1, &(&1 + 1))

      case S3.put(Keys.oauth_connection(id), Jason.encode!(new_record), if_match: etag) do
        {:ok, _} ->
          {:ok, new_record["access_token"]}

        {:error, :precondition_failed} ->
          # Someone else refreshed first; re-read and use their token.
          case get(id) do
            {:ok, current} -> {:ok, current["access_token"]}
            other -> other
          end

        other ->
          other
      end
    end
  end

  defp fresh?(record, now) do
    case record["expires_at"] do
      nil -> false
      exp when is_integer(exp) -> exp > now
      _ -> false
    end
  end
end
