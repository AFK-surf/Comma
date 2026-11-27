defmodule BridgeForTeamsWeb.Dashboard.AuthHTML do
  @moduledoc "Templates for the dashboard auth controller (login page)."
  use BridgeForTeamsWeb.Dashboard, :html

  def login(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-neutral-50">
      <div class="w-full max-w-sm">
        <div class="flex items-center gap-2 justify-center mb-8">
          <img
            src={~p"/images/bridge-icon-512.png"}
            alt=""
            class="h-7 w-7 rounded-md"
          />
          <span class="text-base font-semibold tracking-tight">Comma for Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <%= if @org do %>
            <div class="mb-5 text-center">
              <.org_avatar org={@org} size="lg" class="mx-auto mb-3" />
              <h1 class="text-sm font-semibold mb-1">{@org.name}</h1>
              <p class="text-neutral-500 text-xs">{gettext("Sign in with your organization account.")}</p>
            </div>
          <% else %>
            <h1 class="text-sm font-semibold mb-1">{gettext("Sign in")}</h1>
            <p class="text-neutral-500 text-xs mb-4">
              {gettext("Enter your organization to continue with SSO.")}
            </p>
          <% end %>

          <%= if @error do %>
            <div class="mb-3 rounded-md bg-red-50 border border-red-200 px-3 py-2 text-xs text-red-700">
              {@error}
            </div>
          <% end %>

          <div
            id="remembered-org-login"
            class="mb-4 hidden"
            data-disabled={if @shortcuts_disabled, do: "true", else: "false"}
            data-storage-key="bridge_for_teams:login_orgs"
            data-legacy-storage-key="bridge_for_teams:last_login_org"
            data-continue-prefix={gettext("Continue as")}
            data-sso-label={gettext("SSO")}
            data-email-label={gettext("Email")}
            data-csrf-token={get_csrf_token()}
            data-return-to={@return_to || ""}
          >
            <div id="remembered-org-list" class="space-y-2"></div>

            <div class="mb-4 flex items-center gap-3">
              <div class="h-px flex-1 bg-neutral-200"></div>
              <span class="text-[11px] font-medium uppercase text-neutral-400">{gettext("or")}</span>
              <div class="h-px flex-1 bg-neutral-200"></div>
            </div>
          </div>

          <script><%= login_local_storage_script() %></script>

          <form method="post" action="/auth/start" class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input :if={@org} type="hidden" name="org_slug" value={@org.slug} />
            <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
            <div :if={is_nil(@org)}>
              <label class="block text-xs font-medium text-neutral-600 mb-1">
                {gettext("Organization slug")}
              </label>
              <input
                type="text"
                name="org_slug"
                placeholder="acme-co"
                autofocus
                class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
              />
            </div>
            <button
              type="submit"
              class="w-full inline-flex items-center justify-center h-8 rounded-md bg-brand-500 px-3 text-sm font-medium text-white shadow-subtle hover:bg-brand-600 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1"
            >
              {if @lark_sign_in, do: gettext("Sign in with Lark"), else: gettext("Continue with SSO")}
            </button>
          </form>

          <div class="mt-4 space-y-2 text-center">
            <div>
              <a
                href={email_login_link(@org, @return_to)}
                class="text-xs font-medium text-brand-700 hover:text-brand-800"
              >
                {gettext("Forgot your organization slug? Sign in with email")}
              </a>
            </div>
            <div>
              <a href="/signup/teams" class="text-xs font-medium text-brand-700 hover:text-brand-800">
                {gettext("Buy Comma for Teams")}
              </a>
            </div>
            <div>
              <a href="/signup" class="text-xs text-neutral-500 hover:text-neutral-700">
                {gettext("Create organization with invite code")}
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp email_login_link(org, return_to) do
    query =
      %{}
      |> then(fn q -> if org, do: Map.put(q, "o", org.slug), else: q end)
      |> then(fn q -> if return_to, do: Map.put(q, "return_to", return_to), else: q end)
      |> URI.encode_query()

    if query == "", do: "/auth/email", else: "/auth/email?" <> query
  end

  def email_login(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-neutral-50">
      <div class="w-full max-w-sm">
        <div class="flex items-center gap-2 justify-center mb-8">
          <img
            src={~p"/images/bridge-icon-512.png"}
            alt=""
            class="h-7 w-7 rounded-md"
          />
          <span class="text-base font-semibold tracking-tight">Comma for Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <h1 class="text-sm font-semibold mb-1">{gettext("Sign in with email")}</h1>
          <p :if={@org_slug != ""} class="text-neutral-500 text-xs mb-4">
            {gettext(
              "This organization does not use SSO. We'll email you a one-time sign-in link instead."
            )}
          </p>
          <p :if={@org_slug == ""} class="text-neutral-500 text-xs mb-4">
            {gettext(
              "Enter your work email and we'll send sign-in links for your Comma for Teams organizations."
            )}
          </p>

          <%= if @info do %>
            <div class="mb-3 rounded-md bg-emerald-50 border border-emerald-200 px-3 py-2 text-xs text-emerald-700">
              {@info}
            </div>
          <% end %>

          <%= if @error do %>
            <div class="mb-3 rounded-md bg-red-50 border border-red-200 px-3 py-2 text-xs text-red-700">
              {@error}
            </div>
          <% end %>

          <form method="post" action="/auth/email/send" class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input :if={@org_slug != ""} type="hidden" name="org_slug" value={@org_slug} />
            <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />

            <div :if={@org_slug != ""} class="text-xs text-neutral-500">
              {gettext("Organization:")} <span class="font-medium text-neutral-800">{@org_slug}</span>
            </div>

            <div>
              <label class="block text-xs font-medium text-neutral-600 mb-1">
                {gettext("Work email")}
              </label>
              <input
                type="email"
                name="email"
                value={@prefill_email}
                placeholder="you@example.com"
                autofocus
                required
                class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
              />
            </div>

            <button
              type="submit"
              class="w-full inline-flex items-center justify-center h-8 rounded-md bg-brand-500 px-3 text-sm font-medium text-white shadow-subtle hover:bg-brand-600 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1"
            >
              {if @org_slug == "", do: gettext("Send sign-in links"), else: gettext("Email me a sign-in link")}
            </button>
          </form>

          <div class="mt-4 text-center">
            <a
              href={if @return_to, do: "/login?" <> URI.encode_query(%{"return_to" => @return_to}), else: "/login"}
              class="text-xs font-medium text-brand-700 hover:text-brand-800"
            >
              {gettext("Back to sign in")}
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def remember_orgs(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-neutral-50">
      <div class="w-full max-w-sm text-center">
        <div class="flex items-center gap-2 justify-center mb-8">
          <img
            src={~p"/images/bridge-icon-512.png"}
            alt=""
            class="h-7 w-7 rounded-md"
          />
          <span class="text-base font-semibold tracking-tight">Comma for Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <div
            id="remember-login-orgs"
            data-storage-key="bridge_for_teams:login_orgs"
            data-login-orgs={Jason.encode!(@orgs)}
            data-next={@next}
          >
          </div>
          <p class="text-sm font-medium text-neutral-900">{gettext("Signing you in...")}</p>
          <p class="mt-1 text-xs text-neutral-500">{List.first(@orgs).name}</p>
          <noscript>
            <a href={@next} class="mt-4 inline-flex text-xs font-medium text-brand-700 hover:text-brand-800">
              {gettext("Continue")}
            </a>
          </noscript>
        </div>
      </div>
    </div>

    <script><%= remember_org_script() %></script>
    """
  end

  def teams_chooser(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-neutral-50 px-4 py-8">
      <div class="w-full max-w-lg">
        <div class="flex items-center gap-2 justify-center mb-6">
          <img
            src={~p"/images/bridge-icon-512.png"}
            alt=""
            class="h-7 w-7 rounded-md"
          />
          <span class="text-base font-semibold tracking-tight">Comma for Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <div class="mb-4">
            <h1 class="text-sm font-semibold text-neutral-900 mb-1">
              {gettext("Your Teams organizations")}
            </h1>
            <p class="text-xs text-neutral-500">
              {gettext("Signed in as %{email}", email: @current_user.email || @current_user.name || "")}
            </p>
          </div>

          <%= if @info do %>
            <div class="mb-4 rounded-md bg-emerald-50 border border-emerald-200 px-3 py-2 text-xs text-emerald-700">
              {@info}
            </div>
          <% end %>

          <div class="divide-y divide-neutral-200 border-t border-b border-neutral-200">
            <div :for={item <- @items} class="py-3.5 flex items-start justify-between gap-4">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="text-sm font-medium text-neutral-900 truncate">{item.org.name}</span>
                  <span class="inline-flex items-center rounded border border-neutral-200 bg-neutral-50 px-1.5 py-0.5 text-[11px] font-medium text-neutral-600">
                    {chooser_role_label(item.role)}
                  </span>
                </div>
                <p class="text-xs text-neutral-500 mt-0.5 truncate">{item.org.slug}</p>

                <%= if item.role in ["owner", "admin"] do %>
                  <p class={["text-xs mt-1.5", chooser_billing_class(item.billing)]}>
                    {chooser_billing_text(item.billing)}
                  </p>
                <% else %>
                  <p class="text-xs text-neutral-500 mt-1.5">
                    {gettext("Ask an organization owner or admin to manage seats.")}
                  </p>
                <% end %>
              </div>

              <div class="shrink-0 flex flex-col items-end gap-1.5 pt-0.5">
                <a
                  href={item.open_path}
                  class="inline-flex items-center justify-center h-7 rounded-md border border-neutral-300 bg-white px-2.5 text-xs font-medium text-neutral-700 hover:bg-neutral-50"
                >
                  {gettext("Open")}
                </a>
                <a
                  :if={item.billing_path}
                  href={item.billing_path}
                  class="text-xs font-medium text-brand-700 hover:text-brand-800 whitespace-nowrap"
                >
                  {gettext("Manage billing & seats")}
                </a>
              </div>
            </div>
          </div>

          <div :if={@has_prev or @has_next} class="mt-4 flex items-center justify-between text-xs">
            <a
              :if={@has_prev}
              href={chooser_page_path(@page - 1, @from)}
              class="font-medium text-brand-700 hover:text-brand-800"
            >
              {gettext("Previous")}
            </a>
            <span :if={!@has_prev}></span>
            <a
              :if={@has_next}
              href={chooser_page_path(@page + 1, @from)}
              class="font-medium text-brand-700 hover:text-brand-800"
            >
              {gettext("Next")}
            </a>
          </div>

          <div class="mt-5 space-y-3">
            <div>
              <a
                href={@new_org_path}
                class="w-full inline-flex items-center justify-center h-8 rounded-md bg-brand-500 px-3 text-sm font-medium text-white shadow-subtle hover:bg-brand-600 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1"
              >
                {gettext("Create a new organization")}
              </a>
              <p class="mt-1.5 text-xs text-neutral-500 text-center">
                {gettext("Creates a separate organization and does not add seats to existing ones.")}
              </p>
            </div>

            <form method="post" action="/logout" class="text-center">
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <input type="hidden" name="_method" value="delete" />
              <input type="hidden" name="return_to" value="/signup/teams" />
              <button
                type="submit"
                class="text-xs font-medium text-neutral-600 hover:text-neutral-900"
              >
                {gettext("Sign out and use another account")}
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp chooser_role_label("owner"), do: gettext("Owner")
  defp chooser_role_label("admin"), do: gettext("Admin")
  defp chooser_role_label(_), do: gettext("Member")

  defp chooser_billing_class(:unavailable), do: "text-amber-700"
  defp chooser_billing_class(%{managed: true, active: true}), do: "text-emerald-700 tabular-nums"
  defp chooser_billing_class(%{managed: true, active: false}), do: "text-amber-700"
  defp chooser_billing_class(_), do: "text-neutral-600"

  defp chooser_billing_text(:unavailable), do: gettext("Billing status unavailable")

  defp chooser_billing_text(%{managed: false}),
    do: gettext("Contract or invite-managed")

  defp chooser_billing_text(%{
         managed: true,
         active: true,
         licensed_seats: seats,
         expires_at: %DateTime{} = exp
       }) do
    gettext("Active: %{seats} seats (valid through %{date})",
      seats: seats,
      date: Calendar.strftime(exp, "%Y-%m-%d")
    )
  end

  defp chooser_billing_text(%{managed: true, active: true, licensed_seats: seats}) do
    gettext("Active: %{seats} seats", seats: seats)
  end

  defp chooser_billing_text(%{managed: true, active: false}) do
    gettext("Subscription inactive")
  end

  defp chooser_billing_text(_), do: gettext("Billing status unavailable")

  defp chooser_page_path(page, from) do
    query =
      %{"page" => Integer.to_string(page)}
      |> then(fn q -> if from, do: Map.put(q, "from", from), else: q end)
      |> URI.encode_query()

    "/signup/teams?" <> query
  end

  def teams_payment(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-neutral-50 px-4">
      <div class="w-full max-w-sm">
        <div class="flex items-center gap-2 justify-center mb-8">
          <img
            src={~p"/images/bridge-icon-512.png"}
            alt=""
            class="h-7 w-7 rounded-md"
          />
          <span class="text-base font-semibold tracking-tight">Comma for Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <%= cond do %>
            <% @state == :unmatched -> %>
              <h1 class="text-sm font-semibold mb-1">{gettext("Checkout session not found")}</h1>
              <p class="text-neutral-500 text-xs mb-4">
                {gettext(
                  "This payment confirmation link does not match your current browser session. If you already completed payment, check your email for your organization sign-in link."
                )}
              </p>
              <div class="flex items-center gap-4">
                <a href="/login" class="text-xs font-medium text-brand-700 hover:text-brand-800">
                  {gettext("Sign in")}
                </a>
                <a href="/signup/teams" class="text-xs font-medium text-neutral-600 hover:text-neutral-900">
                  {gettext("Back to checkout")}
                </a>
              </div>

            <% @state == :settled_inactive and @org != nil -> %>
              <h1 class="text-sm font-semibold mb-1">{gettext("Subscription inactive")}</h1>
              <p class="text-neutral-500 text-xs mb-4">
                {gettext(
                  "Organization %{name} was created, but its Teams subscription is not active. Sign in to manage billing for this organization.",
                  name: @org.name
                )}
              </p>
              <div class="flex items-center gap-4">
                <% cta =
                  assigns[:settled_inactive_cta] ||
                    %{
                      href: "/login?" <> URI.encode_query(%{"o" => @org.slug}),
                      label: gettext("Sign in to organization")
                    } %>
                <a
                  href={cta.href}
                  class="text-xs font-medium text-brand-700 hover:text-brand-800"
                >
                  {cta.label}
                </a>
                <a href="/signup/teams" class="text-xs font-medium text-neutral-600 hover:text-neutral-900">
                  {gettext("Back to checkout")}
                </a>
              </div>

            <% true -> %>
              <h1 class="text-sm font-semibold mb-1">
                {if @cancelled, do: gettext("Checkout cancelled"), else: gettext("Confirming your payment")}
              </h1>
              <p class="text-neutral-500 text-xs mb-4">
                {if @state == :unavailable,
                  do:
                    gettext(
                      "Payment status is temporarily unavailable. Refresh this page shortly to check again."
                    ),
                  else:
                    gettext(
                      "Your organization is created after payment is confirmed. Refresh this page to check again. Payment does not sign you in."
                    )}
              </p>
              <div class="flex items-center gap-4">
                <a
                  :if={@check_payment_path}
                  href={@check_payment_path}
                  class="text-xs font-medium text-brand-700 hover:text-brand-800"
                >
                  {gettext("Check payment")}
                </a>
                <a href="/signup/teams" class="text-xs font-medium text-brand-700 hover:text-brand-800">
                  {gettext("Back to checkout")}
                </a>
              </div>

              <div
                :if={!@cancelled and @matched_session and @state in [:pending, :half_committed] and is_binary(@purchase_id)}
                id="teams-payment-poll"
                data-status-url={"/signup/payment/status?" <> URI.encode_query(%{"p" => @purchase_id})}
                data-ready-url={"/signup/payment?" <> URI.encode_query(%{"p" => @purchase_id})}
              >
              </div>
              <script :if={!@cancelled and @matched_session and @state in [:pending, :half_committed] and is_binary(@purchase_id)}>
                <%= teams_payment_poll_script() %>
              </script>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp teams_payment_poll_script do
    Phoenix.HTML.raw("""
    (() => {
      const el = document.getElementById("teams-payment-poll");
      if (!el) return;
      const statusUrl = el.dataset.statusUrl;
      const readyUrl = el.dataset.readyUrl;
      let attempts = 0;
      const maxAttempts = 15;

      async function poll() {
        if (attempts >= maxAttempts) return;
        attempts += 1;
        try {
          const resp = await fetch(statusUrl, {
            headers: { "accept": "application/json" },
            credentials: "same-origin"
          });
          if (resp.ok) {
            const data = await resp.json();
            if (data.state === "ready" || data.state === "settled_inactive") {
              window.location.replace(readyUrl);
              return;
            }
            if (data.state === "unmatched") return;
          }
        } catch (_err) {
        }
        if (attempts < maxAttempts) setTimeout(poll, 2000);
      }

      setTimeout(poll, 2000);
    })();
    """)
  end

  def signup(assigns) do
    assigns =
      Map.put(assigns, :local_active, assigns.local_checkout && assigns.local_checkout.active)

    ~H"""
    <div class={["min-h-screen flex items-center justify-center bg-neutral-50", @local_checkout && "px-3 py-6 sm:has-[#show-local-payment:not([hidden])]:pt-12 sm:has-[#local-signup-fields:not([hidden])]:py-3"]}>
      <div class="w-full max-w-sm">
        <div class="flex items-center gap-2 justify-center mb-8">
          <img
            src={~p"/images/bridge-icon-512.png"}
            alt=""
            class="h-7 w-7 rounded-md"
          />
          <span class="text-base font-semibold tracking-tight">Comma for Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <h1 class="text-sm font-semibold mb-1">{gettext("Create organization")}</h1>
          <div
            :if={@paid and is_nil(@current_user)}
            class="mb-3 rounded-md bg-neutral-50 border border-neutral-200 px-3 py-2 text-xs text-neutral-600"
          >
            {gettext("Already have a Teams organization?")}
            <a
              href="/login?return_to=%2Fsignup%2Fteams"
              class="font-medium text-brand-700 hover:text-brand-800 ml-1"
            >
              {gettext("Sign in")}
            </a>
          </div>
          <div
            :if={@paid and @current_user != nil and @has_existing_orgs}
            class="mb-3 rounded-md bg-neutral-50 border border-neutral-200 px-3 py-2 text-xs text-neutral-600"
          >
            <p>
              {gettext(
                "You are creating a separate new organization. This will not add seats to your existing organizations."
              )}
            </p>
            <a
              href="/signup/teams"
              class="mt-1 inline-block font-medium text-brand-700 hover:text-brand-800"
            >
              {gettext("Manage existing organizations")}
            </a>
          </div>
          <p :if={!@paid} class="text-neutral-500 text-xs mb-4">
            {gettext("Use your invite code to create your organization and owner account.")}
          </p>
          <p :if={@paid} id="stripe-signup-description" hidden={@local_active} class="text-neutral-500 text-xs mb-4">
            {gettext("$80 per seat per month, billed quarterly. Creates a standalone Comma for Teams organization separate from personal Comma accounts. Model subscriptions and API usage are paid separately.")}
          </p>
          <p :if={@local_checkout} id="local-signup-description" hidden={!@local_active} class="text-neutral-500 text-xs mb-4">
            {gettext("Pay for three months in your local currency. Creates a standalone Comma for Teams organization separate from personal Comma accounts. Model subscriptions and API usage are paid separately.")}
          </p>

          <div
            :if={assigns[:info]}
            class="mb-3 rounded-md bg-brand-50 border border-brand-200 px-3 py-2 text-xs text-brand-800"
          >
            {@info}
          </div>

          <%= if @error do %>
            <div role="alert" class="mb-3 rounded-md bg-red-50 border border-red-200 px-3 py-2 text-xs text-red-700">
              <p>{@error}</p>
              <div :if={@pending_checkout} class="mt-2 space-y-1.5">
                <p :if={is_binary(@pending_checkout.url) and not is_nil(@pending_checkout.expires_at)} class="text-neutral-700">
                  {gettext("Your original checkout stays locked until %{expires_at} UTC.",
                    expires_at: Calendar.strftime(@pending_checkout.expires_at, "%Y-%m-%d %H:%M")
                  )}
                </p>
                <div class="flex flex-wrap items-center gap-3">
                  <a
                    :if={is_binary(@pending_checkout.url)}
                    href={@pending_checkout.url}
                    class="font-medium text-brand-700 underline hover:text-brand-800"
                  >
                    {gettext("Open original checkout")}
                  </a>
                  <a
                    href={@pending_checkout.payment_path}
                    class="font-medium text-brand-700 underline hover:text-brand-800"
                  >
                    {gettext("Check payment status")}
                  </a>
                </div>
              </div>
            </div>
          <% end %>

          <div
            :if={@paid}
            id="signup-quote-expired"
            role="alert"
            hidden={!@quote_expired}
            class="mb-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-neutral-700"
          >
            <p>{gettext("This payment session has expired. Re-enter the payment page to continue.")}</p>
            <a href="/signup/teams" class="mt-1 inline-block font-medium text-brand-700 underline">
              {gettext("Re-enter payment page")}
            </a>
          </div>

          <form
            id={if @paid, do: "teams-checkout"}
            method="post"
            action={if @paid, do: "/signup/teams", else: "/signup"}
            class="group"
            data-local-active={if @local_active, do: "true"}
            data-ttl-seconds={@quote_ttl_seconds}
            data-quote-expired={if @paid, do: to_string(@quote_expired)}
          >
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input :if={@quote_token} type="hidden" name="signup[quote_token]" value={@quote_token} />

            <fieldset id={if @paid, do: "teams-checkout-fields"} disabled={@quote_expired} class="min-w-0 space-y-3">

              <fieldset
                :if={@local_checkout}
                id="teams-payment-channels"
                hidden={!@local_checkout.show_channels}
                disabled={!@local_checkout.show_channels}
              >
                <legend class="text-xs font-medium text-neutral-600 mb-1">{gettext("Payment channel")}</legend>
                <div class="flex flex-wrap gap-x-4 gap-y-1 text-sm text-neutral-700">
                  <label class="inline-flex items-start gap-1.5">
                    <input class="h-5 w-3.5 shrink-0" type="radio" name="signup[provider]" value="stripe" checked={!@local_active} />
                    <span>Stripe</span>
                  </label>
                  <label class="inline-flex items-start gap-1.5">
                    <input class="h-5 w-3.5 shrink-0" type="radio" name="signup[provider]" value="m2square" checked={@local_active} />
                    <span>{gettext("Local payment")}</span>
                  </label>
                </div>
              </fieldset>

              <div :if={!@paid}>
                <label class="block text-xs font-medium text-neutral-600 mb-1">
                  {gettext("Invite code")}
                </label>
                <input
                  type="text"
                  name="signup[invite_code]"
                  value={@signup["invite_code"]}
                  autofocus
                  class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
                />
              </div>

              <div class="grid grid-cols-1 gap-3">
                <div>
                  <label for="signup-org-name" class="block text-xs font-medium text-neutral-600 mb-1">
                    {gettext("Organization name")}
                  </label>
                  <input
                    type="text"
                    id="signup-org-name"
                    name="signup[org_name]"
                    value={@signup["org_name"]}
                    placeholder="Acme"
                    readonly={!@paid}
                    required={@paid}
                    maxlength="200"
                    class={[
                      "block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm text-neutral-700 placeholder:text-neutral-400 focus:outline-none",
                      if(@paid, do: "focus:border-brand-500 focus:ring-1 focus:ring-brand-500", else: "bg-neutral-50")
                    ]}
                  />
                </div>

                <div :if={!@paid}>
                  <label class="block text-xs font-medium text-neutral-600 mb-1">
                    {gettext("Organization slug")}
                  </label>
                  <input
                    type="text"
                    name="signup[org_slug]"
                    value={@signup["org_slug"]}
                    placeholder="acme"
                    readonly
                    class="block w-full h-8 rounded-md border border-neutral-300 bg-neutral-50 px-2.5 text-sm text-neutral-700 placeholder:text-neutral-400 focus:outline-none"
                  />
                </div>
              </div>

              <div class="grid grid-cols-1 gap-3 sm:group-data-[local-active=true]:grid-cols-2">
                <div>
                  <label for="signup-email" class="block text-xs font-medium text-neutral-600 mb-1">
                    {gettext("Work email")}
                  </label>
                  <input
                    type="email"
                    id="signup-email"
                    name="signup[email]"
                    value={@signup["email"]}
                    placeholder="you@example.com"
                    class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label for="signup-name" class="block text-xs font-medium text-neutral-600 mb-1">
                    {gettext("Name")}
                  </label>
                  <input
                    type="text"
                    id="signup-name"
                    name="signup[name]"
                    value={@signup["name"]}
                    placeholder={gettext("Your name")}
                    class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
                  />
                </div>
              </div>

              <fieldset :if={@paid} id="stripe-signup-fields" hidden={@local_active} disabled={@local_active}>
                <label for="stripe-signup-seats" class="block text-xs font-medium text-neutral-600 mb-1">
                  {gettext("Seats")}
                </label>
                <input
                  type="text"
                  inputmode="numeric"
                  id="stripe-signup-seats"
                  name="signup[seats]"
                  value={@stripe_seats}
                  required
                  class={seat_input_class()}
                />
                <p
                  id="stripe-signup-seats-error"
                  role="alert"
                  hidden
                  data-min-error={gettext("Enter at least %{min} seats.", min: 100)}
                  data-range-error={gettext("Enter between %{min} and %{max} seats.", min: 100, max: 2_147_483_647)}
                  class="mt-1 text-xs text-red-600"
                >
                  {gettext("Enter at least %{min} seats.", min: 100)}
                </p>
                <p
                  id="stripe-signup-total"
                  aria-live="polite"
                  class="mt-1.5 text-xs font-medium text-neutral-700 tabular-nums"
                  data-template={
                    gettext("Quarterly total: $%{total} USD before tax ($240 / seat × %{seats} seats)",
                      total: "__TOTAL__",
                      seats: "__SEATS__"
                    )
                  }
                >
                  {stripe_quarterly_total_text(@stripe_seats)}
                </p>
              </fieldset>

              <.local_checkout :if={@local_checkout} checkout={@local_checkout} signup={@signup} locale={@locale} />

              <button
                id={if @paid, do: "teams-checkout-submit"}
                type="submit"
                disabled={@quote_expired}
                class="w-full inline-flex items-center justify-center h-8 rounded-md bg-brand-500 px-3 text-sm font-medium text-white shadow-subtle hover:bg-brand-600 active:bg-brand-600 disabled:opacity-50 disabled:hover:bg-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1"
              >
                {if @paid, do: gettext("Continue to payment"), else: gettext("Create organization")}
              </button>
            </fieldset>
          </form>

          <div :if={!@paid} class="mt-4 text-center">
            <a href="/signup/teams" class="text-xs font-medium text-brand-700 hover:text-brand-800">{gettext("Buy Teams and create an organization")}</a>
          </div>
          <div class="mt-4 space-y-1 text-center">
            <button
              :if={@local_checkout}
              id="show-local-payment"
              type="button"
              hidden={@local_checkout.show_channels}
              aria-controls="teams-payment-channels local-signup-fields"
              class="text-xs font-medium text-brand-700 hover:text-brand-800 active:text-brand-800 focus-visible:outline-brand-500"
            >
              {gettext("Pay with a local method in Latin America")}
            </button>
            <div>
              <a
                href={if @paid, do: "/login?return_to=%2Fsignup%2Fteams", else: "/login"}
                class="text-xs font-medium text-brand-700 hover:text-brand-800"
              >
                {if @paid, do: gettext("Sign in to an existing organization"), else: gettext("Sign in with SSO")}
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    <script :if={@paid}><%= teams_checkout_script() %></script>
    """
  end

  defp stripe_quarterly_total_text(seats_str) do
    case Integer.parse(String.trim(to_string(seats_str || ""))) do
      {seats, ""} when seats >= 100 and seats <= 2_147_483_647 ->
        gettext("Quarterly total: $%{total} USD before tax ($240 / seat × %{seats} seats)",
          total: format_thousands(seats * 240),
          seats: format_thousands(seats)
        )

      _ ->
        ""
    end
  end

  defp format_thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp local_checkout(assigns) do
    country = assigns.checkout.country
    country_name_key = if assigns.locale == "zh_Hans", do: "name_zh", else: "name_en"
    document_type = selected_value(country["id_types"], assigns.signup["beneficiary_type"])

    methods =
      if country["code"] == "EC" and document_type == "PAS",
        do: Enum.filter(country["payment_types"], &(&1 == "NET_BANKING")),
        else: country["payment_types"]

    assigns =
      assign(assigns,
        country: country,
        country_name_key: country_name_key,
        brazil: country["code"] == "BR",
        ecuador: country["code"] == "EC",
        document_type: document_type,
        methods: methods,
        method: selected_value(methods, assigns.signup["payment_type"]),
        payment_labels: %{
          "PIX" => "Pix",
          "NET_BANKING" => gettext("Online banking"),
          "TD" => gettext("Debit card"),
          "TC" => gettext("Credit card"),
          "CASH" => gettext("Cash")
        }
      )

    ~H"""
    <fieldset
      id="local-signup-fields"
      hidden={!@checkout.active}
      disabled={!@checkout.active}
      class="space-y-3"
      data-countries={Jason.encode!(@checkout.countries)}
      data-payment-labels={Jason.encode!(@payment_labels)}
      data-seat-error={gettext("Enter between %{min} and %{max} seats.", min: "__MIN__", max: "__MAX__")}
      data-seats-edited={to_string(@checkout.active and not is_nil(@checkout.seats))}
    >
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div>
          <label for="local-signup-country" class="block text-xs font-medium text-neutral-600 mb-1">
            {gettext("Billing country")}
          </label>
          <select id="local-signup-country" name="signup[country]" class={signup_input_class()}>
            <option
              :for={country <- @checkout.countries}
              value={country["code"]}
              selected={country["code"] == @country["code"]}
            >
              {country[@country_name_key]}
            </option>
          </select>
        </div>
        <div>
          <label for="local-signup-seats" class="block text-xs font-medium text-neutral-600 mb-1">
            {gettext("Seats")}
          </label>
          <input
            type="text"
            inputmode="numeric"
            id="local-signup-seats"
            name="signup[seats]"
            value={@checkout.seats || @country["min_seats"]}
            required
            class={seat_input_class()}
          />
          <p id="local-signup-seats-error" role="alert" hidden class="mt-1 text-xs text-red-600"></p>
        </div>
      </div>

      <div id="local-signup-payment-picker" hidden={length(@methods) == 1}>
        <label for="local-signup-payment-type" class="block text-xs font-medium text-neutral-600 mb-1">
          {gettext("Payment method")}
        </label>
        <select
          id="local-signup-payment-type"
          name="signup[payment_type]"
          required
          disabled={length(@methods) == 1}
          class={signup_input_class()}
        >
          <option :for={method <- @methods} value={method} selected={method == @method}>
            {Map.get(@payment_labels, method, method)}
          </option>
        </select>
      </div>
      <div id="local-signup-fixed-payment" hidden={length(@methods) != 1}>
        <span class="block text-xs font-medium text-neutral-600 mb-1">{gettext("Payment method")}</span>
        <p id="local-signup-payment-label" class="text-sm text-neutral-700">{@payment_labels[@method] || @method}</p>
        <input
          id="local-signup-payment-value"
          type="hidden"
          name="signup[payment_type]"
          value={@method}
          disabled={length(@methods) != 1}
        />
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.payer_input field="firstname" label={gettext("First name")} value={@signup["firstname"]} maxlength="100" autocomplete="given-name" />
        <.payer_input field="lastname" label={gettext("Last name")} value={@signup["lastname"]} maxlength="100" autocomplete="family-name" />
      </div>

      <.payer_input field="phone" label={gettext("Phone number")} type="tel" maxlength="20" autocomplete="tel">
        <p id="local-signup-ec-phone-hint" hidden={!@ecuador} class="mt-1 text-xs text-neutral-500">
          {gettext("6–9 local digits, without +593 or a leading zero.")}
        </p>
      </.payer_input>

      <div id="local-signup-cpf" hidden={!@brazil}>
        <.payer_input field="doc_number" label={gettext("CPF number")} maxlength="14" inputmode="numeric" disabled={!@brazil} />
      </div>
      <div id="local-signup-document" hidden={@brazil}>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div>
            <label for="local-signup-beneficiary-type" class="block text-xs font-medium text-neutral-600 mb-1">
              {gettext("Document type")}
            </label>
            <select
              id="local-signup-beneficiary-type"
              name="signup[beneficiary_type]"
              disabled={@brazil}
              class={signup_input_class()}
            >
              <option :for={type <- @country["id_types"]} value={type} selected={type == @document_type}>
                {type}
              </option>
            </select>
          </div>
          <.payer_input field="beneficiary_id" label={gettext("Document number")} maxlength="20" disabled={@brazil} />
        </div>
      </div>

      <p
        id="local-signup-estimate"
        aria-live="polite"
        hidden
        class="text-xs font-medium text-neutral-700 tabular-nums"
        data-template={gettext("Estimated quarterly total: %{amount}", amount: "__AMOUNT__")}
      >
      </p>
    </fieldset>
    """
  end

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:type, :string, default: "text")
  attr(:value, :string, default: nil)
  attr(:maxlength, :string, required: true)
  attr(:autocomplete, :string, default: "off")
  attr(:inputmode, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  slot(:inner_block)

  defp payer_input(assigns) do
    ~H"""
    <div>
      <label for={"local-signup-" <> @field} class="block text-xs font-medium text-neutral-600 mb-1">
        {@label}
      </label>
      <input
        id={"local-signup-" <> @field}
        name={"signup[" <> @field <> "]"}
        type={@type}
        value={@value}
        maxlength={@maxlength}
        autocomplete={@autocomplete}
        inputmode={@inputmode}
        disabled={@disabled}
        required
        class={signup_input_class()}
      />
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp signup_input_class do
    "block w-full min-w-0 h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
  end

  defp selected_value(values, value), do: if(value in values, do: value, else: List.first(values))

  defp seat_input_class do
    [
      signup_input_class(),
      "aria-[invalid=true]:focus:border-red-400 aria-[invalid=true]:focus:ring-red-400"
    ]
  end

  defp teams_checkout_script do
    Phoenix.HTML.raw(~S"""
    (() => {
      const mountedAt = performance.now();
      const byId = (id) => document.getElementById(id);
      const form = byId("teams-checkout");
      const fields = byId("teams-checkout-fields");
      const submit = byId("teams-checkout-submit");
      const reveal = byId("show-local-payment");
      const stripeSeats = byId("stripe-signup-seats");
      const stripeSeatsError = byId("stripe-signup-seats-error");
      const stripeTotal = byId("stripe-signup-total");
      const stripeNumberFormat = new Intl.NumberFormat("en-US");
      const ttlMs = Number(form.dataset.ttlSeconds) * 1000;
      let expired = form.dataset.quoteExpired === "true";
      function validateStripeSeats() {
        const value = /^\d+$/.test(stripeSeats.value) ? BigInt(stripeSeats.value) : null;
        if (value !== null && value > 2147483647n) {
          stripeSeatsError.textContent = stripeSeatsError.dataset.rangeError;
        } else {
          stripeSeatsError.textContent = stripeSeatsError.dataset.minError;
        }
        const valid = seatValid(stripeSeats, stripeSeatsError, 100, 2147483647);
        if (stripeTotal) {
          if (valid && value !== null) {
            const totalUsd = value * 240n;
            stripeTotal.textContent = stripeTotal.dataset.template
              .replace("__TOTAL__", stripeNumberFormat.format(totalUsd))
              .replace("__SEATS__", stripeNumberFormat.format(value));
            stripeTotal.hidden = false;
          } else {
            stripeTotal.textContent = "";
            stripeTotal.hidden = true;
          }
        }
        return valid;
      }

      let validateSeats = () => validateStripeSeats();

      function expire() {
        expired = true;
        form.dataset.quoteExpired = "true";
        fields.disabled = submit.disabled = true;
        if (reveal) reveal.disabled = true;
        byId("signup-quote-expired").hidden = false;
      }

      function enforceDeadline() {
        if (expired || !(ttlMs > 0) || performance.now() - mountedAt >= ttlMs) expire();
        return expired;
      }

      function seatValid(input, error, min, max) {
        const value = /^\d+$/.test(input.value) ? BigInt(input.value) : null;
        const valid = value !== null && value >= BigInt(min) && value <= BigInt(max);
        error.hidden = valid;
        input.classList.toggle("border-red-400", !valid);
        input.classList.toggle("border-neutral-300", valid);
        if (valid) {
          input.removeAttribute("aria-invalid");
          input.removeAttribute("aria-describedby");
        } else {
          input.setAttribute("aria-invalid", "true");
          input.setAttribute("aria-describedby", error.id);
        }
        return valid;
      }

      function update() {
        if (!enforceDeadline()) submit.disabled = !validateSeats();
      }

      form.addEventListener("input", update);
      form.addEventListener("submit", (event) => {
        update();
        if (submit.disabled) event.preventDefault();
      });
      window.addEventListener("pageshow", update);

      if (enforceDeadline()) return;
      setTimeout(expire, Math.max(0, ttlMs - (performance.now() - mountedAt)));

      const local = byId("local-signup-fields");
      if (!local) {
        update();
        return;
      }

      const stripe = byId("stripe-signup-fields");
      const localRadio = form.querySelector('[value="m2square"]');
      const channels = byId("teams-payment-channels");
      const countryInput = byId("local-signup-country");
      const seats = byId("local-signup-seats");
      const documentType = byId("local-signup-beneficiary-type");
      const paymentType = byId("local-signup-payment-type");
      const fixedPayment = byId("local-signup-payment-value");
      const cpf = byId("local-signup-doc_number");
      const documentNumber = byId("local-signup-beneficiary_id");
      const phone = byId("local-signup-phone");
      const phoneHint = byId("local-signup-ec-phone-hint");
      const localSeatsError = byId("local-signup-seats-error");
      let seatsEdited = local.dataset.seatsEdited === "true";
      const estimate = byId("local-signup-estimate");
      const countries = JSON.parse(local.dataset.countries);
      const paymentLabels = JSON.parse(local.dataset.paymentLabels);
      const numberFormat = new Intl.NumberFormat(document.documentElement.lang);
      const country = () => countries.find((item) => item.code === countryInput.value);

      function replaceOptions(select, values, labels = {}) {
        const previous = select.value;
        select.replaceChildren(...values.map((value) => new Option(labels[value] ?? value, value)));
        if (values.includes(previous)) select.value = previous;
      }

      function updatePaymentMethods() {
        const current = country();
        const methods = current.code === "EC" && documentType.value === "PAS"
          ? current.payment_types.filter((method) => method === "NET_BANKING")
          : current.payment_types;
        replaceOptions(paymentType, methods, paymentLabels);
        const single = methods.length === 1;
        byId("local-signup-payment-picker").hidden = paymentType.disabled = single;
        byId("local-signup-fixed-payment").hidden = fixedPayment.disabled = !single;
        fixedPayment.value = single ? methods[0] : "";
        byId("local-signup-payment-label").textContent = paymentLabels[fixedPayment.value] ?? fixedPayment.value;
      }

      // Same integer calculation as the Teams settings estimator. Currency amounts
      // stay in BigInt throughout, including rounding the gateway fee to cents.
      function decimal(value) {
        const parts = /^(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(value);
        if (!parts) return;
        const fraction = parts[2] ?? "";
        const scale = fraction.length - Number(parts[3] ?? 0);
        if (!Number.isInteger(scale) || Math.abs(scale) > 100) return;
        const coefficient = BigInt(parts[1] + fraction);
        return scale >= 0
          ? { numerator: coefficient, denominator: 10n ** BigInt(scale) }
          : { numerator: coefficient * 10n ** BigInt(-scale), denominator: 1n };
      }

      const ceil = (num, den) => (num + den - 1n) / den;

      function quarterlyTotal(current, quantity) {
        const fx = decimal(current.fx_rate);
        const markup = decimal(current.markup_rate);
        const fee = decimal(current.fee_rate);
        if (!fx?.numerator || !markup || !fee || fee.numerator >= fee.denominator ||
            (current.scale !== 0 && current.scale !== 2)) return;

        const targetCents = ceil(
          quantity * 24_000n * (markup.denominator + markup.numerator) * fx.denominator,
          markup.denominator * fx.numerator
        );
        const centsPerUnit = current.scale === 0 ? 100n : 1n;
        const minor = ceil(
          targetCents * fee.denominator,
          centsPerUnit * (fee.denominator - fee.numerator)
        );
        const formatted = current.scale === 0
          ? numberFormat.format(minor)
          : numberFormat.format(minor / 100n) + "." + String(minor % 100n).padStart(2, "0");

        return current.display_currency + " " + formatted;
      }

      validateSeats = () => {
        if (!localRadio.checked) {
          return validateStripeSeats();
        }

        const current = country();
        localSeatsError.textContent = local.dataset.seatError
          .replace("__MIN__", current.min_seats)
          .replace("__MAX__", current.max_seats);
        const valid = seatValid(seats, localSeatsError, current.min_seats, current.max_seats);
        const amount = valid ? quarterlyTotal(current, BigInt(seats.value)) : "";
        estimate.textContent = amount ? estimate.dataset.template.replace("__AMOUNT__", amount) : "";
        estimate.hidden = !amount;
        return valid;
      };

      function updateCountry() {
        const current = country();
        const brazil = current.code === "BR";
        const ecuador = current.code === "EC";
        byId("local-signup-cpf").hidden = !brazil;
        cpf.disabled = !brazil;
        byId("local-signup-document").hidden = brazil;
        documentType.disabled = documentNumber.disabled = brazil;
        phoneHint.hidden = !ecuador;
        if (ecuador) phone.setAttribute("aria-describedby", phoneHint.id);
        else phone.removeAttribute("aria-describedby");

        replaceOptions(documentType, current.id_types);
        updatePaymentMethods();
        if (!seatsEdited) seats.value = current.min_seats;
        update();
      }

      function updateChannel() {
        const active = localRadio.checked;
        form.dataset.localActive = String(active);
        local.hidden = local.disabled = !active;
        stripe.hidden = stripe.disabled = active;
        byId("stripe-signup-description").hidden = active;
        byId("local-signup-description").hidden = !active;
        update();
      }

      channels.addEventListener("change", updateChannel);
      reveal.addEventListener("click", () => {
        if (enforceDeadline()) return;
        channels.hidden = channels.disabled = false;
        reveal.hidden = true;
        localRadio.checked = true;
        updateChannel();
        localRadio.focus();
      });
      countryInput.addEventListener("change", () => {
        // A new jurisdiction requires its own document, even if the field name matches.
        cpf.value = documentNumber.value = "";
        updateCountry();
      });
      documentType.addEventListener("change", updatePaymentMethods);
      seats.addEventListener("input", () => { seatsEdited = true; });
      window.addEventListener("pageshow", () => {
        updateCountry();
        updateChannel();
      });
      updateCountry();
      updateChannel();
    })();
    """)
  end

  defp login_local_storage_script do
    Phoenix.HTML.raw("""
    (() => {
      const section = document.getElementById("remembered-org-login");
      if (!section || section.dataset.disabled === "true") return;

      const orgs = loadLoginOrgs(section);
      if (orgs.length === 0) return;

      const list = document.getElementById("remembered-org-list");
      if (!list) return;

      const prefix = section.dataset.continuePrefix || "Continue as";
      const ssoLabel = section.dataset.ssoLabel || "SSO";
      const emailLabel = section.dataset.emailLabel || "Email";
      const csrfToken = section.dataset.csrfToken || "";
      const returnTo = section.dataset.returnTo || "";

      orgs.forEach((org) => {
        list.appendChild(orgLoginForm(org, { prefix, ssoLabel, emailLabel, csrfToken, returnTo }));
      });

      section.dataset.orgCount = String(orgs.length);
      section.classList.remove("hidden");

      function loadLoginOrgs(section) {
        const stored = parseStored(section.dataset.storageKey);
        const legacy = parseStored(section.dataset.legacyStorageKey);
        return uniqueOrgs(stored.concat(legacy));
      }

      function parseStored(key) {
        if (!key) return [];

        try {
          const value = JSON.parse(window.localStorage.getItem(key) || "null");
          if (Array.isArray(value)) return value.map(normalizeOrg).filter(Boolean);
          const org = normalizeOrg(value);
          return org ? [org] : [];
        } catch (_error) {
          return [];
        }
      }

      function normalizeOrg(value) {
        if (!value || typeof value.slug !== "string") return null;

        const slug = value.slug.trim();
        if (!slug) return null;

        const rawName = typeof value.name === "string" ? value.name.trim() : "";
        const authMethod = value.auth_method === "email" ? "email" : "sso";
        const org = { slug, name: rawName || slug, auth_method: authMethod };
        const icon = normalizeIcon(value.icon);
        if (icon) org.icon = icon;
        return org;
      }

      function normalizeIcon(value) {
        if (typeof value !== "string") return null;

        const icon = value.trim();
        if (
          icon.startsWith("data:image/png;base64,") ||
          icon.startsWith("data:image/jpeg;base64,") ||
          icon.startsWith("data:image/jpg;base64,") ||
          icon.startsWith("data:image/gif;base64,") ||
          icon.startsWith("data:image/webp;base64,")
        ) {
          return icon;
        }

        return null;
      }

      function uniqueOrgs(orgs) {
        const seen = new Set();
        return orgs.filter((org) => {
          if (seen.has(org.slug)) return false;
          seen.add(org.slug);
          return true;
        });
      }

      function orgLoginForm(org, labels) {
        const form = document.createElement("form");
        form.method = "post";
        form.action = "/auth/start";

        const csrfInput = document.createElement("input");
        csrfInput.type = "hidden";
        csrfInput.name = "_csrf_token";
        csrfInput.value = labels.csrfToken;
        form.appendChild(csrfInput);

        const slugInput = document.createElement("input");
        slugInput.type = "hidden";
        slugInput.name = "org_slug";
        slugInput.value = org.slug;
        form.appendChild(slugInput);

        if (labels.returnTo) {
          const returnToInput = document.createElement("input");
          returnToInput.type = "hidden";
          returnToInput.name = "return_to";
          returnToInput.value = labels.returnTo;
          form.appendChild(returnToInput);
        }

        const button = document.createElement("button");
        button.type = "submit";
        button.className =
          "group flex w-full items-center gap-3 rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-left hover:border-brand-200 hover:bg-brand-50 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1";
        form.appendChild(button);

        button.appendChild(orgAvatar(org));

        const text = document.createElement("span");
        text.className = "min-w-0 flex-1";
        button.appendChild(text);

        const label = document.createElement("span");
        label.className = "block truncate text-sm font-medium text-neutral-900";
        label.textContent = `${labels.prefix} ${org.name}`;
        text.appendChild(label);

        const subtitle = document.createElement("span");
        subtitle.className = "block truncate text-xs text-neutral-500";
        subtitle.textContent = org.slug;
        text.appendChild(subtitle);

        const sso = document.createElement("span");
        sso.className = "text-xs font-medium text-brand-700 group-hover:text-brand-800";
        sso.textContent = org.auth_method === "email" ? labels.emailLabel : labels.ssoLabel;
        button.appendChild(sso);

        return form;
      }

      function orgAvatar(org) {
        if (org.icon) {
          const image = document.createElement("img");
          image.src = org.icon;
          image.alt = "";
          image.className =
            "h-6 w-6 shrink-0 rounded-md border border-neutral-200 bg-white object-cover";
          return image;
        }

        const avatar = document.createElement("span");
        avatar.className =
          "flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-brand-500 text-[11px] font-semibold text-white";
        avatar.textContent = (org.name[0] || "?").toUpperCase();
        return avatar;
      }
    })();
    """)
  end

  defp remember_org_script do
    Phoenix.HTML.raw("""
    (() => {
      const el = document.getElementById("remember-login-orgs");
      if (!el) return;

      let orgs = [];
      try {
        const parsed = JSON.parse(el.dataset.loginOrgs || "[]");
        orgs = Array.isArray(parsed) ? parsed.map(normalizeOrg).filter(Boolean) : [];
      } catch (_error) {
      }

      if (orgs.length > 0) {
        try {
          window.localStorage.setItem(el.dataset.storageKey, JSON.stringify(orgs));
        } catch (_error) {
        }
      }

      window.location.replace(el.dataset.next || "/");

      function normalizeOrg(value) {
        if (!value || typeof value.slug !== "string") return null;

        const slug = value.slug.trim();
        if (!slug) return null;

        const rawName = typeof value.name === "string" ? value.name.trim() : "";
        const authMethod = value.auth_method === "email" ? "email" : "sso";
        const org = { slug, name: rawName || slug, auth_method: authMethod };
        const icon = normalizeIcon(value.icon);
        if (icon) org.icon = icon;
        return org;
      }

      function normalizeIcon(value) {
        if (typeof value !== "string") return null;

        const icon = value.trim();
        if (
          icon.startsWith("data:image/png;base64,") ||
          icon.startsWith("data:image/jpeg;base64,") ||
          icon.startsWith("data:image/jpg;base64,") ||
          icon.startsWith("data:image/gif;base64,") ||
          icon.startsWith("data:image/webp;base64,")
        ) {
          return icon;
        }

        return null;
      }
    })();
    """)
  end
end
