defmodule SalixWeb.Dashboard.BrowserLive do
  @moduledoc "Operator-managed global and tenant Browser Run configuration."
  use SalixWeb.Dashboard, :live_view
  alias SalixStore.BrowserSettings

  def mount(_, _, socket),
    do:
      {:ok,
       socket
       |> assign(
         active_nav: :browser,
         page_title: "Browser Run",
         breadcrumbs: [{"Browser Run", nil}]
       )
       |> load()}

  defp load(socket),
    do:
      assign(socket,
        global: BrowserSettings.view(BrowserSettings.default_scope()),
        tenant: BrowserSettings.view(socket.assigns.current_tenant)
      )

  def handle_event("save", %{"scope" => scope} = attrs, socket)
      when scope in ["global", "tenant"] do
    # This entire dashboard uses the authenticated platform-admin live_session.
    scope =
      if scope == "global",
        do: BrowserSettings.default_scope(),
        else: socket.assigns.current_tenant

    attrs =
      Map.put(
        attrs,
        "allowed_domains",
        case String.trim(attrs["allowed_domains"] || "") do
          "" -> nil
          value -> String.split(value, ~r/[\s,]+/, trim: true)
        end
      )

    case BrowserSettings.put(scope, attrs) do
      {:ok, :ok} -> {:noreply, socket |> load() |> put_flash(:info, "Browser settings saved.")}
      {:error, reason} -> {:noreply, socket |> put_flash(:error, "Save failed: #{reason}")}
    end
  end

  def handle_event("test", %{"scope" => scope}, socket) when scope in ["global", "tenant"] do
    selected =
      if scope == "global",
        do: BrowserSettings.default_scope(),
        else: socket.assigns.current_tenant

    case SalixAgent.Browser.test_settings(selected) do
      {:ok, :connected} ->
        {:noreply, put_flash(socket, :info, "Browser created and closed successfully.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Connection test failed: #{reason}")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">Browser Run</h1>
      <p>Cloud browsers for agent tools and Comma. Credentials stay on the server. Existing browsers retain their original account.</p>
      <section :for={{scope, settings} <- [{"global", @global}, {"tenant", @tenant}]} class="rounded border p-4 space-y-3">
        <h2 class="font-semibold"><%= if scope == "global", do: "Global default", else: "Tenant override" %></h2>
        <p :if={settings[:error]} role="alert">Settings are unavailable.</p>
        <form id={"browser-" <> scope} phx-submit="save" class="space-y-3">
          <input type="hidden" name="scope" value={scope} />
          <label class="block">Mode
            <select name="mode" class="block rounded border p-2">
              <option :if={scope == "tenant"} value="inherit" selected={settings[:mode] == "inherit"}>Inherit global default</option>
              <option value="override" selected={settings[:mode] == "override"}>Use these credentials</option>
              <option value="disabled" selected={settings[:mode] == "disabled"}>Disabled</option>
            </select>
          </label>
          <label class="block">Cloudflare account ID<input name="account_id" value={settings[:account_id]} maxlength="32" class="block rounded border p-2 w-full" /></label>
          <label class="block">API token<input type="password" name="api_token" autocomplete="new-password" value="" placeholder={if settings[:token_configured], do: "Configured. Leave blank to keep.", else: "Browser Rendering Edit token"} class="block rounded border p-2 w-full" /></label>
          <label class="block">Inactivity timeout (milliseconds)<input type="number" name="idle_timeout_ms" min="1000" max="600000" value={settings[:idle_timeout_ms]} class="block rounded border p-2" /></label>
          <label class="block">Operation timeout (milliseconds)<input type="number" name="operation_timeout_ms" min="1000" max="30000" value={settings[:operation_timeout_ms]} class="block rounded border p-2" /></label>
          <label class="block">Allowed destination hostnames (optional)<textarea name="allowed_domains" class="block rounded border p-2 w-full"><%= Enum.join(settings[:allowed_domains] || [], "\n") %></textarea></label>
          <p>Blank permits all HTTP and HTTPS destinations. Include redirect and page dependency hostnames. Changes apply to new browsers.</p>
          <button class="rounded border px-3 py-2" type="submit">Save</button>
        </form>
        <button type="button" phx-click="test" phx-value-scope={scope} class="rounded border px-3 py-2">Test saved credentials</button>
        <p>The test creates and closes a browser and consumes Cloudflare usage.</p>
      </section>
    </div>
    """
  end
end
