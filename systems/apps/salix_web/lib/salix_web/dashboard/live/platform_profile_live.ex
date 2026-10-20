defmodule SalixWeb.Dashboard.PlatformProfileLive do
  @moduledoc """
  The operator page for platform Profiles: API-key Profiles under the reserved
  platform Tenant (`SalixAgent.AccountPool.platform_tenant/0`). They serve
  only the Comma model; a model a member chose runs on the member's own
  Profiles.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.AccountPool

  @protocols [
    {"OpenAI Responses", "responses"},
    {"OpenAI Chat Completions", "chat_completions"},
    {"Anthropic Messages", "anthropic"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        active_nav: :platform_profiles,
        page_title: "Platform Profiles",
        breadcrumbs: [{"Platform Profiles", nil}],
        profiles: [],
        next: "",
        cursor: "",
        page_error: nil,
        form: blank_form(),
        form_error: nil
      )

    {:ok, if(connected?(socket), do: load(socket, ""), else: socket)}
  end

  defp blank_form, do: %{"source" => "openrouter"}

  defp load(socket, cursor) do
    case AccountPool.list(AccountPool.platform_tenant(), cursor) do
      {:ok, %{"accounts" => accounts, "next" => next}} ->
        assign(socket,
          profiles: Enum.filter(accounts, &(&1["credential_kind"] == "provider_api_key")),
          next: next,
          cursor: cursor,
          page_error: nil
        )

      {:error, :not_configured} ->
        assign(socket,
          profiles: [],
          next: "",
          page_error: "Profile storage is not configured on this node."
        )

      {:error, _} ->
        assign(socket,
          profiles: [],
          next: "",
          page_error: "Platform Profiles are unavailable. Check database access, then retry."
        )
    end
  end

  @impl true
  def handle_event("change", %{"profile" => form}, socket),
    do: {:noreply, assign(socket, form: form, form_error: nil)}

  def handle_event("create", %{"profile" => form}, socket) do
    case AccountPool.create(AccountPool.platform_tenant(), create_attrs(form)) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Platform Profile added.")
         |> assign(form: blank_form(), form_error: nil)
         |> load("")}

      {:error, _} ->
        {:noreply,
         assign(socket,
           form: form,
           form_error:
             "Could not add this Profile. Check the key, and for a source without its own endpoint, the endpoint URL and protocol."
         )}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %{} = profile <- Enum.find(socket.assigns.profiles, &(&1["id"] == id)),
         {:ok, _} <-
           AccountPool.update(AccountPool.platform_tenant(), id, %{
             "disabled" => not profile["disabled"],
             "version" => profile["version"]
           }) do
      {:noreply, load(socket, socket.assigns.cursor)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not change this Profile. Reload and retry.")
         |> load(socket.assigns.cursor)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %{} = profile <- Enum.find(socket.assigns.profiles, &(&1["id"] == id)),
         :ok <- delete(id, profile["version"]) do
      {:noreply, socket |> put_flash(:info, "Platform Profile deleted.") |> load("")}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not delete this Profile. Reload and retry.")
         |> load(socket.assigns.cursor)}
    end
  end

  def handle_event("next", _, %{assigns: %{next: next}} = socket) when next != "",
    do: {:noreply, load(socket, next)}

  def handle_event("first", _, socket), do: {:noreply, load(socket, "")}
  def handle_event("retry", _, socket), do: {:noreply, load(socket, socket.assigns.cursor)}

  defp delete(id, version) do
    case AccountPool.delete(AccountPool.platform_tenant(), id, version) do
      {:ok, _} -> :ok
      :ok -> :ok
      error -> error
    end
  end

  # Only the fields the chosen source takes: an endpoint and protocol where the
  # source has none, and a model list for a Custom endpoint.
  defp create_attrs(form) do
    source = form["source"]
    needs_endpoint = endpoint_required?(source)

    %{"credential_kind" => "provider_api_key", "source" => source}
    |> put_text("name", form["name"])
    |> put_text("api_key", form["api_key"])
    |> then(&if(needs_endpoint, do: put_text(&1, "base_url", form["base_url"]), else: &1))
    |> then(&if(needs_endpoint, do: put_text(&1, "protocol", form["protocol"]), else: &1))
    |> then(fn attrs ->
      if source == "custom", do: Map.put(attrs, "models", model_ids(form["models"])), else: attrs
    end)
  end

  defp put_text(attrs, key, value) do
    case String.trim(value || "") do
      "" -> attrs
      text -> Map.put(attrs, key, text)
    end
  end

  defp model_ids(text),
    do: (text || "") |> String.split(~r/[\s,]+/, trim: true) |> Enum.uniq()

  defp sources do
    SalixAgent.Models.sources()
    |> Enum.filter(fn {_id, source} -> source["kind"] == "api_key" end)
    |> Enum.map(fn {id, source} -> {source["name"], id} end)
    |> Enum.sort()
  end

  defp endpoint_required?(source) do
    case SalixAgent.Models.source(source) do
      {:ok, %{"endpoint_required" => true}} -> true
      _ -> false
    end
  end

  defp source_name(id) do
    case SalixAgent.Models.source(id) do
      {:ok, %{"name" => name}} -> name
      _ -> id
    end
  end

  defp serves(%{"source" => "custom", "models" => models}) when is_list(models),
    do: "#{length(models)} listed models"

  defp serves(profile), do: "Catalog models of " <> source_name(profile["source"])

  @impl true
  def render(assigns) do
    assigns = assign(assigns, sources: sources(), protocols: @protocols)

    ~H"""
    <div class="mx-auto max-w-6xl space-y-8">
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">Platform Profiles</h1>
        <p class="mt-2 text-sm text-neutral-500">API keys the platform pays for. They serve only the Comma model, whose calls are metered against the Workspace's credits; a model a member chose runs on the Workspace's own Profiles.</p>
      </div>
      <div :if={@page_error} role="alert" class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm"><p>{@page_error}</p><.button type="button" phx-click="retry">Retry</.button></div>
      <.table id="platform-profiles" rows={@profiles}>
        <:col :let={p} label="Profile"><p class="font-medium">{p["name"]}</p><p class="mt-1 text-xs text-neutral-500">{source_name(p["source"])} · key {p["key_hint"] || "none"}</p></:col>
        <:col :let={p} label="Endpoint"><span class="break-all text-xs">{get_in(p, ["connection", "endpoint"])}</span></:col>
        <:col :let={p} label="Serves">{serves(p)}</:col>
        <:col :let={p} label="Enabled"><.toggle id={"platform-profile-" <> p["id"]} name="enabled" checked={!p["disabled"]} phx-click="toggle" phx-value-id={p["id"]} /></:col>
        <:action :let={p}>
          <button type="button" phx-click="delete" phx-value-id={p["id"]} data-confirm={"Delete platform Profile “" <> p["name"] <> "”?"} class="text-sm text-red-700">Delete</button>
        </:action>
      </.table>
      <p :if={!@page_error && @profiles == []} class="rounded-lg border border-dashed border-neutral-200 p-6 text-sm text-neutral-500">No platform Profiles.</p>
      <div :if={@cursor != "" || @next != ""} class="flex gap-2">
        <.button :if={@cursor != ""} type="button" phx-click="first">First page</.button>
        <.button :if={@next != ""} type="button" phx-click="next">Next page</.button>
      </div>
      <section class="space-y-4 rounded-lg border border-neutral-200 p-4">
        <h2 class="text-lg font-semibold">Add a platform Profile</h2>
        <form id="platform-profile-form" phx-change="change" phx-submit="create" class="grid gap-4 sm:grid-cols-2">
          <.select id="platform-profile-source" name="profile[source]" label="Source" options={@sources} value={@form["source"]} />
          <.input id="platform-profile-name" name="profile[name]" label="Name" value={@form["name"]} placeholder="Defaults to the source's name" />
          <.input id="platform-profile-key" name="profile[api_key]" type="password" label="API key" value="" autocomplete="off" />
          <.input :if={endpoint_required?(@form["source"])} id="platform-profile-endpoint" name="profile[base_url]" label="Endpoint URL" value={@form["base_url"]} placeholder="https://" />
          <.select :if={endpoint_required?(@form["source"])} id="platform-profile-protocol" name="profile[protocol]" label="Protocol" options={@protocols} value={@form["protocol"]} />
          <.textarea :if={@form["source"] == "custom"} id="platform-profile-models" name="profile[models]" label="Model ids" value={@form["models"]} rows="4" hint="One per line. Every Workspace can choose these models." />
          <p :if={@form_error} role="alert" class="text-sm text-red-700 sm:col-span-2">{@form_error}</p>
          <div class="sm:col-span-2"><.button type="submit" variant="primary">Add Profile</.button></div>
        </form>
      </section>
    </div>
    """
  end
end
