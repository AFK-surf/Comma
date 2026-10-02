defmodule Comma.WatchPairing do
  @moduledoc """
  Existing Auth Sessions delegate one short-lived grant to a paired Watch.

  The phone's full session owns the account and the grant's expected secret.
  A redeemed grant creates an independently stored, revocable Auth Session.
  WatchConnectivity carries only the two-minute grant; phone bearer authority
  never crosses this channel. Logout/revocation of the parent denies its grants
  and child sessions; a disconnected or expired phone session does not stop an
  already paired Watch. No compute Device identity is created.
  """
  import Ecto.Query
  alias Comma.Accounts.{AuthSession, SessionIssuer, User}
  alias Comma.Auth.OneTimeCredentials
  alias Comma.Repo

  @purpose "watch_pairing"

  def create(user, session) do
    if session["restricted"] == false and session["session_source"] == "user_login" and
         is_nil(session["parent_session_id"]) do
      with {:ok, grant} <-
             OneTimeCredentials.issue(
               @purpose,
               %{
                 "user_id" => user["id"],
                 "parent_session_id" => session["id"]
               },
               120,
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

  def exchange(attrs) when is_map(attrs) do
    with {:ok, grant} <-
           OneTimeCredentials.consume(@purpose, attrs["pairing_id"], attrs["pairing_secret"]) do
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
        now = DateTime.utc_now()

        if parent == nil or user == nil or parent.revoked_at != nil or
             DateTime.compare(parent.expires_at, now) != :gt or user.status != "active" or
             parent.user_auth_epoch != user.auth_epoch or parent.restricted or
             parent.session_source != "user_login" or parent.parent_session_id != nil,
           do: Repo.rollback(:invalid_watch_pairing)

        case Comma.Accounts.resolve_session_id(parent.id) do
          {:ok, _user, _session} -> :ok
          _ -> Repo.rollback(:invalid_watch_pairing)
        end

        case SessionIssuer.issue(user,
               auth_method: "watch_pairing",
               parent_session_id: parent.id,
               client_kind: "watch",
               client_platform: "watchos",
               device_label: "Comma on Apple Watch"
             ) do
          {:ok, session} -> session
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :invalid_one_time_credential} -> {:error, :invalid_watch_pairing}
      {:error, _} = error -> error
    end
  end

  def exchange(_), do: {:error, :invalid_watch_pairing}
end
