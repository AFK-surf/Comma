defmodule BridgeForTeams.Auth do
  @moduledoc """
  Authentication facade (design §7): organization SSO, JIT user/membership
  provisioning, Postgres-backed sessions, and API-key auth for programmatic org
  access.

  Generic OIDC keeps the existing authorization-code + PKCE flow and verified
  email-domain admission. Feishu uses a provider-aware flow because Feishu users
  often have no email address; the durable key is an org-scoped Feishu subject
  recorded in `org_sso_identities`, with mobile/email stored only as profile
  attributes.

  Provider implementations are resolved via `BridgeForTeams.Auth.OIDC.impl/0`
  and `BridgeForTeams.Auth.Feishu.impl/0`. The per-org IdP config lives in
  `org_sso_connections`; the stored client secret is handed to the provider
  as-is (no encryption at rest).
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.Auth.{Feishu, OIDC, Sessions}
  alias BridgeForTeams.{Memberships, Observability, Repo}

  alias BridgeForTeams.Schema.{
    ApiKey,
    AuthSession,
    DashboardImportToken,
    MacMiniInstallCode,
    Organization,
    OrgMembership,
    OrgSsoConnection,
    OrgSsoIdentity,
    Project,
    User
  }

  # Raw import tokens carry a distinct prefix so they never collide with API
  # keys (`bft_`) or opaque session tokens, and are easy to spot in logs.
  @import_token_prefix "bfti_"
  # Import tokens are deliberately short-lived (default 60 minutes): a project
  # admin mints one, pastes it into a one-off import command, and it lapses.
  @default_import_token_ttl_seconds 60 * 60

  @doc """
  Build the IdP authorization-code + PKCE redirect URL for an org's SSO
  connection. Returns the URL plus the state/verifier to stash for the callback.
  """
  @spec authorize_url(org_id :: Ecto.UUID.t(), opts :: keyword()) ::
          {:ok, %{url: String.t(), state: String.t(), code_verifier: String.t()}}
          | {:error, term()}
  def authorize_url(org_id, opts \\ []) do
    with {:ok, conn} <- sso_connection(org_id),
         {:ok, sso} <- to_sso(conn) do
      authorize_with_provider(conn, sso, opts)
    end
  end

  @doc """
  Handle the OIDC callback: exchange `code` (+ PKCE verifier), verify the
  id_token, JIT-provision the user/membership, and create a session. Returns the
  user and the opaque session token to set as a cookie/bearer.

  `params` must carry `"code"`; `opts` must carry `:code_verifier` (the value
  stashed by `authorize_url/2`). `opts[:device]` is recorded on the session.
  """
  @spec callback(org_id :: Ecto.UUID.t(), params :: map(), opts :: keyword()) ::
          {:ok, %{user: User.t(), token: String.t(), session: AuthSession.t()}}
          | {:error, term()}
  def callback(org_id, params, opts \\ []) do
    result =
      do_callback(org_id, params, opts)

    case result do
      {:ok, _session} ->
        result

      {:error, reason} ->
        record_sso_login_failure(org_id, reason, Keyword.put_new(opts, :stage, "callback"))
        result
    end
  end

  @doc """
  Record a redacted SSO/OAuth login runtime failure for Operations.

  This stores only org-scoped, low-sensitive facts. Authorization codes,
  provider tokens, IdP profiles, email addresses, phone numbers, and provider
  subjects must stay out of the event evidence.
  """
  @spec record_sso_login_failure(Ecto.UUID.t() | nil, term(), keyword()) :: :ok
  def record_sso_login_failure(org_id, reason, opts \\ [])

  def record_sso_login_failure(org_id, reason, opts) when is_binary(org_id) do
    scope = sso_login_failure_scope(org_id)
    reason_class = auth_reason_class(reason)
    request_id = Keyword.get(opts, :request_id) || Ecto.UUID.generate()
    stage = Keyword.get(opts, :stage, "callback")

    case Observability.create_event(%{
           org_id: org_id,
           domain: "sso",
           resource_type: scope.resource_type,
           resource_id: scope.resource_id,
           source: "bft.dashboard",
           event_type: "sso.login.failed",
           severity: auth_failure_severity(reason_class),
           status: "failed",
           reason_class: reason_class,
           summary: "SSO login failed",
           evidence:
             auth_login_failure_evidence(scope.provider, stage, request_id, reason_class, reason),
           correlation_id: request_id,
           occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now())
         }) do
      {:ok, _event} ->
        :ok

      {:error, event_reason} ->
        Logger.warning("sso_login_failure_observability_failed reason=#{inspect(event_reason)}")
        :ok
    end
  end

  def record_sso_login_failure(_org_id, _reason, _opts), do: :ok

  defp do_callback(org_id, params, opts) do
    with {:ok, conn} <- sso_connection(org_id),
         {:ok, sso} <- to_sso(conn),
         {:ok, code} <- fetch_param(params, "code"),
         {:ok, user} <- callback_with_provider(conn, sso, code, params, opts),
         {:ok, %{token: token, session: session}} <-
           Sessions.create(user, Keyword.take(opts, [:device, :ttl_seconds])) do
      {:ok, %{user: user, token: token, session: session}}
    end
  end

  defp callback_with_provider(
         %OrgSsoConnection{provider: "feishu"} = conn,
         sso,
         _code,
         params,
         opts
       ) do
    with provider = Feishu.impl(),
         {:ok, identity} <- provider.fetch_identity(sso, params, opts) do
      provision_from_feishu_identity(conn, identity, Keyword.put_new(opts, :audit, true))
    end
  end

  defp callback_with_provider(%OrgSsoConnection{} = conn, sso, code, _params, opts) do
    with {:ok, verifier} <- fetch_verifier(opts),
         provider = OIDC.impl(),
         {:ok, tokens} <- provider.exchange_code(sso, code, verifier, opts),
         {:ok, id_token} <- fetch_id_token(tokens),
         {:ok, claims} <- provider.verify_id_token(sso, id_token) do
      provision_from_claims(conn, claims, Keyword.put_new(opts, :audit, true))
    end
  end

  @doc "Authenticate a request by session token. The web Auth plug uses this."
  @spec authenticate_session(token :: String.t()) :: {:ok, User.t()} | {:error, :unauthenticated}
  def authenticate_session(token) when is_binary(token) do
    with {:ok, %AuthSession{user_id: user_id}} <- Sessions.fetch(token),
         %User{} = user <- Repo.get(User, user_id),
         "active" <- user.status do
      {:ok, user}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  def authenticate_session(_), do: {:error, :unauthenticated}

  @doc "Authenticate a request by API key. Returns its org, scopes, and bound runner identity."
  @spec authenticate_api_key(key :: String.t()) ::
          {:ok,
           %{
             org_id: Ecto.UUID.t(),
             scopes: [String.t()],
             runner_stable_id: String.t() | nil
           }}
          | {:error, :unauthenticated}
  def authenticate_api_key(key) when is_binary(key) do
    hash = Sessions.hash_token(key)

    case Repo.get_by(ApiKey, key_hash: hash) do
      %ApiKey{revoked_at: nil} = api_key ->
        with {:ok, runner_stable_id} <- runner_stable_id_for_api_key(api_key.id) do
          {:ok,
           %{
             org_id: api_key.org_id,
             scopes: api_key.scopes || [],
             runner_stable_id: runner_stable_id
           }}
        end

      _ ->
        {:error, :unauthenticated}
    end
  end

  def authenticate_api_key(_), do: {:error, :unauthenticated}

  defp runner_stable_id_for_api_key(api_key_id) do
    case Repo.one(
           from(c in MacMiniInstallCode,
             where: c.api_key_id == ^api_key_id,
             order_by: [desc: c.consumed_at],
             limit: 1
           )
         ) do
      %MacMiniInstallCode{runner_stable_id: runner_stable_id}
      when is_binary(runner_stable_id) and runner_stable_id != "" ->
        {:ok, runner_stable_id}

      %MacMiniInstallCode{} ->
        {:error, :unauthenticated}

      nil ->
        {:ok, nil}
    end
  end

  @doc """
  Mint a temporary My Space data-import token for `user` scoped to
  `(org, project)`, returning the raw token exactly once.

  Allowed for project admins or org owners/admins (the canonical project-write
  RBAC check). The database stores only the token hash. Minting revokes the
  user's previous active token for the same project, so a user holds at most one
  active import token per project. TTL defaults to 60 minutes
  (`:ttl_seconds` overrides). Audits the mint via Observability like the
  neighboring auth events.
  """
  @spec create_import_token(User.t(), Organization.t(), Project.t(), keyword()) ::
          {:ok,
           %{token: String.t(), import_token: DashboardImportToken.t(), expires_at: DateTime.t()}}
          | {:error, :forbidden | term()}
  def create_import_token(
        %User{} = user,
        %Organization{} = org,
        %Project{} = project,
        opts \\ []
      ) do
    with :ok <- authorize_import_token(user, org, project) do
      token = @import_token_prefix <> Sessions.generate_token()
      now = DateTime.utc_now()
      ttl = Keyword.get(opts, :ttl_seconds, @default_import_token_ttl_seconds)
      expires_at = DateTime.add(now, ttl, :second)

      attrs = %{
        user_id: user.id,
        org_id: org.id,
        project_id: project.id,
        token_hash: Sessions.hash_token(token),
        expires_at: expires_at
      }

      Repo.transaction(fn ->
        revoke_active_import_tokens(user.id, project.id, now)

        case %DashboardImportToken{} |> DashboardImportToken.changeset(attrs) |> Repo.insert() do
          {:ok, import_token} ->
            _ = record_import_token_audit(user, import_token, opts)
            %{token: token, import_token: import_token, expires_at: import_token.expires_at}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Authenticate a raw My Space import token.

  Checks the hash, that the token is unrevoked and unexpired, that the user is
  still active, AND re-verifies at use time that the user still has project
  write access (membership may have been revoked since the token was minted).
  Returns the resolved user and the token's org/project scope.
  """
  @spec authenticate_import_token(String.t()) ::
          {:ok, %{user: User.t(), org_id: Ecto.UUID.t(), project_id: Ecto.UUID.t()}}
          | {:error, :unauthenticated}
  def authenticate_import_token(@import_token_prefix <> _ = raw) when is_binary(raw) do
    hash = Sessions.hash_token(raw)

    with %DashboardImportToken{revoked_at: nil} = token <-
           Repo.get_by(DashboardImportToken, token_hash: hash),
         true <- DateTime.compare(token.expires_at, DateTime.utc_now()) == :gt,
         %User{status: "active"} = user <- Repo.get(User, token.user_id),
         :ok <- Memberships.authorize(user.id, :write, %{project_id: token.project_id}) do
      {:ok, %{user: user, org_id: token.org_id, project_id: token.project_id}}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  def authenticate_import_token(_), do: {:error, :unauthenticated}

  # Project admins and org owners/admins can mint; the project-write RBAC check
  # is exactly that set (org owner/admin derive project "admin").
  defp authorize_import_token(%User{} = user, %Organization{} = org, %Project{} = project) do
    cond do
      project.org_id != org.id ->
        {:error, :forbidden}

      Memberships.authorize(user.id, :write, %{project_id: project.id}) == :ok ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp revoke_active_import_tokens(user_id, project_id, now) do
    from(t in DashboardImportToken,
      where: t.user_id == ^user_id and t.project_id == ^project_id and is_nil(t.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])
  end

  defp record_import_token_audit(%User{} = user, %DashboardImportToken{} = token, opts) do
    Observability.record_audit(%{
      org_id: token.org_id,
      actor_user_id: user.id,
      actor_label: audit_actor_label(user),
      action: "dashboard_import_token.created",
      resource_type: "dashboard_import_token",
      resource_id: token.id,
      resource_label: "My Space import token #{short_id(token.id)}",
      result: "ok",
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
      metadata: %{
        "user_id" => user.id,
        "project_id" => token.project_id,
        "expires_at" => token.expires_at
      },
      redacted_diff: %{"credential" => %{"from" => nil, "to" => token.id}}
    })
  end

  @doc """
  Create an org API key and return the raw token exactly once.

  The database stores only the token hash. Callers that need to show the token
  must do so from this return value; later reads cannot recover it.
  """
  @spec create_api_key(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{token: String.t(), api_key: ApiKey.t()}} | {:error, term()}
  def create_api_key(org_id, attrs, opts \\ []) when is_binary(org_id) and is_map(attrs) do
    token = "bft_" <> Sessions.generate_token()

    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("org_id", org_id)
      |> Map.put("key_hash", Sessions.hash_token(token))

    insert_api_key_with_optional_audit(attrs, token, opts)
  end

  defp insert_api_key_with_optional_audit(attrs, token, opts) do
    result =
      if audit_enabled?(opts) do
        Repo.transaction(fn ->
          with {:ok, api_key} <- %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert(),
               {:ok, _audit} <- record_api_key_audit("api_key.created", api_key, opts) do
            %{token: token, api_key: api_key}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      else
        case %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
          {:ok, api_key} -> {:ok, %{token: token, api_key: api_key}}
          {:error, changeset} -> {:error, changeset}
        end
      end

    maybe_record_api_key_write_attempt(
      result,
      "api_key.created",
      attrs["org_id"],
      nil,
      attrs,
      opts
    )
  end

  @doc "List org API keys newest first. Raw tokens are never available here."
  @spec list_api_keys(Ecto.UUID.t()) :: [ApiKey.t()]
  def list_api_keys(org_id) do
    Repo.all(
      from k in ApiKey,
        where: k.org_id == ^org_id,
        order_by: [desc: k.created_at]
    )
  end

  @doc "Soft-revoke an org API key."
  @spec revoke_api_key(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ApiKey.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_api_key(org_id, key_id, opts \\ []) do
    case Repo.get_by(ApiKey, id: key_id, org_id: org_id) do
      nil ->
        {:error, :not_found}
        |> maybe_record_api_key_write_attempt(
          "api_key.revoked",
          org_id,
          key_id,
          %{},
          opts
        )

      %ApiKey{} = api_key ->
        revoke_api_key_with_optional_audit(api_key, opts)
    end
  end

  defp revoke_api_key_with_optional_audit(%ApiKey{} = api_key, opts) do
    changeset = ApiKey.changeset(api_key, %{revoked_at: DateTime.utc_now()})

    result =
      if audit_enabled?(opts) do
        Repo.transaction(fn ->
          with {:ok, revoked} <- Repo.update(changeset),
               {:ok, _audit} <- record_api_key_audit("api_key.revoked", revoked, opts) do
            revoked
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      else
        Repo.update(changeset)
      end

    maybe_record_api_key_write_attempt(
      result,
      "api_key.revoked",
      api_key.org_id,
      api_key.id,
      %{"name" => api_key.name, "scopes" => api_key.scopes || []},
      opts
    )
  end

  @doc """
  Rotate an active org API key.

  The replacement key preserves the old key's scopes, revokes the old key in
  the same transaction, and returns the new raw token exactly once.
  """
  @spec rotate_api_key(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{token: String.t(), api_key: ApiKey.t(), revoked_api_key: ApiKey.t()}}
          | {:error, :not_found | :revoked | Ecto.Changeset.t()}
  def rotate_api_key(org_id, key_id, attrs \\ %{}, opts \\ []) do
    result =
      Repo.transaction(fn ->
        case Repo.get_by(ApiKey, id: key_id, org_id: org_id) do
          nil ->
            Repo.rollback(:not_found)

          %ApiKey{revoked_at: %DateTime{}} ->
            Repo.rollback(:revoked)

          %ApiKey{} = old_key ->
            token = "bft_" <> Sessions.generate_token()

            replacement_attrs =
              attrs
              |> Map.new(fn {key, value} -> {to_string(key), value} end)
              |> Map.put_new("name", rotated_api_key_name(old_key))
              |> Map.put("scopes", old_key.scopes || [])
              |> Map.put("org_id", org_id)
              |> Map.put("key_hash", Sessions.hash_token(token))

            with {:ok, replacement} <-
                   %ApiKey{} |> ApiKey.changeset(replacement_attrs) |> Repo.insert(),
                 {:ok, revoked} <-
                   old_key
                   |> ApiKey.changeset(%{revoked_at: DateTime.utc_now()})
                   |> Repo.update(),
                 {:ok, _audit} <-
                   maybe_record_api_key_rotation_audit(old_key, replacement, revoked, opts) do
              %{token: token, api_key: replacement, revoked_api_key: revoked}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)

    maybe_record_api_key_write_attempt(result, "api_key.rotated", org_id, key_id, attrs, opts)
  end

  @doc "Revoke a session (logout)."
  @spec logout(token :: String.t()) :: :ok
  def logout(token), do: Sessions.revoke(token)

  # === JIT provisioning (design §7) ===

  @doc """
  Just-in-time provision a user (and org membership) from verified OIDC claims.
  Public so it can be unit-tested directly; `callback/3` is the normal caller.
  """
  @spec provision_from_claims(OrgSsoConnection.t(), map(), keyword()) ::
          {:ok, User.t()} | {:error, term()}
  def provision_from_claims(%OrgSsoConnection{} = conn, claims, opts \\ []) do
    with {:ok, email} <- claim_email(claims),
         :ok <- check_domain(conn, email) do
      Repo.transaction(fn ->
        user = upsert_user(email, claims)

        case ensure_org_membership(conn, user, opts) do
          {:ok, _membership} -> user
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Just-in-time provision a user and org-scoped SSO identity from Feishu profile
  data. Email is optional and is not used as the durable Feishu login key.
  """
  @spec provision_from_feishu_identity(OrgSsoConnection.t(), map(), keyword()) ::
          {:ok, User.t()} | {:error, term()}

  def provision_from_feishu_identity(conn, identity, opts \\ [])

  def provision_from_feishu_identity(
        %OrgSsoConnection{provider: "feishu"} = conn,
        identity,
        opts
      ) do
    with {:ok, attrs} <- normalize_feishu_identity(identity),
         :ok <- check_feishu_tenant_binding(conn, attrs),
         :ok <- check_feishu_provisioning_policy(conn, attrs) do
      Repo.transaction(fn ->
        user = upsert_user_for_feishu_identity(conn, attrs)

        case ensure_org_membership(conn, user, opts) do
          {:ok, _membership} -> user
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def provision_from_feishu_identity(%OrgSsoConnection{}, _identity, _opts),
    do: {:error, :not_feishu_sso_connection}

  # === private ===

  defp sso_connection(org_id) do
    case Repo.get_by(OrgSsoConnection, org_id: org_id) do
      nil -> {:error, :no_sso_connection}
      conn -> {:ok, conn}
    end
  end

  # Translate a stored connection into the provider-facing sso map. A connection
  # without a client secret (public client) simply has a nil secret.
  defp to_sso(%OrgSsoConnection{} = conn) do
    secret =
      case conn.client_secret do
        "" -> nil
        other -> other
      end

    {:ok,
     %{
       org_id: conn.org_id,
       provider: conn.provider || "generic_oidc",
       issuer: conn.issuer,
       client_id: conn.client_id,
       client_secret: secret,
       provider_config: conn.provider_config || %{}
     }}
  end

  defp sso_login_failure_scope(org_id) do
    case sso_connection(org_id) do
      {:ok, %OrgSsoConnection{} = conn} ->
        %{
          provider: conn.provider || "generic_oidc",
          resource_type: "org_sso_connection",
          resource_id: conn.id
        }

      {:error, _reason} ->
        %{
          provider: "unknown",
          resource_type: "organization",
          resource_id: org_id
        }
    end
  end

  defp authorize_with_provider(%OrgSsoConnection{provider: "feishu"}, sso, opts) do
    Feishu.impl().authorize_url(sso, opts)
  end

  defp authorize_with_provider(%OrgSsoConnection{}, sso, opts) do
    OIDC.impl().authorize_url(sso, opts)
  end

  defp fetch_param(params, key) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      nil -> {:error, :missing_code}
      "" -> {:error, :missing_code}
      value -> {:ok, value}
    end
  end

  defp fetch_verifier(opts) do
    case Keyword.get(opts, :code_verifier) do
      nil -> {:error, :missing_code_verifier}
      "" -> {:error, :missing_code_verifier}
      verifier -> {:ok, verifier}
    end
  end

  defp fetch_id_token(tokens) do
    case Map.get(tokens, "id_token") || Map.get(tokens, :id_token) do
      nil -> {:error, :no_id_token}
      id_token -> {:ok, id_token}
    end
  end

  defp auth_login_failure_evidence(provider, stage, request_id, reason_class, reason) do
    %{
      provider: provider,
      stage: stage,
      request_id: request_id,
      reason_class: reason_class,
      status_code: auth_status_code(reason)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp auth_reason_class(%Ecto.Changeset{}), do: "validation_failed"
  defp auth_reason_class({:http, status}) when is_integer(status), do: "provider_http_error"
  defp auth_reason_class({:status, status}) when is_integer(status), do: "provider_http_error"
  defp auth_reason_class({:error, reason}), do: auth_reason_class(reason)
  defp auth_reason_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)

  defp auth_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp auth_reason_class(reason) when is_binary(reason) do
    reason = String.downcase(reason)

    cond do
      String.contains?(reason, "timeout") -> "timeout"
      String.contains?(reason, "http") -> "provider_http_error"
      String.contains?(reason, "token") -> "provider_token_error"
      String.contains?(reason, "state") -> "invalid_state"
      true -> "provider_error"
    end
  end

  defp auth_reason_class(_reason), do: "unknown"

  defp auth_failure_severity("invalid_state"), do: "warning"
  defp auth_failure_severity("missing_code"), do: "warning"
  defp auth_failure_severity("missing_code_verifier"), do: "warning"
  defp auth_failure_severity("no_sso_connection"), do: "warning"
  defp auth_failure_severity(_reason_class), do: "error"

  defp auth_status_code({:http, status}) when is_integer(status), do: status
  defp auth_status_code({:status, status}) when is_integer(status), do: status
  defp auth_status_code({:error, reason}), do: auth_status_code(reason)
  defp auth_status_code({_reason, status}) when is_integer(status), do: status
  defp auth_status_code(_reason), do: nil

  defp claim_email(claims) do
    email = claims["email"] || claims[:email]
    verified = Map.get(claims, "email_verified", Map.get(claims, :email_verified, false))

    cond do
      not is_binary(email) or email == "" -> {:error, :no_email_claim}
      verified == false -> {:error, :email_not_verified}
      true -> {:ok, String.downcase(email)}
    end
  end

  defp check_domain(%OrgSsoConnection{allowed_domains: domains}, email)
       when is_list(domains) and domains != [] do
    domain = email |> String.split("@") |> List.last()

    if domain in domains do
      :ok
    else
      {:error, :domain_not_allowed}
    end
  end

  defp check_domain(_conn, _email), do: :ok

  defp upsert_user(email, claims) do
    name = claims["name"] || claims[:name]

    case Repo.get_by(User, email: email) do
      nil ->
        %User{}
        |> User.changeset(%{email: email, name: name, status: "active"})
        |> Repo.insert!()

      %User{} = user ->
        # Backfill a missing display name from the IdP, but never overwrite an
        # existing one or the user's status.
        if is_binary(name) and (is_nil(user.name) or user.name == "") do
          user |> User.changeset(%{name: name}) |> Repo.update!()
        else
          user
        end
    end
  end

  defp normalize_feishu_identity(identity) do
    with {:ok, {subject_type, subject}} <- feishu_subject(identity) do
      {:ok,
       %{
         provider: "feishu",
         provider_subject_type: subject_type,
         provider_subject: subject,
         email: normalize_optional_email(value(identity, "email")),
         mobile: normalize_optional(value(identity, "mobile")),
         display_name:
           normalize_optional(value(identity, "display_name") || value(identity, "name")),
         provider_profile: provider_profile(identity)
       }}
    end
  end

  defp feishu_subject(identity) do
    cond do
      valid_subject?(value(identity, "provider_subject")) ->
        subject_type = normalize_optional(value(identity, "provider_subject_type")) || "user_id"
        {:ok, {subject_type, value(identity, "provider_subject")}}

      valid_subject?(value(identity, "user_id")) ->
        {:ok, {"user_id", value(identity, "user_id")}}

      valid_subject?(value(identity, "union_id")) ->
        {:ok, {"union_id", value(identity, "union_id")}}

      valid_subject?(value(identity, "open_id")) ->
        {:ok, {"open_id", value(identity, "open_id")}}

      true ->
        {:error, :missing_provider_subject}
    end
  end

  defp valid_subject?(value), do: is_binary(value) and value != ""

  defp provider_profile(identity) do
    case value(identity, "profile") do
      profile when is_map(profile) -> profile
      _ -> identity
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp normalize_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional(_), do: nil

  defp normalize_optional_email(value) do
    case normalize_optional(value) do
      nil -> nil
      email -> String.downcase(email)
    end
  end

  defp check_feishu_tenant_binding(%OrgSsoConnection{provider_config: config}, attrs) do
    expected = config_value(config || %{}, "tenant_key")
    actual = config_value(attrs.provider_profile || %{}, "tenant_key")

    cond do
      is_nil(expected) -> :ok
      actual == expected -> :ok
      true -> {:error, :feishu_tenant_mismatch}
    end
  end

  defp check_feishu_provisioning_policy(%OrgSsoConnection{} = conn, attrs) do
    case config_value(conn.provider_config || %{}, "provisioning_policy") do
      nil ->
        :ok

      "jit" ->
        :ok

      "existing_identity" ->
        if existing_feishu_identity?(conn, attrs) do
          :ok
        else
          {:error, :feishu_provisioning_policy_rejected}
        end

      _ ->
        {:error, :unsupported_feishu_provisioning_policy}
    end
  end

  defp existing_feishu_identity?(
         %OrgSsoConnection{org_id: org_id},
         %{provider_subject_type: subject_type, provider_subject: subject}
       ) do
    Repo.exists?(
      from i in OrgSsoIdentity,
        where:
          i.org_id == ^org_id and i.provider == "feishu" and
            i.provider_subject_type == ^subject_type and i.provider_subject == ^subject
    )
  end

  defp config_value(config, key) when is_map(config) do
    case Map.get(config, key) || Map.get(config, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp upsert_user_for_feishu_identity(
         %OrgSsoConnection{org_id: org_id} = conn,
         %{provider_subject_type: subject_type, provider_subject: subject} = attrs
       ) do
    case Repo.get_by(OrgSsoIdentity,
           org_id: org_id,
           provider: "feishu",
           provider_subject_type: subject_type,
           provider_subject: subject
         ) do
      %OrgSsoIdentity{} = identity ->
        user = Repo.get!(User, identity.user_id)

        identity
        |> OrgSsoIdentity.changeset(Map.merge(attrs, %{org_id: org_id, user_id: user.id}))
        |> Repo.update!()

        maybe_backfill_user_name(user, attrs.display_name)

      nil ->
        user =
          %User{}
          |> User.changeset(%{
            email: nil,
            name: attrs.display_name,
            status: "active"
          })
          |> Repo.insert!()

        %OrgSsoIdentity{}
        |> OrgSsoIdentity.changeset(Map.merge(attrs, %{org_id: conn.org_id, user_id: user.id}))
        |> Repo.insert!()

        user
    end
  end

  defp maybe_backfill_user_name(%User{} = user, name) when is_binary(name) and name != "" do
    if is_nil(user.name) or user.name == "" do
      user |> User.changeset(%{name: name}) |> Repo.update!()
    else
      user
    end
  end

  defp maybe_backfill_user_name(%User{} = user, _name), do: user

  defp ensure_org_membership(
         %OrgSsoConnection{org_id: org_id, default_role: role} = conn,
         user,
         opts
       ) do
    exists? =
      Repo.exists?(from m in OrgMembership, where: m.org_id == ^org_id and m.user_id == ^user.id)

    if exists? do
      {:ok, nil}
    else
      membership =
        %OrgMembership{}
        |> OrgMembership.changeset(%{org_id: org_id, user_id: user.id, role: role || "member"})
        |> Repo.insert!()

      with {:ok, _audit} <- maybe_record_sso_membership_audit(conn, user, membership, opts) do
        {:ok, membership}
      end
    end
  end

  defp maybe_record_sso_membership_audit(
         %OrgSsoConnection{} = conn,
         %User{} = user,
         %OrgMembership{} = membership,
         opts
       ) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: conn.org_id,
        actor_user_id: user.id,
        actor_label: audit_actor_label(user),
        action: "org_member.granted",
        resource_type: "org_member",
        resource_id: user.id,
        resource_label: "Org member #{short_id(user.id)}",
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{
          "target_user_id" => user.id,
          "new_role" => membership.role,
          "previous_role" => nil,
          "source" => "sso_jit",
          "provider" => conn.provider || "generic_oidc",
          "sso_connection_id" => conn.id
        },
        redacted_diff: %{"role" => %{"from" => nil, "to" => membership.role}}
      })
    else
      {:ok, nil}
    end
  end

  defp rotated_api_key_name(%ApiKey{name: name}) when is_binary(name) and name != "",
    do: "#{name} rotation"

  defp rotated_api_key_name(_), do: "Runner key rotation"

  defp record_api_key_audit(action, %ApiKey{} = api_key, opts) do
    Observability.record_audit(%{
      org_id: api_key.org_id,
      actor_user_id: Keyword.get(opts, :actor_user_id),
      actor_label: Keyword.get(opts, :actor_label),
      action: action,
      resource_type: "api_key",
      resource_id: api_key.id,
      resource_label: api_key.name || "API key #{short_id(api_key.id)}",
      result: "ok",
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
      metadata: %{
        "key_id" => api_key.id,
        "name" => api_key.name,
        "scopes" => api_key.scopes || [],
        "revoked" => not is_nil(api_key.revoked_at),
        "revoked_at" => api_key.revoked_at
      },
      redacted_diff: api_key_audit_diff(action, api_key)
    })
  end

  defp maybe_record_api_key_rotation_audit(old_key, replacement, revoked, opts) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: replacement.org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: "api_key.rotated",
        resource_type: "api_key",
        resource_id: replacement.id,
        resource_label: replacement.name || "API key #{short_id(replacement.id)}",
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{
          "old_key_id" => old_key.id,
          "replacement_key_id" => replacement.id,
          "old_name" => old_key.name,
          "replacement_name" => replacement.name,
          "scopes" => replacement.scopes || [],
          "old_key_revoked" => "true",
          "old_key_revoked_at" => revoked.revoked_at
        },
        redacted_diff: %{
          "credential" => %{"from" => old_key.id, "to" => replacement.id},
          "revoked_at" => %{"from" => nil, "to" => revoked.revoked_at}
        }
      })
    else
      {:ok, nil}
    end
  end

  defp maybe_record_api_key_write_attempt(
         {:error, reason} = result,
         action,
         org_id,
         key_id,
         attrs,
         opts
       ) do
    if audit_enabled?(opts) do
      case Observability.record_write_attempt(%{
             org_id: org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "api_key",
             resource_id: key_id,
             resource_label: api_key_attempt_label(attrs, key_id),
             result: "failed",
             reason: reason,
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             surface: "api_key",
             metadata: api_key_attempt_metadata(attrs, key_id)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning("api_key_write_attempt_audit_failed reason=#{inspect(audit_reason)}")
      end
    end

    result
  end

  defp maybe_record_api_key_write_attempt(result, _action, _org_id, _key_id, _attrs, _opts),
    do: result

  defp api_key_attempt_label(attrs, key_id) do
    attrs = stringify_api_key_attrs(attrs)

    cond do
      present?(attrs["name"]) -> attrs["name"]
      present?(key_id) -> "API key #{short_id(key_id)}"
      true -> "API key"
    end
  end

  defp api_key_attempt_metadata(attrs, key_id) do
    attrs = stringify_api_key_attrs(attrs)

    %{
      "key_id" => key_id,
      "name_configured" => present?(attrs["name"]),
      "scopes" => scopes_metadata(attrs["scopes"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp scopes_metadata(scopes) when is_list(scopes), do: scopes
  defp scopes_metadata(_scopes), do: nil

  defp stringify_api_key_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_api_key_attrs(_attrs), do: %{}

  defp api_key_audit_diff("api_key.revoked", %ApiKey{} = api_key) do
    %{"revoked_at" => %{"from" => nil, "to" => api_key.revoked_at}}
  end

  defp api_key_audit_diff("api_key.created", %ApiKey{} = api_key) do
    %{"credential" => %{"from" => nil, "to" => api_key.id}}
  end

  defp api_key_audit_diff(_action, _api_key), do: %{}

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  defp audit_actor_label(user) do
    cond do
      present?(user.email) -> String.trim(user.email)
      present?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_id(value), do: value
end
