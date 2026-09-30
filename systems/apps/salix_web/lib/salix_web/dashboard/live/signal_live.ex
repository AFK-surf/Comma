defmodule SalixWeb.Dashboard.SignalLive do
  @moduledoc """
  Operator page for Signal (docs/messaging-voice.md): the platform Signal
  number that every tenant uses unless it sets its own, and the registered
  Signal accounts. This page chooses among registered, active accounts; a
  new number is registered on `/dash/signal/register`
  (`SalixWeb.Dashboard.SignalRegisterLive`), linked from the account table.
  Tenant numbers are set on each tenant's page.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixSignal.Settings

  @page_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_nav: :signal, page_title: "Signal", breadcrumbs: [{"Signal", nil}])
     |> load()}
  end

  defp load(socket) do
    platform =
      case Settings.platform() do
        {:ok, platform} -> platform
        {:error, _reason} -> nil
      end

    accounts =
      try do
        SalixSignal.Accounts.list(limit: @page_limit)
      rescue
        _error -> :unavailable
      end

    assign(socket, platform: platform, accounts: accounts)
  end

  @impl true
  def handle_event("save", %{"number" => number}, socket) do
    case Salix.Control.Signal.put_platform_settings(%{"number" => number}) do
      {:ok, _settings} ->
        {:noreply, socket |> put_flash(:info, "Platform Signal number saved.") |> load()}

      {:error, reason} ->
        {_status, error} = Salix.Control.Signal.http_error(reason)
        {:noreply, put_flash(socket, :error, "Not saved: #{error}")}
    end
  end

  defp scope(:platform), do: "platform"
  defp scope({:organization, id}), do: "tenant #{id}"
  defp scope(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl space-y-6">
      <div>
        <h1 class="text-xl font-semibold">Signal</h1>
        <p class="mt-1 text-sm text-neutral-500">
          The platform Signal number serves every tenant that has no number of its own.
          Set a tenant's own number on its tenant page.
        </p>
      </div>

      <.card>
        <:title>Platform number</:title>
        <:actions>
          <.badge color={if (@platform || %{})["state"] == "active", do: "green", else: "neutral"}>
            {(@platform || %{})["state"] || "not set"}
          </.badge>
        </:actions>
        <form id="signal-platform-number" phx-submit="save" class="flex items-end gap-2">
          <.input
            name="number"
            label="Platform Signal number (E.164, blank to clear)"
            value={(@platform || %{})["e164"]}
            class="w-64"
          />
          <.button type="submit" variant="primary">Save</.button>
        </form>
      </.card>

      <.card>
        <:title>Registered accounts</:title>
        <:actions>
          <.button id="signal-register-link" size="sm" navigate="/dash/signal/register">
            Register a number
          </.button>
        </:actions>
        <p :if={@accounts == :unavailable} class="text-xs text-red-700">Accounts are unavailable.</p>
        <.table :if={is_list(@accounts) and @accounts != []} id="signal-accounts" rows={@accounts}>
          <:col :let={a} label="Number"><span class="font-mono">{a.e164}</span></:col>
          <:col :let={a} label="State">{a.state}</:col>
          <:col :let={a} label="Owner">{scope(a.scope)}</:col>
          <:col :let={a} label="Environment">{a.environment}</:col>
        </.table>
        <.empty_state :if={@accounts == []} icon="chat" title="No registered Signal accounts" />
      </.card>
    </div>
    """
  end
end
