defmodule BridgeForTeams.Auth.Sessions do
  @moduledoc """
  Postgres-backed session store (design §1, §7): replaces Redis. Tokens are
  random; only `token_hash` is persisted (`auth_sessions`).

  The opaque token is shown to the caller exactly once (at `create/2`); the
  database only ever holds its SHA-256 hash, so a database read cannot recover a
  usable session credential. Lookups hash the presented token and match on the
  unique `token_hash` index.
  """
  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{AuthSession, User}

  # Tokens are 32 random bytes, URL-safe base64 (no padding) -> 43 chars.
  @token_bytes 32
  # Default session lifetime: 30 days.
  @default_ttl_seconds 30 * 24 * 60 * 60

  @doc """
  Create a session for a user. Returns the opaque token (shown once) and the
  persisted record (which stores only the hash).

  Options:
    * `:ttl_seconds` — session lifetime (default 30 days)
    * `:device` — free-form device/user-agent label
    * `:client_name` — optional display name for the client that owns the session
  """
  @spec create(User.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, %{token: String.t(), session: AuthSession.t()}} | {:error, term()}
  def create(user_or_id, opts \\ []) do
    user_id = user_id(user_or_id)
    token = generate_token()
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    now = DateTime.utc_now()

    attrs = %{
      user_id: user_id,
      token_hash: hash_token(token),
      expires_at: DateTime.add(now, ttl, :second),
      last_seen_at: now,
      device: Keyword.get(opts, :device),
      client_name: Keyword.get(opts, :client_name)
    }

    case %AuthSession{} |> AuthSession.changeset(attrs) |> Repo.insert() do
      {:ok, session} -> {:ok, %{token: token, session: session}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Look up a non-expired session by its opaque token; touches `last_seen_at`
  unless `touch: false` is passed.
  Returns `{:error, :invalid}` when unknown and `{:error, :expired}` when
  past `expires_at` (the expired row is deleted).
  """
  @spec fetch(token :: String.t(), opts :: keyword()) ::
          {:ok, AuthSession.t()} | {:error, :invalid | :expired}
  def fetch(token, opts \\ [])

  def fetch(token, opts) when is_binary(token) do
    hash = hash_token(token)
    touch? = Keyword.get(opts, :touch, true)

    case Repo.get_by(AuthSession, token_hash: hash) do
      nil ->
        {:error, :invalid}

      %AuthSession{} = session ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
          if touch?, do: touch(session), else: {:ok, session}
        else
          Repo.delete(session)
          {:error, :expired}
        end
    end
  end

  def fetch(_, _opts), do: {:error, :invalid}

  @doc "Revoke (delete) a session by token. Idempotent."
  @spec revoke(token :: String.t()) :: :ok
  def revoke(token) when is_binary(token) do
    hash = hash_token(token)
    Repo.delete_all(from s in AuthSession, where: s.token_hash == ^hash)
    :ok
  end

  def revoke(_), do: :ok

  @doc "List non-expired sessions for a user."
  @spec list_for_user(User.t() | Ecto.UUID.t(), keyword()) :: [AuthSession.t()]
  def list_for_user(user_or_id, opts \\ []) do
    user_id = user_id(user_or_id)
    now = DateTime.utc_now()

    AuthSession
    |> where([s], s.user_id == ^user_id and s.expires_at > ^now)
    |> maybe_filter_device(Keyword.get(opts, :device))
    |> order_by([s], desc: s.created_at)
    |> Repo.all()
  end

  @doc "Revoke a user's session by persisted session id. Idempotent."
  @spec revoke_for_user(User.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok
  def revoke_for_user(user_or_id, session_id, opts \\ [])

  def revoke_for_user(user_or_id, session_id, opts) when is_binary(session_id) do
    user_id = user_id(user_or_id)

    AuthSession
    |> where([s], s.user_id == ^user_id and s.id == ^session_id)
    |> maybe_filter_device(Keyword.get(opts, :device))
    |> Repo.delete_all()

    :ok
  end

  def revoke_for_user(_user_or_id, _session_id, _opts), do: :ok

  @doc "Hash an opaque token for storage/lookup (same scheme as Salix tenant keys)."
  @spec hash_token(token :: String.t()) :: String.t()
  def hash_token(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  @doc "Generate a fresh opaque session token (URL-safe, unpadded base64)."
  @spec generate_token() :: String.t()
  def generate_token,
    do: Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  defp maybe_filter_device(query, nil), do: query
  defp maybe_filter_device(query, device), do: where(query, [s], s.device == ^device)

  defp touch(session) do
    session
    |> AuthSession.changeset(%{last_seen_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      # A failed last_seen_at touch must not invalidate an otherwise-valid
      # session; fall back to the read value.
      {:error, _} -> {:ok, session}
    end
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_binary(id), do: id
end
