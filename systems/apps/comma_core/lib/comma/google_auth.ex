defmodule Comma.GoogleAuth do
  @moduledoc "Google social login, exact-email convergence, and conditional OTP account linking."

  import Ecto.Query

  alias Comma.Accounts.{Identity, Repository, SessionClientMetadata, SessionIssuer, User}
  alias Comma.Auth.{GoogleClaims, GoogleEmailAuthority, GoogleLoginAttempts}
  alias Comma.{AuthChallenges, Repo}
  alias CommaProduct.Telemetry

  @max_credential_bytes 16_384
  @max_authorization_code_bytes 16_384
  @pkce_verifier ~r/\A[A-Za-z0-9._~-]{43,128}\z/
  @desktop_redirect_uri ~r/\Ahttp:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/oauth2\/callback\z/
  @serializable_transaction_attempts 3

  @spec start_attempt(map()) :: {:ok, map()} | {:error, term()}
  def start_attempt(attrs \\ %{}) when is_map(attrs) do
    GoogleLoginAttempts.create(trim(value(attrs, "platform")) || "web", attrs)
  end

  @spec complete(map()) :: {:ok, map()} | {:error, term()}
  def complete(attrs) when is_map(attrs) do
    # Protocol anchor: tla/google_desktop_auth/GoogleDesktopAuth.tla
    with {:ok, platform} <- google_completion_platform(attrs),
         {:ok, attempt} <- GoogleLoginAttempts.consume(attrs, platform),
         {:ok, raw_claims} <- verified_claims(attempt, attrs),
         {:ok, claims} <- GoogleClaims.from_verified(raw_claims),
         {:ok, outcome} <- resolve_claims(claims) do
      finish(outcome, claims, attrs)
    else
      {:error, _reason} = error -> error
    end
  end

  def complete(_attrs), do: {:error, :invalid_google_credential}

  defp verified_claims(%{"platform" => "web"} = attempt, attrs) do
    adapter().verify_id_token(trim(value(attrs, "credential")),
      client_id: attempt["client_id"],
      nonce: attempt["nonce"],
      platform: "web"
    )
  end

  defp verified_claims(%{"platform" => "electron"} = attempt, attrs) do
    started_at = System.monotonic_time()

    result =
      adapter().exchange_authorization_code(trim(value(attrs, "authorization_code")),
        client_id: attempt["client_id"],
        client_secret: google_config()[:electron_client_secret],
        nonce: attempt["nonce"],
        pkce_verifier: trim(value(attrs, "code_verifier")),
        platform: "electron",
        redirect_uri: trim(value(attrs, "redirect_uri"))
      )

    Telemetry.emit_operation(
      :google_desktop_exchange,
      exchange_outcome(result),
      System.monotonic_time() - started_at
    )

    result
  end

  defp verified_claims(_attempt, _attrs), do: {:error, :invalid_google_credential}

  defp exchange_outcome({:ok, _claims}), do: :ok
  defp exchange_outcome({:error, :invalid_google_credential}), do: :rejected
  defp exchange_outcome({:error, :google_provider_unavailable}), do: :unavailable
  defp exchange_outcome(_other), do: :error

  defp google_completion_platform(attrs) do
    credential = trim(value(attrs, "credential")) || ""
    authorization_code = trim(value(attrs, "authorization_code")) || ""
    code_verifier = trim(value(attrs, "code_verifier")) || ""
    redirect_uri = trim(value(attrs, "redirect_uri")) || ""

    web? = valid_credential?(credential)

    electron? =
      bounded?(authorization_code, @max_authorization_code_bytes) and
        Regex.match?(@pkce_verifier, code_verifier) and valid_desktop_redirect?(redirect_uri)

    case {web?, electron?} do
      {true, false} -> {:ok, "web"}
      {false, true} -> {:ok, "electron"}
      _invalid_or_ambiguous -> {:error, :invalid_google_credential}
    end
  end

  defp valid_desktop_redirect?(redirect_uri) do
    case Regex.run(@desktop_redirect_uri, redirect_uri, capture: :all_but_first) do
      [port] ->
        case Integer.parse(port) do
          {parsed, ""} -> parsed <= 65_535
          _other -> false
        end

      _other ->
        false
    end
  end

  defp bounded?(value, maximum) when is_binary(value),
    do: value != "" and byte_size(value) <= maximum

  defp bounded?(_value, _maximum), do: false

  @spec verify_link(map()) :: {:ok, map()} | {:error, term()}
  def verify_link(attrs) when is_map(attrs) do
    with {:ok, state} <- AuthChallenges.verify_google_link_challenge(attrs),
         {:ok, claims} <- GoogleClaims.from_link_state(state),
         {:ok, user} <- link_after_otp(state["user_id"], state["email"], claims) do
      issue_session(user, state)
    end
  end

  def verify_link(_attrs), do: {:error, :invalid_verification_code}

  defp resolve_claims(%GoogleClaims{} = claims) do
    serializable_transaction(fn ->
      lock_identity_key!(claims)

      case identity_for_update(claims) do
        %Identity{} = identity -> resolve_returning_identity(identity, claims)
        nil -> resolve_first_identity(claims)
      end
    end)
    |> normalize_transaction()
  end

  defp resolve_returning_identity(identity, claims) do
    user = user_for_update!(identity.user_id)
    require_active!(user)

    case Repository.update_identity_metadata(identity, metadata_updates(claims), repo: Repo) do
      {:ok, _identity} -> {:signed_in, user}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp resolve_first_identity(%GoogleClaims{email: nil}),
    do: Repo.rollback(:invalid_google_identity)

  defp resolve_first_identity(%GoogleClaims{email: email} = claims) do
    case Repo.one(from(user in User, where: user.email == ^email, lock: "FOR UPDATE")) do
      %User{} = user ->
        require_active!(user)

        case GoogleEmailAuthority.classify(claims) do
          :authoritative -> {:signed_in, link_identity_locked!(user, claims)}
          :requires_otp -> {:otp_required, user}
        end

      nil ->
        if claims.email_verified == true do
          case Repository.ensure_user_by_email(email, %{name: claims.name}, repo: Repo) do
            {:ok, user} ->
              user = user_for_update!(user.id)
              {:signed_in, link_identity_locked!(user, claims)}

            {:error, reason} ->
              Repo.rollback(reason)
          end
        else
          Repo.rollback(:invalid_google_identity)
        end
    end
  end

  defp link_after_otp(user_id, expected_email, claims)
       when is_binary(user_id) and is_binary(expected_email) do
    serializable_transaction(fn ->
      lock_identity_key!(claims)
      user = user_for_update!(user_id)
      require_active!(user)

      if user.email != expected_email or claims.email != expected_email do
        Repo.rollback(:google_link_changed)
      end

      link_identity_locked!(user, claims)
    end)
    |> normalize_transaction()
  end

  defp link_after_otp(_user_id, _expected_email, _claims),
    do: {:error, :invalid_google_identity}

  defp link_identity_locked!(%User{} = user, %GoogleClaims{} = claims) do
    case identity_for_update(claims) do
      %Identity{user_id: user_id} = identity when user_id == user.id ->
        update_identity!(identity, claims)
        user

      %Identity{} ->
        Repo.rollback(:identity_conflict)

      nil ->
        case Repo.one(
               from(identity in Identity,
                 where: identity.user_id == ^user.id and identity.provider == "google",
                 lock: "FOR UPDATE"
               )
             ) do
          %Identity{subject: subject, issuer: issuer} = identity
          when subject == claims.subject and issuer == claims.issuer ->
            update_identity!(identity, claims)
            user

          %Identity{} ->
            Repo.rollback(:provider_already_linked)

          nil ->
            case Repository.ensure_identity(user.id, GoogleClaims.identity_attrs(claims),
                   repo: Repo
                 ) do
              {:ok, _identity} -> user
              {:error, reason} -> Repo.rollback(reason)
            end
        end
    end
  end

  defp update_identity!(identity, claims) do
    case Repository.update_identity_metadata(identity, metadata_updates(claims), repo: Repo) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp metadata_updates(claims) do
    %{last_authenticated_at: DateTime.utc_now()}
    |> maybe_put(:email_snapshot, claims.email, &is_binary/1)
    |> maybe_put(:email_verified, claims.email_verified, &is_boolean/1)
    |> maybe_put_hosted_domain(claims.hosted_domain)
  end

  defp maybe_put_hosted_domain(attrs, value) when is_binary(value),
    do: Map.put(attrs, :hosted_domain, value)

  defp maybe_put_hosted_domain(attrs, nil), do: Map.put(attrs, :hosted_domain, nil)
  defp maybe_put_hosted_domain(attrs, :invalid), do: attrs

  defp maybe_put(attrs, key, value, predicate) do
    if predicate.(value), do: Map.put(attrs, key, value), else: attrs
  end

  defp identity_for_update(claims) do
    Repo.one(
      from(identity in Identity,
        where:
          identity.provider == "google" and identity.issuer == ^claims.issuer and
            identity.subject == ^claims.subject,
        lock: "FOR UPDATE"
      )
    )
  end

  defp user_for_update!(user_id) do
    case Repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE")) do
      %User{} = user -> user
      nil -> Repo.rollback(:not_found)
    end
  end

  defp require_active!(%User{status: "active"}), do: :ok
  defp require_active!(%User{}), do: Repo.rollback(:disabled)

  defp lock_identity_key!(claims) do
    key = "google:" <> claims.issuer <> ":" <> claims.subject

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [key]
    )

    :ok
  end

  defp serializable_transaction(fun, attempts_left \\ @serializable_transaction_attempts) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE",
        []
      )

      fun.()
    end)
  rescue
    error in Postgrex.Error ->
      if serialization_failure?(error) and attempts_left > 1 do
        serializable_transaction(fun, attempts_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp serialization_failure?(%Postgrex.Error{postgres: %{code: :serialization_failure}}),
    do: true

  defp serialization_failure?(_error), do: false

  defp finish({:signed_in, %User{} = user}, _claims, attrs), do: issue_session(user, attrs)

  defp finish({:otp_required, %User{} = user}, claims, attrs) do
    claims
    |> GoogleClaims.link_state(user.id)
    |> Map.put("remote_ip", trim(value(attrs, "remote_ip")) || "unknown")
    |> Map.merge(SessionClientMetadata.attributes(attrs))
    |> AuthChallenges.request_google_link_verification()
  end

  defp issue_session(%User{} = user, attrs) do
    SessionIssuer.issue(
      user,
      Keyword.merge(
        [auth_method: "google"],
        SessionClientMetadata.options(attrs)
      )
    )
  end

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp adapter do
    google_config()[:adapter] || Comma.Auth.GoogleAdapter.Oidcc
  end

  defp google_config, do: Application.get_env(:comma_core, :google_auth, [])

  defp valid_credential?(credential),
    do:
      is_binary(credential) and credential != "" and
        byte_size(credential) <= @max_credential_bytes

  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: nil
end
