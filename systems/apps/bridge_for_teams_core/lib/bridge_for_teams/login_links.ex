defmodule BridgeForTeams.LoginLinks do
  @moduledoc """
  Self-service email magic-link login — the fallback for orgs WITHOUT an SSO
  connection (design §7 keeps SSO the primary path).

  A visitor on the login page names an org and their email;
  `request_login_link/3` silently issues a one-time link only when everything
  matches: the org exists, the org has **no** SSO connection (a magic link
  must never bypass a configured IdP), the email belongs to an existing
  active user, and that user is a member of the org. The caller always shows
  the same neutral "link sent if matched" message, so the endpoint reveals
  nothing about org slugs, accounts, or membership.

  Token handling mirrors `BridgeForTeams.AccountRecovery`: an opaque random
  token whose SHA-256 hash is stored (`login_email_links`), single-use under
  a row lock, short TTL (15 minutes). Redemption re-checks
  the org still has no SSO connection and the user is still an active member,
  then mints a normal dashboard session (`BridgeForTeams.Auth.Sessions`).

  Delivery goes through `BridgeForTeams.LoginLinks.Delivery` (Postmark by
  default, same server token as agent owner notifications with a dedicated
  From address). Requests are rate-limited per IP and per org+email via
  `BridgeForTeams.RateLimit`.
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.LoginLinks.Delivery
  alias BridgeForTeams.{Memberships, Observability, Orgs, RateLimit, Repo}
  alias BridgeForTeams.Schema.{LoginEmailLink, Organization, User}

  @ttl_seconds 15 * 60
  # Per requester IP: absorbs a login page's worth of retries, then ~2/minute.
  @ip_burst 10
  @ip_rate 1 / 30
  # Per org+email: a couple of immediate resends, then one per 5 minutes.
  @email_burst 3
  @email_rate 1 / 300

  @doc """
  Whether magic-link login can be offered at all (delivery configured). The
  login flow falls back to the plain "SSO not configured" error when false.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Delivery.impl().configured?()

  @doc """
  Issue and email a one-time sign-in link when `org_slug` + `email` match an
  SSO-less org and one of its active members. Always returns `:ok` — the
  caller must not be able to distinguish matched from unmatched requests.

  Options:

    * `:base_url` - dashboard base URL the link is built on (required for a
      clickable absolute URL; a relative path is emailed otherwise).
    * `:remote_ip` - requester IP string for rate limiting.
    * `:request_id` - audit correlation id.
    * `:rate_limits` - `[ip_burst:, ip_rate:, email_burst:, email_rate:]`
      overrides, mainly for tests.
  """
  @spec request_login_link(String.t(), String.t(), keyword()) :: :ok
  def request_login_link(org_slug, email, opts \\ []) do
    org_slug = normalize(org_slug)
    email = normalize(email)

    with true <- enabled?(),
         :ok <- check_rate_limits(org_slug, email, opts),
         true <- valid_email?(email),
         {:ok, %Organization{} = org} <- Orgs.get_org_by_slug(org_slug),
         :ok <- ensure_no_sso(org),
         {:ok, %User{status: "active"} = user} <- fetch_user_by_email(email),
         {:ok, _role} <- Memberships.org_role(org.id, user.id) do
      issue_and_deliver(org, user, email, opts)
    else
      _no_match -> :ok
    end
  end

  @doc """
  Redeem a one-time login token and create a normal dashboard auth session
  atomically. Rejects used, expired, and unknown tokens; rejects redemption
  when the org has since configured SSO or the user is no longer an active
  member. `:device`/`:ttl_seconds` pass through to `Sessions.create/2`.
  """
  @spec redeem_login_token_for_session(String.t(), keyword()) ::
          {:ok,
           %{
             user: User.t(),
             org: Organization.t(),
             token: String.t(),
             session: BridgeForTeams.Schema.AuthSession.t(),
             login_link: LoginEmailLink.t()
           }}
          | {:error, term()}
  def redeem_login_token_for_session(token, opts \\ [])

  def redeem_login_token_for_session(token, opts) when is_binary(token) do
    session_opts = Keyword.take(opts, [:device, :ttl_seconds])

    Repo.transaction(fn ->
      with {:ok, link} <- fetch_redeemable_link(token),
           {:ok, org} <- fetch_sso_less_org(link),
           {:ok, user} <- fetch_active_member(link, org),
           {:ok, used_link} <- mark_used(link),
           {:ok, %{token: session_token, session: session}} <-
             Sessions.create(user, session_opts) do
        record_audit("login_link.redeemed", org, user, used_link,
          actor_user_id: user.id,
          actor_label: user.email,
          request_id: opts[:request_id]
        )

        %{user: user, org: org, token: session_token, session: session, login_link: used_link}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def redeem_login_token_for_session(_token, _opts), do: {:error, :invalid_login_token}

  # ---- issuance ----

  defp issue_and_deliver(%Organization{} = org, %User{} = user, email, opts) do
    token = generate_token()

    insert_attrs = %{
      "user_id" => user.id,
      "org_id" => org.id,
      "token_hash" => token_hash(token),
      "expires_at" => DateTime.add(now(), @ttl_seconds, :second)
    }

    with {:ok, link} <-
           %LoginEmailLink{} |> LoginEmailLink.changeset(insert_attrs) |> Repo.insert(),
         :ok <- Delivery.impl().deliver_login_link(email, org.name, login_url(token, opts)) do
      record_audit("login_link.requested", org, user, link, request_id: opts[:request_id])
    else
      {:error, reason} ->
        Logger.warning("login link issue failed: org=#{org.id} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp login_url(token, opts) do
    path = "/auth/email/verify?" <> URI.encode_query(%{"token" => token})

    case normalize(opts[:base_url]) do
      "" -> path
      base_url -> String.trim_trailing(base_url, "/") <> path
    end
  end

  defp generate_token do
    "bft_login_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp token_hash(token), do: token |> String.trim() |> Sessions.hash_token()

  # ---- matching / policy checks ----

  defp valid_email?(email), do: String.contains?(email, "@")

  defp ensure_no_sso(%Organization{id: org_id}) do
    case Orgs.get_sso_connection(org_id) do
      nil -> :ok
      _sso -> {:error, :sso_configured}
    end
  end

  defp fetch_user_by_email(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  # ---- redemption ----

  defp fetch_redeemable_link(token) do
    hash = token_hash(token)

    query =
      from l in LoginEmailLink,
        where: l.token_hash == ^hash,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :invalid_login_token}
      %LoginEmailLink{used_at: %DateTime{}} -> {:error, :login_token_already_used}
      %LoginEmailLink{} = link -> check_expiry(link)
    end
  end

  defp check_expiry(%LoginEmailLink{expires_at: expires_at} = link) do
    case DateTime.compare(expires_at, now()) do
      :gt -> {:ok, link}
      _ -> {:error, :login_token_expired}
    end
  end

  # The link was issued because the org had no SSO; if an IdP has been
  # configured since, the magic link must not bypass it.
  defp fetch_sso_less_org(%LoginEmailLink{org_id: org_id}) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
         :ok <- ensure_no_sso(org) do
      {:ok, org}
    else
      _ -> {:error, :invalid_login_token}
    end
  end

  defp fetch_active_member(%LoginEmailLink{user_id: user_id}, %Organization{id: org_id}) do
    with %User{status: "active"} = user <- Repo.get(User, user_id),
         {:ok, _role} <- Memberships.org_role(org_id, user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_login_token}
    end
  end

  defp mark_used(%LoginEmailLink{} = link) do
    link
    |> LoginEmailLink.changeset(%{"used_at" => now()})
    |> Repo.update()
  end

  # ---- rate limiting ----

  defp check_rate_limits(org_slug, email, opts) do
    limits =
      :bridge_for_teams_core
      |> Application.get_env(:login_link_rate_limits, [])
      |> Keyword.merge(Keyword.get(opts, :rate_limits, []))

    ip = normalize(opts[:remote_ip])

    ip_ok? =
      ip == "" or
        match?(
          {:ok, _},
          RateLimit.hit({:login_link_ip, ip}, 1,
            burst: Keyword.get(limits, :ip_burst, @ip_burst),
            rate: Keyword.get(limits, :ip_rate, @ip_rate)
          )
        )

    email_ok? =
      match?(
        {:ok, _},
        RateLimit.hit({:login_link_email, org_slug, String.downcase(email)}, 1,
          burst: Keyword.get(limits, :email_burst, @email_burst),
          rate: Keyword.get(limits, :email_rate, @email_rate)
        )
      )

    if ip_ok? and email_ok?, do: :ok, else: {:error, :rate_limited}
  end

  # ---- audit ----

  # Redacted org-scoped audit rows: never the token or its hash.
  defp record_audit(action, %Organization{} = org, %User{} = user, %LoginEmailLink{} = link, opts) do
    case Observability.record_audit(%{
           org_id: org.id,
           actor_user_id: opts[:actor_user_id],
           actor_label: opts[:actor_label],
           action: action,
           resource_type: "login_email_link",
           resource_id: link.id,
           resource_label: "Email sign-in link #{String.slice(link.id, 0, 8)}",
           result: "ok",
           request_id: opts[:request_id] || Ecto.UUID.generate(),
           metadata: %{
             "user_id" => user.id,
             "expires_at" => DateTime.to_iso8601(link.expires_at)
           }
         }) do
      {:ok, _audit} -> :ok
      {:error, reason} -> Logger.warning("login link audit failed: #{inspect(reason)}")
    end

    :ok
  end

  defp normalize(value) when is_binary(value), do: String.trim(value)
  defp normalize(_value), do: ""

  defp now, do: DateTime.utc_now()
end
