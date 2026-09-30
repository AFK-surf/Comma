defmodule SalixWeb.Dashboard.SlackCommandsLive do
  @moduledoc "Admin-only command aliases and manifest synchronization for one Slack App."
  use SalixWeb.Dashboard, :live_view

  alias SalixIM.{SlackCommands, SlackCommandSync, SlackCommandTemplates}

  @blank %{
    "command" => "",
    "description" => "",
    "usage_hint" => "",
    "prompt" => "",
    "enabled" => true
  }

  @impl true
  def mount(params, _session, socket) do
    apps = SalixWeb.Dashboard.SlackCommandScope.apps(socket.assigns.current_tenant)

    selected =
      case params do
        %{"id" => group, "connect_id" => connect} ->
          %{"group_id" => group, "connect_id" => connect}

        _ ->
          if length(apps) == 1, do: hd(apps), else: %{}
      end

    group_id = selected["group_id"]
    connect_id = selected["connect_id"]

    socket =
      assign(socket,
        apps: apps,
        app: nil,
        dialog: nil,
        draft_dirty: false,
        return_to_editor: false,
        mutation_error: nil,
        sample: "Review this pull request",
        group_id: group_id,
        connect_id: connect_id,
        active_nav: :im,
        page_title: "Slack commands",
        busy: false,
        credential_epoch: 0,
        draft_epoch: 0,
        built_ins: SlackCommandTemplates.built_ins(),
        editing: nil,
        entry: @blank,
        breadcrumbs: [{"IM", "/dash/im"}, {"Slack commands", nil}]
      )

    case load(socket) do
      {:ok, socket} ->
        {:ok, socket}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Slack App not found in this tenant.")
         |> push_navigate(to: "/dash/im")}
    end
  end

  defp load(%{assigns: %{connect_id: nil}} = socket), do: {:ok, socket}

  defp load(socket) do
    with {:ok, templates} <- SlackCommandTemplates.get(socket.assigns.current_tenant),
         {:ok, app} <-
           SlackCommands.get(
             socket.assigns.current_tenant,
             socket.assigns.group_id,
             socket.assigns.connect_id
           ) do
      {:ok,
       assign(socket,
         profile_apps:
           SalixWeb.Dashboard.SlackCommandScope.profile_apps(socket.assigns.current_tenant),
         app: app,
         templates: templates,
         config: app["configuration"],
         credential_configured:
           SlackCommandSync.credential_configured?(
             socket.assigns.current_tenant,
             app["configuration"]["credential_profile"] || "default"
           ),
         credential_profiles:
           case SalixStore.SlackCommandControl.profiles(socket.assigns.current_tenant) do
             {:ok, names} -> Enum.uniq(["default" | names])
             _ -> ["default"]
           end
       )}
    end
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("select-app", _, %{assigns: %{dialog: dialog}} = socket)
      when not is_nil(dialog), do: {:noreply, socket}

  def handle_event("select-app", %{"connect_id" => id}, socket) do
    case Enum.find(socket.assigns.apps, &(&1["connect_id"] == id)) do
      nil ->
        {:noreply, socket}

      app ->
        {:noreply,
         push_navigate(socket, to: "/dash/groups/#{app["group_id"]}/slack/#{id}/commands")}
    end
  end

  def handle_event(_, _, %{assigns: %{app: nil}} = socket), do: {:noreply, socket}

  def handle_event("custom", _, socket), do: {:noreply, assign(socket, dialog: :edit)}

  def handle_event("open-credentials", _, socket),
    do:
      {:noreply,
       assign(socket, dialog: :credentials, return_to_editor: socket.assigns.dialog == :edit)}

  def handle_event("back-editor", _, socket), do: {:noreply, assign(socket, dialog: :edit)}

  def handle_event("cancel", _, socket),
    do:
      {:noreply,
       assign(socket,
         dialog: nil,
         draft_dirty: false,
         editing: nil,
         entry: @blank,
         draft_epoch: socket.assigns.draft_epoch + 1
       )}

  def handle_event("preview", %{"entry" => params} = all, socket) do
    {:noreply,
     assign(socket,
       draft_dirty: true,
       entry: parse_entry(params),
       sample: all["sample"] || socket.assigns.sample
     )}
  end

  def handle_event("separator", _, socket) do
    entry = Map.update!(socket.assigns.entry, "prompt", &(&1 <> "\n"))
    {:noreply, assign(socket, entry: entry, draft_dirty: true)}
  end

  def handle_event("edit", %{"command" => command}, socket) do
    case Enum.find(socket.assigns.config["commands"], &(&1["command"] == command)) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         assign(socket,
           dialog: :edit,
           mutation_error: nil,
           draft_dirty: false,
           editing: command,
           entry: entry,
           draft_epoch: socket.assigns.draft_epoch + 1
         )}
    end
  end

  def handle_event("new", _, socket),
    do:
      {:noreply,
       assign(socket,
         dialog: :choose,
         mutation_error: nil,
         draft_dirty: false,
         editing: nil,
         entry: @blank,
         draft_epoch: socket.assigns.draft_epoch + 1
       )}

  def handle_event("save", %{"entry" => params}, socket) do
    entry = parse_entry(params)

    entries =
      Enum.reject(socket.assigns.config["commands"], &(&1["command"] == socket.assigns.editing))

    save(assign(socket, entry: entry), entries ++ [entry])
  end

  def handle_event("delete", %{"command" => command}, socket) do
    save(socket, Enum.reject(socket.assigns.config["commands"], &(&1["command"] == command)))
  end

  def handle_event(event, %{"command" => command}, socket)
      when event in ["copy-template", "use-builtin"] do
    entries =
      if event == "use-builtin",
        do: socket.assigns.built_ins,
        else: socket.assigns.templates["commands"]

    cond do
      Enum.any?(socket.assigns.config["commands"], &(&1["command"] == command)) ->
        {:noreply,
         put_flash(socket, :error, "This App already has that command. Edit its existing alias.")}

      true ->
        case Enum.find(entries, &(&1["command"] == command)) do
          nil ->
            {:noreply, socket}

          entry ->
            {:noreply,
             assign(socket,
               dialog: :edit,
               draft_dirty: true,
               editing: nil,
               entry: entry,
               draft_epoch: socket.assigns.draft_epoch + 1
             )}
        end
    end
  end

  def handle_event("retry", _, socket) do
    %{current_tenant: tenant, group_id: group, connect_id: connect, app: app} = socket.assigns
    run(socket, fn -> SlackCommands.retry_sync(tenant, group, connect, app["app_id"]) end)
  end

  def handle_event(
        "credentials",
        %{"configuration_refresh_token" => token, "profile_name" => profile},
        socket
      ) do
    tenant = socket.assigns.current_tenant
    # Never assign the secret to the socket, return it, or include exceptions in flash.
    run(socket, fn -> SlackCommandSync.configure_credential(tenant, token, profile) end)
  end

  def handle_event("profile", %{"credential_profile" => profile}, socket) do
    save(socket, socket.assigns.config["commands"], profile)
  end

  defp save(socket, entries, profile \\ nil) do
    %{current_tenant: tenant, group_id: group, connect_id: connect, app: app, config: config} =
      socket.assigns

    run(
      socket,
      fn ->
        SlackCommands.save(
          tenant,
          group,
          connect,
          app["app_id"],
          config["revision"],
          entries,
          profile || config["credential_profile"] || "default"
        )
      end,
      is_nil(profile)
    )
  end

  defp run(socket, fun, reset_draft \\ false) do
    {:noreply,
     socket
     |> assign(busy: true, reset_draft: reset_draft, mutation_error: nil)
     |> start_async(:mutation, fn ->
       try do
         fun.()
       rescue
         _ -> {:error, :operation_failed}
       catch
         _, _ -> {:error, :operation_failed}
       end
     end)}
  end

  @impl true
  def handle_async(:mutation, result, socket) do
    socket = assign(socket, busy: false, credential_epoch: socket.assigns.credential_epoch + 1)

    case result do
      {:ok, outcome} when outcome == :ok or (is_tuple(outcome) and elem(outcome, 0) == :ok) ->
        case load(socket) do
          {:ok, updated} ->
            updated =
              if socket.assigns.reset_draft,
                do:
                  assign(updated,
                    dialog: nil,
                    draft_dirty: false,
                    entry: @blank,
                    editing: nil,
                    draft_epoch: socket.assigns.draft_epoch + 1
                  ),
                else:
                  assign(updated,
                    dialog:
                      if(
                        socket.assigns.dialog == :credentials and socket.assigns.return_to_editor,
                        do: :edit,
                        else: socket.assigns.dialog
                      )
                  )

            {:noreply,
             updated
             |> put_flash(
               :info,
               if(socket.assigns.dialog == :credentials,
                 do: "Advanced settings saved.",
                 else: sync_label(updated.assigns.config)
               )
             )}

          _ ->
            {:noreply, put_flash(socket, :error, "Cannot reload this App. Refresh the page.")}
        end

      {:ok, {:error, reason}} ->
        # Preserve the draft and revision on conflict. Reload is an explicit action.
        {:noreply,
         assign(socket, mutation_error: SlackCommandSync.error_text(reason))
         |> put_flash(:error, SlackCommandSync.error_text(reason))}

      _ ->
        {:noreply,
         assign(socket, mutation_error: "Update interrupted. Reload and retry synchronization.")
         |> put_flash(:error, "Update interrupted. Reload and retry synchronization.")}
    end
  end

  defp app_label(app, apps) do
    if Enum.count(apps, &(&1["app_name"] == app["app_name"])) > 1,
      do: "#{app["app_name"]} (#{app["app_id"]})",
      else: app["app_name"]
  end

  defp parse_entry(params) do
    params
    |> Map.take(~w(command description usage_hint prompt))
    |> Map.put("enabled", params["enabled"] == "true")
  end

  defp sync_label(config) do
    case config["status"] do
      "synced" -> "Latest App configuration synchronized to Slack"
      "reauthorization_required" -> "App authorization required"
      "not_configured" -> "No commands published yet"
      "failed" -> failure_label(config["failure_outcome"])
      _ -> "Configuration saved; Slack synchronization not confirmed"
    end
  end

  defp failure_label("not_sent"),
    do: "Configuration saved. This attempt did not send an update to Slack"

  defp failure_label("rejected"), do: "Configuration saved. Slack rejected this update attempt"
  defp failure_label(_), do: "Configuration saved; Slack synchronization not confirmed"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="app-command-editor" phx-hook="CommandDraft" data-epoch={@draft_epoch} data-busy={to_string(@busy)} data-draft={to_string(@draft_dirty)} class="space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold">Slack commands</h1>
          <p class="text-sm text-neutral-500">Organization: {SalixWeb.Dashboard.SlackCommandScope.label(@tenants, @current_tenant)}</p>
        </div>
        <.button :if={@app} variant="primary" phx-click="new" disabled={@busy}>Add command</.button>
      </div>
      <form :if={@apps != []} id="slack-app-picker" phx-change="select-app" class="flex flex-wrap items-center gap-3">
        <label for="slack-app-select" class="text-sm font-medium">Slack App</label>
        <select id="slack-app-select" name="connect_id" disabled={@busy} class="rounded-lg border border-neutral-300 bg-white px-3 py-2">
          <option :if={is_nil(@app)} value="">Choose an App</option>
          <option :for={app <- @apps} value={app["connect_id"]} selected={app["connect_id"] == @connect_id}>{app_label(app, @apps)}</option>
        </select>
        <span class="text-sm text-neutral-500">Only Apps in this organization</span>
      </form>
      <div :if={is_nil(@app)} class="rounded-xl border border-neutral-200 p-10 text-center space-y-4">
        <p>{if @apps == [], do: "No Slack Apps in this organization", else: "Choose an App to manage its commands"}</p>
        <p :if={@apps == []} class="text-sm text-neutral-500">Connect a Slack App from a Group's IM settings, then return here.</p>
        <.button :if={@apps == []} navigate="/dash/groups">Choose Group to connect Slack</.button>
      </div>
      <div :if={@app} class="space-y-6">
        <div :if={@config["status"] != "not_configured" or @busy} class="rounded-lg border border-neutral-200 p-4 space-y-2">
          <p id="command-sync-status" role="status" aria-live="polite">{if @busy, do: "Publishing App configuration…", else: sync_label(@config)}</p>
          <p :if={@config["status"] == "synced"} class="text-sm text-neutral-500">Configuration confirmed. This does not verify an actual Slack invocation.</p>
          <p :if={@config["error"]} class="text-sm text-red-600">{@config["error"]} <span :if={@config["status"] == "failed" and @config["failure_outcome"] not in ["not_sent", "rejected"]}>Slack may already have received the update.</span></p>
          <.link :if={@config["authorization_required"]} href={@app["oauth_url"]} target="_blank" rel="noopener noreferrer" class="text-brand-600">Authorize App</.link>
          <.button :if={@config["status"] not in ["synced", "not_configured"]} phx-click="retry" disabled={@busy}>Retry synchronization</.button>
        </div>
        <.table :if={@config["commands"] != []} id="slack-command-list" rows={@config["commands"]}>
          <:col :let={entry} label="Command">{entry["command"]}</:col>
          <:col :let={entry} label="Description">{entry["description"]}</:col>
          <:col :let={entry} label="Configuration">{if entry["enabled"], do: "Configured enabled", else: "Configured disabled"}</:col>
          <:action :let={entry}><.button size="sm" phx-click="edit" phx-value-command={entry["command"]} disabled={@busy}>Edit</.button></:action>
        </.table>
        <.empty_state :if={@config["commands"] == []} icon="chat" title="No commands yet" description="Add a command to let your team start tasks directly from Slack." />
        <div class="flex flex-wrap items-start justify-between gap-4">
          <.link navigate="/dash/slack-command-templates" class="text-sm text-brand-600">Manage organization presets</.link>
          <details class="text-sm">
            <summary class="cursor-pointer">App details and advanced settings</summary>
            <p class="mt-2">App ID: {@app["app_id"]}</p>
            <.link navigate={"/dash/groups/#{@group_id}?tab=im"} class="text-brand-600">Group IM connection</.link>
            <div class="mt-2"><.button phx-click="open-credentials" disabled={@busy}>Configuration credentials</.button></div>
          </details>
        </div>
      </div>
      <dialog id="command-dialog" phx-mounted={JS.ignore_attributes("open")} aria-labelledby="command-dialog-title" data-open={to_string(not is_nil(@dialog))} class="m-auto w-full max-w-4xl rounded-xl border border-neutral-200 bg-white p-0 shadow-xl backdrop:bg-black/40">
        <div :if={@app} class="p-6 space-y-5">
          <div>
            <h2 id="command-dialog-title" class="text-lg font-semibold">{cond do @dialog == :credentials -> "Configuration credentials"; @editing -> "Edit command"; true -> "Add command" end}</h2>
            <p class="text-sm text-neutral-500">{SalixWeb.Dashboard.SlackCommandScope.label(@tenants, @current_tenant)} / {@app["app_name"]} <span :if={@dialog == :edit}>· Not published</span></p>
          </div>
          <p :if={@mutation_error} role="alert" class="rounded-lg bg-red-50 p-3 text-sm text-red-700">{@mutation_error}</p>
          <div :if={@dialog == :choose} class="space-y-3">
            <p class="text-sm text-neutral-500">Choose a starting point, then customize before publishing.</p>
            <div :for={{source, event, entries} <- [{"System preset", "use-builtin", @built_ins}, {"Organization preset", "copy-template", @templates["commands"]}]}>
              <button :for={entry <- entries} type="button" phx-click={event} phx-value-command={entry["command"]}
                disabled={Enum.any?(@config["commands"], &(&1["command"] == entry["command"]))}
                class="mb-2 block w-full rounded-lg border border-neutral-200 p-4 text-left hover:bg-neutral-50 disabled:opacity-50">
                <strong>{entry["command"]}</strong> <span class="text-xs text-neutral-500">{source}</span>
                <span :if={Enum.any?(@config["commands"], &(&1["command"] == entry["command"]))} class="text-xs"> · Already in this App</span>
                <div class="text-sm text-neutral-500">{entry["description"]}</div>
              </button>
            </div>
            <.button phx-click="custom">Create custom command</.button>
            <div class="flex justify-end"><.button phx-click="cancel">Cancel</.button></div>
          </div>
          <form :if={@dialog == :edit} id="slack-command-form" phx-change="preview" phx-submit="save">
            <fieldset disabled={@busy} class="space-y-5">
              <div class="grid gap-6 md:grid-cols-2">
                <div class="space-y-3">
                  <.input name="entry[command]" label="Command" value={@entry["command"]} placeholder="/review" required />
                  <.input name="entry[description]" label="Slack menu description" value={@entry["description"]} required />
                  <.textarea name="entry[prompt]" label="What should the assistant do?" value={@entry["prompt"]} rows="5" required />
                  <input type="hidden" name="entry[enabled]" value="false" />
                  <label class="flex items-center gap-2 text-sm"><input type="checkbox" name="entry[enabled]" value="true" checked={@entry["enabled"]} /> Enable when published</label>
                  <p class="text-xs text-neutral-500">Enable and disable changes are applied only when you publish.</p>
                  <details><summary class="cursor-pointer text-sm">Optional Slack usage hint</summary><.input name="entry[usage_hint]" label="Usage hint" value={@entry["usage_hint"]} /></details>
                </div>
                <aside class="self-start rounded-lg border border-neutral-200 bg-neutral-50 p-4 space-y-3">
                  <h3 class="font-medium">Slack usage preview</h3>
                  <strong>{@entry["command"]}</strong><p class="text-sm">{@entry["description"]}</p>
                  <.input name="sample" label="Example user input (not saved)" value={@sample} />
                  <p class="text-xs text-neutral-500">Exact request sent to the assistant</p>
                  <pre id="command-request-preview" class="whitespace-pre-wrap break-words rounded bg-white p-3 text-sm">{(@entry["prompt"] || "") <> @sample}</pre>
                  <p class="text-xs text-neutral-500">This preview uses the exact prefix. It is a user request, not a system instruction.</p>
                  <.button :if={@entry["prompt"] != "" and not Regex.match?(~r/\s$/, @entry["prompt"])} type="button" size="sm" phx-click="separator">Add a line break before user input</.button>
                </aside>
              </div>
              <div :if={not @credential_configured} class="rounded-lg bg-amber-50 p-3 text-sm">Set up configuration credentials before publishing. Your command stays here.
                <.button type="button" phx-click="open-credentials">Set up credentials</.button>
              </div>
              <div class="flex flex-wrap items-center justify-between gap-3 border-t border-neutral-200 pt-4">
                <p class="text-xs text-neutral-500">Updates this App across its installed workspaces.</p>
                <div class="flex gap-2"><.button type="button" phx-click="cancel">Cancel</.button><.button type="submit" variant="primary" disabled={@busy or not @credential_configured}>Publish to {@app["app_name"]}</.button></div>
              </div>
              <details :if={@editing}><summary class="cursor-pointer text-xs text-red-600">Delete command</summary><.button type="button" variant="danger" phx-click="delete" phx-value-command={@editing} data-confirm={"Delete #{@editing} and synchronize #{@app["app_name"]}?"}>Delete and synchronize</.button></details>
            </fieldset>
          </form>
          <div :if={@dialog == :credentials}>
      <.card>
        <:title>Configuration credentials</:title>
        <p class="text-sm">Status: {if @credential_configured, do: "Configured", else: "Not configured"}.
          Each App selects a named credential profile. Share a profile only when the same Slack configuration account manages those Apps.</p>
        <form id="slack-command-profile" phx-submit="profile" class="mt-3 space-y-3">
          <label for="credential-profile">Profile for this App</label>
          <select id="credential-profile" name="credential_profile" class="rounded border p-2">
            <option :for={name <- @credential_profiles} value={name}
              selected={name == (@config["credential_profile"] || "default")}>{name}</option>
          </select>
          <.button type="submit" disabled={@busy}>Use profile and synchronize</.button>
        </form>
        <p class="text-sm">Generate a dedicated configuration token in Slack App settings. Do not reuse its refresh token in another tenant or external tool.</p>
        <form id="slack-command-credentials" phx-submit="credentials" class="mt-3 space-y-3">
          <.input name="profile_name" label="Profile name" value={@config["credential_profile"] || "default"} required />
          <p class="text-sm">Replacing a shared profile changes credentials for every App that selects it.</p>
        <ul class="text-sm">
          <li :for={{profile, apps} <- Enum.sort(@profile_apps)}><strong>{profile}</strong>: {Enum.join(apps, ", ")}</li>
        </ul>
          <.input type="password" id={"configuration-token-#{@credential_epoch}"} name="configuration_refresh_token" label="New configuration refresh token"
            value="" autocomplete="new-password" required />
          <.button type="submit" disabled={@busy} data-confirm="Replace this profile’s credentials for all Apps listed under that profile?">Replace credentials</.button>
        </form>
      </.card>

            <.button :if={@return_to_editor} phx-click="back-editor" disabled={@busy}>Back to command</.button>
            <.button :if={not @return_to_editor} phx-click="cancel" disabled={@busy}>Close</.button>
          </div>
        </div>
      </dialog>
    </div>
    """
  end
end
