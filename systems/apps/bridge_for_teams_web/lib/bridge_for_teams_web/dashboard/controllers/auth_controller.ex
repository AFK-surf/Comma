defmodule BridgeForTeamsWeb.Dashboard.AuthController do
  @moduledoc """
  Dashboard auth actions driving the existing OIDC SSO flow (design §7) via
  `BridgeForTeams.Auth`. These actions do browser redirects and set the SIGNED
  dashboard session cookie with the opaque `BridgeForTeams.Auth` session token.

  Flow:

    * `GET  /login`               — render the login page (enter an org slug).
    * `POST /auth/:org_slug/start`— build the IdP authorization-code+PKCE redirect,
                                     stash state/verifier in the session, redirect.
    * `GET  /auth/callback`       — exchange the code, provision, create a session,
                                     store the token in the signed cookie, redirect /.
    * `GET  /auth/recovery`       — redeem a system-admin-generated one-time link,
                                     create a session, redirect /.
    * `GET  /auth/email`          — email magic-link form (fallback for orgs
                                     without an SSO connection).
    * `POST /auth/email/send`     — issue + email the one-time sign-in link
                                     (always the same neutral response).
    * `GET  /auth/email/verify`   — redeem the emailed link, create a session,
                                     store the token in the signed cookie, redirect /.
    * `DELETE /logout`            — revoke the session and clear the cookie.

  Tests/dev never need a live IdP: the OIDC Fake is injected, and the
  `BridgeForTeamsWeb.Dashboard.LiveCase` login helper creates a real session
  directly via `BridgeForTeams.Auth.Sessions`.
  """
  use BridgeForTeamsWeb.Dashboard, :controller
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{AccountRecovery, Accounts, Auth, CftAnalytics, LoginLinks, Memberships}
  alias BridgeForTeams.{OrgCreationInvites, Orgs}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.M2square.QuoteToken
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  @doc """
  GET /dev/login — dev/e2e-ONLY login bypass. Creates a real session for an
  existing user (by email) without driving an external IdP, so the Playwright
  suite can authenticate. Disabled by default: returns 404 unless the
  `:dev_login` flag is set (non-prod + config.json
  `bridge_for_teams.dashboard.dev_login=true`, wired in config/runtime.exs).
  Never enabled in prod.
  """
  def dev_login(conn, params) do
    if SystemsRuntime.get_env(:bridge_for_teams_web, :dev_login, false) do
      email = params["email"] || "e2e@example.com"

      with {:ok, user} <- Accounts.get_user_by_email(email),
           {:ok, %{token: token}} <- Sessions.create(user, []) do
        conn
        |> DashAuth.put_token_in_session(token)
        |> redirect(
          to:
            DashAuth.local_return_to(params["to"]) ||
              DashAuth.local_return_to(params["return_to"]) || "/"
        )
      else
        _ -> conn |> send_resp(404, "not found") |> halt()
      end
    else
      conn |> send_resp(404, "not found") |> halt()
    end
  end

  @doc "GET /login — show the login form (org slug -> OIDC)."
  def login(conn, params) do
    return_to = DashAuth.local_return_to(params["return_to"])

    if conn.assigns[:current_user] do
      redirect(conn, to: return_to || "/")
    else
      org = login_org(params)

      render(conn, :login,
        error: Phoenix.Flash.get(conn.assigns.flash, :error),
        layout: false,
        org: org,
        lark_sign_in: lark_sign_in?(org),
        org_slug: params["o"],
        shortcuts_disabled: login_shortcuts_disabled?(params),
        return_to: return_to
      )
    end
  end

  @doc "GET /signup — show the invite-code org/account creation form."
  def signup(conn, params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render_signup(conn, params)
    end
  end

  @teams_signup_fields ~w(email name org_name seats quote_token)
  @expired_quote_errors [:quote_expired, :invalid_quote_token, :quote_signing_unconfigured]
  @m2square_signup_fields ~w(provider country payment_type firstname lastname phone)

  def teams_signup(conn, params) do
    current_user = conn.assigns[:current_user]

    if current_user && params["mode"] != "new" do
      page = parse_page(params["page"])
      page_data = Orgs.list_user_orgs_with_roles_page(current_user.id, page, per_page: 20)

      if page_data.items != [] or page > 1 do
        render_teams_chooser(conn, current_user, page_data, params)
      else
        render_teams_new_purchase(conn, params, current_user, false)
      end
    else
      has_existing_orgs =
        not is_nil(current_user) and not is_nil(Orgs.first_org_for_user(current_user.id))

      render_teams_new_purchase(conn, params, current_user, has_existing_orgs)
    end
  end

  defp render_teams_chooser(conn, current_user, page_data, params) do
    admin_account_ids =
      for %{org: org, role: role} <- page_data.items,
          role in ["owner", "admin"],
          do: org.billing_account_id

    summaries =
      if admin_account_ids == [] do
        %{}
      else
        case BillingCore.TeamsAccess.batch_admin_summary(
               admin_account_ids,
               SystemsClock.utc_now()
             ) do
          {:ok, map} -> map
          {:error, _} -> :unavailable
        end
      end

    items =
      Enum.map(page_data.items, fn %{org: org, role: role} ->
        billing =
          cond do
            role not in ["owner", "admin"] -> nil
            summaries == :unavailable -> :unavailable
            true -> Map.get(summaries, org.billing_account_id, :unavailable)
          end

        encoded_slug = URI.encode(org.slug, &URI.char_unreserved?/1)

        %{
          org: org,
          role: role,
          billing: billing,
          open_path: "/orgs/" <> encoded_slug,
          billing_path:
            if(role in ["owner", "admin"],
              do: "/orgs/" <> encoded_slug <> "/settings#teams-billing"
            )
        }
      end)

    from_param = valid_signup_from(params["from"])

    new_org_query =
      %{"mode" => "new"}
      |> maybe_put_query("from", from_param)
      |> URI.encode_query()

    render(conn, :teams_chooser,
      layout: false,
      current_user: current_user,
      items: items,
      page: page_data.page,
      has_prev: page_data.page > 1,
      has_next: page_data.has_next,
      from: from_param,
      new_org_path: "/signup/teams?" <> new_org_query,
      info: Phoenix.Flash.get(conn.assigns.flash, :info)
    )
  end

  defp render_teams_new_purchase(conn, params, current_user, has_existing_orgs) do
    case resolve_signup_purchase(conn) do
      {:redirect_payment, id} ->
        redirect(conn, to: "/signup/payment?" <> URI.encode_query(%{"p" => id}))

      {status, purchase_id, new?, rotated?} ->
        conn =
          conn
          |> put_session(:teams_purchase_id, purchase_id)
          |> then(fn c ->
            if new?, do: put_session(c, :teams_purchase_requires_p, true), else: c
          end)
          |> then(fn c ->
            if rotated?, do: delete_session(c, :teams_signup_email), else: c
          end)

        signup =
          params
          |> checkout_fields(@teams_signup_fields -- ["quote_token"])
          |> prefill_user_signup(current_user)

        # A purchase opens once: "Back to checkout" and a refreshed quote come back
        # to this page without the website's `from`, and must not restate its entry.
        if new? and not crawler?(conn) do
          observe(conn, fn ->
            CftAnalytics.capture(purchase_id, "cft_signup_opened", purchase_id, %{
              "entry" => CftAnalytics.entry(params["from"]),
              "country" => detected_checkout_country(conn),
              "locale" => Gettext.get_locale(BridgeForTeamsWeb.Gettext)
            })
          end)
        end

        unavailable_error =
          if status == :unavailable do
            gettext(
              "Unable to verify your previous checkout status right now. Please refresh and try again."
            )
          end

        case QuoteToken.prepare_payment_window("signup:" <> purchase_id, 100) do
          {:ok, %{ttl_seconds: ttl} = window} when ttl > 0 ->
            render_teams_signup(conn, signup, window, unavailable_error,
              current_user: current_user,
              has_existing_orgs: has_existing_orgs
            )

          _ ->
            render_expired_teams_signup(conn, signup,
              current_user: current_user,
              has_existing_orgs: has_existing_orgs
            )
        end
    end
  end

  defp resolve_signup_purchase(conn) do
    case Ecto.UUID.cast(get_session(conn, :teams_purchase_id) || "") do
      {:ok, existing_id} ->
        case paid_signup_purchase_state(paid_signup_mod(), existing_id) do
          {:settled_active, _org} ->
            {:ok, SystemsRuntime.Proc.uuid(), true, true}

          {:settled_inactive, _org} ->
            {:ok, SystemsRuntime.Proc.uuid(), true, true}

          {:half_committed, %{id: ^existing_id}} ->
            {:redirect_payment, existing_id}

          :unavailable ->
            {:unavailable, existing_id, false, false}

          :pending ->
            {:ok, existing_id, false, false}
        end

      :error ->
        {:ok, SystemsRuntime.Proc.uuid(), true, false}
    end
  end

  defp prefill_user_signup(signup, nil), do: signup

  defp prefill_user_signup(signup, user) do
    signup
    |> Map.put_new("email", user.email || "")
    |> Map.put_new("name", user.name || "")
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp valid_signup_from(from) when from in ~w(pricing enterprise personal dashboard), do: from
  defp valid_signup_from(_), do: nil

  def buy_teams(conn, params) do
    signup = checkout_params(params["signup"])
    token = signup["quote_token"]
    current_user = conn.assigns[:current_user]

    has_existing_orgs =
      not is_nil(current_user) and not is_nil(Orgs.first_org_for_user(current_user.id))

    with {:ok, purchase_id} <- Ecto.UUID.cast(get_session(conn, :teams_purchase_id) || ""),
         {:ok, snapshot} <-
           QuoteToken.verify(token, "signup:" <> purchase_id, SystemsClock.utc_now()) do
      base_url =
        SystemsRuntime.fetch_env!(:bridge_for_teams_web, :public_base_url)
        |> String.trim_trailing("/")

      result =
        start_teams_checkout(
          paid_signup_mod(),
          purchase_id,
          signup |> Map.delete("quote_token") |> put_analytics_opt_out(conn),
          token,
          base_url
        )

      observe(conn, fn -> observe_checkout(purchase_id, signup, result) end)

      case result do
        {:ok, %{"url" => url}} ->
          conn
          |> put_session(:teams_signup_email, signup["email"])
          |> redirect(external: url)

        {:error, reason} when reason in @expired_quote_errors ->
          render_expired_teams_signup(conn, signup,
            current_user: current_user,
            has_existing_orgs: has_existing_orgs
          )

        {:error, reason} ->
          remaining_ttl =
            snapshot["expires_at"] - DateTime.to_unix(SystemsClock.utc_now(), :second)

          if remaining_ttl > 0 do
            window = %{
              token: token,
              ttl_seconds: remaining_ttl,
              countries: QuoteToken.countries_for_view(snapshot)
            }

            pending_checkout =
              if reason == :subscription_checkout_pending do
                build_pending_checkout(paid_signup_mod(), purchase_id)
              end

            render_teams_signup(conn, signup, window, checkout_error(signup, reason),
              current_user: current_user,
              has_existing_orgs: has_existing_orgs,
              pending_checkout: pending_checkout
            )
          else
            render_expired_teams_signup(conn, signup,
              current_user: current_user,
              has_existing_orgs: has_existing_orgs
            )
          end
      end
    else
      failure ->
        reason =
          case failure do
            {:error, reason} when is_atom(reason) -> reason
            _ -> :quote_expired
          end

        with {:ok, purchase_id} <- Ecto.UUID.cast(get_session(conn, :teams_purchase_id) || "") do
          observe(conn, fn -> observe_checkout(purchase_id, signup, {:error, reason}) end)
        end

        render_expired_teams_signup(conn, signup,
          current_user: current_user,
          has_existing_orgs: has_existing_orgs
        )
    end
  end

  defp build_pending_checkout(mod, purchase_id) do
    snapshot =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :pending_checkout_snapshot, 1) do
        case mod.pending_checkout_snapshot(purchase_id) do
          {:ok, snap} -> snap
          _ -> nil
        end
      end

    %{
      url: snapshot && snapshot.url,
      expires_at: snapshot && snapshot.expires_at,
      payment_path: "/signup/payment?" <> URI.encode_query(%{"p" => purchase_id})
    }
  end

  # Funnel events skip a request with DNT; the observation never changes the answer.
  defp observe(conn, fun) do
    unless get_req_header(conn, "dnt") == ["1"], do: CftAnalytics.observe(fun)
    :ok
  end

  # Link previews and crawlers open the page without a session, each as a new purchase.
  @crawler ~r/bot|crawl|spider|slurp|preview|facebookexternalhit|curl|wget|python-requests|headless/i
  defp crawler?(conn) do
    case get_req_header(conn, "user-agent") do
      [agent | _] -> Regex.match?(@crawler, agent)
      [] -> true
    end
  end

  defp put_analytics_opt_out(signup, conn) do
    if get_req_header(conn, "dnt") == ["1"],
      do: Map.put(signup, "analytics_opt_out", true),
      else: signup
  end

  defp observe_checkout(purchase_id, signup, result) do
    provider = if signup["provider"] == "m2square", do: "m2square", else: "stripe"

    properties = %{
      "provider" => provider,
      "seats" => parse_seats(signup["seats"]),
      "is_internal" => CftAnalytics.internal_email?(signup["email"])
    }

    case result do
      {:ok, %{"id" => session_id} = checkout} when is_binary(session_id) ->
        CftAnalytics.capture(
          purchase_id,
          "cft_checkout_created",
          session_id,
          properties,
          stripe_session_created_at(checkout)
        )

      {:ok, %{"mch_order_id" => order}} when is_binary(order) ->
        CftAnalytics.capture(purchase_id, "cft_checkout_created", order, properties)

      {:error, reason} ->
        kind = CftAnalytics.failure_kind(reason)

        CftAnalytics.capture(
          purchase_id,
          "cft_checkout_failed",
          "#{purchase_id}:#{kind}",
          Map.put(properties, "failure_kind", kind)
        )

      _ ->
        :ok
    end
  end

  # A Stripe session lasts 24 hours from creation; a reused session keeps its
  # first creation time, so its event deduplicates on any day. Whole seconds
  # round down: round up, so the event never precedes the request's own steps.
  defp stripe_session_created_at(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: DateTime.from_unix!(expires_at - 86_400 + 1)

  defp stripe_session_created_at(_checkout), do: SystemsClock.utc_now()

  defp parse_seats(value) when is_integer(value), do: value

  defp parse_seats(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seats, ""} -> seats
      _ -> nil
    end
  end

  defp parse_seats(_value), do: nil

  defp start_teams_checkout(mod, purchase_id, signup, token, base_url) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :start_with_quote, 4) do
      mod.start_with_quote(purchase_id, signup, token, base_url)
    else
      mod.start(purchase_id, signup, base_url)
    end
  end

  def teams_payment(conn, params) do
    case resolve_payment_purchase(conn, params) do
      :unmatched ->
        render(conn, :teams_payment,
          layout: false,
          matched_session: false,
          cancelled: false,
          state: :unmatched,
          org: nil,
          purchase_id: nil,
          check_payment_path: nil
        )

      {:matched, purchase_id} ->
        order = valid_m2square_order(params["m2_order"])
        paid_signup = paid_signup_mod()

        if order && Code.ensure_loaded?(paid_signup) &&
             function_exported?(paid_signup, :check_m2square_signup_return, 2) do
          paid_signup.check_m2square_signup_return(purchase_id, order)
        end

        if params["status"] in ["success", "cancel"] do
          observe(conn, fn ->
            CftAnalytics.capture(
              purchase_id,
              "cft_payment_returned",
              "#{purchase_id}:#{params["status"]}",
              %{
                "state" => params["status"],
                "provider" => if(order, do: "m2square", else: "stripe")
              }
            )
          end)
        end

        case paid_signup_purchase_state(paid_signup, purchase_id) do
          {:settled_active, org} ->
            conn =
              conn
              |> delete_session(:teams_purchase_id)
              |> delete_session(:teams_purchase_requires_p)

            handle_settled_active_payment(conn, org)

          {:settled_inactive, org} ->
            settled_inactive_cta = settled_inactive_cta(conn, org)

            conn
            |> delete_session(:teams_purchase_id)
            |> delete_session(:teams_purchase_requires_p)
            |> delete_session(:teams_signup_email)
            |> render(:teams_payment,
              layout: false,
              matched_session: true,
              cancelled: false,
              state: :settled_inactive,
              org: org,
              settled_inactive_cta: settled_inactive_cta,
              purchase_id: nil,
              check_payment_path: nil
            )

          other_state ->
            state_atom =
              case other_state do
                {:half_committed, _} -> :half_committed
                s -> s
              end

            check_query =
              %{"p" => purchase_id}
              |> maybe_put_query("m2_order", order)
              |> URI.encode_query()

            render(conn, :teams_payment,
              layout: false,
              matched_session: true,
              cancelled: params["status"] == "cancel",
              state: state_atom,
              org: nil,
              purchase_id: purchase_id,
              check_payment_path: "/signup/payment?" <> check_query
            )
        end
    end
  end

  def teams_payment_status(conn, params) do
    payload =
      case resolve_payment_purchase(conn, params) do
        :unmatched ->
          %{"state" => "unmatched"}

        {:matched, purchase_id} ->
          case paid_signup_purchase_state(paid_signup_mod(), purchase_id) do
            {:settled_active, _org} -> %{"state" => "ready"}
            {:settled_inactive, _org} -> %{"state" => "settled_inactive"}
            {:half_committed, _} -> %{"state" => "pending"}
            :pending -> %{"state" => "pending"}
            :unavailable -> %{"state" => "unavailable"}
          end
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(payload)
  end

  defp settled_inactive_cta(conn, org) do
    slug = URI.encode(org.slug, &URI.char_unreserved?/1)

    with %{id: user_id} <- conn.assigns[:current_user],
         org_id when is_binary(org_id) <- Map.get(org, :id),
         {:ok, role} <- Memberships.org_role(org_id, user_id) do
      if role in ["owner", "admin"] do
        %{
          href: "/orgs/" <> slug <> "/settings#teams-billing",
          label: Gettext.gettext(BridgeForTeamsWeb.Gettext, "Manage billing & seats")
        }
      else
        %{
          href: "/orgs/" <> slug,
          label: Gettext.gettext(BridgeForTeamsWeb.Gettext, "Open")
        }
      end
    else
      _ ->
        %{
          href: "/login?" <> URI.encode_query(%{"o" => org.slug}),
          label: Gettext.gettext(BridgeForTeamsWeb.Gettext, "Sign in to organization")
        }
    end
  end

  defp handle_settled_active_payment(conn, org) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_flash(
          :info,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Organization created. Verify your email to sign in."
          )
        )
        |> redirect(to: "/auth/email?" <> URI.encode_query(%{"o" => org.slug}))

      user ->
        conn = delete_session(conn, :teams_signup_email)

        if org[:id] && match?({:ok, _}, Memberships.org_role(org.id, user.id)) do
          next_path = "/orgs/" <> URI.encode(org.slug, &URI.char_unreserved?/1)
          render_remember_orgs(conn, user, org.id, next_path)
        else
          conn
          |> put_flash(
            :info,
            gettext(
              "Organization %{name} was created for another account. Sign out to sign in as the new organization owner.",
              name: org.name
            )
          )
          |> redirect(to: "/signup/teams")
        end
    end
  end

  # Strict purchase ownership check (F1):
  # - If `"p"` is present in query params, it must be a valid UUID equal to
  #   `session[:teams_purchase_id]`; otherwise `:unmatched`.
  # - If `"p"` is absent, only legacy in-flight returns (where
  #   `session[:teams_purchase_requires_p] != true`) match `session[:teams_purchase_id]`.
  defp resolve_payment_purchase(conn, params) do
    session_id =
      case Ecto.UUID.cast(get_session(conn, :teams_purchase_id) || "") do
        {:ok, id} -> id
        :error -> nil
      end

    requires_p? = get_session(conn, :teams_purchase_requires_p) == true

    cond do
      Map.has_key?(params, "p") ->
        case Ecto.UUID.cast(params["p"] || "") do
          {:ok, p} when is_binary(session_id) and p == session_id -> {:matched, p}
          _ -> :unmatched
        end

      is_binary(session_id) and not requires_p? ->
        {:matched, session_id}

      true ->
        :unmatched
    end
  end

  defp paid_signup_purchase_state(mod, purchase_id) do
    mod.purchase_state(purchase_id)
  end

  defp paid_signup_mod,
    do: SystemsRuntime.get_env(:bridge_for_teams_web, :paid_signup_mod, BridgeForTeams.PaidSignup)

  defp valid_m2square_order(order) when is_binary(order) do
    if Regex.match?(~r/\A[a-z]{24}\z/, order), do: order
  end

  defp valid_m2square_order(_), do: nil

  defp checkout_params(%{"provider" => "m2square"} = params) do
    document_fields =
      if params["country"] == "BR", do: ~w(doc_number), else: ~w(beneficiary_type beneficiary_id)

    checkout_fields(params, @teams_signup_fields ++ @m2square_signup_fields ++ document_fields)
  end

  defp checkout_params(params), do: checkout_fields(params, @teams_signup_fields)

  defp checkout_fields(%{} = params, fields) do
    params
    |> Map.take(fields)
    |> Map.filter(fn {field, value} ->
      is_binary(value) or (field == "seats" and is_integer(value))
    end)
  end

  defp checkout_fields(_, _), do: %{}

  defp render_expired_teams_signup(conn, signup, opts) do
    render_teams_signup(conn, signup, %{token: nil, ttl_seconds: 0, countries: []}, nil, opts)
  end

  defp render_teams_signup(conn, params, window, error, opts) do
    countries = window.countries
    detected_country = detected_checkout_country(conn)
    local? = params["provider"] == "m2square"
    available_country = fn code -> Enum.find(countries, &(&1["code"] == code)) end
    detected = available_country.(detected_country)
    selected = available_country.(params["country"]) || detected || List.first(countries)

    signup =
      Map.take(params, ~w(email name org_name firstname lastname beneficiary_type payment_type))

    render(conn, :signup,
      error: error,
      info: Phoenix.Flash.get(conn.assigns.flash, :info),
      layout: false,
      paid: true,
      signup: signup,
      current_user: Keyword.get(opts, :current_user, conn.assigns[:current_user]),
      has_existing_orgs: Keyword.get(opts, :has_existing_orgs, false),
      pending_checkout: Keyword.get(opts, :pending_checkout),
      quote_token: window.token,
      quote_ttl_seconds: window.ttl_seconds,
      quote_expired: window.ttl_seconds == 0,
      stripe_seats: if(local?, do: "100", else: params["seats"] || "100"),
      local_checkout:
        selected &&
          %{
            active: local?,
            show_channels: local? || not is_nil(detected),
            countries: countries,
            country: selected,
            seats: if(local?, do: params["seats"], else: selected["min_seats"])
          }
    )
  end

  defp detected_checkout_country(conn) do
    case get_req_header(conn, "cf-ipcountry") do
      [country] ->
        code = String.upcase(country)
        if code != "XX" and Regex.match?(~r/\A[A-Z]{2}\z/, code), do: code

      _ ->
        nil
    end
  end

  defp checkout_error(_, {:invalid_seats_range, min, max}),
    do: gettext("Enter between %{min} and %{max} seats.", min: min, max: max)

  defp checkout_error(_, {:invalid_seats_min, min}),
    do: gettext("Enter at least %{min} seats.", min: min)

  defp checkout_error(%{"provider" => "m2square"} = signup, {:payer_invalid, reason}),
    do: payer_error(reason, signup["country"])

  defp checkout_error(%{"provider" => "m2square"}, reason) do
    case reason do
      :invalid_seats ->
        gettext("Enter a valid seat count.")

      :amount_out_of_bounds ->
        gettext("This total exceeds the local payment limits. Choose fewer seats.")

      reason
      when reason in [:m2square_country_unavailable, :unsupported_country, :fx_rate_unavailable] ->
        gettext(
          "Local payment is unavailable for this country. Choose another country or use Stripe."
        )

      :subscription_checkout_pending ->
        gettext(
          "A checkout is already in progress. Check your payment before starting a new checkout."
        )

      :m2square_pay_uncertain ->
        gettext(
          "We could not confirm that checkout started. Check your payment before trying again."
        )

      _ ->
        gettext("Local checkout could not start. Check your details and try again.")
    end
  end

  defp checkout_error(_, :subscription_checkout_pending) do
    gettext(
      "A checkout is already in progress. Check your payment before starting a new checkout."
    )
  end

  defp checkout_error(_, :teams_price_not_configured) do
    gettext("Teams checkout is temporarily unavailable. Please try again later.")
  end

  defp checkout_error(_, _) do
    gettext("Checkout could not start. Check your details and try again.")
  end

  defp payer_error(:invalid_phone, "EC"),
    do: gettext("Enter 6–9 local digits, without +593 or a leading zero.")

  defp payer_error(:invalid_phone, _), do: gettext("Enter a valid phone number.")
  defp payer_error(:invalid_firstname, _), do: gettext("Enter the payer’s first name.")
  defp payer_error(:invalid_lastname, _), do: gettext("Enter the payer’s last name.")
  defp payer_error(:invalid_email, _), do: gettext("Enter a valid work email address.")
  defp payer_error(:invalid_doc_number, _), do: gettext("Enter an 11-digit CPF number.")

  defp payer_error(:invalid_beneficiary_type, _),
    do: gettext("Choose a document type for this country.")

  defp payer_error(:invalid_beneficiary_id, _),
    do: gettext("Enter a valid number for the selected document type.")

  defp payer_error(reason, _)
       when reason in [:unsupported_payment_type, :passport_requires_net_banking],
       do: gettext("Choose a payment method available for this document type.")

  defp payer_error(_, _), do: gettext("Check the payer details and try again.")

  @doc "POST /signup — redeem an invite code, create org + owner account, and log in."
  def create_from_invite(conn, params) do
    signup = params["signup"] || params

    with {:ok, %{user: user}} <-
           OrgCreationInvites.redeem_invite_code(signup["invite_code"], signup,
             audit: true,
             request_id: request_id(conn)
           ),
         {:ok, %{token: token}} <- Sessions.create(user, []) do
      conn
      |> DashAuth.put_token_in_session(token)
      |> put_flash(:info, Gettext.gettext(BridgeForTeamsWeb.Gettext, "Organization created."))
      |> redirect(to: "/")
    else
      _ ->
        conn
        |> render_signup(
          signup,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Invite code or signup details could not be used."
          )
        )
    end
  end

  @doc "POST /auth/:org_slug/start — kick off the OIDC authorization-code+PKCE flow."
  def start(conn, %{"org_slug" => slug}) do
    request_id = request_id(conn)
    return_to = DashAuth.local_return_to(conn.params["return_to"])

    case Orgs.get_org_by_slug(slug) do
      {:ok, org} ->
        case Auth.authorize_url(org.id, redirect_uri: redirect_uri(conn)) do
          {:ok, %{url: url, state: state, code_verifier: verifier}} ->
            conn
            |> put_session(:oidc_org_id, org.id)
            |> put_session(:oidc_state, state)
            |> put_session(:oidc_code_verifier, verifier)
            |> put_oidc_return_to(return_to)
            |> redirect(external: url)

          {:error, reason} ->
            Auth.record_sso_login_failure(org.id, reason,
              request_id: request_id,
              stage: "authorize"
            )

            case reason do
              :no_sso_connection -> email_login_fallback(conn, slug, return_to)
              _other -> sso_not_configured(conn)
            end
        end

      {:error, _reason} ->
        # Unknown slug takes the same fallback as a known SSO-less org, so the
        # response still does not reveal whether the org exists; the magic-link
        # endpoint only sends mail for real SSO-less org members.
        email_login_fallback(conn, slug, return_to)
    end
  end

  # SSO-less orgs fall back to the email magic link when delivery is
  # configured; otherwise keep the historical ambiguous error.
  defp email_login_fallback(conn, slug, return_to) do
    if LoginLinks.enabled?() do
      query =
        %{"o" => slug}
        |> maybe_put_query("return_to", return_to)
        |> URI.encode_query()

      redirect(conn, to: "/auth/email?" <> query)
    else
      sso_not_configured(conn)
    end
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  @doc "GET /auth/email — show the magic-link email form (SSO-less orgs or slugless recovery)."
  def email_login(conn, params) do
    cond do
      conn.assigns[:current_user] ->
        redirect(conn, to: DashAuth.local_return_to(params["return_to"]) || "/")

      not LoginLinks.enabled?() ->
        sso_not_configured(conn)

      true ->
        prefill_email = get_session(conn, :teams_signup_email)

        conn
        |> delete_session(:teams_signup_email)
        |> render(:email_login,
          layout: false,
          error: Phoenix.Flash.get(conn.assigns.flash, :error),
          info: Phoenix.Flash.get(conn.assigns.flash, :info),
          org_slug: String.trim(to_string(params["o"] || "")),
          prefill_email: prefill_email,
          return_to: DashAuth.local_return_to(params["return_to"])
        )
    end
  end

  @doc """
  POST /auth/email/send — issue the magic link (with slug) or workspace links
  (without slug). Always answers with the same neutral message, whatever matched.
  """
  def send_login_link(conn, params) do
    slug = String.trim(to_string(params["org_slug"] || ""))
    email = String.trim(to_string(params["email"] || ""))
    return_to = DashAuth.local_return_to(params["return_to"])
    next = email_login_next(return_to)

    opts = [
      base_url: public_base_url(conn),
      remote_ip: remote_ip(conn),
      request_id: request_id(conn),
      next: next
    ]

    :ok =
      if slug != "" do
        LoginLinks.request_login_link(slug, email, opts)
      else
        LoginLinks.request_workspace_links(email, opts)
      end

    query =
      %{}
      |> maybe_put_query("o", if(slug != "", do: slug))
      |> maybe_put_query("return_to", return_to)
      |> URI.encode_query()

    flash_msg =
      if slug != "" do
        Gettext.gettext(
          BridgeForTeamsWeb.Gettext,
          "If that email matches a member of this organization, we sent a sign-in link. It expires in 15 minutes."
        )
      else
        Gettext.gettext(
          BridgeForTeamsWeb.Gettext,
          "If that email matches any organizations, we sent sign-in links. Magic links expire in 15 minutes."
        )
      end

    redirect_to = if query == "", do: "/auth/email", else: "/auth/email?" <> query

    conn
    |> put_flash(:info, flash_msg)
    |> redirect(to: redirect_to)
  end

  defp email_login_next(return_to) when return_to in ["/signup/teams", "/signup/teams?mode=new"],
    do: "teams_signup"

  defp email_login_next(_return_to), do: nil

  @doc "GET /auth/email/verify — redeem a one-time emailed sign-in link."
  def verify_login_link(conn, params) do
    with token when is_binary(token) and token != "" <- params["token"],
         {:ok, %{token: session_token, user: user, org: org}} <-
           LoginLinks.redeem_login_token_for_session(token, request_id: request_id(conn)) do
      next_path =
        if params["next"] == "teams_signup" do
          "/signup/teams"
        else
          "/orgs/" <> URI.encode(org.slug, &URI.char_unreserved?/1)
        end

      conn
      |> DashAuth.put_token_in_session(session_token)
      |> render_remember_orgs(user, org.id, next_path)
    else
      _ ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Sign-in link is invalid, expired, or already used."
          )
        )
        |> redirect(to: "/login")
    end
  end

  @doc "GET /auth/callback — exchange the code, provision, set the session cookie."
  def callback(conn, params) do
    org_id = get_session(conn, :oidc_org_id)
    verifier = get_session(conn, :oidc_code_verifier)
    expected_state = get_session(conn, :oidc_state)
    return_to = DashAuth.local_return_to(get_session(conn, :oidc_return_to))
    request_id = request_id(conn)
    state_result = verify_oidc_state(expected_state, params["state"] || params[:state])

    cond do
      not is_binary(org_id) ->
        sign_in_failed(conn)

      match?({:error, _reason}, state_result) ->
        {:error, reason} = state_result

        Auth.record_sso_login_failure(org_id, reason,
          request_id: request_id,
          stage: "state"
        )

        sign_in_failed(conn)

      true ->
        case Auth.callback(org_id, params,
               code_verifier: verifier,
               redirect_uri: redirect_uri(conn),
               request_id: request_id
             ) do
          {:ok, %{token: token, user: user}} ->
            finish_login(conn, token, user, org_id, return_to)

          {:error, _reason} ->
            sign_in_failed(conn)
        end
    end
  end

  @doc "GET /auth/recovery — redeem a one-time shell-generated recovery link."
  def recover(conn, params) do
    with token when is_binary(token) and token != "" <- params["token"],
         {:ok, %{token: session_token}} <-
           AccountRecovery.redeem_recovery_token_for_session(token) do
      conn
      |> DashAuth.put_token_in_session(session_token)
      |> put_flash(
        :info,
        Gettext.gettext(BridgeForTeamsWeb.Gettext, "Signed in with recovery link.")
      )
      |> redirect(to: "/")
    else
      _ ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Recovery link is invalid, expired, or already used."
          )
        )
        |> redirect(to: "/login")
    end
  end

  defp verify_oidc_state(expected, returned) when is_binary(expected) and is_binary(returned) do
    if byte_size(expected) == byte_size(returned) and
         Plug.Crypto.secure_compare(expected, returned) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  defp verify_oidc_state(_expected, _returned), do: {:error, :invalid_state}

  defp clear_oidc_session(conn) do
    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_code_verifier)
    |> delete_session(:oidc_org_id)
    |> delete_session(:oidc_return_to)
  end

  defp put_oidc_return_to(conn, nil), do: delete_session(conn, :oidc_return_to)
  defp put_oidc_return_to(conn, return_to), do: put_session(conn, :oidc_return_to, return_to)

  defp sign_in_failed(conn) do
    conn
    |> clear_oidc_session()
    |> put_flash(
      :error,
      Gettext.gettext(BridgeForTeamsWeb.Gettext, "Sign-in failed. Please try again.")
    )
    |> redirect(to: "/login")
  end

  defp sso_not_configured(conn) do
    conn
    |> put_flash(
      :error,
      Gettext.gettext(
        BridgeForTeamsWeb.Gettext,
        "Unknown organization or SSO not configured."
      )
    )
    |> redirect(to: "/login")
  end

  @doc "DELETE /logout — revoke the session and clear the cookie."
  def logout(conn, params) do
    if token = get_session(conn, DashAuth.session_token_key()), do: Auth.logout(token)
    redirect_to = DashAuth.local_return_to(params["return_to"]) || "/login"

    conn
    |> configure_session(drop: true)
    |> redirect(to: redirect_to)
  end

  defp redirect_uri(conn), do: public_base_url(conn) <> "/auth/callback"

  # Configured public base URL when available; falling back to the request
  # host keeps dev/e2e working but is why config should win in production
  # (emailed links must not trust the Host header).
  defp public_base_url(conn) do
    case SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" -> String.trim_trailing(base, "/")
      _ -> "#{conn.scheme}://#{conn.host}:#{conn.port}"
    end
  end

  defp remote_ip(conn) do
    case :inet.ntoa(conn.remote_ip) do
      {:error, _} -> ""
      chars -> to_string(chars)
    end
  end

  defp request_id(_conn) do
    case Logger.metadata()[:request_id] do
      value when is_binary(value) and value != "" -> value
      _ -> SystemsRuntime.Proc.uuid()
    end
  end

  defp login_org(%{"o" => slug}) when is_binary(slug) and slug != "" do
    case Orgs.get_org_by_slug(slug) do
      {:ok, org} -> org
      {:error, :not_found} -> nil
    end
  end

  defp login_org(_params), do: nil

  # The page of one organization names Lark on its button when that
  # organization signs in with Lark.
  defp lark_sign_in?(%{id: org_id}),
    do: match?(%{provider: "lark"}, Orgs.get_sso_connection(org_id))

  defp lark_sign_in?(_org), do: false

  defp login_shortcuts_disabled?(%{"o" => slug}) when is_binary(slug),
    do: String.trim(slug) != ""

  defp login_shortcuts_disabled?(_params), do: false

  defp finish_login(conn, token, _user, _org_id, return_to) when is_binary(return_to) do
    conn
    |> clear_oidc_session()
    |> DashAuth.put_token_in_session(token)
    |> redirect(to: return_to)
  end

  defp finish_login(conn, token, user, org_id, _return_to) do
    conn
    |> clear_oidc_session()
    |> DashAuth.put_token_in_session(token)
    |> render_remember_orgs(user, org_id, "/")
  end

  defp render_remember_orgs(conn, user, fallback_org_id, next_path) do
    case login_orgs(user, fallback_org_id) do
      [_ | _] = orgs -> render(conn, :remember_orgs, layout: false, orgs: orgs, next: next_path)
      {:error, :not_found} -> redirect(conn, to: next_path)
    end
  end

  @remember_orgs_limit 5
  @valid_icon_prefixes [
    "data:image/png;base64,",
    "data:image/jpeg;base64,",
    "data:image/jpg;base64,",
    "data:image/gif;base64,",
    "data:image/webp;base64,"
  ]

  defp login_orgs(%{id: user_id}, fallback_org_id) when is_binary(user_id) do
    case Orgs.list_orgs_with_auth_method_for_user(user_id, @remember_orgs_limit,
           prioritize_org_id: fallback_org_id
         ) do
      [_ | _] = entries ->
        entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} -> login_org_json(entry, idx == 0) end)

      [] ->
        fallback_login_orgs(fallback_org_id)
    end
  end

  defp login_orgs(_user, fallback_org_id), do: fallback_login_orgs(fallback_org_id)

  defp fallback_login_orgs(org_id) do
    case Orgs.get_org(org_id) do
      {:ok, org} ->
        auth_method = if Orgs.get_sso_connection(org.id), do: "sso", else: "email"
        [login_org_json(%{org: org, auth_method: auth_method}, true)]

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp login_org_json(%{org: org, auth_method: auth_method}, include_icon?) do
    %{slug: org.slug, name: org.name, auth_method: auth_method}
    |> maybe_put_org_icon(if(include_icon?, do: org.icon))
  end

  defp maybe_put_org_icon(payload, icon) when is_binary(icon) and icon != "" do
    trimmed = String.trim(icon)

    if Enum.any?(@valid_icon_prefixes, &String.starts_with?(trimmed, &1)) do
      Map.put(payload, :icon, trimmed)
    else
      payload
    end
  end

  defp maybe_put_org_icon(payload, _icon), do: payload

  defp render_signup(conn, params, error \\ nil) do
    signup = signup_attrs(params)

    render(conn, :signup,
      error: error,
      info: Phoenix.Flash.get(conn.assigns.flash, :info),
      layout: false,
      paid: false,
      current_user: nil,
      has_existing_orgs: false,
      pending_checkout: nil,
      quote_token: nil,
      quote_ttl_seconds: nil,
      quote_expired: false,
      local_checkout: nil,
      signup: signup
    )
  end

  defp signup_attrs(params) do
    invite_code = params["invite_code"] || params["code"]
    invite = invite_for_signup(invite_code)

    %{
      "invite_code" => invite_code,
      "email" => params["email"],
      "name" => params["name"],
      "org_name" => invite && invite.org_name,
      "org_slug" => invite && invite.org_slug
    }
  end

  defp invite_for_signup(code) when is_binary(code) and code != "" do
    case OrgCreationInvites.get_redeemable_invite(code) do
      {:ok, invite} -> invite
      {:error, _reason} -> nil
    end
  end

  defp invite_for_signup(_code), do: nil
end
