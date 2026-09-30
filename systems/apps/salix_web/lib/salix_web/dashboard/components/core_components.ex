defmodule SalixWeb.Dashboard.CoreComponents do
  @moduledoc """
  The Salix dashboard design system — Linear-style minimalist function components
  (light theme, neutral gray, brand blue `#205BFF` accent used sparingly).
  Imported into every dashboard LiveView/HTML module via
  `use SalixWeb.Dashboard, :live_view | :html`.

  Component set: `button/1`, `input/1`, `select/1`, `textarea/1`, `toggle/1`,
  `field_label/1`, `error/1`, `table/1` (+ `:col`/`:action` slots), `modal/1`,
  `tabs/1`, `badge/1`, `status_pill/1`, `card/1`, `empty_state/1`, `dropdown/1`
  (+ `dropdown_item/1`), `markdown/1`, `icon/1`, plus `flash/1` and
  `flash_group/1`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ============================ Button ============================

  attr(:variant, :string, default: "secondary", values: ~w(primary secondary ghost danger))
  attr(:size, :string, default: "md", values: ~w(sm md))
  attr(:type, :string, default: "button")
  attr(:class, :string, default: nil)
  attr(:navigate, :string, default: nil)
  attr(:patch, :string, default: nil)
  attr(:href, :string, default: nil)

  attr(:rest, :global,
    include:
      ~w(disabled form name rel target value method phx-click phx-disable-with phx-value-id phx-value-provider phx-value-provider-key)
  )

  slot(:inner_block, required: true)

  def button(assigns) do
    assigns =
      assign(assigns, :computed_class, [
        button_base(),
        button_variant(assigns.variant),
        button_size(assigns.size),
        assigns.class
      ])

    ~H"""
    <%= if @navigate || @patch || @href do %>
      <.link navigate={@navigate} patch={@patch} href={@href} class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
    <% else %>
      <button type={@type} class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
    <% end %>
    """
  end

  defp button_base,
    do:
      "inline-flex items-center justify-center gap-1.5 rounded-md font-medium tracking-tight transition-colors focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1 disabled:opacity-50 disabled:pointer-events-none"

  defp button_size("sm"), do: "h-7 px-2.5 text-xs"
  defp button_size(_), do: "h-8 px-3 text-sm"

  defp button_variant("primary"),
    do: "bg-brand-500 text-white border border-brand-600 shadow-subtle hover:bg-brand-600"

  defp button_variant("danger"),
    do: "bg-red-600 text-white border border-red-700 shadow-subtle hover:bg-red-700"

  defp button_variant("ghost"),
    do: "text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900"

  defp button_variant(_secondary),
    do: "bg-white text-neutral-700 border border-neutral-300 hover:bg-neutral-50"

  # ============================ Markdown ============================

  @doc "Render untrusted Markdown as sanitized HTML."
  attr(:text, :string, required: true)
  attr(:class, :string, default: nil)

  def markdown(assigns) do
    assigns = assign(assigns, :html, markdown_html(assigns.text))

    ~H"""
    <div class={["conversation-markdown text-sm text-neutral-700", @class]}>
      {Phoenix.HTML.raw(@html)}
    </div>
    """
  end

  defp markdown_html(text) do
    MDEx.to_html!(text || "",
      extension: [autolink: true, strikethrough: true, table: true, tasklist: true],
      sanitize:
        Keyword.put(MDEx.Document.default_sanitize_options(), :set_tag_attribute_values, %{
          "a" => %{"target" => "_blank"}
        })
    )
  rescue
    _ -> Phoenix.HTML.html_escape(text || "") |> Phoenix.HTML.safe_to_string()
  end

  # ============================ Inputs ============================

  attr(:id, :any, default: nil)
  attr(:name, :any, default: nil)
  attr(:label, :string, default: nil)
  attr(:value, :any, default: nil)
  attr(:type, :string, default: "text")
  attr(:field, Phoenix.HTML.FormField)
  attr(:errors, :list, default: [])
  attr(:hint, :string, default: nil)
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include: ~w(autocomplete autofocus disabled placeholder readonly required step min max)
  )

  slot(:inner_block)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(assigns) do
    ~H"""
    <div class={@class}>
      <.field_label :if={@label} for={@id}>{@label}</.field_label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "block w-full h-8 rounded-md border px-2.5 text-sm placeholder:text-neutral-400 focus:outline-none focus:ring-1",
          @errors == [] && "border-neutral-300 focus:border-brand-500 focus:ring-brand-500",
          @errors != [] && "border-red-400 focus:border-red-500 focus:ring-red-500"
        ]}
        {@rest}
      />
      <p :if={@hint && @errors == []} class="mt-1 text-xs text-neutral-500">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @model_icon_dir Path.expand("../../../../assets/icons/providers", __DIR__)
  @model_icons (for path <- Path.wildcard(Path.join(@model_icon_dir, "model-*.svg")), into: %{} do
                  @external_resource path
                  {path |> Path.basename(".svg") |> String.replace_prefix("model-", ""),
                   "data:image/svg+xml;base64," <> Base.encode64(File.read!(path))}
                end)

  attr(:brand, :string, default: nil)

  def model_icon(assigns) do
    assigns = assign(assigns, :src, Map.get(@model_icons, assigns.brand, @model_icons["unknown"]))

    ~H"""
    <img src={@src} alt="" aria-hidden="true" width="20" height="20" class="h-5 w-5 shrink-0" />
    """
  end

  defp model_selection(options, catalog, prompt, value, default_icon) do
    by_id = Map.new(catalog, &{&1["template_id"], &1})

    options =
      Enum.map(options, fn
        {label, id} ->
          case by_id[id] do
            nil -> {label, id}
            template -> {SalixAgent.ModelPresentation.option_name(template), id}
          end

        option ->
          option
      end)

    {byok, platform} =
      Enum.split_with(options, fn option ->
        id = if is_list(option), do: Keyword.get(option, :value), else: elem(option, 1)
        t = by_id[id] || %{}

        t["scope"] == "tenant" or not is_nil(t["tenant_id"]) or
          t["account_pool"] in ["codex", "claude"] or
          get_in(t, ["provider_config", "account_pool"]) in ["codex", "claude"]
      end)

    platform = if prompt, do: [{prompt, ""} | platform], else: platform
    selected = by_id[value] || %{}

    brand =
      if value in [nil, ""],
        do: default_icon,
        else:
          selected["model_icon"] || selected["account_pool"] ||
            get_in(selected, ["provider_config", "account_pool"]) || selected["model_vendor"]

    groups =
      [{"Platform billing", platform}, {"BYOK", byok}]
      |> Enum.reject(fn {_, choices} -> choices == [] end)

    {groups, Map.get(@model_icons, brand, @model_icons["unknown"])}
  end

  @doc "A labelled `<select>`. Pass `:options` as for `Phoenix.HTML.Form.options_for_select/2`."
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any, default: nil)
  attr(:options, :list, required: true)
  attr(:model_catalog, :list, default: nil)
  attr(:model_default_icon, :string, default: nil)
  attr(:prompt, :string, default: nil)
  attr(:field, Phoenix.HTML.FormField)
  attr(:errors, :list, default: [])
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(disabled multiple required))

  def select(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> select()
  end

  def select(assigns) do
    {options, icon} =
      if assigns.model_catalog do
        model_selection(
          assigns.options,
          assigns.model_catalog,
          assigns.prompt,
          assigns.value,
          assigns.model_default_icon
        )
      else
        {assigns.options, nil}
      end

    assigns = assign(assigns, rendered_options: options, selected_model_icon: icon)

    ~H"""
    <div class={@class}>
      <.field_label :if={@label} for={@id}>{@label}</.field_label>
      <div class="flex items-center gap-2">
      <img :if={@selected_model_icon} src={@selected_model_icon} alt="" aria-hidden="true" width="16" height="16" class="h-4 w-4 shrink-0" />
      <select
        id={@id}
        name={@name}
        class={[
          "block w-full h-8 rounded-md border bg-white px-2.5 text-sm focus:outline-none focus:ring-1",
          @errors == [] && "border-neutral-300 focus:border-brand-500 focus:ring-brand-500",
          @errors != [] && "border-red-400 focus:border-red-500 focus:ring-red-500"
        ]}
        {@rest}
      >
        <option :if={@prompt && is_nil(@model_catalog)} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@rendered_options, @value)}
      </select>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "A labelled `<textarea>`."
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any, default: nil)
  attr(:field, Phoenix.HTML.FormField)
  attr(:errors, :list, default: [])
  attr(:hint, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(autofocus disabled placeholder readonly required rows))

  def textarea(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> textarea()
  end

  def textarea(assigns) do
    ~H"""
    <div class={@class}>
      <.field_label :if={@label} for={@id}>{@label}</.field_label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "block w-full rounded-md border px-2.5 py-1.5 text-sm font-mono placeholder:text-neutral-400 focus:outline-none focus:ring-1",
          @errors == [] && "border-neutral-300 focus:border-brand-500 focus:ring-brand-500",
          @errors != [] && "border-red-400 focus:border-red-500 focus:ring-red-500"
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint && @errors == []} class="mt-1 text-xs text-neutral-500">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "A compact toggle switch (checkbox-backed)."
  attr(:id, :any, default: nil)
  attr(:name, :any, required: true)
  attr(:label, :string, default: nil)
  attr(:checked, :boolean, default: false)
  attr(:rest, :global, include: ~w(disabled phx-click phx-value-id value))

  def toggle(assigns) do
    ~H"""
    <label class="inline-flex items-center gap-2 cursor-pointer select-none">
      <span class="relative inline-flex">
        <input type="checkbox" name={@name} id={@id} checked={@checked} class="peer sr-only" {@rest} />
        <span class="h-4 w-7 rounded-full bg-neutral-300 transition-colors peer-checked:bg-brand-500"></span>
        <span class="absolute left-0.5 top-0.5 h-3 w-3 rounded-full bg-white transition-transform peer-checked:translate-x-3"></span>
      </span>
      <span :if={@label} class="text-sm text-neutral-700">{@label}</span>
    </label>
    """
  end

  @doc "A small field label."
  attr(:for, :string, default: nil)
  slot(:inner_block, required: true)

  def field_label(assigns) do
    ~H"""
    <label for={@for} class="block text-xs font-medium text-neutral-600 mb-1">
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc "An inline field error message."
  slot(:inner_block, required: true)

  def error(assigns) do
    ~H"""
    <p class="mt-1 flex items-center gap-1 text-xs text-red-600">
      {render_slot(@inner_block)}
    </p>
    """
  end

  # ============================ Table ============================

  @doc """
  A dense table. Provide `:col` slots (each with a `:label` attr) and an optional
  trailing `:action` slot.
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil)
  attr(:row_click, :any, default: nil)
  attr(:class, :string, default: nil)

  slot :col, required: true do
    attr(:label, :string)
  end

  slot(:action)

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class={["overflow-x-auto rounded-lg border border-neutral-200", @class]}>
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-neutral-200">
            <th
              :for={col <- @col}
              class="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-neutral-500"
            >
              {col[:label]}
            </th>
            <th
              :if={@action != []}
              class="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-neutral-500"
            >
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class="divide-y divide-neutral-100"
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={["hover:bg-neutral-50", @row_click && "cursor-pointer"]}
            phx-click={@row_click && @row_click.(row)}
          >
            <td :for={col <- @col} class="px-3 py-2 align-middle text-neutral-700">
              {render_slot(col, row_item(row))}
            </td>
            <td :if={@action != []} class="px-3 py-2 text-right align-middle">
              <div class="inline-flex items-center justify-end gap-2">
                <%= for action <- @action do %>
                  {render_slot(action, row_item(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp row_item({_id, item}), do: item
  defp row_item(item), do: item

  # ============================ Modal ============================

  @doc "A centered modal with backdrop blur."
  attr(:id, :string, required: true)
  attr(:show, :boolean, default: false)
  attr(:scrollable, :boolean, default: false)
  attr(:on_cancel, JS, default: %JS{})
  slot(:title)
  slot(:inner_block, required: true)
  slot(:footer)

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["fixed inset-0 z-50", !@show && "hidden"]}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
    >
      <div
        id={"#{@id}-bg"}
        class="fixed inset-0 bg-neutral-900/30 backdrop-blur-sm transition-opacity"
        aria-hidden="true"
      />
      <div class="fixed inset-0 flex items-center justify-center p-4" role="dialog" aria-modal="true">
        <.focus_wrap
          id={"#{@id}-container"}
          phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
          phx-key="escape"
          phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
          class={[
            "w-full max-w-lg rounded-lg border border-neutral-200 bg-white shadow-lg",
            @scrollable && "max-h-[calc(100dvh-2rem)] overflow-y-auto overscroll-contain"
          ]}
        >
          <div
            :if={@title != []}
            class="flex items-center justify-between border-b border-neutral-200 px-4 py-3"
          >
            <h3 class="text-sm font-semibold">{render_slot(@title)}</h3>
            <button
              type="button"
              class="text-neutral-400 hover:text-neutral-700"
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              aria-label="Close"
            >
              <.icon name="x-mark" class="h-4 w-4" />
            </button>
          </div>
          <div class="px-4 py-4">
            {render_slot(@inner_block)}
          </div>
          <div
            :if={@footer != []}
            class="flex items-center justify-end gap-2 border-t border-neutral-200 px-4 py-3"
          >
            {render_slot(@footer)}
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  def show_modal(js \\ %JS{}, id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(to: "##{id}-bg", transition: {"ease-out duration-200", "opacity-0", "opacity-100"})
    |> JS.focus_first(to: "##{id}-container")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(to: "##{id}-bg", transition: {"ease-in duration-150", "opacity-100", "opacity-0"})
    |> JS.hide(to: "##{id}")
  end

  # ============================ Tabs ============================

  @doc "Underline-style tabs. Provide `:tab` slots; mark the current with `active`."
  attr(:class, :string, default: nil)

  slot :tab, required: true do
    attr(:label, :string)
    attr(:patch, :string)
    attr(:navigate, :string)
    attr(:href, :string)
    attr(:active, :boolean)
  end

  def tabs(assigns) do
    ~H"""
    <div class={["border-b border-neutral-200", @class]}>
      <nav class="-mb-px flex gap-4">
        <.link
          :for={tab <- @tab}
          patch={tab[:patch]}
          navigate={tab[:navigate]}
          href={tab[:href]}
          class={[
            "whitespace-nowrap border-b-2 px-1 py-2 text-sm font-medium",
            tab[:active] && "border-brand-500 text-neutral-900",
            !tab[:active] &&
              "border-transparent text-neutral-500 hover:border-neutral-300 hover:text-neutral-700"
          ]}
        >
          {tab[:label]}
        </.link>
      </nav>
    </div>
    """
  end

  # ============================ Badge / StatusPill ============================

  @doc "A small rounded badge. `:color` one of neutral/brand/green/amber/red."
  attr(:color, :string, default: "neutral", values: ~w(neutral brand green amber red))
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium",
      badge_color(@color),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_color("brand"), do: "bg-brand-50 text-brand-700"
  defp badge_color("green"), do: "bg-green-50 text-green-700"
  defp badge_color("amber"), do: "bg-amber-50 text-amber-700"
  defp badge_color("red"), do: "bg-red-50 text-red-700"
  defp badge_color(_), do: "bg-neutral-100 text-neutral-600"

  @doc """
  A status pill with a leading dot, colored by status string:
  green = connected/active/ok; amber = pending; red = error/disconnected/failed;
  neutral = idle/everything else. Pass `:label` to override the displayed text.
  """
  attr(:status, :any, required: true)
  attr(:label, :string, default: nil)

  def status_pill(assigns) do
    status = to_string(assigns.status || "")
    color = status_color(status)
    assigns = assign(assigns, color: color, text: assigns.label || status)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium",
      badge_color(@color)
    ]}>
      <span class={["h-1.5 w-1.5 rounded-full", dot_color(@color)]}></span>
      {@text}
    </span>
    """
  end

  defp status_color(status) when is_binary(status) do
    case String.downcase(status) do
      s when s in ~w(connected active ok ready healthy enabled online running completed) ->
        "green"

      s when s in ~w(pending provisioning connecting reconciling queued waiting paused) ->
        "amber"

      s when s in ~w(error disconnected failed revoked offline cancelled) ->
        "red"

      _ ->
        "neutral"
    end
  end

  defp status_color(_), do: "neutral"

  defp dot_color("brand"), do: "bg-brand-500"
  defp dot_color("green"), do: "bg-green-500"
  defp dot_color("amber"), do: "bg-amber-500"
  defp dot_color("red"), do: "bg-red-500"
  defp dot_color(_), do: "bg-neutral-400"

  # ============================ Card ============================

  @doc "A bordered card container with optional `:title`/`:actions` header."
  attr(:class, :string, default: nil)
  slot(:title)
  slot(:actions)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <div class={["rounded-lg border border-neutral-200 bg-white", @class]}>
      <div
        :if={@title != [] || @actions != []}
        class="flex items-center justify-between border-b border-neutral-200 px-4 py-3"
      >
        <h3 :if={@title != []} class="text-sm font-semibold">{render_slot(@title)}</h3>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      <div class="px-4 py-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ============================ EmptyState ============================

  @doc "An empty-state placeholder with optional icon, title, description, and action slot."
  attr(:icon, :string, default: nil)
  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:actions)

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center rounded-lg border border-dashed border-neutral-300 px-6 py-12 text-center",
      @class
    ]}>
      <.icon :if={@icon} name={@icon} class="h-6 w-6 text-neutral-400" />
      <h3 class="mt-3 text-sm font-medium text-neutral-900">{@title}</h3>
      <p :if={@description} class="mt-1 text-xs text-neutral-500">{@description}</p>
      <div :if={@actions != []} class="mt-4 flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  # ============================ Dropdown ============================

  @doc "A click-to-open dropdown menu."
  attr(:id, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:menu_class, :string, default: nil)
  attr(:floating, :boolean, default: false)
  attr(:label, :string, default: "More actions")
  attr(:align, :string, default: "right", values: ~w(left right))
  attr(:placement, :string, default: "bottom", values: ~w(bottom top))
  slot(:trigger, required: true)
  slot(:inner_block, required: true)

  def dropdown(assigns) do
    ~H"""
    <div class={["relative inline-block", @class]} id={@id} phx-hook={@floating && "FloatingDropdown"}>
      <button :if={@floating} type="button" popovertarget={"#{@id}-menu"} aria-label={@label} aria-haspopup="menu" aria-expanded="false" class="rounded-md px-2 py-1 text-sm text-neutral-600 hover:bg-neutral-100 focus-visible:outline-brand-500">{render_slot(@trigger)}</button>
      <div :if={@floating} id={"#{@id}-menu"} popover="auto" role="menu" aria-label={@label} class={["fixed m-0 min-w-44 rounded-md border border-neutral-200 bg-white py-1 text-left shadow-lg", @menu_class]}>{render_slot(@inner_block)}</div>
      <div :if={!@floating} phx-click={JS.toggle(to: "##{@id}-menu")} class="cursor-pointer">
        {render_slot(@trigger)}
      </div>
      <div :if={!@floating}
        id={"#{@id}-menu"}
        class={[
          "absolute z-40 hidden min-w-44 rounded-md border border-neutral-200 bg-white py-1 shadow-lg",
          @placement == "bottom" && "mt-1",
          @placement == "top" && "bottom-full mb-1",
          @align == "right" && "right-0",
          @align == "left" && "left-0",
          @menu_class
        ]}
        phx-click-away={JS.hide(to: "##{@id}-menu")}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "A single dropdown menu item (link or button)."
  attr(:navigate, :string, default: nil)
  attr(:patch, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(phx-click method))
  slot(:inner_block, required: true)

  def dropdown_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={["block w-full overflow-hidden px-3 py-1.5 text-sm text-neutral-700 hover:bg-neutral-50", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # ============================ Icon ============================

  @doc """
  An inline icon (small built-in SVG set). Unknown names render a neutral dot so
  missing icons never crash a page.
  """
  attr(:name, :string, required: true)
  attr(:class, :string, default: "h-4 w-4")

  def icon(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 20 20"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      {Phoenix.HTML.raw(icon_path(@name))}
    </svg>
    """
  end

  defp icon_path("home"), do: ~s(<path d="M3 9.5 10 4l7 5.5"/><path d="M5 9v7h10V9"/>)

  defp icon_path("building-office"),
    do:
      ~s(<rect x="4" y="3" width="12" height="14" rx="1"/><path d="M7 6h2M7 9h2M7 12h2M11 6h2M11 9h2M11 12h2"/>)

  defp icon_path("folder"),
    do:
      ~s(<path d="M3 6a1 1 0 0 1 1-1h3l2 2h7a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6Z"/>)

  defp icon_path("users"),
    do:
      ~s(<circle cx="7" cy="7" r="2.5"/><path d="M3 16c0-2.2 1.8-4 4-4s4 1.8 4 4"/><path d="M13 12c1.7 0 3 1.3 3 3"/><circle cx="13.5" cy="7.5" r="2"/>)

  defp icon_path("cog"),
    do:
      ~s(<circle cx="10" cy="10" r="2.5"/><path d="M10 3v2M10 15v2M3 10h2M15 10h2M5 5l1.5 1.5M13.5 13.5 15 15M15 5l-1.5 1.5M6.5 13.5 5 15"/>)

  defp icon_path("plug"),
    do: ~s(<path d="M8 3v4M12 3v4"/><path d="M6 7h8v3a4 4 0 0 1-8 0V7Z"/><path d="M10 14v3"/>)

  defp icon_path("bolt"), do: ~s(<path d="M11 3 5 11h4l-1 6 6-8h-4l1-6Z"/>)

  defp icon_path("pulse"), do: ~s(<path d="M2 10h3.5L8 4.5 12 15.5l2.5-5.5H17"/>)

  defp icon_path("cube"),
    do: ~s(<path d="M10 3 4 6.5v7L10 17l6-3.5v-7L10 3Z"/><path d="M4 6.5 10 10l6-3.5M10 10v7"/>)

  defp icon_path("server"),
    do:
      ~s(<rect x="3" y="4" width="14" height="5" rx="1"/><rect x="3" y="11" width="14" height="5" rx="1"/><path d="M6 6.5h.01M6 13.5h.01"/>)

  defp icon_path("template"),
    do: ~s(<rect x="3" y="3" width="14" height="14" rx="1"/><path d="M3 8h14M8 8v9"/>)

  defp icon_path("chat"),
    do: ~s(<path d="M4 5h12a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1H8l-4 3V6a1 1 0 0 1 1-1Z"/>)

  defp icon_path("key"),
    do: ~s(<circle cx="7" cy="7" r="3"/><path d="m9 9 7 7M14 14l2-2M12 12l2-2"/>)

  defp icon_path("file"),
    do:
      ~s(<path d="M5 3h7l3 3v11a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Z"/><path d="M12 3v3h3"/>)

  defp icon_path("chevron-down"), do: ~s(<path d="m6 8 4 4 4-4"/>)
  defp icon_path("chevron-right"), do: ~s(<path d="m8 6 4 4-4 4"/>)
  defp icon_path("x-mark"), do: ~s(<path d="m5 5 10 10M15 5 5 15"/>)
  defp icon_path("plus"), do: ~s(<path d="M10 4v12M4 10h12"/>)
  defp icon_path("check"), do: ~s(<path d="m4 10 4 4 8-8"/>)
  defp icon_path("trash"), do: ~s(<path d="M4 6h12M8 6V4h4v2M6 6l1 10h6l1-10"/>)
  defp icon_path("search"), do: ~s(<circle cx="9" cy="9" r="5"/><path d="m13 13 3 3"/>)
  defp icon_path("arrow-left"), do: ~s(<path d="M16 10H4M9 5l-5 5 5 5"/>)
  defp icon_path("refresh"), do: ~s(<path d="M15 5a6 6 0 1 0 1.5 4"/><path d="M16 3v3h-3"/>)
  defp icon_path("chart-bar"), do: ~s(<path d="M4 16v-6M10 16V4M16 16v-9"/><path d="M3 16h14"/>)

  defp icon_path("logout"),
    do: ~s(<path d="M8 5H5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h3"/><path d="M12 7l3 3-3 3M15 10H8"/>)

  defp icon_path(_), do: ~s(<circle cx="10" cy="10" r="2"/>)

  # ============================ Flash ============================

  @doc "Renders a single flash kind (`:info` | `:error`) from the flash map."
  attr(:flash, :map, default: %{})
  attr(:kind, :atom, values: [:info, :error])
  attr(:id, :string, default: nil)

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.hide(to: "##{@id}")}
      role="alert"
      class={[
        "pointer-events-auto cursor-pointer rounded-md border px-3 py-2 text-xs shadow-subtle",
        @kind == :info && "border-neutral-200 bg-white text-neutral-700",
        @kind == :error && "border-red-200 bg-red-50 text-red-700"
      ]}
    >
      {msg}
    </div>
    """
  end

  @doc "Renders the standard info/error flash group, fixed top-right."
  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-3 right-3 z-50 flex w-72 flex-col gap-2">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  # ============================ Error translation ============================

  @doc "Translate an Ecto changeset error tuple to a string (no gettext)."
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  def translate_error(msg) when is_binary(msg), do: msg
end
