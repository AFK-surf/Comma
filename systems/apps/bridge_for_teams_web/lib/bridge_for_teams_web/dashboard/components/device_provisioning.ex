defmodule BridgeForTeamsWeb.Dashboard.DeviceProvisioning do
  @moduledoc """
  Shared project-device provisioning UI for the Agent Swarm Devices tab and
  the My Space devices rail.

  Devices are created on an online organization runner. Runner onboarding and
  credentials stay in the organization Fin page; this component only links to
  that surface when no runner is available.
  """
  use Phoenix.Component

  use Gettext, backend: BridgeForTeamsWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: BridgeForTeamsWeb.DashboardEndpoint,
    router: BridgeForTeamsWeb.DashboardRouter,
    statics: BridgeForTeamsWeb.Dashboard.static_paths()

  import BridgeForTeamsWeb.Dashboard.CoreComponents

  alias BridgeForTeams.Environments
  alias Phoenix.LiveView.JS

  attr(:form, Phoenix.HTML.Form, required: true)
  attr(:provisioners, :list, required: true)
  attr(:org, :map, required: true)

  def add_device_modal(assigns) do
    ~H"""
    <.modal id="new-env-modal" show on_cancel={JS.push("close_env_form")}>
      <:title>{gettext("Add device")}</:title>

      <.form :if={@provisioners != []} for={@form} phx-submit="create_environment" id="new-env-form">
        <div class="space-y-4">
          <.input field={@form[:name]} label={gettext("Name")} placeholder={gettext("e.g. staging-box")} />
          <.input
            field={@form[:alias]}
            label={gettext("Alias")}
            placeholder={gettext("e.g. prod-mac")}
          />
          <.select
            field={@form[:provisioner_id]}
            label={gettext("Runner")}
            options={provisioner_options(@provisioners)}
          />
        </div>
        <div class="mt-5 flex items-center justify-end gap-2">
          <.button
            type="button"
            phx-click={JS.exec("phx-remove", to: "#new-env-modal") |> JS.push("close_env_form")}
          >
            {gettext("Cancel")}
          </.button>
          <.button type="submit" variant="primary">
            {gettext("Create on runner")}
          </.button>
        </div>
      </.form>

      <div :if={@provisioners == []} id="runner-unavailable" class="space-y-4">
        <.empty_state
          icon="bolt"
          title={gettext("No runners connected")}
          description={gettext("Connect a runner in Fin before creating a project device.")}
        >
          <:actions>
            <.button href={~p"/orgs/#{@org.slug}/fin"} variant="primary" size="sm">
              {gettext("Open Fin")}
            </.button>
          </:actions>
        </.empty_state>

        <div class="flex items-center justify-end gap-2">
          <.button
            type="button"
            phx-click={JS.exec("phx-remove", to: "#new-env-modal") |> JS.push("close_env_form")}
          >
            {gettext("Cancel")}
          </.button>
          <.button type="button" variant="secondary" phx-click="new_environment">
            {gettext("Check for runners")}
          </.button>
        </div>
      </div>
    </.modal>
    """
  end

  def env_form(params, changeset \\ nil) do
    to_form(stringify(params), as: :device, errors: form_errors(changeset))
  end

  def env_form_defaults(provisioners) do
    case provisioners do
      [provisioner | _] ->
        %{"provisioner_id" => provisioner.id}

      _ ->
        %{}
    end
  end

  def online_mac_mini_provisioners(org_id) do
    org_id
    |> Environments.list_mac_mini_provisioners()
    |> Enum.filter(&(&1.effective_status == "online"))
  end

  defp provisioner_options(provisioners) do
    Enum.map(provisioners, fn provisioner ->
      {provisioner.name || provisioner.stable_id || provisioner.id, provisioner.id}
    end)
  end

  defp form_errors(nil), do: []
  defp form_errors(%Ecto.Changeset{} = changeset), do: changeset.errors

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
