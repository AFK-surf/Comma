defmodule SalixWeb.Dashboard.M2squareSettingsLive do
  @moduledoc "Platform controls for new M2square checkouts."
  use SalixWeb.Dashboard, :live_view

  alias BridgeForTeams.M2square.Config
  alias Salix.Control.M2squareSettings

  @payment_labels %{
    "NET_BANKING" => "Online banking (NET_BANKING)",
    "TD" => "Debit card (TD)",
    "TC" => "Credit card (TC)",
    "CASH" => "Cash (CASH)",
    "PIX" => "Pix (PIX)"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :m2square_settings,
       page_title: "M2square billing",
       breadcrumbs: [{"M2square billing", nil}],
       catalog: Config.catalog(),
       countries: %{},
       etag: M2squareSettings.unconfigured_etag(),
       configured?: false,
       errors: %{},
       page_error: nil
     )
     |> load()}
  end

  @impl true
  def handle_event("retry", _, socket), do: {:noreply, load(socket)}

  def handle_event(event, _, %{assigns: %{page_error: error}} = socket)
      when event in ["change", "save"] and not is_nil(error),
      do: {:noreply, socket}

  def handle_event("change", params, socket) do
    countries = countries_input(params)

    errors =
      Map.reject(socket.assigns.errors, fn {code, error} ->
        error == :payment_types_required_when_enabled and
          row_corrected?(countries, code, socket.assigns.catalog)
      end)

    {:noreply, assign(socket, countries: draft(countries), errors: errors)}
  end

  def handle_event("save", params, socket) do
    countries = countries_input(params)
    socket = clear_flash(socket)

    case M2squareSettings.put(countries, params["expected_etag"]) do
      {:ok, {:saved, saved, etag}} ->
        {:noreply, saved_state(socket, saved, etag, "M2square settings saved.")}

      {:ok, {:already_applied, saved, etag}} ->
        {:noreply,
         saved_state(socket, saved, etag, "Current settings already match your changes.")}

      {:error, {:validation, errors}} ->
        {:noreply, assign(socket, countries: draft(countries), errors: errors)}

      {:error, :conflict} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(
           :error,
           "Someone else saved first. Review the current settings, then retry."
         )}

      {:error, {:conflict_settled, state}} ->
        {:noreply,
         socket
         |> assign_state(state)
         |> put_flash(
           :error,
           "Save could not be confirmed and live settings differ. Review the current settings below before retrying."
         )}

      {:error, {:unconfigured_after_ambiguous, state}} ->
        {:noreply,
         socket
         |> assign_state(%{state | countries: draft(countries)})
         |> put_flash(
           :error,
           "Currently unconfigured (all currencies remain disabled); the record was not saved. Retry Save to persist this configuration."
         )}

      {:error, :ambiguous_unconfirmed} ->
        {:noreply,
         assign(socket,
           page_error:
             "Save status is pending confirmation due to a storage error. Click Retry to load current settings before making further edits."
         )}

      {:error, :invalid_etag} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(
           :error,
           "The settings version was invalid. Review the current settings and retry."
         )}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(countries: draft(countries))
         |> put_flash(:error, "Could not save M2square settings. Try again.")}
    end
  end

  defp load(socket) do
    case M2squareSettings.get_for_admin() do
      {:ok, state} ->
        assign_state(socket, state)

      {:error, _} ->
        assign(socket, page_error: "M2square settings are unavailable. Click Retry to load them.")
    end
  end

  defp saved_state(socket, countries, etag, message) do
    socket
    |> assign_state(%{configured?: true, countries: countries, etag: etag})
    |> put_flash(:info, message)
  end

  defp assign_state(socket, state) do
    assign(socket,
      configured?: state.configured?,
      countries: state.countries,
      etag: state.etag,
      errors: %{},
      page_error: nil
    )
  end

  defp countries_input(%{"countries" => %{} = countries}) do
    Map.new(countries, fn
      {code, %{} = country} ->
        country =
          country
          |> Map.update("enabled", nil, fn
            "true" -> true
            "false" -> false
            value -> value
          end)
          |> Map.put_new("payment_types", [])

        {code, country}

      entry ->
        entry
    end)
  end

  defp countries_input(_), do: nil
  defp draft(countries), do: countries || %{}

  defp row_corrected?(countries, code, catalog) do
    entry = row(draft(countries), code)
    currency = Enum.find(catalog, &(&1.code == code))
    types = payment_types(entry)

    entry["enabled"] == false or
      (types != [] and Enum.all?(types, &(&1 in currency.supported_payment_types)))
  end

  defp row(countries, code) do
    case countries[code] do
      %{} = entry -> entry
      _ -> %{}
    end
  end

  defp payment_types(%{"payment_types" => types}) when is_list(types), do: types
  defp payment_types(_), do: []

  defp error_text(:payment_types_required_when_enabled),
    do: "Select at least one payment method before enabling this currency."

  defp error_text(_), do: "Check the currency switch and selected payment methods."

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :payment_labels, @payment_labels)

    ~H"""
    <div class="mx-auto max-w-4xl space-y-6">
      <header class="space-y-2">
        <h1 class="text-2xl font-semibold tracking-tight">M2square billing</h1>
        <p class="text-sm text-neutral-600">
          All currencies are off by default. Merchant credentials are managed in the deployment configuration.
        </p>
        <p class="text-sm text-neutral-600">
          Turning off a currency or payment method prevents new checkouts. Callbacks, reconciliation and reversals still apply to existing orders.
        </p>
        <p :if={!@page_error} id="m2square-settings-status" class="inline-block rounded-md bg-neutral-100 px-2 py-1 text-xs font-medium text-neutral-700">
          {if @configured?, do: "Configured", else: "Unconfigured (all disabled)"}
        </p>
      </header>

      <div :if={@page_error} class="space-y-3 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm">
        <p role="alert">{@page_error}</p>
        <.button type="button" phx-click="retry">Retry</.button>
      </div>

      <form :if={!@page_error} id="m2square-settings-form" phx-change="change" phx-submit="save" class="space-y-4">
        <input type="hidden" name="expected_etag" value={@etag} />
        <.error :for={{code, _} <- @errors} :if={code not in Config.country_order()}>
          Submit settings for all four supported currencies.
        </.error>

        <div class="divide-y divide-neutral-200 rounded-xl border border-neutral-200 bg-white px-4 sm:px-5">
          <section
            :for={currency <- @catalog}
            id={"m2square-country-" <> currency.code}
            class="grid grid-cols-1 gap-3 py-4 md:grid-cols-[12rem_1fr] md:gap-6"
          >
            <div class="space-y-2">
              <div>
                <h2 class="text-sm font-semibold text-neutral-900">{currency.gateway_currency} — {currency.name_en}</h2>
                <p :if={currency.display_currency != currency.gateway_currency} class="text-xs text-neutral-500">
                  Displays {currency.display_currency}
                </p>
              </div>
              <input type="hidden" name={"countries[#{currency.code}][enabled]"} value="false" />
              <.toggle
                id={"m2square-enabled-" <> currency.code}
                name={"countries[#{currency.code}][enabled]"}
                value="true"
                checked={row(@countries, currency.code)["enabled"] == true}
                label="Enabled"
              />
            </div>

            <fieldset class="min-w-0">
              <legend class="mb-2 text-sm font-medium text-neutral-600">Payment methods</legend>
              <div class="grid grid-cols-1 gap-x-3 gap-y-2 sm:grid-cols-2">
                <label :for={method <- currency.supported_payment_types} class="flex items-start gap-2 text-sm text-neutral-700">
                  <input
                    id={"m2square-method-#{currency.code}-#{method}"}
                    type="checkbox"
                    name={"countries[#{currency.code}][payment_types][]"}
                    value={method}
                    checked={method in payment_types(row(@countries, currency.code))}
                    aria-invalid={if @errors[currency.code], do: "true"}
                    aria-describedby={if @errors[currency.code], do: "m2square-error-" <> currency.code}
                    class="h-5 w-3.5 shrink-0"
                  />
                  <span>{@payment_labels[method]}</span>
                </label>
              </div>

              <p :if={currency.code == "EC"} class="mt-2 text-xs text-neutral-500">
                Passport (PAS) requires online banking (NET_BANKING).
              </p>
              <div :if={@errors[currency.code]} id={"m2square-error-" <> currency.code} role="alert">
                <.error>{error_text(@errors[currency.code])}</.error>
              </div>
            </fieldset>
          </section>
        </div>

        <.button type="submit" variant="primary">Save</.button>
      </form>
    </div>
    """
  end
end
