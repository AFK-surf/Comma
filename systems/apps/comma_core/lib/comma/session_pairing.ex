defmodule Comma.SessionPairing do
  @moduledoc """
  One full Auth Session delegates one short-lived grant to another client of
  the same person: a paired Watch (`Comma.WatchPairing`) or the Raycast
  extension (`Comma.RaycastPairing`).

  The delegating session owns the account and the grant's expected secret. A
  redeemed grant creates an independently stored, revocable Auth Session whose
  `parent_session_id` is that session. Logout or revocation of the parent
  denies its grants and child sessions. A disconnected or expired parent does
  not stop a session it already paired. No compute Device identity is created.
  """
  import Ecto.Query
  alias Comma.Accounts.{AuthSession, SessionIssuer, User}
  alias Comma.Auth.OneTimeCredentials
  alias Comma.Repo

  @grant_seconds 120

  @doc """
  Issues a two-minute, single-use grant for `purpose`. `context` holds facts
  the exchange checks later. Only an ordinary, unrestricted, unpaired login
  session of a signed-in account (not a guest) may delegate.
  """
  def create(purpose, user, session, context \\ %{}) do
    if session["restricted"] == false and session["session_source"] == "user_login" and
         is_nil(session["parent_session_id"]) and session["auth_method"] != "guest" do
      with {:ok, grant} <-
             OneTimeCredentials.issue(
               purpose,
               Map.merge(context, %{
                 "user_id" => user["id"],
                 "parent_session_id" => session["id"]
               }),
               @grant_seconds,
               session["id"]
             ) do
        {:ok,
         %{
           "pairing_id" => grant.id,
           "pairing_secret" => grant.secret,
           "expires_at" => grant.expires_at
         }}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Consumes the grant and issues the paired session. `session_options` gets the
  consumed grant and answers the new session's options, or `:error` to refuse.
  A consumed grant is spent whatever the outcome.
  """
  def exchange(purpose, attrs, session_options)
      when is_map(attrs) and is_function(session_options, 1) do
    with {:ok, grant} <-
           OneTimeCredentials.consume(purpose, attrs["pairing_id"], attrs["pairing_secret"]),
         {:ok, options} <- session_options.(grant) do
      Repo.transaction(fn ->
        parent =
          Repo.one(
            from(session in AuthSession,
              where:
                session.id == ^grant["parent_session_id"] and session.user_id == ^grant["user_id"],
              lock: "FOR UPDATE"
            )
          )

        user = Repo.get(User, grant["user_id"])
        now = SystemsClock.utc_now()

        if parent == nil or user == nil or parent.revoked_at != nil or
             DateTime.compare(parent.expires_at, now) != :gt or user.status != "active" or
             parent.user_auth_epoch != user.auth_epoch or parent.restricted or
             parent.session_source != "user_login" or parent.parent_session_id != nil or
             parent.auth_method == "guest",
           do: Repo.rollback(:invalid_pairing)

        case Comma.Accounts.resolve_session_id(parent.id) do
          {:ok, _user, _session} -> :ok
          _ -> Repo.rollback(:invalid_pairing)
        end

        case SessionIssuer.issue(user, Keyword.put(options, :parent_session_id, parent.id)) do
          {:ok, session} -> session
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :invalid_one_time_credential} -> {:error, :invalid_pairing}
      :error -> {:error, :invalid_pairing}
      {:error, _} = error -> error
    end
  end

  def exchange(_purpose, _attrs, _session_options), do: {:error, :invalid_pairing}
end
