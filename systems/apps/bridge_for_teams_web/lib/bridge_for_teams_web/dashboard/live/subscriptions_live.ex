defmodule BridgeForTeamsWeb.Dashboard.SubscriptionsLive do
  use BridgeForTeamsWeb.Dashboard, :live_view
  alias BridgeForTeams.{Orgs, Subscriptions}
  alias SalixWeb.Dashboard.AccountPoolLive, as: Panel

  @impl true
  def mount(%{"org" => slug}, session, socket) do
    user = socket.assigns.current_user

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, _} <- Subscriptions.authorize({org.id, user.id}) do
      scope = {org.id, user.id}

      {:ok, socket} =
        Panel.mount(
          %{},
          session,
          assign(socket, current_tenant: scope, account_pool_api: Subscriptions)
        )

      {:ok,
       assign(socket,
         current_org: org,
         orgs: Orgs.list_orgs_for_user(user.id),
         active_nav: :settings,
         page_title: "Organization accounts",
         breadcrumbs: [
           {org.name, ~p"/orgs/#{org.slug}"},
           {"Models", ~p"/orgs/#{org.slug}/settings/models"},
           {"Organization accounts", nil}
         ]
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Organization administrator access is required.")
         |> redirect(to: ~p"/orgs")}
    end
  end

  @impl true
  def handle_event(event, params, socket), do: Panel.handle_event(event, params, socket)
  @impl true
  def handle_async(name, result, socket), do: Panel.handle_async(name, result, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">Organization accounts</h1>
          <p class="mt-0.5 text-sm text-neutral-500">Subscriptions and Provider API keys for {@current_org.name}.</p>
        </div>
        <div class="flex items-center gap-2">
          <.button size="sm" phx-click="open-import" disabled={@busy}>
            <.icon name="document-text" class="h-3.5 w-3.5" /> Import
          </.button>
          <.button id="add-provider-key" size="sm" phx-click="open-provider-key" disabled={@busy}>
            <.icon name="key" class="h-3.5 w-3.5" /> Add Provider API key
          </.button>
          <.button :if={@accounts != []} size="sm" variant="primary" phx-click="open-connect" disabled={@busy}>
            <.icon name="plus" class="h-3.5 w-3.5" /> Connect subscription
          </.button>
        </div>
      </div>
      <div :if={@page_error} role="alert" class="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-700">{@page_error}</div>
      <div :if={@reset_notice} role="status" class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-xs">{@reset_notice}</div>
      <.empty_state :if={@loaded && @accounts == []} icon="plug" title="No organization accounts"
        description="Connect a subscription or add a Provider API key for your team's Agents.">
        <:actions>
          <div class="flex gap-2">
            <.button size="sm" variant="primary" phx-click="open-connect" disabled={@busy}>
              <.icon name="plus" class="h-3.5 w-3.5" /> Connect subscription
            </.button>
            <.button size="sm" phx-click="open-provider-key" disabled={@busy}>Add Provider API key</.button>
          </div>
        </:actions>
      </.empty_state>
      <Panel.account_list :if={!@loaded || @accounts != []} {assigns} />
      <div class="flex flex-wrap items-center justify-between gap-4 border-t border-neutral-200 pt-4">
        <div class="min-w-0">
          <h2 class="text-[13px] font-medium text-neutral-900">Use subscriptions in private templates</h2>
          <p class="mt-1 text-xs text-neutral-500">Only your organization can use them. Model usage does not spend platform credits.</p>
        </div>
        <.button size="sm" navigate={~p"/orgs/#{@current_org.slug}/settings/models/templates"}>
          Manage private templates <.icon name="chevron-right" class="h-3.5 w-3.5" />
        </.button>
      </div>
      <.modal :if={@dialog} id="subscription-dialog" show on_cancel={JS.push("close")}>
        <:title>{Panel.dialog_title(@dialog, @selected)}</:title>
        <Panel.dialog_body {assigns} />
      </.modal>
    </div>
    """
  end
end
