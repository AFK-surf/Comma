defmodule BridgeForTeamsWeb.Dashboard.CLIDeviceLoginLive do
  @moduledoc """
  Dashboard confirmation page for CLI device login requests.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{CLI.Login, Orgs}

  @impl true
  def mount(%{"user_code" => user_code}, _session, socket) do
    mount_device_login(
      socket,
      Login.normalize_user_code(user_code),
      load_authorization(user_code)
    )
  end

  def mount(_params, _session, socket) do
    mount_device_login(socket, nil, nil)
  end

  defp mount_device_login(socket, user_code, authorization) do
    user = socket.assigns.current_user
    manageable_orgs = Orgs.list_manageable_orgs_for_user(user.id)

    if manageable_orgs != [] do
      {:ok,
       socket
       |> assign(:page_title, gettext("Approve BFT CLI login"))
       |> assign(:active_nav, nil)
       |> assign(:current_org, nil)
       |> assign(:manageable_orgs, manageable_orgs)
       |> assign(:selected_org_ids, MapSet.new())
       |> assign(:breadcrumbs, [{gettext("BFT CLI login"), nil}])
       |> assign(:user_code, user_code)
       |> assign(:authorization, authorization)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to approve CLI login requests."))
       |> redirect(to: ~p"/orgs")}
    end
  end

  @impl true
  def handle_event("continue", %{"device_login" => %{"user_code" => user_code}}, socket) do
    case Login.normalize_user_code(user_code) do
      "" ->
        {:noreply, put_flash(socket, :error, gettext("Enter the user code shown in the CLI."))}

      normalized ->
        {:noreply, push_navigate(socket, to: ~p"/cli/device-login/#{normalized}")}
    end
  end

  def handle_event("toggle_org", %{"org_id" => org_id}, socket) do
    allowed_ids = MapSet.new(Enum.map(socket.assigns.manageable_orgs, & &1.id))
    selected = socket.assigns.selected_org_ids

    selected =
      cond do
        not MapSet.member?(allowed_ids, org_id) -> selected
        MapSet.member?(selected, org_id) -> MapSet.delete(selected, org_id)
        true -> MapSet.put(selected, org_id)
      end

    {:noreply, assign(socket, :selected_org_ids, selected)}
  end

  def handle_event("approve", _params, socket) do
    org_ids = MapSet.to_list(socket.assigns.selected_org_ids)

    if org_ids == [] do
      {:noreply, put_flash(socket, :error, gettext("Select at least one organization."))}
    else
      case Login.approve_device_authorization(
             socket.assigns.user_code,
             socket.assigns.current_user,
             org_ids
           ) do
        {:ok, authorization} ->
          {:noreply,
           socket
           |> assign(:authorization, authorization)
           |> assign(:selected_org_ids, MapSet.new())
           |> put_flash(:info, gettext("CLI login approved. Return to the terminal."))}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:authorization, load_authorization(socket.assigns.user_code))
           |> put_flash(:error, status_message(reason))}
      end
    end
  end

  def handle_event("cancel", _params, socket) do
    case Login.cancel_device_authorization(socket.assigns.user_code, socket.assigns.current_user) do
      {:ok, authorization} ->
        {:noreply,
         socket
         |> assign(:authorization, authorization)
         |> put_flash(:info, gettext("CLI login cancelled."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:authorization, load_authorization(socket.assigns.user_code))
         |> put_flash(:error, status_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <div>
        <h1 class="text-2xl font-semibold text-neutral-900">{gettext("Approve BFT CLI login")}</h1>
        <p class="mt-1 text-sm text-neutral-500">
          {gettext("Review the request and choose which organizations the CLI may access.")}
        </p>
      </div>

      <.card>
        <:title>{gettext("Login request")}</:title>

        <div :if={@user_code != nil and @authorization == nil} class="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
          {gettext("This CLI login request was not found.")}
        </div>

        <form :if={is_nil(@user_code)} id="cli-device-login-code-form" phx-submit="continue" class="space-y-3">
          <div>
            <label class="block text-xs font-medium text-neutral-600 mb-1">
              {gettext("User code")}
            </label>
            <input
              type="text"
              name="device_login[user_code]"
              autocomplete="one-time-code"
              autofocus
              class="block w-full h-9 rounded-md border border-neutral-300 px-2.5 font-mono text-sm uppercase placeholder:text-neutral-400 focus:border-brand-500 focus:ring-1 focus:ring-brand-500 focus:outline-none"
            />
          </div>
          <div class="flex justify-end">
            <.button type="submit" variant="primary">
              {gettext("Continue")}
            </.button>
          </div>
        </form>

        <div :if={@authorization} class="space-y-4">
          <dl class="grid gap-3 text-sm sm:grid-cols-2">
            <div>
              <dt class="text-neutral-500">{gettext("User code")}</dt>
              <dd class="mt-1 font-mono text-neutral-900">{@authorization.user_code}</dd>
            </div>
            <div>
              <dt class="text-neutral-500">{gettext("Status")}</dt>
              <dd class="mt-1">
                <.badge color={status_color(@authorization.status)}>{@authorization.status}</.badge>
              </dd>
            </div>
            <div>
              <dt class="text-neutral-500">{gettext("Client")}</dt>
              <dd class="mt-1 text-neutral-900">{@authorization.client_name || "bft CLI"}</dd>
            </div>
            <div>
              <dt class="text-neutral-500">{gettext("Created at")}</dt>
              <dd class="mt-1 font-mono text-neutral-900">{format_time(@authorization.created_at)}</dd>
            </div>
            <div>
              <dt class="text-neutral-500">{gettext("Expires at")}</dt>
              <dd class="mt-1 font-mono text-neutral-900">{format_time(@authorization.expires_at)}</dd>
            </div>
          </dl>
        </div>
      </.card>

      <.card :if={@authorization}>
        <:title>{gettext("Organization access")}</:title>

        <div :if={@authorization.status == "pending"} class="space-y-3">
          <p class="text-sm text-neutral-600">
            {gettext("Select one or more organizations to grant access to.")}
          </p>

          <fieldset class="space-y-2">
            <legend class="sr-only">{gettext("Organizations")}</legend>
            <label
              :for={org <- @manageable_orgs}
              class="flex cursor-pointer items-center gap-3 rounded-md border border-neutral-200 p-3 hover:bg-neutral-50"
            >
              <input
                type="checkbox"
                name="org_ids[]"
                value={org.id}
                checked={MapSet.member?(@selected_org_ids, org.id)}
                phx-click="toggle_org"
                phx-value-org_id={org.id}
                class="h-4 w-4 rounded border-neutral-300 text-brand-500 focus:ring-brand-500"
              />
              <.org_avatar org={org} size="sm" />
              <span class="flex-1 text-sm font-medium text-neutral-900">{org.name}</span>
              <.badge color="green">{gettext("manageable")}</.badge>
            </label>
          </fieldset>
        </div>

        <div :if={@authorization.status in ["approved", "consumed"]} class="space-y-3">
          <p class="text-sm text-neutral-600">
            {gettext("The CLI has been granted access to the following organizations:")}
          </p>
          <ul class="divide-y divide-neutral-100 rounded-md border border-neutral-200">
            <li :for={org <- authorization_granted_orgs(@authorization)} class="flex items-center gap-3 px-3 py-2">
              <.org_avatar org={org} size="sm" />
              <span class="flex-1 text-sm font-medium text-neutral-900">{org.name}</span>
              <.badge color="green">{gettext("granted")}</.badge>
            </li>
          </ul>
        </div>

        <p :if={@authorization.status == "cancelled"} class="text-sm text-neutral-600">
          {gettext("No organizations were granted access because the request was cancelled.")}
        </p>
        <p :if={@authorization.status == "expired"} class="text-sm text-neutral-600">
          {gettext("No organizations were granted access because the request expired.")}
        </p>
      </.card>

      <div :if={@authorization} class="space-y-3">
        <div :if={@authorization.status == "pending"} class="flex justify-end gap-2">
          <.button type="button" variant="secondary" phx-click="cancel">
            {gettext("Deny access")}
          </.button>
          <.button
            type="button"
            variant="primary"
            phx-click="approve"
            disabled={MapSet.size(@selected_org_ids) == 0}
          >
            {gettext("Approve access")}
          </.button>
        </div>

        <p :if={@authorization.status == "approved"} class="rounded-md border border-green-200 bg-green-50 px-3 py-2 text-sm text-green-700">
          {gettext("Approved. The CLI can now access the selected organizations.")}
        </p>
        <p :if={@authorization.status == "cancelled"} class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-sm text-neutral-600">
          {gettext("Cancelled. The terminal will not receive a session.")}
        </p>
        <p :if={@authorization.status == "consumed"} class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-sm text-neutral-600">
          {gettext("Completed. The CLI already received its session.")}
        </p>
        <p :if={@authorization.status == "expired"} class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-700">
          {gettext("Expired. Start a new login from the terminal.")}
        </p>
      </div>
    </section>
    """
  end

  defp load_authorization(user_code) do
    case Login.get_device_authorization(user_code) do
      {:ok, authorization} -> authorization
      {:error, :not_found} -> nil
    end
  end

  defp authorization_granted_orgs(authorization) do
    authorization
    |> Map.get(:org_grants, [])
    |> Enum.map(& &1.org)
    |> Enum.reject(&is_nil/1)
  end

  defp status_color("pending"), do: "amber"
  defp status_color("approved"), do: "green"
  defp status_color("consumed"), do: "neutral"
  defp status_color("cancelled"), do: "neutral"
  defp status_color("expired"), do: "amber"
  defp status_color(_), do: "neutral"

  defp format_time(nil), do: "—"
  defp format_time(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp status_message("cancelled"), do: gettext("This CLI login was already cancelled.")
  defp status_message("consumed"), do: gettext("This CLI login was already completed.")
  defp status_message("expired"), do: gettext("This CLI login has expired.")
  defp status_message(:missing_org_grants), do: gettext("Select at least one organization.")
  defp status_message(_), do: gettext("Could not update this CLI login request.")
end
