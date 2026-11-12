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

  Every request writes one private `login_link_request` log line with its
  outcome (`accepted`, `org_not_found`, `not_member`, `rate_limited_email`,
  `recipient_suppressed`, ...), the request id, and the internal org, user,
  link and provider message ids it reached. It never logs the email address,
  the org slug the visitor typed, the token, or provider error text.
  `delivery_evidence/3` adds what the provider saw after acceptance.
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

    {outcome, facts} =
      with :ok <- check(enabled?(), :delivery_not_configured),
           :ok <- check_rate_limits(org_slug, email, opts),
           :ok <- check(valid_email?(email), :invalid_email),
           {:ok, org, user} <- match_member(org_slug, email) do
        issue_and_deliver(org, user, email, opts)
      end

    log_request(outcome, facts, opts)
    :ok
  end

  @doc """
  Operator diagnosis of a member's missing sign-in email, for `bin/comma rpc`:
  whether a request would match now, the provider's suppression of the
  member's address, and the latest `limit` (default 5, at most 20) links with
  their request reference and delivery events.

  Each link's `acceptance_recorded` says whether a `login_link.requested`
  audit row exists. Only a recorded row is evidence of provider acceptance;
  `false` means the outcome is unknown (the send failed, or the audit write
  failed after acceptance), so `provider_events` is `nil` without a stored
  message id rather than a provider answer.

  Find `org_id` and `user_id` from the `login_link_request` log line or the
  database. The result carries no email address, token, or provider free text.
  """
  @spec delivery_evidence(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def delivery_evidence(org_id, user_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 5) |> min(20) |> max(1)

    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
         %User{} = user <- Repo.get(User, user_id) do
      links =
        Repo.all(
          from l in LoginEmailLink,
            where: l.org_id == ^org.id and l.user_id == ^user.id,
            order_by: [desc: l.created_at],
            limit: ^limit
        )

      {:ok,
       %{
         org_id: org.id,
         user_id: user.id,
         delivery_configured: enabled?(),
         sso_configured: ensure_no_sso(org) != :ok,
         user_status: user.status,
         member: match?({:ok, _role}, Memberships.org_role(org.id, user.id)),
         suppression: provider_lookup(Delivery.impl().recipient_suppression(user.email)),
         links: Enum.map(links, &link_evidence(org, &1))
       }}
    else
      _ -> {:error, :not_found}
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
    facts = %{org_id: org.id, user_id: user.id}

    insert_attrs = %{
      "user_id" => user.id,
      "org_id" => org.id,
      "token_hash" => token_hash(token),
      "expires_at" => DateTime.add(now(), @ttl_seconds, :second)
    }

    case %LoginEmailLink{} |> LoginEmailLink.changeset(insert_attrs) |> Repo.insert() do
      {:ok, link} ->
        facts = Map.put(facts, :link_id, link.id)

        case Delivery.impl().deliver_login_link(email, org.name, login_url(token, opts)) do
          {:ok, receipt} ->
            message_id = receipt[:provider_message_id]

            record_audit("login_link.requested", org, user, link,
              request_id: opts[:request_id],
              provider_message_id: message_id
            )

            {:accepted, Map.put(facts, :provider_message_id, message_id)}

          {:error, reason} ->
            delivery_failure(reason, facts)
        end

      {:error, _changeset} ->
        {:link_insert_failed, facts}
    end
  end

  # Bounded outcome classes: a provider or transport reason can carry
  # response bytes, so only its status and code are kept. Postmark answers
  # ErrorCode 406 for a recipient on its suppression list.
  defp delivery_failure({:postmark, _status, 406}, facts), do: {:recipient_suppressed, facts}

  defp delivery_failure({:postmark, status, code}, facts) do
    {:provider_rejected, Map.merge(facts, %{provider_status: status, provider_error_code: code})}
  end

  defp delivery_failure({:transport, _reason}, facts), do: {:provider_unreachable, facts}
  defp delivery_failure(:not_configured, facts), do: {:delivery_not_configured, facts}
  defp delivery_failure(_reason, facts), do: {:delivery_failed, facts}

  @failure_outcomes [
    :link_insert_failed,
    :recipient_suppressed,
    :provider_rejected,
    :provider_unreachable,
    :delivery_failed,
    :rate_limiter_unavailable
  ]

  # One private line per request: the outcome the visitor's neutral notice
  # hides, with internal ids only — never the email, slug, token, or link URL.
  defp log_request(outcome, facts, opts) do
    level = if outcome in @failure_outcomes, do: :warning, else: :info

    metadata =
      [event: "login_link_request", outcome: outcome, request_id: opts[:request_id]] ++
        Enum.to_list(facts)

    Logger.log(level, "Login link request #{outcome}", metadata)
  end

  defp link_evidence(%Organization{} = org, %LoginEmailLink{} = link) do
    audit =
      org.id
      |> Observability.list_audit_logs(
        action: "login_link.requested",
        resource_type: "login_email_link",
        resource_id: link.id,
        limit: 1
      )
      |> List.first()

    message_id = audit && audit.metadata["message_id"]

    %{
      link_id: link.id,
      created_at: link.created_at,
      expires_at: link.expires_at,
      used_at: link.used_at,
      request_id: audit && audit.request_id,
      # Whether an acceptance audit row exists. Its absence is not a provider
      # rejection: the audit write can fail after Postmark accepted the send.
      acceptance_recorded: not is_nil(audit),
      provider_message_id: message_id,
      provider_events:
        if(is_binary(message_id), do: provider_lookup(Delivery.impl().message_events(message_id)))
    }
  end

  defp provider_lookup({:ok, value}), do: value

  defp provider_lookup({:error, {:postmark, status, code}}),
    do: %{error: {:provider, status, code}}

  defp provider_lookup({:error, {:transport, _reason}}), do: %{error: :provider_unreachable}
  defp provider_lookup({:error, reason}) when is_atom(reason), do: %{error: reason}
  defp provider_lookup(_result), do: %{error: :lookup_failed}

  defp login_url(token, opts) do
    path = "/auth/email/verify?" <> URI.encode_query(%{"token" => token})

    case normalize(opts[:base_url]) do
      "" -> path
      base_url -> String.trim_trailing(base_url, "/") <> path
    end
  end

  defp generate_token do
    "bft_login_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(24), padding: false)
  end

  defp token_hash(token), do: token |> String.trim() |> Sessions.hash_token()

  # ---- matching / policy checks ----

  defp valid_email?(email), do: String.contains?(email, "@")

  defp check(true, _outcome), do: :ok
  defp check(_false, outcome), do: {outcome, %{}}

  defp match_member(org_slug, email) do
    case Orgs.get_org_by_slug(org_slug) do
      {:ok, %Organization{} = org} -> match_org_member(org, email)
      _ -> {:org_not_found, %{}}
    end
  end

  defp match_org_member(%Organization{} = org, email) do
    facts = %{org_id: org.id}

    with :ok <- ensure_no_sso(org) |> check_ok(:sso_configured, facts),
         {:ok, user} <- fetch_user_by_email(email) |> check_ok(:user_not_found, facts) do
      facts = Map.put(facts, :user_id, user.id)

      cond do
        user.status != "active" -> {:user_inactive, facts}
        not match?({:ok, _role}, Memberships.org_role(org.id, user.id)) -> {:not_member, facts}
        true -> {:ok, org, user}
      end
    end
  end

  defp check_ok(:ok, _outcome, _facts), do: :ok
  defp check_ok({:ok, _value} = ok, _outcome, _facts), do: ok
  defp check_ok(_error, outcome, facts), do: {outcome, facts}

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
      |> SystemsRuntime.get_env(:login_link_rate_limits, [])
      |> Keyword.merge(Keyword.get(opts, :rate_limits, []))

    ip = normalize(opts[:remote_ip])

    ip_result =
      if ip == "" do
        {:ok, :unlimited}
      else
        RateLimit.hit({:login_link_ip, ip}, 1,
          burst: Keyword.get(limits, :ip_burst, @ip_burst),
          rate: Keyword.get(limits, :ip_rate, @ip_rate)
        )
      end

    email_result =
      RateLimit.hit({:login_link_email, org_slug, String.downcase(email)}, 1,
        burst: Keyword.get(limits, :email_burst, @email_burst),
        rate: Keyword.get(limits, :email_rate, @email_rate)
      )

    # Fails closed: an unavailable limiter drops the request like a denial.
    case {ip_result, email_result} do
      {{:ok, _}, {:ok, _}} -> :ok
      {{:error, :rate_limited}, _} -> {:rate_limited_ip, %{}}
      {_, {:error, :rate_limited}} -> {:rate_limited_email, %{}}
      _ -> {:rate_limiter_unavailable, %{}}
    end
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
           request_id: opts[:request_id] || SystemsRuntime.Proc.uuid(),
           metadata:
             %{
               "user_id" => user.id,
               "expires_at" => DateTime.to_iso8601(link.expires_at)
             }
             # The Postmark MessageID; audit redaction keeps the `message_id` key.
             |> maybe_put("message_id", opts[:provider_message_id])
         }) do
      {:ok, _audit} -> :ok
      {:error, reason} -> Logger.warning("login link audit failed: #{inspect(reason)}")
    end

    :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize(value) when is_binary(value), do: String.trim(value)
  defp normalize(_value), do: ""

  defp now, do: SystemsClock.utc_now()
end
