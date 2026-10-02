defmodule Comma.AppleAuth do
  @moduledoc """
  Apple subject login through existing Login Identity and Auth Session owners.

  Apple's signed issuer/subject identifies the account, never a submitted
  email. A first login matching an existing account requires that account's
  email OTP before linking. This prevents account takeover by email reuse.
  """
  import Ecto.Query
  alias Comma.Accounts.{Email, Identity, Repository, SessionClientMetadata, SessionIssuer, User}
  alias Comma.Auth.{AppleToken, OneTimeCredentials}
  alias Comma.{AuthChallenges, Repo}

  @issuer "https://appleid.apple.com"
  @purpose "apple_attempt"

  def start_attempt(attrs \\ %{}) do
    with {:ok, client_id} <- client_id(),
         nonce =
           :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)) |> Base.encode16(case: :lower),
         {:ok, grant} <-
           OneTimeCredentials.issue(
             @purpose,
             %{
               "client_id" => client_id,
               "nonce" => nonce,
               "issued_at" => System.system_time(:second)
             },
             300,
             attrs["remote_ip"] || "unknown"
           ) do
      {:ok,
       %{
         "attempt_id" => grant.id <> "." <> grant.secret,
         "nonce" => nonce,
         "client_id" => client_id,
         "expires_at" => grant.expires_at
       }}
    end
  end

  def complete(attrs) when is_map(attrs) do
    with {:ok, client_id} <- client_id(),
         [id, secret] <- split_attempt(attrs["attempt_id"]),
         {:ok, attempt} <- OneTimeCredentials.consume(@purpose, id, secret),
         true <- attempt["client_id"] == client_id,
         {:ok, claims} <- AppleToken.verify(attrs["identity_token"], attempt),
         {:ok, outcome} <- transaction(fn -> resolve_claims(claims) end) do
      case outcome do
        {user, identity} ->
          issue_session(user, identity, attrs)

        {:otp, user, email} ->
          AuthChallenges.request_apple_link_verification(
            %{
              "user_id" => user.id,
              "issuer" => @issuer,
              "subject" => claims["sub"],
              "email" => email,
              "email_verified" => true,
              "remote_ip" => attrs["remote_ip"] || "unknown"
            }
            |> Map.merge(SessionClientMetadata.attributes(attrs))
          )
      end
    else
      {:error, :invalid_one_time_credential} -> {:error, :invalid_apple_attempt}
      {:error, _} = error -> error
      _ -> {:error, :invalid_apple_attempt}
    end
  end

  def complete(_attrs), do: {:error, :invalid_apple_credential}

  def verify_link(attrs) do
    with {:ok, state} <- AuthChallenges.verify_apple_link_challenge(attrs),
         {:ok, {user, identity}} <-
           transaction(fn ->
             lock_identity!(state["subject"])

             user =
               Repo.one(
                 from(user in User, where: user.id == ^state["user_id"], lock: "FOR UPDATE")
               )

             require_active!(user)
             if user.email != state["email"], do: Repo.rollback(:apple_link_changed)
             identity = link_identity!(user, state["subject"], state["email"])
             {user, identity}
           end) do
      issue_session(user, identity, state)
    end
  end

  defp resolve_claims(claims) do
    lock_identity!(claims["sub"])

    email =
      case Email.normalize(claims["email"]) do
        {:ok, value} -> value
        _ -> nil
      end

    case identity_for_update(claims["sub"]) do
      %Identity{disabled_at: nil} = identity ->
        user =
          Repo.one(from(user in User, where: user.id == ^identity.user_id, lock: "FOR UPDATE"))

        require_active!(user)
        updates = %{last_authenticated_at: DateTime.utc_now()}

        updates =
          if email != nil and claims["email_verified"] in [true, "true"],
            do: Map.merge(updates, %{email_snapshot: email, email_verified: true}),
            else: updates

        {:ok, identity} = Repository.update_identity_metadata(identity, updates)
        {user, identity}

      %Identity{} ->
        Repo.rollback(:disabled)

      nil ->
        if email == nil or claims["email_verified"] not in [true, "true"],
          do: Repo.rollback(:apple_email_required)

        case Repo.one(from(user in User, where: user.email == ^email, lock: "FOR UPDATE")) do
          %User{} = user ->
            require_active!(user)
            {:otp, user, email}

          nil ->
            {:ok, user} = Repository.ensure_user_by_email(email)
            require_active!(user)
            {user, link_identity!(user, claims["sub"], email)}
        end
    end
  end

  defp link_identity!(user, subject, email) do
    case identity_for_update(subject) do
      %Identity{user_id: user_id, disabled_at: nil} = identity when user_id == user.id ->
        identity

      %Identity{} ->
        Repo.rollback(:identity_conflict)

      nil ->
        case Repo.get_by(Identity, user_id: user.id, provider: "apple") do
          nil ->
            case Repository.ensure_identity(user.id, %{
                   provider: "apple",
                   issuer: @issuer,
                   subject: subject,
                   email_snapshot: email,
                   email_verified: true
                 }) do
              {:ok, identity} -> identity
              {:error, reason} -> Repo.rollback(reason)
            end

          _ ->
            Repo.rollback(:provider_already_linked)
        end
    end
  end

  defp identity_for_update(subject),
    do:
      Repo.one(
        from(identity in Identity,
          where:
            identity.provider == "apple" and identity.issuer == @issuer and
              identity.subject == ^subject,
          lock: "FOR UPDATE"
        )
      )

  defp lock_identity!(subject),
    do:
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "apple:" <> subject
      ])

  defp transaction(fun, attempts \\ 3) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", [])
      fun.()
    end)
  rescue
    error in Postgrex.Error ->
      if match?(%{postgres: %{code: :serialization_failure}}, error) and attempts > 1,
        do: transaction(fun, attempts - 1),
        else: reraise(error, __STACKTRACE__)
  end

  defp issue_session(user, identity, attrs),
    do:
      SessionIssuer.issue(
        user,
        Keyword.merge(
          [auth_method: "apple", login_identity_id: identity.id],
          SessionClientMetadata.options(attrs)
        )
      )

  defp require_active!(%User{status: "active"}), do: :ok
  defp require_active!(_), do: Repo.rollback(:disabled)

  defp client_id do
    case Application.get_env(:comma_core, :apple_auth, [])[:client_id] do
      id when is_binary(id) and byte_size(id) in 1..500 -> {:ok, id}
      _ -> {:error, :apple_not_configured}
    end
  end

  defp split_attempt(value) when is_binary(value) and byte_size(value) <= 200,
    do: String.split(value, ".", parts: 2)

  defp split_attempt(_), do: []
end
