defmodule SalixWeb.Dashboard.AccountPoolLive do
  @moduledoc """
  Shared subscription UI callbacks and rendering. The Salix route uses AccountPool.
  BFT supplies an organization-authorized API and an opaque organization/user scope.
  Neither the API module nor its scope comes from browser parameters.
  """
  use SalixWeb.Dashboard, :live_view
  alias SalixAgent.AccountPool
  alias Phoenix.LiveView.JS

  @codex_icon_path Path.expand("../../../../assets/icons/providers/codex.svg", __DIR__)
  @claude_icon_path Path.expand("../../../../assets/icons/providers/claude.svg", __DIR__)
  @external_resource @codex_icon_path
  @external_resource @claude_icon_path
  @provider_icons %{
    "codex" => "data:image/svg+xml;base64," <> Base.encode64(File.read!(@codex_icon_path)),
    "claude" => "data:image/svg+xml;base64," <> Base.encode64(File.read!(@claude_icon_path))
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        account_pool_api: socket.assigns[:account_pool_api] || AccountPool,
        active_nav: :account_pool,
        page_title: "Subscription Proxy",
        breadcrumbs: [{"Subscription Proxy", nil}],
        accounts: [],
        next: "",
        cursor: "",
        busy: false,
        loaded: false,
        attempt: nil,
        dialog: nil,
        selected: nil,
        dialog_error: nil,
        page_error: nil,
        reset_request_id: nil,
        reset_notice: nil,
        provider: "codex",
        usage: nil,
        usage_next: nil,
        usage_hidden_count: 0,
        provider_defaults: %{},
        form_epoch: 0
      )
      |> allow_upload(:credentials,
        accept: ~w(.json),
        max_entries: 1,
        max_file_size: 2_097_152,
        auto_upload: true
      )

    {:ok, if(connected?(socket), do: load(socket, ""), else: socket)}
  end

  @impl true
  def handle_event("validate", params, socket),
    do:
      {:noreply,
       assign(socket, provider: params["provider"] || socket.assigns.provider, dialog_error: nil)}

  def handle_event(_event, _params, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}
  def handle_event("refresh", _, socket), do: {:noreply, load(socket, "")}
  def handle_event("next", _, socket), do: {:noreply, load(socket, socket.assigns.next)}
  def handle_event("close", _, socket), do: {:noreply, close_dialog(socket)}
  def handle_event("open-import", _, socket), do: {:noreply, open_dialog(socket, :import)}
  def handle_event("open-connect", _, socket), do: {:noreply, open_dialog(socket, :connect)}

  def handle_event("open-provider-key", _, socket),
    do: {:noreply, open_dialog(socket, :provider_key)}

  def handle_event("use-openrouter", _, socket) do
    {:noreply,
     assign(socket,
       provider_defaults: %{
         "endpoint" => "https://openrouter.ai/api",
         "protocol" => "anthropic_messages",
         "auth_scheme" => "bearer"
       }
     )}
  end

  def handle_event("save-provider-key", params, socket) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant
    selected = socket.assigns.selected

    attrs = %{
      "name" => params["name"],
      "connection" => %{
        "endpoint" => params["endpoint"],
        "protocol" => params["protocol"],
        "auth_scheme" => params["auth_scheme"]
      },
      "credentials" => %{"api_key" => params["api_key"]}
    }

    operation =
      case {socket.assigns.dialog, selected} do
        {:provider_name, %{} = account} ->
          fn ->
            api.update(
              tenant,
              account["id"],
              Map.take(params, ["name"]) |> Map.put("version", account["version"])
            )
          end

        {:provider_connection, %{} = account} ->
          fn ->
            api.update(
              tenant,
              account["id"],
              Map.put(Map.drop(attrs, ["name"]), "version", account["version"])
            )
          end

        {:provider_key, nil} ->
          fn -> api.create(tenant, Map.put(attrs, "credential_kind", "provider_api_key")) end
      end

    {:noreply,
     socket
     |> assign(form_epoch: socket.assigns.form_epoch + 1)
     |> run(:mutation, operation)}
  end

  def handle_event("usage-next", _, %{assigns: %{selected: account}} = socket)
      when is_map(account) do
    {:noreply, load_usage(socket, account, socket.assigns.usage_next)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :credentials, ref)}

  def handle_event("import", params, socket) do
    entries = socket.assigns.uploads.credentials.entries
    pasted = String.trim(params["credential_json"] || "")

    cond do
      entries != [] and pasted != "" ->
        invalid(socket, "Choose a file or paste JSON, not both.")

      Enum.any?(entries, &(!&1.done?)) ->
        invalid(socket, "Wait for the file upload to finish.")

      true ->
        contents =
          if entries == [],
            do: pasted,
            else:
              List.first(
                consume_uploaded_entries(socket, :credentials, fn %{path: path}, _ ->
                  {:ok, File.read!(path)}
                end)
              )

        case Jason.decode(contents || "") do
          {:ok, credentials} when is_map(credentials) ->
            api = socket.assigns.account_pool_api
            tenant = socket.assigns.current_tenant
            selected = socket.assigns.selected
            provider = socket.assigns.provider

            operation =
              if selected do
                fn ->
                  api.update(tenant, selected["id"], %{
                    "version" => selected["version"],
                    "credentials" => credentials
                  })
                end
              else
                fn ->
                  api.create(tenant, %{
                    "credential_kind" => "subscription_oauth",
                    "provider" => provider,
                    "credentials" => credentials
                  })
                end
              end

            {:noreply,
             socket
             |> assign(form_epoch: socket.assigns.form_epoch + 1)
             |> run(:mutation, operation)}

          _ ->
            invalid(socket, "The credentials must contain a valid JSON object.")
        end
    end
  end

  def handle_event("authorize", params, socket) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant
    selected = socket.assigns.selected

    provider =
      if selected, do: selected["provider"], else: params["provider"] || socket.assigns.provider

    attrs =
      if selected,
        do: %{
          "provider" => provider,
          "account_id" => selected["id"],
          "version" => selected["version"]
        },
        else: %{"provider" => provider}

    {:noreply,
     socket
     |> assign(provider: provider, attempt: nil)
     |> run(:oauth, fn ->
       api.begin_oauth(
         tenant,
         Map.put(attrs, "mode", if(provider == "codex", do: "device", else: "callback"))
       )
     end)}
  end

  def handle_event(
        "poll-device",
        %{"id" => id},
        %{assigns: %{attempt: %{"id" => id, "mode" => "device"}}} = socket
      ) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant

    {:noreply,
     start_async(socket, {:device_poll, id}, fn ->
       api.complete_oauth(tenant, id, %{"code" => ""})
     end)}
  end

  def handle_event("complete", params, %{assigns: %{attempt: %{"id" => id}}} = socket) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant
    attrs = %{"code" => params["code"]}

    {:noreply,
     socket
     |> assign(attempt: nil)
     |> run(:mutation, fn -> api.complete_oauth(tenant, id, attrs) end)}
  end

  def handle_event(
        "confirm-delete",
        _,
        %{assigns: %{selected: account, dialog: :delete}} = socket
      )
      when is_map(account) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant

    {:noreply,
     run(socket, :mutation, fn ->
       api.delete(tenant, account["id"], account["version"])
     end)}
  end

  def handle_event("confirm-reset", _, %{assigns: %{dialog: :reset, selected: account}} = socket) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant
    attrs = %{"version" => account["version"], "request_id" => socket.assigns.reset_request_id}
    {:noreply, run(socket, :reset, fn -> api.reset_quota(tenant, account["id"], attrs) end)}
  end

  def handle_event(
        "confirm-disable",
        _,
        %{assigns: %{dialog: :disable, selected: account}} = socket
      ) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant

    {:noreply,
     run(socket, :mutation, fn ->
       api.update(tenant, account["id"], %{
         "version" => account["version"],
         "disabled" => true
       })
     end)}
  end

  def handle_event(event, %{"id" => id}, socket)
      when event in ~w(toggle quota reauthorize replace delete reset edit-name edit-connection usage) do
    case Enum.find(socket.assigns.accounts, &(&1["id"] == id)) do
      nil ->
        {:noreply,
         assign(socket, page_error: "Refresh the list before changing this subscription.")}

      account ->
        api = socket.assigns.account_pool_api
        tenant = socket.assigns.current_tenant

        case event do
          "reset" ->
            if reset_available?(account) do
              key =
                if reset_pending?(account),
                  do: account["reset_attempt"]["request_id"],
                  else: SalixAgent.SubscriptionStore.id()

              {:noreply, socket |> open_dialog(:reset, account) |> assign(reset_request_id: key)}
            else
              {:noreply, socket}
            end

          "replace" ->
            {:noreply, open_dialog(socket, :import, account)}

          "delete" ->
            {:noreply, open_dialog(socket, :delete, account)}

          "reauthorize" ->
            {:noreply, open_dialog(socket, :connect, account)}

          "quota" ->
            {:noreply, run(socket, :mutation, fn -> api.quota(tenant, id) end)}

          "toggle" ->
            if static_account?(account) and !account["disabled"] do
              {:noreply, open_dialog(socket, :disable, account)}
            else
              {:noreply,
               run(socket, :mutation, fn ->
                 api.update(tenant, id, %{
                   "version" => account["version"],
                   "disabled" => !account["disabled"]
                 })
               end)}
            end

          "edit-name" ->
            {:noreply, open_dialog(socket, :provider_name, account)}

          "edit-connection" ->
            {:noreply, open_dialog(socket, :provider_connection, account)}

          "usage" ->
            {:noreply, socket |> open_dialog(:usage, account) |> load_usage(account, 0)}
        end
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp invalid(socket, error),
    do: {:noreply, assign(socket, dialog_error: error, form_epoch: socket.assigns.form_epoch + 1)}

  defp close_dialog(socket) do
    socket =
      Enum.reduce(
        socket.assigns.uploads.credentials.entries,
        socket,
        &cancel_upload(&2, :credentials, &1.ref)
      )

    assign(socket,
      dialog: nil,
      selected: nil,
      attempt: nil,
      dialog_error: nil,
      usage: nil,
      usage_next: nil,
      usage_hidden_count: 0,
      provider_defaults: %{}
    )
  end

  defp open_dialog(socket, kind, account \\ nil),
    do:
      socket
      |> close_dialog()
      |> assign(
        dialog: kind,
        selected: account,
        provider: (account && account["provider"]) || "codex"
      )

  defp run(socket, :mutation, fun) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant
    cursor = socket.assigns.cursor

    socket
    |> assign(busy: true, page_error: nil, dialog_error: nil)
    |> start_async(:mutation, fn ->
      with {:ok, _} <- fun.(), do: api.list(tenant, cursor)
    end)
  end

  defp run(socket, kind, fun),
    do: socket |> assign(busy: true, page_error: nil, dialog_error: nil) |> start_async(kind, fun)

  defp load_usage(socket, account, cursor) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant

    socket
    |> assign(busy: true, dialog_error: nil)
    |> start_async(:usage, fn -> api.list_bindings(tenant, account["id"], cursor || 0) end)
  end

  defp load(socket, cursor) do
    api = socket.assigns.account_pool_api
    tenant = socket.assigns.current_tenant
    socket |> assign(cursor: cursor) |> run(:list, fn -> api.list(tenant, cursor) end)
  end

  @impl true
  def handle_async(kind, {:ok, {:ok, %{"accounts" => accounts} = data}}, socket)
      when kind in [:list, :mutation] do
    socket = if kind == :mutation, do: close_dialog(socket), else: socket

    {:noreply,
     assign(socket, busy: false, loaded: true, accounts: accounts, next: data["next"] || "")}
  end

  def handle_async(:reset, {:ok, {:ok, result}}, socket) do
    account = result["account"]

    accounts =
      Enum.map(socket.assigns.accounts, fn old ->
        if old["id"] == account["id"], do: account, else: old
      end)

    notice =
      reset_message(result["outcome"]) <>
        if(result["quota_refreshed"],
          do: " Allowance refreshed.",
          else:
            " Allowance could not be refreshed. Use Refresh allowance to check it. Do not submit another reset for this result."
        )

    {:noreply,
     socket |> close_dialog() |> assign(busy: false, accounts: accounts, reset_notice: notice)}
  end

  def handle_async(:oauth, {:ok, {:ok, attempt}}, socket) do
    socket = assign(socket, busy: false, attempt: attempt)

    if attempt["mode"] == "device" do
      {:noreply,
       push_event(socket, "subscription-device-pending", %{
         id: attempt["id"],
         interval: attempt["interval"]
       })}
    else
      {:noreply, push_event(socket, "subscription-oauth-ready", %{url: attempt["url"]})}
    end
  end

  def handle_async({:device_poll, id}, result, %{assigns: %{attempt: %{"id" => id}}} = socket) do
    case result do
      {:ok, {:ok, %{"status" => "pending", "interval" => interval}}} ->
        {:noreply,
         push_event(socket, "subscription-device-pending", %{id: id, interval: interval})}

      {:ok, {:ok, _account}} ->
        {:noreply, socket |> close_dialog() |> load(socket.assigns.cursor)}

      {:ok, {:error, reason}} ->
        failed(assign(socket, attempt: nil), :oauth, reason)

      _ ->
        failed(assign(socket, attempt: nil), :oauth, :unavailable)
    end
  end

  def handle_async({:device_poll, _}, _, socket), do: {:noreply, socket}

  def handle_async(:usage, {:ok, {:ok, page}}, socket) do
    usage = (socket.assigns.usage || []) ++ (page["bindings"] || [])

    {:noreply,
     assign(socket,
       busy: false,
       usage: usage,
       usage_next: page["next"],
       usage_hidden_count:
         (socket.assigns[:usage_hidden_count] || 0) + (page["hidden_count"] || 0)
     )}
  end

  def handle_async(kind, {:ok, {:error, reason}}, socket),
    do: failed(socket, kind, reason)

  def handle_async(kind, {:exit, _}, socket),
    do: failed(socket, kind, :unavailable)

  defp failed(socket, kind, reason) do
    socket =
      if kind == :reset and reason in [:reset_pending, :unavailable] do
        selected =
          put_in(socket.assigns.selected, ["reset_attempt"], %{
            "request_id" => socket.assigns.reset_request_id,
            "outcome" => "pending"
          })

        accounts =
          Enum.map(socket.assigns.accounts, fn a ->
            if a["id"] == selected["id"], do: selected, else: a
          end)

        assign(socket, selected: selected, accounts: accounts)
      else
        socket
      end

    socket =
      if kind == :oauth, do: push_event(socket, "subscription-oauth-error", %{}), else: socket

    key = if socket.assigns.dialog, do: :dialog_error, else: :page_error
    {:noreply, socket |> assign(busy: false) |> assign(key, AccountPool.error_message(reason))}
  end

  defp reset_pending?(account), do: get_in(account, ["reset_attempt", "outcome"]) == "pending"

  defp reset_available?(account) do
    count = get_in(account, ["quota", "reset_credits", "available_count"])

    account["provider"] == "codex" and account["status"] == "active" and
      (reset_pending?(account) or (is_integer(count) and count > 0))
  end

  defp reset_count(%{"provider" => "claude"}), do: "Reset not supported"

  defp reset_count(account) do
    case get_in(account, ["quota", "reset_credits", "available_count"]) do
      count when is_integer(count) -> "Resets available: #{count}"
      _ -> "Resets available: unknown"
    end
  end

  defp reset_message("reset"),
    do: "One reset credit was used. Eligible allowance windows were reset."

  defp reset_message("already_redeemed"),
    do: "This reset already completed. No additional reset credit was used."

  defp reset_message("no_credit"), do: "No reset credits are available."
  defp reset_message("nothing_to_reset"), do: "No allowance window is eligible for a reset."

  defp identity(account), do: account["name"] || account["email"] || "Identity unavailable"

  defp subscription_plan(account) do
    case get_in(account, ["quota", "plan_type"]) do
      plan when is_binary(plan) ->
        case String.trim(plan) do
          "" -> "Plan unknown"
          value -> String.capitalize(value) <> " plan"
        end

      _ ->
        "Plan unknown"
    end
  end

  defp provider_name("codex"), do: "Codex"
  defp provider_name("claude"), do: "Claude"
  defp provider_name(_), do: "Subscription"
  defp provider_icon(provider), do: Map.get(@provider_icons, provider, "")

  defp static_account?(account), do: account["credential_kind"] == "provider_api_key"

  defp runtime_names(account) do
    account["compatible_runtimes"]
    |> List.wrap()
    |> Enum.map(&if(&1 == "pi", do: "pi", else: String.capitalize(&1)))
    |> Enum.join(", ")
  end

  defp protocol_name("anthropic_messages"), do: "Anthropic Messages"
  defp protocol_name("openai_completions"), do: "OpenAI Completions"
  defp protocol_name("openai_responses"), do: "OpenAI Responses"
  defp protocol_name(value), do: value || "Unknown"

  defp usage_path(assigns, binding) do
    with %{slug: org_slug} <- assigns[:current_org],
         project_id when is_binary(project_id) <- get_in(binding, ["project", "id"]),
         workload_id when is_binary(workload_id) <- binding["workload_id"] do
      "/orgs/#{org_slug}/projects/#{project_id}/devices?runtime_auth_target=#{URI.encode_www_form(workload_id)}"
    else
      _ -> nil
    end
  end

  defp primary_window(account) do
    all = get_in(account, ["quota", "windows"]) || []

    Enum.find(all, &(&1["period"] == "week")) ||
      Enum.find(all, &(&1["period"] == "month")) || List.first(all)
  end

  defp period("week"), do: "Weekly"
  defp period("month"), do: "Monthly"
  defp period("short"), do: "Short window"
  defp period(other), do: String.capitalize(other || "Quota")

  defp percent(n) when is_number(n),
    do:
      "#{Float.round(n * 1.0, 1) |> :erlang.float_to_binary(decimals: 1) |> String.trim_trailing(".0")}%"

  defp percent(_), do: "Unknown"
  defp bar_width(n) when is_number(n), do: max(0, min(100, n))
  defp bar_width(_), do: 0

  defp relative(value, direction) do
    case DateTime.from_iso8601(value || "") do
      {:ok, at, _} ->
        seconds = DateTime.diff(at, DateTime.utc_now())
        n = abs(seconds)

        duration =
          cond do
            n >= 86400 -> "#{div(n, 86400)}d #{div(rem(n, 86400), 3600)}h"
            n >= 3600 -> "#{div(n, 3600)}h #{div(rem(n, 3600), 60)}m"
            n >= 60 -> "#{div(n, 60)}m"
            true -> "just now"
          end

        cond do
          direction == :reset and seconds <= 0 -> "Awaiting refresh"
          direction == :reset -> "Resets in #{duration}"
          n < 60 -> "Updated just now"
          true -> "Updated #{duration} ago"
        end

      _ ->
        "Not checked yet"
    end
  end

  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:event, :string, required: true)
  attr(:account, :map, required: true)
  attr(:busy, :boolean, default: false)
  attr(:danger, :boolean, default: false)

  defp action(assigns) do
    ~H"""
    <span class="group relative inline-flex">
      <button type="button" aria-label={@label} aria-describedby={"tip-#{@account["id"]}-#{@event}"} phx-click={@event} phx-value-id={@account["id"]} disabled={@busy}
        class={["inline-flex h-8 w-8 items-center justify-center rounded-md text-neutral-600 transition-colors hover:bg-neutral-100 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-500 disabled:opacity-40", @danger && "hover:text-red-700"]}>
        <.icon name={@icon} />
      </button>
      <span id={"tip-#{@account["id"]}-#{@event}"} role="tooltip" class="pointer-events-none absolute right-0 bottom-full mb-2 hidden whitespace-nowrap rounded-md bg-neutral-800 px-2 py-1 text-xs text-white group-hover:block group-focus-within:block">{@label}</span>
    </span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold">Subscription Proxy</h1>
          <p class="mt-1 text-sm text-neutral-600">Route Agent requests through your Codex and Claude subscriptions.</p>
        </div>
        <div class="flex shrink-0 gap-2">
          <.button phx-click="open-import" disabled={@busy}><.icon name="file" /> Import</.button>
          <.button variant="primary" phx-click="open-connect" disabled={@busy}><.icon name="plus" /> Connect subscription</.button>
        </div>
      </div>
      <div :if={@page_error} role="alert" class="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">{@page_error}</div>
      <div :if={@reset_notice} role="status" class="rounded-md border border-neutral-200 bg-neutral-50 px-4 py-3 text-sm">{@reset_notice}</div>
      <.account_list {assigns} />
      <p class="text-xs text-neutral-600">Choose Subscription Proxy in a private template to use these subscriptions.</p>
      <.modal :if={@dialog} id="subscription-dialog" show scrollable on_cancel={JS.push("close")}>
        <:title>{dialog_title(@dialog, @selected)}</:title>
        <.dialog_body {assigns} />
      </.modal>
    </div>
    """
  end

  def dialog_title(:reset, _), do: "Use one reset credit"
  def dialog_title(:delete, _), do: "Remove subscription"
  def dialog_title(:connect, nil), do: "Connect subscription"
  def dialog_title(:connect, _), do: "Reauthorize subscription"
  def dialog_title(:provider_key, _), do: "Add Provider API key"
  def dialog_title(:provider_name, _), do: "Edit account name"
  def dialog_title(:provider_connection, _), do: "Edit connection"
  def dialog_title(:usage, _), do: "Account usage"
  def dialog_title(:disable, _), do: "Disable organization account"
  def dialog_title(_, nil), do: "Import credentials"
  def dialog_title(_, _), do: "Replace credentials"

  def account_list(assigns) do
    ~H"""
      <div class="rounded-lg border border-neutral-200 bg-white">
        <div class="flex items-center justify-between border-b border-neutral-200 px-4 py-3">
          <span class="text-sm font-medium">Subscriptions <span :if={@loaded} class="ml-1 text-neutral-500">{length(@accounts)} on this page</span></span>
          <button type="button" phx-click="refresh" aria-label="Refresh subscriptions" title="Refresh subscriptions" disabled={@busy} class="rounded p-1.5 text-neutral-600 hover:bg-neutral-100 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-500 disabled:opacity-40"><.icon name="refresh" /></button>
        </div>
        <div :if={!@loaded && @busy} role="status" aria-label="Loading subscriptions" class="space-y-4 p-5">
          <div :for={_ <- 1..3} class="h-10 rounded bg-neutral-100"></div>
        </div>
        <div :if={@loaded && @accounts == []} class="px-6 py-12 text-center">
          <div class="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-lg bg-neutral-100 text-neutral-600"><.icon name="plug" class="h-5 w-5" /></div>
          <h2 class="text-sm font-semibold">No subscriptions connected</h2>
          <p class="mt-2 text-sm text-neutral-600">Connect a subscription or import its credential file to start routing requests.</p>
        </div>
        <table :if={@accounts != []} class="w-full table-fixed text-left text-sm" aria-label="Connected subscriptions" aria-busy={to_string(@busy)}>
          <thead class="bg-neutral-50 text-xs text-neutral-600">
            <tr>
              <th scope="col" class="w-12 px-2 py-2.5"><span class="sr-only">Enabled</span></th>
              <th scope="col" class="px-2 py-2.5 font-medium">Account</th>
              <th scope="col" class="px-3 py-2.5 font-medium">Details</th>
              <th scope="col" class="w-36 px-2 py-2.5 text-right font-medium">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-neutral-100">
            <tr :for={account <- @accounts} id={"account-" <> account["id"]} data-disabled={to_string(account["disabled"] || false)}
              class={["align-middle", if(account["disabled"], do: "bg-neutral-100 text-neutral-500", else: "text-neutral-900 hover:bg-neutral-50/50")]}>
              <td class="py-3 pl-3 pr-1">
                <button type="button" role="switch" aria-checked={to_string(!account["disabled"])}
                  aria-label={"Enable organization account for " <> identity(account)}
                  title={if account["disabled"], do: "Enable account", else: "Disable account"}
                  phx-click="toggle" phx-value-id={account["id"]} disabled={@busy}
                  class={["relative flex h-5 w-8 items-center rounded-full transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-500 disabled:opacity-40", if(account["disabled"], do: "bg-neutral-300", else: "bg-brand-600")]}>
                  <span class={["h-4 w-4 rounded-full bg-white shadow-sm transition-transform", if(account["disabled"], do: "translate-x-0.5", else: "translate-x-3.5")]}></span>
                </button>
              </td>
              <td class="px-2 py-3">
                <div class="flex items-center gap-2">
                  <span :if={!static_account?(account)} tabindex="0" role="img" aria-label={provider_name(account["provider"])}
                    aria-describedby={"provider-tip-" <> account["id"]}
                    class="group relative inline-flex h-5 w-5 shrink-0 items-center justify-center rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-500">
                    <img src={provider_icon(account["provider"])} alt="" aria-hidden="true" width="20" height="20" class={["h-5 w-5", account["disabled"] && "grayscale opacity-50"]} />
                    <span role="tooltip" id={"provider-tip-" <> account["id"]} class="pointer-events-none absolute bottom-full left-1/2 mb-2 hidden -translate-x-1/2 whitespace-nowrap rounded-md bg-neutral-800 px-2 py-1 text-xs text-white group-hover:block group-focus:block">{provider_name(account["provider"])}</span>
                  </span>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-1">
                      <span class="min-w-0 break-all font-medium" title={account["id"]}>{identity(account)}</span>
                      <span :if={static_account?(account)} class="rounded bg-neutral-100 px-1.5 py-0.5 text-[10px] text-neutral-600">Provider API key</span>
                      <span :if={account["status"] == "reauthorization_required"} role="img" aria-label="Reauthorization required" title="Credential preparation did not finish. Reauthorize or replace credentials." class="shrink-0 text-amber-600">!</span>
                    </div>
                    <div :if={!static_account?(account)} class="mt-1 text-xs leading-4 text-neutral-500 break-words">
                      {subscription_plan(account)}
                    </div>
                  </div>
                </div>
              </td>
              <td tabindex="0" aria-describedby={"quota-tip-" <> account["id"]}
                class="group/quota relative px-3 py-3 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-500">
                <% window = if(static_account?(account), do: nil, else: primary_window(account)) %>
                <div :if={static_account?(account)} class="space-y-1 text-xs">
                  <div class="truncate font-medium" title={get_in(account, ["connection", "endpoint"])}>{get_in(account, ["connection", "endpoint"])}</div>
                  <div class="text-neutral-500">{protocol_name(get_in(account, ["connection", "protocol"]))} · {runtime_names(account)}</div>
                </div>
                <div :if={!static_account?(account)} class="flex min-h-9 flex-col justify-center gap-1">
                  <div :if={is_nil(window)} class="text-xs text-neutral-500">Not checked yet</div>
                  <div :if={window}>
                    <div class="flex items-center gap-2">
                      <div role="progressbar" aria-label={period(window["period"]) <> " quota remaining"} aria-valuemin="0" aria-valuemax="100" aria-valuenow={if is_number(window["remaining_percent"]), do: bar_width(window["remaining_percent"])}
                        class="h-1.5 min-w-0 max-w-[200px] flex-1 rounded-full bg-neutral-200">
                        <div class={["h-full rounded-full", if(account["disabled"], do: "bg-neutral-400", else: "bg-brand-600")]} style={"width: #{bar_width(window["remaining_percent"])}%"}></div>
                      </div>
                      <span class="shrink-0 text-xs font-medium tabular-nums">{percent(window["remaining_percent"])}</span>
                      <span class="hidden shrink-0 text-xs text-neutral-500 xl:inline">{period(window["period"])}</span>
                    </div>
                  </div>
                </div>
                <div :if={!static_account?(account)} class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-neutral-500">
                  <span>{reset_count(account)}</span>
                  <button :if={account["provider"] == "codex"} type="button" phx-click="reset" phx-value-id={account["id"]}
                    disabled={@busy || !reset_available?(account)} class="rounded text-brand-700 underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-500 disabled:text-neutral-400 disabled:no-underline">
                    {if reset_pending?(account), do: "Check pending reset", else: "Use one reset"}
                  </button>
                </div>
                <div :if={!static_account?(account)} role="tooltip" id={"quota-tip-" <> account["id"]}
                  class="pointer-events-none absolute bottom-full right-0 z-10 mb-1 hidden w-max max-w-xs rounded-md bg-neutral-800 px-3 py-2 text-xs text-white shadow-sm group-hover/quota:block group-focus/quota:block">
                  <div :if={is_nil(window)}>Quota has not been checked yet.</div>
                  <div :if={window}>
                    <div>{relative(window["reset_at"], :reset)}</div>
                  </div>
                  <div :if={account["quota"]} class="mt-1 text-neutral-300">{relative(account["quota"]["observed_at"], :observed)}</div>
                </div>
              </td>
              <td class="px-2 py-3">
                <div :if={!static_account?(account)} class="flex flex-nowrap justify-end">
                  <.action label="Refresh allowance" icon="refresh" event="quota" account={account} busy={@busy} />
                  <.action label="Reauthorize" icon="key" event="reauthorize" account={account} busy={@busy} />
                  <.action label="Replace credentials" icon="file" event="replace" account={account} busy={@busy} />
                  <.action label="Remove subscription" icon="trash" event="delete" account={account} busy={@busy} danger />
                </div>
                <div :if={static_account?(account)} class="flex flex-nowrap justify-end">
                  <.action label="View usage" icon="eye" event="usage" account={account} busy={@busy} />
                  <.action label="Edit name" icon="pencil" event="edit-name" account={account} busy={@busy} />
                  <.action label="Edit connection" icon="key" event="edit-connection" account={account} busy={@busy} />
                  <.action label="Delete account" icon="trash" event="delete" account={account} busy={@busy} danger />
                </div>
              </td>
            </tr>
          </tbody>
        </table>
        <div :if={@cursor != "" || @next != ""} class="flex justify-end gap-2 border-t border-neutral-200 px-4 py-3">
          <.button :if={@cursor != ""} phx-click="refresh" disabled={@busy}>First page</.button>
          <.button :if={@next != ""} phx-click="next" disabled={@busy}>Next page</.button>
        </div>
      </div>
    """
  end

  def dialog_body(assigns) do
    ~H"""
        <p :if={@selected} class="mb-4 break-all text-sm text-neutral-600">{identity(@selected)}</p>
        <div :if={@dialog_error} role="alert" class="mb-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">{@dialog_error}</div>
        <form :if={@dialog == :import} id={"import-#{@form_epoch}"} phx-submit="import" phx-change="validate" class="space-y-4">
          <.select :if={!@selected} id="subscription-provider" name="provider" label="Provider" value={@provider} options={[{"Codex", "codex"}, {"Claude", "claude"}]} disabled={@busy} />
          <label phx-drop-target={@uploads.credentials.ref} for={@uploads.credentials.ref} class="block cursor-pointer rounded-lg border border-dashed border-neutral-300 bg-neutral-50 p-6 text-center hover:border-brand-500 focus-within:outline focus-within:outline-2 focus-within:outline-brand-500">
            <.icon name="file" class="mx-auto mb-2 h-6 w-6 text-neutral-600" />
            <span class="block text-sm font-medium">Drop a credential file here</span>
            <span class="mt-1 block text-xs text-neutral-600">or click to choose a JSON file, up to 2 MB</span>
            <.live_file_input upload={@uploads.credentials} class="sr-only" disabled={@busy} />
          </label>
          <div :for={entry <- @uploads.credentials.entries} class="flex items-center justify-between gap-2 rounded-md bg-neutral-50 px-3 py-2 text-sm">
            <span class="truncate">{entry.client_name} <span class="text-neutral-600">{entry.progress}%</span></span>
            <button type="button" aria-label="Remove selected file" phx-click="cancel-upload" phx-value-ref={entry.ref} disabled={@busy}><.icon name="x-mark" /></button>
          </div>
          <p :for={error <- upload_errors(@uploads.credentials)} role="alert" class="text-sm text-red-700">{upload_error(error)}</p>
          <p :for={entry <- @uploads.credentials.entries} :if={upload_errors(@uploads.credentials, entry) != []} role="alert" class="text-sm text-red-700">The file must be JSON and no larger than 2 MB.</p>
          <.textarea id="subscription-credentials" name="credential_json" label="Or paste credential JSON" value="" rows="5" disabled={@busy} />
          <p class="text-xs text-neutral-600">Your login identity is read from the credentials. Secrets are encrypted and never shown again.</p>
          <div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button type="submit" variant="primary" disabled={@busy}>{if @busy, do: "Importing…", else: if(@selected, do: "Replace credentials", else: "Import subscription")}</.button></div>
        </form>
        <div :if={@dialog == :connect} id="subscription-oauth" phx-hook="SubscriptionOAuth" data-device-attempt={@attempt && @attempt["mode"] == "device" && @attempt["id"]} data-device-interval={@attempt && @attempt["interval"]}>
          <form :if={!@attempt} id="authorize" phx-submit="authorize" phx-change="validate" class="space-y-4">
            <.select :if={!@selected} id="subscription-provider" name="provider" label="Provider" value={@provider} options={[{"Codex", "codex"}, {"Claude", "claude"}]} disabled={@busy} />
            <p class="text-sm text-neutral-600">{if @provider == "codex", do: "Open the authorization page and enter the device code. Your account is added automatically.", else: "Sign in with your subscription, then paste the callback URL here. The link is valid for 15 minutes."}</p>
            <div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button type="submit" variant="primary" disabled={@busy}>{if @busy, do: "Preparing…", else: "Continue with #{provider_name(@provider)}"}</.button></div>
          </form>
          <div :if={@attempt} class="space-y-4">
            <.button href={@attempt["url"]} target="_blank" rel="noopener noreferrer" variant="primary">Open {provider_name(@provider)} authorization</.button>
            <p :if={@attempt["mode"] != "device"} class="text-sm text-neutral-600">If the authorization tab did not open, use the link above. Approve access, then copy the full callback URL even if the localhost page cannot load.</p>
            <div :if={@attempt["mode"] == "device"} class="space-y-3">
              <.input id="subscription-device-code" label="Device code" value={@attempt["user_code"]} readonly />
              <p role="status">Enter this code on the authorization page. Waiting for authorization. The code expires in 15 minutes.</p>
              <.button phx-click="close">Cancel</.button>
            </div>
            <form :if={@attempt["mode"] != "device"} id={"complete-" <> @attempt["id"]} phx-submit="complete" class="space-y-4">
              <.textarea id="subscription-code" name="code" label="Callback URL or authorization code" value="" rows="3" required disabled={@busy} />
              <div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button type="submit" variant="primary" disabled={@busy}>Connect subscription</.button></div>
            </form>
          </div>
        </div>
        <form :if={@dialog in [:provider_key, :provider_name, :provider_connection]} id={"provider-key-#{@form_epoch}"} phx-submit="save-provider-key" class="space-y-4">
          <.input :if={@dialog in [:provider_key, :provider_name]} id="provider-account-name" name="name" label="Name" value={(@selected && @selected["name"]) || ""} required disabled={@busy} />
          <div :if={@dialog in [:provider_key, :provider_connection]} class="space-y-4">
            <.button :if={@dialog == :provider_key} type="button" size="sm" phx-click="use-openrouter" disabled={@busy}>Use OpenRouter settings</.button>
            <.input id="provider-endpoint" name="endpoint" type="url" label="HTTPS endpoint" value={get_in(@selected || %{}, ["connection", "endpoint"]) || @provider_defaults["endpoint"] || ""} required disabled={@busy} />
            <.select id="provider-protocol" name="protocol" label="Protocol" value={get_in(@selected || %{}, ["connection", "protocol"]) || @provider_defaults["protocol"] || "anthropic_messages"} options={[{"Anthropic Messages", "anthropic_messages"}, {"OpenAI Responses", "openai_responses"}, {"OpenAI Completions", "openai_completions"}]} disabled={@busy} />
            <.select id="provider-auth-scheme" name="auth_scheme" label="Authentication" value={get_in(@selected || %{}, ["connection", "auth_scheme"]) || @provider_defaults["auth_scheme"] || "bearer"} options={[{"Bearer token", "bearer"}, {"API key header", "api_key"}]} disabled={@busy} />
            <.input id="provider-api-key" name="api_key" type="password" label="Provider API key" value="" required autocomplete="new-password" disabled={@busy} />
            <p class="text-xs text-neutral-600">The key is stored for this organization and sent to bound runtimes. Saving does not verify the provider.</p>
          </div>
          <div class="flex justify-end gap-2"><.button type="button" phx-click="close" disabled={@busy}>Cancel</.button><.button type="submit" variant="primary" disabled={@busy}>{if @busy, do: "Saving…", else: "Save"}</.button></div>
        </form>
        <div :if={@dialog == :usage} class="space-y-4">
          <p :if={is_nil(@usage)} role="status" class="text-sm text-neutral-600">Loading usage…</p>
          <p :if={@usage == [] && @usage_hidden_count == 0} class="text-sm text-neutral-600">No workloads use this account.</p>
          <ul :if={is_list(@usage) && @usage != []} class="divide-y divide-neutral-100 rounded-md border border-neutral-200">
            <li :for={binding <- @usage} class="px-3 py-2 text-sm">
              <a :if={usage_path(assigns, binding)} href={usage_path(assigns, binding)} class="font-medium text-brand-700 underline">{get_in(binding, ["project", "name"])}</a>
              <div :if={!usage_path(assigns, binding)} class="font-medium">{get_in(binding, ["project", "name"])}</div>
              <div class="text-xs text-neutral-500">Workload {binding["workload_id"]}</div>
            </li>
          </ul>
          <p :if={@usage_hidden_count > 0} class="text-sm text-neutral-600">Other projects still use this account.</p>
          <div class="flex justify-end gap-2">
            <.button :if={@usage_next} type="button" phx-click="usage-next" disabled={@busy}>Next page</.button>
            <.button type="button" phx-click="close" disabled={@busy}>Close</.button>
          </div>
        </div>
        <div :if={@dialog == :reset} class="space-y-4">
          <p class="text-sm text-neutral-600">{reset_count(@selected)}. This uses one existing Codex reset credit to reset eligible allowance windows. It does not purchase credits.</p>
          <p :if={reset_pending?(@selected)} class="text-sm text-amber-700">The previous result is not confirmed. This checks the same request and does not request a second reset.</p>
          <div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button variant="primary" phx-click="confirm-reset" disabled={@busy}>{if reset_pending?(@selected), do: "Check same reset", else: "Use one reset credit"}</.button></div>
        </div>
        <div :if={@dialog == :disable} class="space-y-4">
          <p class="text-sm text-neutral-600">Disabling stops new credential delivery and starts removal from connected runtimes. Offline runtimes can still hold the key. Revoke the key at the Provider when immediate revocation is required.</p>
          <div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button variant="danger" phx-click="confirm-disable" disabled={@busy}>Disable account</.button></div>
        </div>
        <div :if={@dialog == :delete} class="space-y-4">
          <p class="text-sm text-neutral-600">{if static_account?(@selected), do: "Delete this account? Bound workloads must be removed first.", else: "Remove this subscription from the proxy? Your provider subscription stays active."}</p>
          <div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button variant="danger" phx-click="confirm-delete" disabled={@busy}>{if static_account?(@selected), do: "Delete account", else: "Remove subscription"}</.button></div>
        </div>
    """
  end

  defp upload_error(:too_many_files), do: "Choose one credential file at a time."
  defp upload_error(_), do: "Choose a JSON file no larger than 2 MB."
end
