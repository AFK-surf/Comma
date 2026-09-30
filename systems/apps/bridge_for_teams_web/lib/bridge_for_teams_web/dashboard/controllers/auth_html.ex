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
          <span class="text-base font-semibold tracking-tight">Bridge For Teams</span>
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
              {gettext("Continue with SSO")}
            </button>
          </form>

          <div class="mt-4 text-center">
            <a href="/signup" class="text-xs font-medium text-brand-700 hover:text-brand-800">
              {gettext("Create organization with invite code")}
            </a>
          </div>
        </div>
      </div>
    </div>
    """
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
          <span class="text-base font-semibold tracking-tight">Bridge For Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <h1 class="text-sm font-semibold mb-1">{gettext("Sign in with email")}</h1>
          <p class="text-neutral-500 text-xs mb-4">
            {gettext(
              "This organization does not use SSO. We'll email you a one-time sign-in link instead."
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

            <div :if={@org_slug == ""}>
              <label class="block text-xs font-medium text-neutral-600 mb-1">
                {gettext("Organization slug")}
              </label>
              <input
                type="text"
                name="org_slug"
                placeholder="acme-co"
                class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
              />
            </div>

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
                placeholder="you@example.com"
                autofocus
                class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
              />
            </div>

            <button
              type="submit"
              class="w-full inline-flex items-center justify-center h-8 rounded-md bg-brand-500 px-3 text-sm font-medium text-white shadow-subtle hover:bg-brand-600 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1"
            >
              {gettext("Email me a sign-in link")}
            </button>
          </form>

          <div class="mt-4 text-center">
            <a href="/login" class="text-xs font-medium text-brand-700 hover:text-brand-800">
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
          <span class="text-base font-semibold tracking-tight">Bridge For Teams</span>
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

  def signup(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-neutral-50">
      <div class="w-full max-w-sm">
        <div class="flex items-center gap-2 justify-center mb-8">
          <img
            src={~p"/images/bridge-icon-512.png"}
            alt=""
            class="h-7 w-7 rounded-md"
          />
          <span class="text-base font-semibold tracking-tight">Bridge For Teams</span>
        </div>

        <div class="rounded-xl border border-neutral-200 bg-white p-6 shadow-subtle">
          <h1 class="text-sm font-semibold mb-1">{gettext("Create organization")}</h1>
          <p class="text-neutral-500 text-xs mb-4">
            {gettext("Use your invite code to create your organization and owner account.")}
          </p>

          <%= if @error do %>
            <div class="mb-3 rounded-md bg-red-50 border border-red-200 px-3 py-2 text-xs text-red-700">
              {@error}
            </div>
          <% end %>

          <form method="post" action="/signup" class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />

            <div>
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
                <label class="block text-xs font-medium text-neutral-600 mb-1">
                  {gettext("Organization name")}
                </label>
                <input
                  type="text"
                  name="signup[org_name]"
                  value={@signup["org_name"]}
                  placeholder="Acme"
                  readonly
                  class="block w-full h-8 rounded-md border border-neutral-300 bg-neutral-50 px-2.5 text-sm text-neutral-700 placeholder:text-neutral-400 focus:outline-none"
                />
              </div>

              <div>
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

            <div>
              <label class="block text-xs font-medium text-neutral-600 mb-1">
                {gettext("Work email")}
              </label>
              <input
                type="email"
                name="signup[email]"
                value={@signup["email"]}
                placeholder="you@example.com"
                class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
              />
            </div>

            <div>
              <label class="block text-xs font-medium text-neutral-600 mb-1">
                {gettext("Name")}
              </label>
              <input
                type="text"
                name="signup[name]"
                value={@signup["name"]}
                placeholder={gettext("Your name")}
                class="block w-full h-8 rounded-md border border-neutral-300 px-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
              />
            </div>

            <button
              type="submit"
              class="w-full inline-flex items-center justify-center h-8 rounded-md bg-brand-500 px-3 text-sm font-medium text-white shadow-subtle hover:bg-brand-600 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1"
            >
              {gettext("Create organization")}
            </button>
          </form>

          <div class="mt-4 text-center">
            <a href="/login" class="text-xs font-medium text-brand-700 hover:text-brand-800">
              {gettext("Sign in with SSO")}
            </a>
          </div>
        </div>
      </div>
    </div>
    """
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
      const csrfToken = section.dataset.csrfToken || "";
      const returnTo = section.dataset.returnTo || "";

      orgs.forEach((org) => {
        list.appendChild(orgLoginForm(org, { prefix, ssoLabel, csrfToken, returnTo }));
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
        const org = { slug, name: rawName || slug };
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
        sso.textContent = labels.ssoLabel;
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
        const org = { slug, name: rawName || slug };
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
