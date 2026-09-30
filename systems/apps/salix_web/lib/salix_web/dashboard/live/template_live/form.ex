defmodule SalixWeb.Dashboard.TemplateLive.Form do
  @moduledoc "Create (`:new`) and edit (`:edit`) an agent template."
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{Templates, ModelPresentation}
  alias SalixWeb.Dashboard.Format

  @json_fields ~w(provider_config request_headers image_config video_config
                  vision_describer_config analyze_config)

  @impl true
  def mount(params, _session, socket) do
    tenant = if params["scope"] == "tenant", do: socket.assigns.current_tenant, else: nil

    {:ok,
     init(
       assign(socket,
         active_nav: :templates,
         template_tenant: tenant,
         discovered_models: [],
         discovering: false,
         discovery_error: nil,
         model_search: "",
         model_picker: false,
         connection_changed: false,
         dirty: false,
         field_errors: %{},
         stored_api_key: nil,
         discovery_truncated: false
       ),
       params
     )}
  end

  defp init(socket, %{"id" => id}) do
    case Templates.get(id, socket.assigns.template_tenant) do
      {:ok, t} ->
        assign(socket,
          action: :edit,
          template_tenant: t["tenant_id"],
          template_id: id,
          page_title: t["name"],
          breadcrumbs: [{"Templates", "/dash/templates"}, {t["name"], nil}],
          stored_api_key: get_in(t, ["provider_config", "api_key"]),
          form: form_from(t)
        )

      {:error, _} ->
        socket |> put_flash(:error, "Template not found.") |> push_navigate(to: "/dash/templates")
    end
  end

  defp init(socket, _params) do
    assign(socket,
      action: :new,
      template_id: nil,
      page_title:
        if(socket.assigns.template_tenant,
          do: "New private template",
          else: "New global template"
        ),
      breadcrumbs: [{"Templates", "/dash/templates"}, {"New", nil}],
      form: form_from(%{})
    )
  end

  # Build the form map (string values) from a template record.
  defp form_from(t) do
    %{
      "account_pool" => (t["provider_config"] || %{})["account_pool"] || "",
      "image_account_pool" =>
        get_in(t, ["image_config", "provider_config", "account_pool"]) || "",
      "name" => t["name"] || "",
      "model" => t["model"] || "",
      "model_display_name" => t["model_display_name"],
      "model_vendor" => t["model_vendor"],
      "provider" => t["provider"] || "",
      "purpose" => t["purpose"] || "",
      "max_tokens" => to_string(t["max_tokens"] || 65_536),
      "context_tokens" => to_string(t["context_tokens"] || 0),
      "supports_images" => !!t["supports_images"],
      "hidden" => !!t["hidden"],
      "base_url" => get_in(t, ["provider_config", "base_url"]) || "",
      "protocol" => get_in(t, ["provider_config", "protocol"]) || "",
      "api_key" => "",
      "provider_config" =>
        json_text(
          Map.drop(t["provider_config"] || %{}, ~w(base_url protocol api_key account_pool))
        ),
      "request_headers" => json_text(t["request_headers"]),
      "image_config" => json_text(t["image_config"]),
      "video_config" => json_text(t["video_config"]),
      "vision_describer_config" => json_text(t["vision_describer_config"]),
      "analyze_config" => json_text(t["analyze_config"])
    }
  end

  defp json_text(nil), do: "{}"
  defp json_text(v) when is_map(v) and map_size(v) == 0, do: "{}"
  defp json_text(v), do: Format.pretty_json(v)

  @impl true
  def handle_event("change", %{"_target" => ["model_search"], "model_search" => query}, socket),
    do: {:noreply, assign(socket, model_search: query)}

  def handle_event("change", params, socket) do
    socket = clear_flash(socket)
    form = form_values(Map.merge(socket.assigns.form, params))

    connection_changed =
      Enum.any?(
        ~w(provider_config account_pool base_url protocol api_key),
        &(form[&1] != socket.assigns.form[&1])
      )

    socket =
      if connection_changed,
        do:
          socket
          |> cancel_async(:discover)
          |> assign(discovered_models: [], discovering: false, discovery_error: nil),
        else: socket

    form =
      display_values(
        form,
        socket.assigns.form,
        socket.assigns.discovered_models,
        connection_changed
      )

    {:noreply,
     assign(socket,
       form: form,
       dirty: true,
       field_errors: %{},
       connection_changed: connection_changed or socket.assigns.connection_changed
     )}
  end

  def handle_event("discover", _, %{assigns: %{discovering: true}} = socket),
    do: {:noreply, socket}

  def handle_event("discover", _, socket) do
    form = socket.assigns.form
    tenant = socket.assigns.template_tenant

    config = connection_config(form, socket.assigns.stored_api_key)

    attrs =
      if form["account_pool"] in ["codex", "claude"] do
        %{"account_pool" => form["account_pool"]}
      else
        case config do
          {:ok, value} -> Map.take(value, ~w(base_url api_key protocol))
          _ -> %{}
        end
      end

    {:noreply,
     socket
     |> assign(discovering: true, discovery_error: nil, model_picker: true)
     |> start_async(:discover, fn -> SalixAgent.ModelDiscovery.discover(attrs, tenant) end)}
  end

  def handle_event("choose-model", %{"id" => id}, socket) do
    socket = clear_flash(socket)

    case Enum.find(socket.assigns.discovered_models, &(&1["id"] == id)) do
      nil ->
        {:noreply, socket}

      model ->
        {:noreply,
         assign(socket,
           dirty: true,
           connection_changed: false,
           model_picker: false,
           form:
             Map.merge(socket.assigns.form, %{
               "model" => id,
               "name" =>
                 if(socket.assigns.form["name"] == "",
                   do: model["name"],
                   else: socket.assigns.form["name"]
                 ),
               "model_display_name" => model["name"],
               "model_vendor" => model["vendor"],
               "supports_images" => model["supports_images"] == true
             })
         )}
    end
  end

  def handle_event("save", params, socket) do
    socket = clear_flash(socket)
    params = Map.merge(socket.assigns.form, params)

    params =
      display_values(
        params,
        socket.assigns.form,
        socket.assigns.discovered_models,
        socket.assigns.connection_changed or
          Enum.any?(
            ~w(provider_config account_pool base_url protocol api_key),
            &(params[&1] != socket.assigns.form[&1])
          )
      )

    with {:ok, config} <- connection_config(params, socket.assigns.stored_api_key),
         {:ok, attrs} <- build_attrs(Map.put(params, "provider_config", Jason.encode!(config))) do
      attrs =
        if Map.has_key?(params, "account_pool") do
          update_in(attrs["provider_config"], fn config ->
            if params["account_pool"] == "",
              do: Map.delete(config, "account_pool"),
              else: Map.put(config, "account_pool", params["account_pool"])
          end)
        else
          attrs
        end

      result =
        case {socket.assigns.action, socket.assigns.template_tenant} do
          {:new, nil} -> Templates.create(attrs)
          {:new, tenant} -> Templates.create_private(attrs, tenant)
          {:edit, nil} -> Templates.update(socket.assigns.template_id, attrs)
          {:edit, tenant} -> Templates.update_private(socket.assigns.template_id, attrs, tenant)
        end

      case result do
        {:ok, t} ->
          {:noreply,
           socket
           |> put_flash(:info, "Template saved.")
           |> push_navigate(
             to:
               "/dash/templates/#{t["template_id"]}" <>
                 if(socket.assigns.template_tenant, do: "?scope=tenant", else: "")
           )}

        {:error, {:bad_request, msg}} ->
          {:noreply, socket |> put_flash(:error, msg) |> assign(form: form_values(params))}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Save failed: #{inspect(reason)}")
           |> assign(form: form_values(params))}
      end
    else
      {:error, field} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           if(field == "provider_config",
             do:
               "Extra provider parameters must be a JSON object. Set endpoint, protocol, key, and source in Connection.",
             else: "Could not save. Check the highlighted field."
           )
         )
         |> assign(
           form: form_values(params),
           field_errors: %{field => "Enter a valid JSON object."}
         )}
    end
  end

  def handle_event("toggle-model-picker", _, socket),
    do: {:noreply, assign(socket, model_picker: not socket.assigns.model_picker)}

  def handle_event("confirm-model", _, socket),
    do: {:noreply, assign(socket, connection_changed: false, dirty: true)}

  @impl true
  def handle_async(:discover, {:ok, {:ok, result}}, socket),
    do:
      {:noreply,
       assign(socket,
         discovering: false,
         discovered_models: result["data"],
         discovery_truncated: result["truncated"] == true
       )}

  def handle_async(:discover, _, socket),
    do:
      {:noreply,
       assign(socket,
         discovering: false,
         discovery_error: "Could not fetch models. Check the connection or enter a model ID."
       )}

  defp display_values(form, previous, models, changed) do
    model = unless changed, do: Enum.find(models, &(&1["id"] == form["model"]))

    cond do
      model ->
        Map.merge(form, %{
          "model_display_name" => model["name"],
          "model_vendor" => model["vendor"]
        })

      not changed and form["model"] == previous["model"] ->
        Map.merge(form, Map.take(previous, ~w(model_display_name model_vendor)))

      true ->
        Map.merge(form, %{"model_display_name" => nil, "model_vendor" => nil})
    end
  end

  defp form_values(params) do
    Enum.reduce(~w(supports_images hidden), params, fn field, form ->
      Map.put(form, field, params[field] in [true, "true"])
    end)
  end

  defp connection_config(form, stored_key) do
    with {:ok, extra} when is_map(extra) <- Jason.decode(form["provider_config"] || "{}"),
         false <- Enum.any?(~w(base_url protocol api_key account_pool), &Map.has_key?(extra, &1)) do
      config = Map.drop(extra, ~w(base_url protocol api_key account_pool))
      key = if form["api_key"] in [nil, ""], do: stored_key, else: form["api_key"]

      {:ok,
       Enum.reduce(
         [{"base_url", form["base_url"]}, {"protocol", form["protocol"]}, {"api_key", key}],
         config,
         fn
           {_, value}, acc when value in [nil, ""] -> acc
           {field, value}, acc -> Map.put(acc, field, value)
         end
       )}
    else
      _ -> {:error, "provider_config"}
    end
  end

  defp preview(form) do
    ModelPresentation.public(%{
      "model" => form["model"],
      "model_display_name" => form["model_display_name"],
      "model_vendor" => form["model_vendor"],
      "provider_config" => %{
        "account_pool" => form["account_pool"],
        "base_url" => form["base_url"]
      }
    })
  end

  # Parse form params into template attrs, decoding the JSON-object fields.
  defp build_attrs(params) do
    Enum.reduce_while(@json_fields, {:ok, base_attrs(params)}, fn field, {:ok, acc} ->
      case decode_config(field, params) do
        {:ok, map} when is_map(map) -> {:cont, {:ok, Map.put(acc, field, map)}}
        _ -> {:halt, {:error, field}}
      end
    end)
  end

  defp decode_config("image_config", %{"image_account_pool" => "codex"}) do
    {:ok,
     %{
       "provider" => "openai",
       "model" => "gpt-image-2",
       "provider_config" => %{"account_pool" => "codex"}
     }}
  end

  defp decode_config(field, params) do
    case Jason.decode(blank_to_empty_obj(params[field])) do
      {:ok, %{"provider_config" => config} = image}
      when field == "image_config" and is_map(config) and
             :erlang.map_get("image_account_pool", params) == "" ->
        {:ok, Map.put(image, "provider_config", Map.delete(config, "account_pool"))}

      result ->
        result
    end
  end

  defp base_attrs(params) do
    %{
      "name" => params["name"],
      "model" => params["model"],
      "model_display_name" => params["model_display_name"],
      "model_vendor" => params["model_vendor"],
      "max_tokens" => to_int(params["max_tokens"], 65_536),
      "context_tokens" => to_int(params["context_tokens"], 0),
      "supports_images" => params["supports_images"] in [true, "true"],
      "hidden" => params["hidden"] in [true, "true"],
      "provider" => if(params["provider"] in [nil, ""], do: nil, else: params["provider"])
    }
    |> Map.put("purpose", if(params["purpose"] in [nil, ""], do: nil, else: params["purpose"]))
  end

  defp blank_to_empty_obj(v) when v in [nil, ""], do: "{}"
  defp blank_to_empty_obj(v), do: v

  defp to_int(v, default) do
    case Integer.parse(to_string(v || "")) do
      {n, _} -> n
      :error -> default
    end
  end

  @impl true
  def render(assigns) do
    matches =
      if assigns.model_picker,
        do: matching_models(assigns.discovered_models, assigns.model_search),
        else: []

    assigns = assign(assigns, :matching_models, matches)

    ~H"""
    <div class="mx-auto max-w-5xl space-y-6 pb-8">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="space-y-2">
          <.link navigate="/dash/templates" class="text-sm text-neutral-500 hover:text-neutral-900">← Model catalog</.link>
          <h1 class="text-2xl font-semibold tracking-tight">{if @action == :new, do: "Add model configuration", else: @form["model_display_name"] || @form["model"]}</h1>
          <p id="template-scope" class="text-sm text-neutral-500">
            {if @template_tenant, do: "BYOK · Private · Current tenant", else: "Platform billing · Global"}
          </p>
        </div>
        <.link navigate="/dash/agent-defaults" class="text-sm text-brand-600">Manage defaults →</.link>
      </div>

      <form id="template-form" phx-submit="save" phx-change="change" phx-hook="TemplateDraft" data-dirty={to_string(@dirty)} class="space-y-6">
        <.card>
          <:title>1. Connection</:title>
          <p class="mb-5 text-sm text-neutral-500">Choose how this template calls its model. Connection settings do not set the model vendor.</p>
          <div :if={@action == :new} class="mb-5 flex flex-wrap gap-4 text-sm">
            <span>Available to: <strong>{if @template_tenant, do: "Current tenant", else: "All tenants"}</strong></span>
            <.link navigate={if @template_tenant, do: "/dash/templates/new", else: "/dash/templates/new?scope=tenant"} class="text-brand-600">{if @template_tenant, do: "Use global scope", else: "Use private scope"}</.link>
          </div>
          <.select :if={@template_tenant} id="connection-source" name="account_pool" label="Source" value={@form["account_pool"]}
            options={[{"API connection", ""}, {"Codex subscription", "codex"}, {"Claude subscription", "claude"}]} />
          <div :if={@form["account_pool"] in ["codex", "claude"]} class="mt-4 rounded-lg bg-neutral-50 p-4 text-sm space-y-2">
            <p>Uses this tenant's connected subscriptions. API endpoint, key, and request headers are not used.</p>
            <.link navigate="/dash/account-pool" class="text-brand-600">Manage subscriptions →</.link>
          </div>
          <div :if={@form["account_pool"] not in ["codex", "claude"]} class="mt-4 grid gap-5 sm:grid-cols-2">
            <.input id="connection-url" name="base_url" label="API base URL" value={@form["base_url"]} placeholder="https://api.example.com/v1" class="sm:col-span-2" />
            <.select id="connection-protocol" name="protocol" label="API protocol" value={@form["protocol"]}
              options={protocol_options(@form["protocol"])} />
            <.input id="connection-key" type="password" name="api_key" label="API key" value={@form["api_key"]} autocomplete="new-password"
              placeholder={if @stored_api_key, do: "Configured · leave blank to keep", else: "Enter API key"} hint={if @stored_api_key, do: "The saved key is not displayed. Enter a value only to replace it.", else: "Stored on the server when you save this configuration."} />
          </div>
        </.card>

        <.card>
          <:title>2. Main model</:title>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex items-center gap-3">
              <.model_icon brand={preview(@form)["model_icon"]} />
              <div><p class="font-medium">{@form["model_display_name"] || blank_name(@form["model"])}</p><p class="text-xs text-neutral-500">{@form["model"]}</p></div>
            </div>
            <div class="flex gap-2">
              <.button type="button" phx-click="discover" disabled={@discovering}>{if @discovering, do: "Fetching models…", else: "Fetch models"}</.button>
              <.button :if={@discovered_models != []} type="button" phx-click="toggle-model-picker">{if @model_picker, do: "Close choices", else: "Change model"}</.button>
            </div>
          </div>
          <p :if={@connection_changed && @form["model"] != ""} role="status" class="mt-4 text-sm text-amber-700">Connection changed. Fetch models or confirm the model ID below. Saved display information will be cleared unless you select a discovered model.</p>
          <p :if={@discovery_error} role="alert" class="mt-4 text-sm text-red-600">{@discovery_error}</p>
          <div :if={@model_picker && @discovered_models != []} class="mt-5 space-y-3 rounded-lg border border-neutral-200 p-4">
            <.input id="model-search" name="model_search" label="Search models" value={@model_search} phx-debounce="200" placeholder="Search by name or model ID" />
            <p class="text-xs text-neutral-500">{length(@matching_models)} results. Scroll the list to see more. Fetching a directory does not test model inference.</p>
            <p :if={@discovery_truncated} class="text-xs text-amber-700">The provider result is limited to 1,000 models. You can enter a model ID below.</p>
            <div :if={@matching_models != []} role="group" aria-label="Available models" class="max-h-72 overflow-y-auto overscroll-contain rounded-md border border-neutral-200 divide-y divide-neutral-100">
              <button :for={model <- @matching_models} type="button" phx-click="choose-model" phx-value-id={model["id"]} aria-pressed={@form["model"] == model["id"]} class="flex w-full items-center gap-3 px-3 py-2 text-left hover:bg-neutral-50 focus-visible:outline-brand-500 aria-pressed:bg-brand-50">
                <.model_icon brand={if @form["account_pool"] in ["codex", "claude"], do: @form["account_pool"], else: model["vendor"]} />
                <span class="min-w-0 flex-1"><span class="block truncate text-sm font-medium" title={model["name"]}>{model["name"]}</span><span class="block truncate text-xs text-neutral-500" title={model["id"]}>{model["id"]}</span></span>
              </button>
            </div>
            <p :if={@matching_models == []} class="text-sm text-neutral-500">No matching models. Try another search or enter a model ID.</p>
          </div>
          <details id="manual-model" phx-hook="PersistentDetails" data-force-open={@form["model"] == "" || @connection_changed} class="mt-5 text-sm" open={@form["model"] == "" || @connection_changed}>
            <summary class="cursor-pointer text-neutral-600">Enter a model ID manually</summary>
            <div class="mt-3 space-y-3">
              <.input id="model-id" name="model" label="Model ID" value={@form["model"]} required hint="If no display name is available, users see this ID." />
              <.button :if={@connection_changed && @form["model"] != ""} type="button" phx-click="confirm-model">Keep this model ID</.button>
            </div>
          </details>
        </.card>

        <.card>
          <:title>3. Catalog</:title>
          <div class="grid gap-5 sm:grid-cols-2">
            <.input id="template-alias" name="name" label="Configuration alias" value={@form["name"]} required hint="For administrators. Users see the main model name." />
            <div class="rounded-lg bg-neutral-50 p-3 space-y-2">
              <p class="text-xs text-neutral-500">User preview · {if @template_tenant, do: "BYOK", else: "Platform billing"}</p>
              <p class="flex items-center gap-2 text-sm font-medium"><.model_icon brand={preview(@form)["model_icon"]} />{blank_name(preview(@form)["model_display_name"])}</p>
            </div>
          </div>
          <div class="mt-5"><input type="hidden" name="hidden" value="false" /><.toggle name="hidden" label="Hide from model selectors" checked={@form["hidden"]} value="true" /></div>
        </.card>

        <details id="runtime-options" phx-hook="PersistentDetails" class="rounded-lg border border-neutral-200 bg-white p-5">
          <summary class="cursor-pointer font-medium">Runtime parameters <span class="ml-2 text-xs font-normal text-neutral-500">Output: {@form["max_tokens"]} tokens</span></summary>
          <div class="mt-5 grid gap-5 sm:grid-cols-2">
            <.input id="max-tokens" type="number" name="max_tokens" label="Maximum output tokens" value={@form["max_tokens"]} min="1" required />
            <.input id="context-tokens" type="number" name="context_tokens" label="Context tokens" value={@form["context_tokens"]} min="0" hint="0 keeps the runtime default." required />
            <input type="hidden" name="supports_images" value="false" /><.toggle name="supports_images" label="Main model accepts image input" checked={@form["supports_images"]} value="true" />
          </div>
        </details>

        <details id="media-options" phx-hook="PersistentDetails" data-force-open={Enum.any?(~w(image_config video_config vision_describer_config analyze_config), &Map.has_key?(@field_errors, &1))} open={Enum.any?(~w(image_config video_config vision_describer_config analyze_config), &Map.has_key?(@field_errors, &1))} class="rounded-lg border border-neutral-200 bg-white p-5">
          <summary class="cursor-pointer font-medium">Images, video &amp; analysis <span class="ml-2 text-xs font-normal text-neutral-500">{media_summary(@form)}</span></summary>
          <p class="mt-3 text-sm text-neutral-500">Image generation is separate from image input. Empty configuration keeps existing runtime defaults.</p>
          <div class="mt-5 grid gap-5 sm:grid-cols-2">
            <div class="space-y-3">
              <.select :if={@template_tenant} id="image-source" name="image_account_pool" label="Image generation source" value={@form["image_account_pool"]}
                options={[{"Default / custom configuration", ""}, {"Codex subscription", "codex"}]} />
              <div :if={@template_tenant && @form["image_account_pool"] == "codex"} class="rounded-md bg-neutral-50 p-3 text-sm">
                gpt-image-2 · This tenant's Codex subscriptions
                <input type="hidden" name="image_config" value={@form["image_config"]} />
              </div>
              <.json_field :if={!@template_tenant || @form["image_account_pool"] != "codex"} name="image_config" label="Image generation" value={@form["image_config"]} errors={Map.get(@field_errors, "image_config", []) |> List.wrap()} />
            </div>
            <.json_field name="video_config" label="Video" value={@form["video_config"]} errors={Map.get(@field_errors, "video_config", []) |> List.wrap()} />
            <.json_field name="vision_describer_config" label="Vision describer" value={@form["vision_describer_config"]} errors={Map.get(@field_errors, "vision_describer_config", []) |> List.wrap()} />
            <.json_field name="analyze_config" label="Analysis" value={@form["analyze_config"]} errors={Map.get(@field_errors, "analyze_config", []) |> List.wrap()} />
          </div>
        </details>

        <details id="advanced-options" phx-hook="PersistentDetails" data-force-open={Map.has_key?(@field_errors, "provider_config") || Map.has_key?(@field_errors, "request_headers")} open={Map.has_key?(@field_errors, "provider_config") || Map.has_key?(@field_errors, "request_headers")} class="rounded-lg border border-neutral-200 bg-white p-5">
          <summary class="cursor-pointer font-medium">Advanced configuration</summary>
          <p class="mt-3 text-sm text-neutral-500">Extra fields are preserved. Set the endpoint, protocol, and API key in Connection above.</p>
          <div class="mt-5 grid gap-5 sm:grid-cols-2">
            <.input id="provider-override" name="provider" label="Runtime provider override" value={@form["provider"]} hint="Leave blank to derive from connection settings. This does not choose the logo." />
            <.input id="template-purpose" name="purpose" label="Purpose" value={@form["purpose"]} />
            <.json_field name="provider_config" label="Extra provider parameters" value={@form["provider_config"]} errors={Map.get(@field_errors, "provider_config", []) |> List.wrap()} />
            <.json_field :if={@form["account_pool"] not in ["codex", "claude"]} name="request_headers" label="Request headers" value={@form["request_headers"]} errors={Map.get(@field_errors, "request_headers", []) |> List.wrap()} />
          </div>
        </details>

        <p id="save-impact" class="text-sm text-neutral-500">{if @action == :edit, do: "Saving updates this template for Agents that use it. Their next activation uses the new configuration. New-Agent defaults are managed separately.", else: "Saving adds a model choice. It does not change an Agent or a default."}</p>
        <div class="sticky bottom-0 z-10 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-neutral-200 bg-white p-3 sm:p-4 shadow-sm">
          <p class="text-xs sm:text-sm font-medium">{if @dirty, do: "Unsaved changes", else: "Configuration"}</p>
          <div class="flex gap-2"><.button navigate="/dash/templates">Cancel</.button><.button type="submit" variant="primary" disabled={@discovering} aria-describedby="save-impact">Save template</.button></div>
        </div>
      </form>
    </div>
    """
  end

  defp protocol_options(current) do
    options = [
      {"Automatic", ""},
      {"OpenAI Chat Completions", "chat_completions"},
      {"OpenAI Responses", "responses"},
      {"Anthropic Messages", "anthropic"}
    ]

    if Enum.any?(options, &(elem(&1, 1) == current)),
      do: options,
      else: options ++ [{"Configured: " <> current, current}]
  end

  defp blank_name(value) when value in [nil, ""], do: "Choose a model"
  defp blank_name(value), do: value

  defp matching_models(models, query) do
    query = String.downcase(query)

    Enum.filter(models, fn model ->
      String.contains?(String.downcase(model["name"] <> " " <> model["id"]), query)
    end)
  end

  defp media_summary(form) do
    cond do
      form["image_account_pool"] == "codex" ->
        "Image generation: Codex"

      form["image_config"] in ["{}", ""] and form["account_pool"] == "codex" ->
        "Image generation: Codex default"

      Enum.any?(
        ~w(image_config video_config vision_describer_config analyze_config),
        &(form[&1] not in ["{}", ""])
      ) ->
        "Custom configuration"

      true ->
        "Runtime defaults"
    end
  end

  attr(:errors, :list, default: [])
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, default: "{}")

  defp json_field(assigns) do
    ~H"""
    <.textarea id={"config-" <> @name} name={@name} label={@label} value={@value} rows="5" errors={@errors} />
    """
  end
end
