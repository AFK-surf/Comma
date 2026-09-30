defmodule SalixWeb.Dashboard.SlackCommandTemplatesLive do
  @moduledoc "Admin-only tenant command templates; saves never modify Apps or call Slack."
  use SalixWeb.Dashboard, :live_view
  alias SalixIM.{SlackCommandTemplates, SlackCommandSync}

  @blank %{
    "command" => "",
    "description" => "",
    "usage_hint" => "",
    "prompt" => "",
    "enabled" => true
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, catalog} = SlackCommandTemplates.get(socket.assigns.current_tenant)

    {:ok,
     assign(socket,
       active_nav: :im,
       page_title: "Slack command templates",
       breadcrumbs: [{"IM", "/dash/im"}, {"Command templates", nil}],
       catalog: catalog,
       built_ins: SlackCommandTemplates.built_ins(),
       draft_epoch: 0,
       editing: nil,
       entry: @blank,
       busy: false
     )}
  end

  @impl true
  def handle_event(_, _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("use-builtin", %{"command" => command}, socket) do
    case Enum.find(SlackCommandTemplates.built_ins(), &(&1["command"] == command)) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         assign(socket, editing: nil, entry: entry, draft_epoch: socket.assigns.draft_epoch + 1)}
    end
  end

  def handle_event("edit", %{"command" => command}, socket) do
    case Enum.find(socket.assigns.catalog["commands"], &(&1["command"] == command)) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         assign(socket,
           editing: command,
           entry: entry,
           draft_epoch: socket.assigns.draft_epoch + 1
         )}
    end
  end

  def handle_event("new", _, socket),
    do:
      {:noreply,
       assign(socket, editing: nil, entry: @blank, draft_epoch: socket.assigns.draft_epoch + 1)}

  def handle_event("reload", _, socket) do
    {:ok, catalog} = SlackCommandTemplates.get(socket.assigns.current_tenant)

    {:noreply,
     assign(socket,
       catalog: catalog,
       editing: nil,
       entry: @blank,
       draft_epoch: socket.assigns.draft_epoch + 1
     )}
  end

  def handle_event("save", %{"entry" => params}, socket) do
    entry =
      Map.take(params, ~w(command description usage_hint prompt))
      |> Map.put("enabled", params["enabled"] == "true")

    entries =
      Enum.reject(socket.assigns.catalog["commands"], &(&1["command"] == socket.assigns.editing))

    save(assign(socket, entry: entry), entries ++ [entry])
  end

  def handle_event("set-enabled", %{"command" => command, "enabled" => enabled}, socket)
      when enabled in ["true", "false"] do
    entries = socket.assigns.catalog["commands"]

    updated =
      Enum.map(entries, fn entry ->
        if entry["command"] == command,
          do: Map.put(entry, "enabled", enabled == "true"),
          else: entry
      end)

    if updated == entries, do: {:noreply, socket}, else: save(socket, updated)
  end

  def handle_event("delete", %{"command" => command}, socket) do
    save(socket, Enum.reject(socket.assigns.catalog["commands"], &(&1["command"] == command)))
  end

  defp save(socket, entries) do
    %{current_tenant: tenant, catalog: catalog} = socket.assigns

    {:noreply,
     socket
     |> assign(busy: true)
     |> start_async(:save, fn ->
       SlackCommandTemplates.save(tenant, catalog["revision"], entries)
     end)}
  end

  @impl true
  def handle_async(:save, {:ok, {:ok, catalog}}, socket) do
    {:noreply,
     socket
     |> assign(
       busy: false,
       catalog: catalog,
       editing: nil,
       entry: @blank,
       draft_epoch: socket.assigns.draft_epoch + 1
     )
     |> put_flash(:info, "Template catalog saved. Existing App commands are unchanged.")}
  end

  def handle_async(:save, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket |> assign(busy: false) |> put_flash(:error, SlackCommandSync.error_text(reason))}
  end

  def handle_async(:save, _, socket) do
    {:noreply,
     socket
     |> assign(busy: false)
     |> put_flash(:error, "Save interrupted. Reload the catalog before retrying.")}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :has_draft, assigns.entry != @blank)

    ~H"""
    <div id="template-editor" phx-hook="CommandDraft" data-epoch={@draft_epoch} data-busy={to_string(@busy)} data-draft={to_string(@has_draft)} class="space-y-6">
      <div>
        <h1 class="text-xl font-semibold">Organization templates</h1>
        <p class="text-sm font-medium">Organization: {SalixWeb.Dashboard.SlackCommandScope.label(@tenants, @current_tenant)} · {@current_tenant}</p>
        <.link navigate="/dash/slack-commands" class="text-brand-600">App commands</.link>
        <p class="text-sm text-neutral-500">Shared within the selected organization only. Apps explicitly copy templates; there is no inheritance.</p>
        <p class="text-sm">Editing or deleting a template does not change commands already copied to Apps. Saving templates never updates Slack.</p>
        <.link navigate="/dash/im" class="text-brand-600">Back to IM</.link>
      </div>
      <.card>
        <:title>Built-in template library</:title>
        <p>Read-only system presets, separate from your saved organization templates. Copy to customize.</p>
        <div :for={entry <- @built_ins} class="flex items-center justify-between gap-3 py-2">
          <span>{entry["command"]} — {entry["description"]}</span>
          <.button phx-click="use-builtin" phx-value-command={entry["command"]} disabled={@busy or Enum.any?(@catalog["commands"], &(&1["command"] == entry["command"]))}>Copy to organization draft</.button>
        </div>
      </.card>
      <.button phx-click="reload" disabled={@busy} data-confirm="Reload the catalog and discard your unsaved draft?">Reload catalog</.button>
      <.table :if={@catalog["commands"] != []} id="slack-template-list" rows={@catalog["commands"]}>
        <:col :let={entry} label="Command">{entry["command"]}</:col>
        <:col :let={entry} label="Description">{entry["description"]}</:col>
        <:col :let={entry} label="When copied">{if entry["enabled"], do: "Enabled", else: "Disabled"}</:col>
        <:action :let={entry}>
          <.button size="sm" phx-click="set-enabled" phx-value-command={entry["command"]}
            phx-value-enabled={if entry["enabled"], do: "false", else: "true"}
            aria-label={"#{if entry["enabled"], do: "Disable", else: "Enable"} template default #{entry["command"]}"}
            disabled={@busy}>{if entry["enabled"], do: "Disable", else: "Enable"}</.button>
          <.button size="sm" phx-click="edit" phx-value-command={entry["command"]} disabled={@busy}>Edit</.button>
          <.button size="sm" variant="danger" phx-click="delete" phx-value-command={entry["command"]}
            disabled={@busy} data-confirm="Delete this shared template? Existing App commands will not change.">Delete</.button>
        </:action>
      </.table>
      <.empty_state :if={@catalog["commands"] == []} title="No command templates" icon="chat" />
      <.card>
        <:title>{if @editing, do: "Edit template #{@editing}", else: "New command template"}</:title>
        <form id="slack-template-form" phx-submit="save" class="space-y-3">
          <fieldset disabled={@busy} class="space-y-3">
          <.input name="entry[command]" label="Command" value={@entry["command"]} placeholder="/review" required />
          <.input name="entry[description]" label="Slack menu description" value={@entry["description"]} required />
          <.input name="entry[usage_hint]" label="Usage hint" value={@entry["usage_hint"]} />
          <.textarea name="entry[prompt]" label="Prompt prefix" value={@entry["prompt"]} rows="5" required />
          <p class="text-sm text-neutral-500">User text follows this prefix exactly. Include a trailing space or newline. This is not a system instruction.</p>
          <input type="hidden" name="entry[enabled]" value="false" />
          <label class="flex items-center gap-2">
            <input type="checkbox" name="entry[enabled]" value="true" checked={@entry["enabled"]} /> Enabled by default when copied
          </label>
          <.button type="submit" variant="primary" disabled={@busy}>Save template</.button>
          <.button type="button" phx-click="new" disabled={@busy}>New / cancel edit</.button>
        </fieldset>
        </form>
      </.card>
    </div>
    """
  end
end
