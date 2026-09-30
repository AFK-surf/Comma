defmodule BridgeForTeamsWeb.Dashboard.CoreComponents do
  @moduledoc """
  The BridgeForTeams dashboard design system — Linear-style minimalist function
  components (light theme, neutral gray, brand blue `#205BFF` accent used
  sparingly). Imported into every dashboard LiveView/HTML module via
  `use BridgeForTeamsWeb.Dashboard, :live_view | :html`.

  These signatures are STABLE — page agents compose them, they do not change
  them. Component set: `button/1`, `input/1`, `select/1`, `textarea/1`,
  `toggle/1`, `table/1` (+ `:col`/`:action` slots), `modal/1`, `tabs/1`
  (+ `tab/1`), `badge/1`, `status_pill/1`, `card/1`, `empty_state/1`,
  `dropdown/1` (+ `dropdown_item/1`), `markdown/1`, `org_avatar/1`,
  `icon/1`, plus `flash/1` and `flash_group/1`.
  """
  use Phoenix.Component
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias Phoenix.LiveView.JS

  # ============================ Button ============================

  @doc """
  A button. Renders a `<button>` (or an `<a>`/`<.link>` when given `navigate`,
  `patch`, or `href`).

  ## Attrs
    * `:variant` — `"primary"` | `"secondary"` | `"ghost"` | `"danger"` (default "secondary")
    * `:size` — `"sm"` (h-7) | `"md"` (h-8) (default "md")
    * `:type` — button type (default "button")
    * `:navigate` / `:patch` / `:href` — render as a link instead
    * any global attr (`phx-click`, `disabled`, `class`, `form`, ...)
  """
  attr(:variant, :string, default: "secondary", values: ~w(primary secondary ghost danger))
  attr(:size, :string, default: "md", values: ~w(sm md))
  attr(:type, :string, default: "button")
  attr(:class, :string, default: nil)
  attr(:navigate, :string, default: nil)
  attr(:patch, :string, default: nil)
  attr(:href, :string, default: nil)

  attr(:rest, :global,
    include: ~w(disabled form name rel target value phx-click phx-disable-with)
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
      <.link
        navigate={@navigate}
        patch={@patch}
        href={@href}
        class={@computed_class}
        {@rest}
      >
        {render_slot(@inner_block)}
      </.link>
    <% else %>
      <button type={@type} class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
    <% end %>
    """
  end

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
      extension: [
        autolink: true,
        strikethrough: true,
        table: true,
        tasklist: true
      ],
      sanitize:
        Keyword.put(MDEx.Document.default_sanitize_options(), :set_tag_attribute_values, %{
          "a" => %{"target" => "_blank"}
        })
    )
  rescue
    _ -> Phoenix.HTML.html_escape(text || "") |> Phoenix.HTML.safe_to_string()
  end

  # Quiet 28px controls with a light press deformation (physics-active-state:
  # scale stays inside 0.95-1.05, transitions inside the 120-180ms hover band).
  defp button_base,
    do:
      "inline-flex items-center justify-center gap-1.5 rounded-md font-medium tracking-tight " <>
        "transition-[color,background-color,border-color,transform,box-shadow] duration-150 ease-out " <>
        "active:scale-[0.98] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 " <>
        "focus-visible:ring-offset-1 disabled:opacity-50 disabled:pointer-events-none"

  defp button_size("sm"), do: "h-7 px-2.5 text-xs"
  defp button_size(_), do: "h-8 px-3 text-[13px]"

  defp button_variant("primary"),
    do: "bg-brand-500 text-white shadow-subtle hover:bg-brand-600"

  defp button_variant("danger"),
    do: "bg-red-600 text-white shadow-subtle hover:bg-red-700"

  defp button_variant("ghost"),
    do: "text-neutral-600 hover:bg-neutral-200/60 hover:text-neutral-900"

  defp button_variant(_secondary),
    do: "bg-white text-neutral-800 border border-neutral-300 shadow-subtle hover:bg-neutral-50"

  # ============================ Inputs ============================

  @doc """
  A labelled text-like input. Supports `type` of text/email/password/number/etc.
  Pass a `Phoenix.HTML.FormField` as `:field` to wire name/id/value/errors, or
  pass `:name`/`:value` directly.
  """
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any)
  attr(:type, :string, default: "text")
  attr(:field, Phoenix.HTML.FormField)
  attr(:errors, :list, default: [])
  attr(:hint, :string, default: nil)
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include:
      ~w(autocomplete autofocus disabled placeholder readonly required step min max maxlength)
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

  defp model_selection(options, catalog, prompt, value, default_icon) do
    by_id = Map.new(catalog, &{&1["template_id"], &1})

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
      [{gettext("Platform billing"), platform}, {"BYOK", byok}]
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
    explicit_value = Map.get(assigns, :value)
    value = if is_nil(explicit_value), do: field.value, else: explicit_value

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign(:value, value)
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
  attr(:value, :any)
  attr(:field, Phoenix.HTML.FormField)
  attr(:errors, :list, default: [])
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
    assigns = assign_new(assigns, :value, fn -> nil end)

    ~H"""
    <div class={@class}>
      <.field_label :if={@label} for={@id}>{@label}</.field_label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "block w-full rounded-md border px-2.5 py-1.5 text-sm placeholder:text-neutral-400 focus:outline-none focus:ring-1",
          @errors == [] && "border-neutral-300 focus:border-brand-500 focus:ring-brand-500",
          @errors != [] && "border-red-400 focus:border-red-500 focus:ring-red-500"
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "An image upload control that stores the selected image as a hidden data URL field."
  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:value, :string, default: "")
  attr(:label, :string, default: nil)
  attr(:initial, :string, default: "?")
  attr(:errors, :list, default: [])

  def org_icon_upload(assigns) do
    ~H"""
    <div id={@id} phx-hook="OrgIconUpload" phx-update="ignore">
      <.field_label for={"#{@id}-file"}>{@label || gettext("Icon")}</.field_label>
      <div class="flex items-center gap-3">
        <div class="flex h-10 w-10 shrink-0 items-center justify-center overflow-hidden rounded-md bg-brand-500 text-sm font-semibold text-white">
          <img
            data-org-icon-preview
            src={@value}
            alt=""
            class={["h-full w-full object-cover", (@value || "") == "" && "hidden"]}
          />
          <span data-org-icon-fallback class={(@value || "") != "" && "hidden"}>{@initial}</span>
        </div>
        <div class="min-w-0 flex-1">
          <input type="hidden" name={@name} value={@value} data-org-icon-value />
          <input
            id={"#{@id}-file"}
            type="file"
            accept="image/png,image/jpeg,image/gif,image/webp"
            class="block w-full text-sm text-neutral-600 file:mr-3 file:h-8 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3 file:text-sm file:font-medium file:text-neutral-700 hover:file:bg-neutral-50"
          />
          <button
            type="button"
            data-org-icon-clear
            class={["mt-2 text-xs text-neutral-500 hover:text-neutral-900", (@value || "") == "" && "hidden"]}
          >
            {gettext("Clear icon")}
          </button>
        </div>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "A compact toggle switch (checkbox-backed)."
  attr(:id, :any, default: nil)
  attr(:name, :any, required: true)
  attr(:label, :string, default: nil)
  attr(:checked, :boolean, default: false)
  attr(:rest, :global, include: ~w(disabled phx-click value))

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
  trailing `:action` slot. `:rows` is the enumerable; `:row_id`/`:row_click` are
  optional.

      <.table id="projects" rows={@projects}>
        <:col :let={p} label="Name">{p.name}</:col>
        <:col :let={p} label="Status"><.status_pill status={p.status} /></:col>
        <:action :let={p}><.button size="sm">Edit</.button></:action>
      </.table>
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil)
  attr(:row_click, :any, default: nil)
  attr(:class, :string, default: nil)
  attr(:action_align, :string, default: "right", values: ~w(left right))

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
            <th :for={col <- @col} class="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-neutral-500">
              {col[:label]}
            </th>
            <th
              :if={@action != []}
              class={[
                "relative px-3 py-2 text-xs font-medium uppercase tracking-wide text-neutral-500",
                @action_align == "left" && "text-left",
                @action_align == "right" && "text-right"
              ]}
            >
              <span class="sr-only left-0 top-0">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"} class="divide-y divide-neutral-100">
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={["hover:bg-neutral-50", @row_click && "cursor-pointer"]}
            phx-click={@row_click && @row_click.(row)}
          >
            <td :for={col <- @col} class="px-3 py-2 align-middle text-neutral-700">
              {render_slot(col, row_item(row))}
            </td>
            <td
              :if={@action != []}
              class={[
                "whitespace-nowrap px-3 py-2 align-middle",
                @action_align == "left" && "text-left",
                @action_align == "right" && "text-right"
              ]}
            >
              <div class={[
                "inline-flex items-center gap-2 whitespace-nowrap",
                @action_align == "left" && "justify-start",
                @action_align == "right" && "justify-end"
              ]}>
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

  @doc """
  A centered modal with backdrop blur. Show/hide with `show_modal/1` / `hide_modal/1`
  (or `:if`). Closes on Esc and backdrop click; emits `on_cancel` (a `JS` command).

      <.modal id="new-project" show={@show} on_cancel={JS.push("close")}>
        <:title>New project</:title>
        ...body...
      </.modal>
  """
  attr(:id, :string, required: true)
  attr(:show, :boolean, default: false)
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
      data-cancel={JS.exec("phx-remove") |> JS.concat(@on_cancel)}
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
          class="w-full max-w-lg rounded-xl bg-white shadow-popover"
        >
          <div :if={@title != []} class="flex items-center justify-between border-b border-neutral-200 px-4 py-3">
            <h3 class="text-sm font-semibold">{render_slot(@title)}</h3>
            <button
              type="button"
              class="text-neutral-400 hover:text-neutral-700"
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              aria-label={gettext("Close")}
            >
              <.icon name="x-mark" class="h-4 w-4" />
            </button>
          </div>
          <div class="px-4 py-4">
            {render_slot(@inner_block)}
          </div>
          <div :if={@footer != []} class="flex items-center justify-end gap-2 border-t border-neutral-200 px-4 py-3">
            {render_slot(@footer)}
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  # transitions.dev modal: scale up from 0.96 on open (250ms ease-out), softer
  # and faster scale-down on close (150ms ease-in).
  def show_modal(js \\ %JS{}, id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(to: "##{id}-bg", transition: {"ease-out duration-200", "opacity-0", "opacity-100"})
    |> JS.show(
      to: "##{id}-container",
      display: "block",
      transition: {"ease-out duration-[250ms]", "opacity-0 scale-[0.96]", "opacity-100 scale-100"}
    )
    |> JS.focus_first(to: "##{id}-container")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-container",
      transition: {"ease-in duration-150", "opacity-100 scale-100", "opacity-0 scale-[0.96]"}
    )
    |> JS.hide(to: "##{id}-bg", transition: {"ease-in duration-150", "opacity-100", "opacity-0"})
    |> JS.hide(to: "##{id}")
  end

  # ============================ Drawer ============================

  @doc "A responsive right-side panel for details and contextual editing."
  attr(:id, :string, required: true)
  attr(:show, :boolean, default: false)
  attr(:size, :string, default: "lg", values: ~w(md lg xl))
  attr(:on_cancel, JS, default: %JS{})
  slot(:title)
  slot(:navigation)
  slot(:inner_block, required: true)
  slot(:footer)

  def side_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={["fixed inset-0 z-50", !@show && "hidden"]}
      phx-mounted={@show && show_side_panel(@id)}
      phx-remove={hide_side_panel(@id)}
      data-cancel={JS.exec("phx-remove") |> JS.concat(@on_cancel)}
    >
      <button
        id={"#{@id}-bg"}
        type="button"
        tabindex="-1"
        class="fixed inset-0 hidden bg-neutral-900/25 opacity-0 backdrop-blur-[1px]"
        aria-hidden="true"
        phx-click={JS.exec("data-cancel", to: "##{@id}")}
      />
      <div class="pointer-events-none fixed inset-0 flex justify-end">
        <.focus_wrap
          id={"#{@id}-container"}
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
          phx-key="escape"
          class={[
            "pointer-events-auto hidden h-full w-full translate-x-full flex-col bg-white shadow-popover sm:rounded-l-lg",
            side_panel_width(@size)
          ]}
        >
          <div class="flex min-h-14 shrink-0 items-center justify-between border-b border-neutral-200 px-4 sm:px-5">
            <h2 id={"#{@id}-title"} class="min-w-0 truncate text-sm font-semibold text-neutral-900">
              {render_slot(@title)}
            </h2>
            <button
              type="button"
              class="grid h-8 w-8 shrink-0 place-items-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              aria-label={gettext("Close")}
            >
              <.icon name="x-mark" class="h-4 w-4" />
            </button>
          </div>
          <div :if={@navigation != []} data-slot="side-panel-navigation" class="shrink-0 border-b border-neutral-200 px-4 sm:px-5">
            {render_slot(@navigation)}
          </div>
          <div data-slot="side-panel-body" class="min-h-0 flex-1 overflow-y-auto px-4 py-5 sm:px-5">
            {render_slot(@inner_block)}
          </div>
          <div
            :if={@footer != []}
            class="flex items-center justify-end gap-2 border-t border-neutral-200 px-4 py-3 sm:px-5"
          >
            {render_slot(@footer)}
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  def show_side_panel(js \\ %JS{}, id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(to: "##{id}-bg", transition: {"ease-out duration-200", "opacity-0", "opacity-100"})
    |> JS.show(
      to: "##{id}-container",
      display: "flex",
      transition: {"ease-out duration-200", "translate-x-full", "translate-x-0"}
    )
    |> JS.focus_first(to: "##{id}-container")
  end

  def hide_side_panel(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-container",
      transition: {"ease-in duration-150", "translate-x-0", "translate-x-full"}
    )
    |> JS.hide(to: "##{id}-bg", transition: {"ease-in duration-150", "opacity-100", "opacity-0"})
    |> JS.hide(to: "##{id}")
  end

  defp side_panel_width("md"), do: "sm:max-w-md"
  defp side_panel_width("xl"), do: "sm:max-w-3xl"
  defp side_panel_width(_size), do: "sm:max-w-2xl"

  # ============================ Tabs ============================

  @doc """
  Underline-style tabs. Provide `:tab` slots; mark the current with `active`.

      <.tabs>
        <:tab label="Overview" patch={~p"/.."} active />
        <:tab label="Agents" patch={~p"/../agents"} />
      </.tabs>
  """
  attr(:id, :string, default: "section-tabs")
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
    <% active_tab = Enum.find(@tab, & &1[:active]) || List.first(@tab) %>
    <div class={@class}>
      <details id={@id} class="group relative xl:hidden">
        <summary class="flex h-9 cursor-pointer list-none items-center justify-between rounded-md border border-neutral-200 bg-white px-3 text-sm font-medium text-neutral-800 marker:hidden">
          <span>{active_tab[:label]}</span>
          <.icon name="chevron-down" variant="outlined" class="h-4 w-4 text-neutral-500 transition-transform group-open:rotate-180" />
        </summary>
        <nav class="absolute left-0 right-0 top-10 z-30 max-h-72 overflow-y-auto rounded-lg bg-white p-1 shadow-popover">
          <.link
            :for={tab <- @tab}
            patch={tab[:patch]}
            navigate={tab[:navigate]}
            href={tab[:href]}
            aria-current={tab[:active] && "page"}
            phx-click={JS.remove_attribute("open", to: "##{@id}")}
            class={[
              "block rounded-md px-3 py-2 text-sm",
              tab[:active] && "bg-neutral-100 font-medium text-neutral-900",
              !tab[:active] && "text-neutral-600 hover:bg-neutral-50 hover:text-neutral-900"
            ]}
          >
            {tab[:label]}
          </.link>
        </nav>
      </details>
      <nav class="-mb-px hidden gap-4 border-b border-neutral-200 xl:flex">
        <.link
          :for={tab <- @tab}
          patch={tab[:patch]}
          navigate={tab[:navigate]}
          href={tab[:href]}
          aria-current={tab[:active] && "page"}
          class={[
            "whitespace-nowrap border-b-2 px-1 py-2 text-sm font-medium",
            tab[:active] && "border-brand-500 text-neutral-900",
            !tab[:active] && "border-transparent text-neutral-500 hover:border-neutral-300 hover:text-neutral-700"
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

  # Linear-style: color is carried by a small dot, never a filled surface;
  # neutral badges are plain muted text (no dot, no background).
  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap text-xs font-medium text-neutral-600",
      @class
    ]}>
      <span :if={@color != "neutral"} class={["h-1.5 w-1.5 rounded-full", dot_color(@color)]}>
      </span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A status pill with a leading dot, colored by status string:
  green = connected/active/ok; amber = pending; red = error/disconnected/failed;
  neutral = idle/everything else. Pass `:label` to override the displayed text.
  """
  attr(:status, :string, required: true)
  attr(:label, :string, default: nil)

  def status_pill(assigns) do
    color = status_color(assigns.status)
    assigns = assign(assigns, color: color, text: assigns.label || assigns.status)

    ~H"""
    <span class="inline-flex items-center gap-1.5 whitespace-nowrap text-xs font-medium text-neutral-600">
      <span class={["h-1.5 w-1.5 rounded-full", dot_color(@color)]}></span>
      {@text}
    </span>
    """
  end

  defp status_color(status) when is_binary(status) do
    case String.downcase(status) do
      s when s in ~w(connected active ok ready healthy enabled online completed done) ->
        "green"

      s
      when s in ~w(pending ready_for_review escalated provisioning connecting reconciling preflight starting_connector waiting_for_attach stop_requested stopping recently_lost degraded needs_manual warning) ->
        "amber"

      s when s in ~w(preflight_complete idle stopped cancelled) ->
        "neutral"

      s when s in ~w(error disconnected failed fail revoked offline critical denied) ->
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

  # ======================= RunChecks panel =======================

  @doc """
  Renders a RunChecks result — the shared shape across the SSO and bot setup
  surfaces (see `docs/bridge-for-teams/design.md` §6). `:checks`
  is `%{ran_at, gates: [%{label, status, next_action}]}` where `status` is one
  of `:ok | :fail | :needs_manual | :skipped`.
  """
  attr(:checks, :map, required: true)
  attr(:class, :string, default: nil)

  def run_checks_panel(assigns) do
    ~H"""
    <div class={["rounded-md border border-neutral-200 bg-neutral-50/60 p-4", @class]}>
      <div class="mb-2 flex items-center justify-between">
        <h4 class="text-xs font-semibold tracking-wide text-neutral-700">{gettext("Checks")}</h4>
        <span :if={@checks[:ran_at]} class="text-xs text-neutral-400">{run_checks_time(@checks.ran_at)}</span>
      </div>
      <ul class="space-y-2">
        <li :for={gate <- @checks.gates} class="flex items-start gap-2">
          <.status_pill
            status={run_checks_status(gate.status)}
            label={run_checks_label(gate.status, gate[:reason_class])}
          />
          <div class="min-w-0">
            <p class="text-sm text-neutral-800">{gate.label}</p>
            <p :if={gate[:reason_class]} class="text-xs text-neutral-500">
              {gettext("Reason")}: {run_checks_reason(gate.reason_class)}
            </p>
            <p :if={gate[:next_action]} class="text-xs text-neutral-500">{gate.next_action}</p>
            <% evidence_items = run_checks_evidence_items(gate[:evidence]) %>
            <dl
              :if={evidence_items != []}
              class="mt-1 grid grid-cols-1 gap-x-3 gap-y-1 text-xs text-neutral-500 sm:grid-cols-2"
            >
              <div :for={{key, value} <- evidence_items} class="min-w-0">
                <dt class="font-medium text-neutral-400">{key}</dt>
                <dd class="break-words font-mono text-neutral-600">{value}</dd>
              </div>
            </dl>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp run_checks_status(:ok), do: "ok"
  defp run_checks_status(:needs_manual), do: "pending"
  defp run_checks_status(:fail), do: "error"
  defp run_checks_status(_), do: "idle"

  defp run_checks_label(:needs_manual, reason)
       when reason in [
              :calendar_initial_sync_pending,
              :calendar_enrollment_retrying,
              :calendar_source_maintenance_retrying,
              "calendar_initial_sync_pending",
              "calendar_enrollment_retrying",
              "calendar_source_maintenance_retrying"
            ],
       do: gettext("Pending")

  defp run_checks_label(:ok, _reason), do: gettext("OK")
  defp run_checks_label(:needs_manual, _reason), do: gettext("Manual")
  defp run_checks_label(:fail, _reason), do: gettext("Failed")
  defp run_checks_label(_status, _reason), do: gettext("Skipped")

  defp run_checks_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S UTC")
  defp run_checks_time(_), do: ""

  defp run_checks_reason(reason) when is_atom(reason),
    do: run_checks_reason(Atom.to_string(reason))

  defp run_checks_reason(reason) when is_binary(reason) do
    reason
    |> String.replace("_", " ")
    |> String.replace("-", " ")
  end

  defp run_checks_reason(reason), do: inspect(reason)

  defp run_checks_evidence_items(evidence) when evidence in [nil, %{}], do: []

  defp run_checks_evidence_items(evidence) when is_map(evidence) do
    evidence
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Enum.map(fn {key, value} ->
      {run_checks_reason(key), run_checks_evidence_value(value)}
    end)
  end

  defp run_checks_evidence_items(_evidence), do: []

  defp run_checks_evidence_value(value) when is_boolean(value),
    do: if(value, do: "true", else: "false")

  defp run_checks_evidence_value(value) when is_atom(value), do: Atom.to_string(value)
  defp run_checks_evidence_value(value) when is_binary(value), do: value
  defp run_checks_evidence_value(value) when is_number(value), do: to_string(value)

  defp run_checks_evidence_value(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: Enum.join(value, ", "), else: Jason.encode!(value)
  end

  defp run_checks_evidence_value(value) when is_map(value), do: Jason.encode!(value)
  defp run_checks_evidence_value(value), do: inspect(value)

  # ============================ Card ============================

  @doc "A bordered card container with optional `:title`/`:actions` header."
  attr(:class, :string, default: nil)
  slot(:title)
  slot(:actions)
  slot(:inner_block, required: true)

  # Hairline card: the header is separated by spacing, not a second border.
  def card(assigns) do
    ~H"""
    <div class={["rounded-lg border border-neutral-200 bg-white", @class]}>
      <div
        :if={@title != [] || @actions != []}
        class="flex items-center justify-between px-4 pb-1 pt-3.5"
      >
        <h3 :if={@title != []} class="text-[13px] font-semibold text-neutral-900">
          {render_slot(@title)}
        </h3>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      <div class={[(@title != [] || @actions != []) && "px-4 pb-4 pt-2", @title == [] && @actions == [] && "px-4 py-4"]}>
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

  # Quiet empty state: a faint oversized ghost glyph instead of a dashed box.
  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center px-6 py-14 text-center", @class]}>
      <.icon :if={@icon} name={@icon} class="h-10 w-10 text-neutral-900 opacity-[0.06]" />
      <h3 class="mt-3 text-sm font-medium text-neutral-800">{@title}</h3>
      <p :if={@description} class="mt-1 max-w-sm text-xs text-neutral-500">{@description}</p>
      <div :if={@actions != []} class="mt-4 flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  # ============================ Dropdown ============================

  @doc """
  A click-to-open dropdown menu. Put the trigger in the `:trigger` slot and
  `dropdown_item/1`s (or any content) in the default slot.
  """
  attr(:id, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:menu_class, :string, default: nil)
  attr(:align, :string, default: "right", values: ~w(left right))
  attr(:placement, :string, default: "bottom", values: ~w(bottom top))
  slot(:trigger, required: true)
  slot(:inner_block, required: true)

  def dropdown(assigns) do
    ~H"""
    <div class={["relative inline-block", @class]} id={@id}>
      <div phx-click={toggle_dropdown("##{@id}-menu")} class="cursor-pointer">
        {render_slot(@trigger)}
      </div>
      <div
        id={"#{@id}-menu"}
        class={[
          "t-dropdown-enter absolute z-40 hidden min-w-44 rounded-lg bg-white py-1 shadow-popover",
          @placement == "bottom" && "mt-1 origin-top",
          @placement == "top" && "bottom-full mb-1 origin-bottom",
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
      class={["block px-3 py-1.5 text-sm text-neutral-700 hover:bg-neutral-50", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp toggle_dropdown(js \\ %JS{}, sel) do
    JS.toggle(js, to: sel)
  end

  # ============================ OrgAvatar ============================

  @doc "An organization avatar. Uses the stored inline icon when present, otherwise initials."
  attr(:org, :any, default: nil)
  attr(:size, :string, default: "md", values: ~w(xs sm md lg))
  attr(:class, :string, default: nil)

  def org_avatar(assigns) do
    assigns =
      assigns
      |> assign(:icon, org_icon(assigns.org))
      |> assign(:initial, org_initial(assigns.org))

    ~H"""
    <div class={[org_avatar_size(@size), "flex shrink-0 items-center justify-center overflow-hidden rounded-md bg-brand-500 font-semibold text-white", @class]}>
      <img :if={@icon} src={@icon} alt="" class="h-full w-full object-cover" />
      <span :if={is_nil(@icon)} class={org_avatar_text_size(@size)}>{@initial}</span>
    </div>
    """
  end

  defp org_icon(%{icon: icon}) when is_binary(icon) and icon != "", do: icon
  defp org_icon(_), do: nil

  defp org_initial(nil), do: "·"

  defp org_initial(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp org_initial(_), do: "?"

  defp org_avatar_size("xs"), do: "h-5 w-5"
  defp org_avatar_size("sm"), do: "h-6 w-6"
  defp org_avatar_size("lg"), do: "h-10 w-10"
  defp org_avatar_size(_), do: "h-9 w-9"

  defp org_avatar_text_size("xs"), do: "text-[10px]"
  defp org_avatar_text_size("sm"), do: "text-[11px]"
  defp org_avatar_text_size("lg"), do: "text-sm"
  defp org_avatar_text_size(_), do: "text-sm"

  # ============================ Icon ============================

  @doc """
  An inline SVG icon from the Central Icons set by Iconists, vendored as
  static markup so no JS dependency is needed. The default body style is
  round-filled-radius-2-stroke-2; `variant="square"` (section-card headers)
  uses square-filled-radius-0-stroke-2 and falls back to the round path when
  no square variant is vendored. Unknown names render a neutral dot so
  missing icons never crash a page.
  `:name` examples: home, building-office, folder, users, cog, plug, bolt,
  zap, chart-bar, cube, chevron-down, x-mark, plus, check, search,
  arrow-left, drag-handle.
  """
  attr(:name, :string, required: true)
  attr(:class, :string, default: "h-4 w-4")
  attr(:variant, :string, default: "round", values: ~w(round square outlined))

  def icon(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      {Phoenix.HTML.raw(icon_path(@variant, @name))}
    </svg>
    """
  end

  # round-outlined-radius-2-stroke-2 — sidebar chrome glyphs
  defp icon_path("outlined", "building-office") do
    ~S"""
    <path d="M10 9H8" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M8 13H10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M20 19V10C20 8.89543 19.1046 8 18 8H14" stroke="currentColor" stroke-width="2" stroke-miterlimit="16" stroke-linecap="round" stroke-linejoin="round"></path><path d="M14 19V6C14 4.89543 13.1046 4 12 4H6C4.89543 4 4 4.89543 4 6V19" stroke="currentColor" stroke-width="2" stroke-miterlimit="16" stroke-linecap="round" stroke-linejoin="round"></path><path d="M22 19H2" stroke="currentColor" stroke-width="2" stroke-miterlimit="16" stroke-linecap="round" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "chart-bar") do
    ~S"""
    <path d="M5.665 13.7773C4.74545 13.7773 4 14.5228 4 15.4423V18.3346C4 19.2541 4.74545 19.9996 5.665 19.9996C6.58455 19.9996 7.33 19.2541 7.33 18.3346V15.4423C7.33 14.5228 6.58455 13.7773 5.665 13.7773Z" stroke="currentColor" stroke-width="2" stroke-linecap="square" stroke-linejoin="round"></path><path d="M11.995 9.33398C11.0755 9.33398 10.33 10.0794 10.33 10.999V18.3356C10.33 19.2552 11.0755 20.0007 11.995 20.0007C12.9146 20.0007 13.66 19.2552 13.66 18.3356V10.999C13.66 10.0794 12.9146 9.33398 11.995 9.33398Z" stroke="currentColor" stroke-width="2" stroke-linecap="square" stroke-linejoin="round"></path><path d="M18.335 4C17.4154 4 16.67 4.74545 16.67 5.665V18.335C16.67 19.2546 17.4154 20 18.335 20C19.2546 20 20 19.2546 20 18.335V5.665C20 4.74545 19.2546 4 18.335 4Z" stroke="currentColor" stroke-width="2" stroke-linecap="square" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "check") do
    ~S"""
    <path d="M5 12.75L10 19L19 5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "chevron-down") do
    ~S"""
    <path d="M8 10L11.2929 13.2929C11.6834 13.6834 12.3166 13.6834 12.7071 13.2929L16 10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "cog") do
    ~S"""
    <path d="M18.9805 6.92648L12.9805 3.55152C12.3717 3.20906 11.6283 3.20906 11.0195 3.55152L5.01949 6.92646C4.38973 7.28069 4 7.94707 4 8.66962V15.3305C4 16.0531 4.38975 16.7194 5.01954 17.0737L11.0195 20.4484C11.6283 20.7908 12.3717 20.7908 12.9805 20.4483L18.9805 17.0734C19.6103 16.7192 20 16.0528 20 15.3302V8.66964C20 7.94709 19.6103 7.28072 18.9805 6.92648Z" stroke="currentColor" stroke-width="2" stroke-linecap="square" stroke-linejoin="round"></path><path d="M15 12C15 13.6569 13.6569 15 12 15C10.3431 15 9 13.6569 9 12C9 10.3431 10.3431 9 12 9C13.6569 9 15 10.3431 15 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="square" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "folder") do
    ~S"""
    <path d="M3 6V17C3 18.1046 3.89543 19 5 19H19C20.1046 19 21 18.1046 21 17V9C21 7.89543 20.1046 7 19 7H12.5352C12.2008 7 11.8886 6.8329 11.7031 6.5547L10.5937 4.8906C10.2228 4.3342 9.59834 4 8.92963 4H5C3.89543 4 3 4.89543 3 6Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "home") do
    ~S"""
    <path d="M4 9.77313C4 9.2136 4 8.93383 4.07063 8.67517C4.1332 8.446 4.23609 8.22982 4.3745 8.03675C4.53071 7.81882 4.74784 7.6424 5.1821 7.28957L9.9821 3.38956C10.7014 2.80513 11.0611 2.51291 11.4609 2.40099C11.8135 2.30229 12.1865 2.30229 12.5391 2.40099C12.9389 2.51291 13.2986 2.80513 14.0179 3.38957L18.8179 7.28957C19.2522 7.6424 19.4693 7.81882 19.6255 8.03675C19.7639 8.22982 19.8668 8.446 19.9294 8.67517C20 8.93383 20 9.2136 20 9.77313V16.8C20 17.9201 20 18.4802 19.782 18.908C19.5903 19.2843 19.2843 19.5903 18.908 19.782C18.4802 20 17.9201 20 16.8 20H7.2C6.07989 20 5.51984 20 5.09202 19.782C4.71569 19.5903 4.40973 19.2843 4.21799 18.908C4 18.4802 4 17.9201 4 16.8V9.77313Z" stroke="currentColor" stroke-width="2" stroke-linejoin="round"></path>
    """
  end

  # Central Icons IconPlugin1 (aliases: plugin-1, power, adapter) — the round
  # variant of the same glyph is vendored as "plug".
  defp icon_path("outlined", "plug") do
    ~S"""
    <path d="M19 14V9C19 7.89543 18.1046 7 17 7H7C5.89543 7 5 7.89543 5 9V14C5 16.2091 6.79086 18 9 18H15C17.2091 18 19 16.2091 19 14Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M12 18V21" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M15 7V3" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M9 7V3" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "search") do
    ~S"""
    <path d="M11 18C14.866 18 18 14.866 18 11C18 7.13401 14.866 4 11 4C7.13401 4 4 7.13401 4 11C4 14.866 7.13401 18 11 18Z" stroke="currentColor" stroke-width="2" stroke-linecap="round"></path><path d="M20 20L16.05 16.05" stroke="currentColor" stroke-width="2" stroke-linecap="round"></path>
    """
  end

  defp icon_path("outlined", "sparkles") do
    ~S"""
    <path d="M3 12C8 10.5 10.5 8 12 3C13.5 8 16 10.5 21 12C16 13.5 13.5 16 12 21C10.5 16 8 13.5 3 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="square" stroke-linejoin="round"></path>
    """
  end

  # Central Icons IconUser — the My Space nav mark: a single person, the
  # classic "mine" glyph (Members keeps the three-person "users").
  # Extracted from round-outlined-radius-2-stroke-2.
  defp icon_path("outlined", "user") do
    ~S"""
    <path d="M6.75 20C5.64543 20 4.727 19.0951 4.94927 18.0131C5.62864 14.7061 8.03433 12 12 12C15.9657 12 18.3714 14.7061 19.0507 18.0131C19.273 19.0951 18.3546 20 17.25 20H6.75Z" stroke="currentColor" stroke-width="2" stroke-linejoin="round"></path><circle cx="12" cy="7.75" r="4.25" stroke="currentColor" stroke-width="2" stroke-linejoin="round"></circle>
    """
  end

  defp icon_path("outlined", "users") do
    ~S"""
    <circle cx="12" cy="9" r="3" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></circle><circle cx="4" cy="9.5" r="2" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></circle><circle cx="20" cy="9.5" r="2" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></circle><path d="M9 18C8.17157 18 7.5 17.3284 7.5 16.5C7.5 14.0147 9.51472 12 12 12C14.4853 12 16.5 14.0147 16.5 16.5C16.5 17.3284 15.8284 18 15 18H9Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M4 16.9999H3C1.89543 16.9999 0.9517 16.0895 1.20832 15.0151C1.56541 13.5201 2.41406 12.376 4 11.5698" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M20 17.0001H21C22.1046 17.0001 23.0483 16.0897 22.7917 15.0153C22.4346 13.5203 21.5859 12.3762 20 11.5701" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
    """
  end

  defp icon_path("outlined", "zap") do
    ~S"""
    <path d="M19.5657 9H13.5C13.2239 9 13 8.77614 13 8.5V2.40139C13 1.90668 12.3584 1.71242 12.084 2.12404L4.01823 14.2226C3.79672 14.5549 4.03491 15 4.43426 15H10.5C10.7761 15 11 15.2239 11 15.5V21.5986C11 22.0933 11.6416 22.2876 11.916 21.876L19.9818 9.77735C20.2033 9.44507 19.9651 9 19.5657 9Z" stroke="currentColor" stroke-width="2" stroke-linejoin="round"></path>
    """
  end

  # outlined falls back to round when no outlined variant is vendored
  defp icon_path("outlined", name), do: icon_path("round", name)

  # square-filled-radius-0-stroke-2 — section-card header glyphs
  defp icon_path("square", "calendar") do
    ~S"""
    <path d="M9 2V4H15V2H17V4H21V9H3V4H7V2H9Z" fill="currentColor"></path><path d="M3 11V21H21V11H3Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "chart-bar") do
    ~S"""
    <path d="M20.9999 3H15.6699V21H20.9999V3Z" fill="currentColor"></path><path d="M14.6601 8.33398H9.33008V21.0007H14.6601V8.33398Z" fill="currentColor"></path><path d="M8.33 12.7773H3V20.9996H8.33V12.7773Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "check") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M20.5763 5.06558L10.1618 20.9938L3.38493 13.0875L5.6627 11.1351L9.83825 16.0066L18.0654 3.42383L20.5763 5.06558Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "clock") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22ZM11 12.4142V7H13V11.5858L15.9142 14.5L14.5 15.9142L11 12.4142Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "code-bracket") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M15.2128 3.27236L10.7278 21.2127L8.78747 20.7276L13.2725 2.78729L15.2128 3.27236ZM7.41436 8.00001L3.41436 12L7.41436 16L6.00015 17.4142L0.585938 12L6.00015 6.5858L7.41436 8.00001ZM18.0002 6.5858L23.4144 12L18.0002 17.4142L16.5859 16L20.5859 12L16.5859 8.00001L18.0002 6.5858Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "envelope") do
    ~S"""
    <path d="M2.57918 4L12 11.7079L21.4208 4H2.57918Z" fill="currentColor"></path><path d="M2 6.11025V20H22V6.11024L12 14.2921L2 6.11025Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "globe") do
    ~S"""
    <path d="M14.9834 13C14.8972 15.5438 14.487 17.7937 13.8896 19.4365C13.5509 20.368 13.1711 21.0514 12.7998 21.4834C12.4256 21.9186 12.1522 22 12.001 22C11.8498 22 11.5763 21.9186 11.2021 21.4834C10.8308 21.0514 10.451 20.368 10.1123 19.4365C9.51491 17.7937 9.10476 15.5438 9.01855 13H14.9834Z" fill="currentColor"></path><path d="M7.01758 13C7.10421 15.7329 7.54258 18.2231 8.23242 20.1201C8.40908 20.6059 8.60792 21.0631 8.82617 21.4824C5.16344 20.2566 2.44511 16.9715 2.05078 13H7.01758Z" fill="currentColor"></path><path d="M21.9512 13C21.5568 16.9718 18.838 20.2569 15.1748 21.4824C15.3931 21.063 15.5928 20.6061 15.7695 20.1201C16.4594 18.2231 16.8977 15.7329 16.9844 13H21.9512Z" fill="currentColor"></path><path d="M8.82617 2.5166C8.60776 2.93611 8.40919 3.39378 8.23242 3.87988C7.54258 5.77694 7.10421 8.26715 7.01758 11H2.05078C2.44512 7.02844 5.1633 3.74231 8.82617 2.5166Z" fill="currentColor"></path><path d="M12.001 2C12.1522 2 12.4256 2.08138 12.7998 2.5166C13.1711 2.94858 13.5509 3.63201 13.8896 4.56348C14.487 6.2063 14.8972 8.4562 14.9834 11H9.01855C9.10476 8.4562 9.51491 6.2063 10.1123 4.56348C10.451 3.63201 10.8308 2.94858 11.2021 2.5166C11.5763 2.08138 11.8498 2 12.001 2Z" fill="currentColor"></path><path d="M15.1748 2.5166C18.8381 3.74207 21.5568 7.02812 21.9512 11H16.9844C16.8977 8.26715 16.4594 5.77694 15.7695 3.87988C15.5927 3.39363 15.3933 2.93622 15.1748 2.5166Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "inbox") do
    ~S"""
    <path d="M21 21H3L3.00003 14H7.41605C8.1876 15.7659 9.94968 17 12 17C14.0503 17 15.8124 15.7659 16.584 14L21 14L21 21Z" fill="currentColor"></path><path d="M21 12L21 3L3.00006 3.00001L3.00003 12H9.00001V12.0064C9.00346 13.6603 10.3453 15 12 15C13.6569 15 15 13.6569 15 12L21 12Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "newspaper") do
    ~S"""
    <path d="M8 9V11H11V9H8Z" fill="currentColor"></path><path fill-rule="evenodd" clip-rule="evenodd" d="M2 3H17V11H22V17.5C22 19.2632 20.6961 20.7219 19 20.9646V21H5.5C3.567 21 2 19.433 2 17.5V3ZM18.5 19C19.3284 19 20 18.3284 20 17.5V13H17V17.5C17 18.3284 17.6716 19 18.5 19ZM6 17H13V15H6V17ZM6 13V7H13V13H6Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "sparkles") do
    ~S"""
    <path d="M12.9367 3.64886L12.0003 1.15198L11.064 3.64886C9.66542 7.37843 7.3788 9.66506 3.64922 11.0636L1.15234 12L3.64922 12.9363C7.3788 14.3349 9.66542 16.6215 11.064 20.3511L12.0003 22.848L12.9367 20.3511C14.3353 16.6215 16.6219 14.3349 20.3515 12.9363L22.8483 12L20.3515 11.0636C16.6219 9.66506 14.3353 7.37843 12.9367 3.64886Z" fill="currentColor"></path>
    """
  end

  defp icon_path("square", "users") do
    ~S"""
    <path d="M15.5479 12.2988C16.7413 13.3077 17.5 14.8149 17.5 16.5V19H6.5V16.5C6.5 14.8151 7.25803 13.3077 8.45117 12.2988C9.38053 13.1674 10.6277 13.7002 12 13.7002C13.3721 13.7002 14.6186 13.1671 15.5479 12.2988Z" fill="currentColor"></path><path d="M1.0332 12.8164C1.82058 13.5213 2.86012 13.9502 4 13.9502C4.47039 13.9502 4.92317 13.8757 5.34863 13.7402C4.99535 14.59 4.7998 15.5222 4.7998 16.5V18H0V15.5C0 14.4675 0.390911 13.526 1.0332 12.8164Z" fill="currentColor"></path><path d="M22.9658 12.8164C23.6084 13.5261 24 14.4672 24 15.5V18H19.2002V16.5C19.2002 15.5218 19.003 14.59 18.6494 13.7402C19.0754 13.8759 19.529 13.9502 20 13.9502C21.1396 13.9502 22.1785 13.521 22.9658 12.8164Z" fill="currentColor"></path><path d="M4 6.75C5.51878 6.75 6.75 7.98122 6.75 9.5C6.75 11.0188 5.51878 12.25 4 12.25C2.48122 12.25 1.25 11.0188 1.25 9.5C1.25 7.98122 2.48122 6.75 4 6.75Z" fill="currentColor"></path><path d="M20 6.75C21.5188 6.75 22.75 7.98122 22.75 9.5C22.75 11.0188 21.5188 12.25 20 12.25C18.4812 12.25 17.25 11.0188 17.25 9.5C17.25 7.98122 18.4812 6.75 20 6.75Z" fill="currentColor"></path><path d="M12 5C13.933 5 15.5 6.567 15.5 8.5C15.5 10.433 13.933 12 12 12C10.067 12 8.5 10.433 8.5 8.5C8.5 6.567 10.067 5 12 5Z" fill="currentColor"></path>
    """
  end

  # square falls back to round when no square variant is vendored
  defp icon_path("square", name), do: icon_path("round", name)

  # round-filled-radius-2-stroke-2 — the default body style
  defp icon_path("round", "arrow-left") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M11.0607 18.5607C10.4749 19.1464 9.52513 19.1464 8.93934 18.5607L3.43934 13.0607C3.15804 12.7794 3 12.3978 3 12C3 11.6022 3.15803 11.2207 3.43934 10.9394L8.93934 5.43934C9.52512 4.85355 10.4749 4.85355 11.0607 5.43934C11.6464 6.02512 11.6464 6.97487 11.0607 7.56066L8.12131 10.5H19.5C20.3284 10.5 21 11.1716 21 12C21 12.8284 20.3284 13.5 19.5 13.5H8.12133L11.0607 16.4393C11.6464 17.0251 11.6464 17.9749 11.0607 18.5607Z" fill="currentColor"></path>
    """
  end

  # IconArrowUpRight (external-link badge on Settings → OAuth)
  defp icon_path("round", "arrow-up-right") do
    ~S"""
    <path d="M7 17L17 7M8 7H17V16" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    """
  end

  defp icon_path("round", "arrow-up") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M12 3C12.3978 3 12.7793 3.15803 13.0606 3.43934L18.5607 8.93934C19.1464 9.52512 19.1464 10.4749 18.5607 11.0607C17.9749 11.6464 17.0251 11.6464 16.4393 11.0607L13.5 8.12131V19.5C13.5 20.3284 12.8284 21 12 21C11.1716 21 10.5 20.3284 10.5 19.5V8.12133L7.56066 11.0607C6.97488 11.6464 6.02513 11.6464 5.43934 11.0607C4.85355 10.4749 4.85355 9.52513 5.43934 8.93934L10.9393 3.43934C11.2206 3.15804 11.6022 3 12 3Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "arrows-expand") do
    ~S"""
    <path d="M9 13C10.6569 13 12 14.3431 12 16V19C12 20.6569 10.6569 22 9 22H5C3.34315 22 2 20.6569 2 19V16C2 14.3431 3.34315 13 5 13H9Z" fill="currentColor"></path><path d="M20 6C20 5.44772 19.5523 5 19 5H6C5.44771 5 5 5.44772 5 6V10C5 10.5523 4.55228 11 4 11C3.44772 11 3 10.5523 3 10V6C3 4.34315 4.34315 3 6 3H19C20.6569 3 22 4.34315 22 6V13C22 14.6569 20.6569 16 19 16H15C14.4477 16 14 15.5523 14 15C14 14.4477 14.4477 14 15 14H19C19.5523 14 20 13.5523 20 13V6Z" fill="currentColor"></path><path d="M17 7C17.5523 7 18 7.44772 18 8V11C18 11.5523 17.5523 12 17 12C16.4477 12 16 11.5523 16 11V10.4142L14.7071 11.7071C14.3166 12.0976 13.6834 12.0976 13.2929 11.7071C12.9024 11.3166 12.9024 10.6834 13.2929 10.2929L14.5858 9H14C13.4477 9 13 8.55228 13 8C13 7.44772 13.4477 7 14 7H17Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "attachment") do
    ~S"""
    <path d="M14 2C11.2386 2 9 4.23858 9 7V15C9 16.6569 10.3431 18 12 18C13.6569 18 15 16.6569 15 15V7C15 6.44772 14.5523 6 14 6C13.4477 6 13 6.44772 13 7V15C13 15.5523 12.5523 16 12 16C11.4477 16 11 15.5523 11 15V7C11 5.34315 12.3431 4 14 4C15.6569 4 17 5.34315 17 7V15C17 17.7614 14.7614 20 12 20C9.23858 20 7 17.7614 7 15V11C7 10.4477 6.55228 10 6 10C5.44772 10 5 10.4477 5 11V15C5 18.866 8.13401 22 12 22C15.866 22 19 18.866 19 15V7C19 4.23858 16.7614 2 14 2Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "bolt") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M13.1981 20.0571C11.7326 20.0571 10.2936 19.5252 9.46756 18.3817L9.1762 19.7304L3.79688 22.5824L4.3776 19.7304L8.2951 2H13.0916L11.7059 8.24953C12.8251 7.02621 13.8643 6.57412 15.1967 6.57412C18.0746 6.57412 19.9931 8.46227 19.9931 11.9194C19.9931 15.483 17.7815 20.0571 13.1981 20.0571ZM15.0368 12.9301C15.0368 14.5788 13.8643 15.8287 12.3455 15.8287C11.4927 15.8287 10.72 15.5096 10.2137 14.9511L10.9598 11.6802C11.5194 11.1216 12.1589 10.8025 12.905 10.8025C14.0509 10.8025 15.0368 11.6536 15.0368 12.9301Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "building-office") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M3 6C3 4.34315 4.34315 3 6 3H12C13.6569 3 15 4.34315 15 6V7V18H16V7H18C19.6569 7 21 8.34315 21 10V18H22C22.5523 18 23 18.4477 23 19C23 19.5523 22.5523 20 22 20H2C1.44772 20 1 19.5523 1 19C1 18.4477 1.44772 18 2 18H3V6ZM7 9C7 8.44772 7.44772 8 8 8H10C10.5523 8 11 8.44772 11 9C11 9.55228 10.5523 10 10 10H8C7.44772 10 7 9.55228 7 9ZM7 13C7 12.4477 7.44772 12 8 12H10C10.5523 12 11 12.4477 11 13C11 13.5523 10.5523 14 10 14H8C7.44772 14 7 13.5523 7 13Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "calendar") do
    ~S"""
    <path d="M8 2C8.55228 2 9 2.44772 9 3V4H15V3C15 2.44772 15.4477 2 16 2C16.5523 2 17 2.44772 17 3V4H18C19.6569 4 21 5.34315 21 7V9H3V7C3 5.34315 4.34315 4 6 4H7V3C7 2.44772 7.44772 2 8 2Z" fill="currentColor"></path><path d="M3 18V11H21V18C21 19.6569 19.6569 21 18 21H6C4.34315 21 3 19.6569 3 18Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "chart-bar") do
    ~S"""
    <path d="M15.6699 5.665C15.6699 4.19316 16.8631 3 18.3349 3C19.8068 3 20.9999 4.19316 20.9999 5.665V18.335C20.9999 19.8068 19.8068 21 18.3349 21C16.8631 21 15.6699 19.8068 15.6699 18.335V5.665Z" fill="currentColor"></path><path d="M11.9951 8.33398C10.5232 8.33398 9.33008 9.52715 9.33008 10.999V18.3357C9.33008 19.8075 10.5232 21.0007 11.9951 21.0007C13.4669 21.0007 14.6601 19.8075 14.6601 18.3356V10.999C14.6601 9.52715 13.4669 8.33398 11.9951 8.33398Z" fill="currentColor"></path><path d="M5.665 12.7773C4.19316 12.7773 3 13.9705 3 15.4423V18.3346C3 19.8064 4.19316 20.9996 5.665 20.9996C7.13684 20.9996 8.33 19.8064 8.33 18.3346V15.4423C8.33 13.9705 7.13684 12.7773 5.665 12.7773Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "chat-bubble") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M18.0019 3L6.00195 3.00002C4.3451 3.00002 3.00195 4.34317 3.00195 6.00002V16.0358C3.00195 17.6926 4.3451 19.0358 6.00195 19.0358H8.65157L11.3553 21.3021C11.7252 21.6123 12.2639 21.6138 12.6357 21.3058L15.3757 19.0358L18.002 19.0358C19.6588 19.0357 21.002 17.6926 21.002 16.0358V6C21.002 4.34314 19.6588 3 18.0019 3ZM7.99976 9C7.99976 8.44772 8.44747 8 8.99976 8H14.9998C15.552 8 15.9998 8.44772 15.9998 9C15.9998 9.55228 15.552 10 14.9998 10H8.99976C8.44747 10 7.99976 9.55228 7.99976 9ZM8.99976 12C8.44747 12 7.99976 12.4477 7.99976 13C7.99976 13.5523 8.44747 14 8.99976 14H14.9998C15.552 14 15.9998 13.5523 15.9998 13C15.9998 12.4477 15.552 12 14.9998 12H8.99976Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "check") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M19.3209 4.24472C20.0142 4.69807 20.2088 5.62768 19.7555 6.32105L11.2555 19.321C10.9972 19.7161 10.5681 19.9665 10.0971 19.997C9.62613 20.0276 9.16825 19.8347 8.86111 19.4764L4.36111 14.2264C3.82198 13.5974 3.89482 12.6504 4.52381 12.1113C5.1528 11.5722 6.09975 11.645 6.63888 12.274L9.83825 16.0066L17.2445 4.6793C17.6979 3.98593 18.6275 3.79136 19.3209 4.24472Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "chevron-down") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M10.5858 14.0002C11.3668 14.7812 12.6332 14.7812 13.4142 14.0002L16.7071 10.7073C17.0976 10.3167 17.0976 9.68357 16.7071 9.29304C16.3166 8.90252 15.6834 8.90252 15.2929 9.29304L12 12.5859L8.70711 9.29304C8.31658 8.90252 7.68342 8.90252 7.29289 9.29304C6.90237 9.68357 6.90237 10.3167 7.29289 10.7073L10.5858 14.0002Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "chevron-right") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M9.29289 7.29289C9.68342 6.90237 10.3166 6.90237 10.7071 7.29289L14 10.5858C14.781 11.3668 14.781 12.6332 14 13.4142L10.7071 16.7071C10.3166 17.0976 9.68342 17.0976 9.29289 16.7071C8.90237 16.3166 8.90237 15.6834 9.29289 15.2929L12.5858 12L9.29289 8.70711C8.90237 8.31658 8.90237 7.68342 9.29289 7.29289Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "clock") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22ZM13 8C13 7.44772 12.5523 7 12 7C11.4477 7 11 7.44772 11 8V12C11 12.2652 11.1054 12.5196 11.2929 12.7071L13.7929 15.2071C14.1834 15.5976 14.8166 15.5976 15.2071 15.2071C15.5976 14.8166 15.5976 14.1834 15.2071 13.7929L13 11.5858V8Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "code-bracket") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M14.2422 3.02985C14.778 3.1638 15.1038 3.70673 14.9698 4.24253L10.9698 20.2426C10.8359 20.7784 10.293 21.1041 9.75716 20.9702C9.22137 20.8362 8.89561 20.2933 9.02956 19.7575L13.0296 3.75746C13.1635 3.22166 13.7064 2.8959 14.2422 3.02985ZM6.70681 7.29293C7.09733 7.68345 7.09733 8.31662 6.7068 8.70714L4.12102 11.2929C3.73049 11.6834 3.73049 12.3166 4.12102 12.7071L6.7068 15.2929C7.09733 15.6834 7.09733 16.3166 6.7068 16.7071C6.31628 17.0977 5.68312 17.0977 5.29259 16.7071L2.7068 14.1214C1.53523 12.9498 1.53523 11.0503 2.70681 9.87871L5.29259 7.29293C5.68312 6.9024 6.31628 6.9024 6.70681 7.29293ZM17.2926 7.29293C17.6831 6.9024 18.3163 6.9024 18.7068 7.29293L21.2926 9.87871C22.4642 11.0503 22.4642 12.9498 21.2926 14.1214L18.7068 16.7071C18.3163 17.0977 17.6831 17.0977 17.2926 16.7071C16.9021 16.3166 16.9021 15.6834 17.2926 15.2929L19.8784 12.7071C20.2689 12.3166 20.2689 11.6834 19.8784 11.2929L17.2926 8.70714C16.9021 8.31662 16.9021 7.68345 17.2926 7.29293Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "cog") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M3 8.66986C3 7.58603 3.58459 6.58648 4.52924 6.05512L10.5292 2.68018C11.4425 2.1665 12.5575 2.1665 13.4708 2.68019L19.4708 6.05515C20.4154 6.5865 21 7.58606 21 8.66989L21 15.3305C21 16.4143 20.4154 17.4139 19.4708 17.9452L13.4707 21.3202C12.5575 21.8338 11.4425 21.8338 10.5293 21.3202L4.52931 17.9455C3.58463 17.4142 3 16.4146 3 15.3307V8.66986ZM8.50003 12C8.50003 10.067 10.067 8.5 12 8.5C13.933 8.5 15.5 10.067 15.5 12C15.5 13.933 13.933 15.5 12 15.5C10.067 15.5 8.50003 13.933 8.50003 12Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "cube") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M6 3H8V7.5C8 8.88071 9.11929 10 10.5 10H13.5C14.8807 10 16 8.88071 16 7.5V3H18C19.6569 3 21 4.34315 21 6V18C21 19.6569 19.6569 21 18 21H6C4.34315 21 3 19.6569 3 18V6C3 4.34315 4.34315 3 6 3ZM15 16C14.4477 16 14 16.4477 14 17C14 17.5523 14.4477 18 15 18H17C17.5523 18 18 17.5523 18 17C18 16.4477 17.5523 16 17 16H15Z" fill="currentColor"></path><path d="M10 3H14V7.5C14 7.77614 13.7761 8 13.5 8H10.5C10.2239 8 10 7.77614 10 7.5V3Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "document-text") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M12 7C12 8.65685 13.3431 10 15 10H20V19C20 20.6569 18.6569 22 17 22H7C5.34315 22 4 20.6569 4 19V5C4 3.34315 5.34315 2 7 2H12V7ZM9 17C8.44772 17 8 17.4477 8 18C8 18.5523 8.44772 19 9 19H15.5C16.0523 19 16.5 18.5523 16.5 18C16.5 17.4477 16.0523 17 15.5 17H9ZM9 13C8.44772 13 8 13.4477 8 14C8 14.5523 8.44772 15 9 15H12C12.5523 15 13 14.5523 13 14C13 13.4477 12.5523 13 12 13H9Z" fill="currentColor"></path><path d="M19.4141 8H15C14.4477 8 14.0001 7.55224 14 7V2.58594L19.4141 8Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "drag-handle") do
    ~S"""
    <path d="M9 3C7.89543 3 7 3.89543 7 5C7 6.10457 7.89543 7 9 7C10.1046 7 11 6.10457 11 5C11 3.89543 10.1046 3 9 3Z" fill="currentColor"></path><path d="M15 3C13.8954 3 13 3.89543 13 5C13 6.10457 13.8954 7 15 7C16.1046 7 17 6.10457 17 5C17 3.89543 16.1046 3 15 3Z" fill="currentColor"></path><path d="M9 10C7.89543 10 7 10.8954 7 12C7 13.1046 7.89543 14 9 14C10.1046 14 11 13.1046 11 12C11 10.8954 10.1046 10 9 10Z" fill="currentColor"></path><path d="M15 10C13.8954 10 13 10.8954 13 12C13 13.1046 13.8954 14 15 14C16.1046 14 17 13.1046 17 12C17 10.8954 16.1046 10 15 10Z" fill="currentColor"></path><path d="M9 17C7.89543 17 7 17.8954 7 19C7 20.1046 7.89543 21 9 21C10.1046 21 11 20.1046 11 19C11 17.8954 10.1046 17 9 17Z" fill="currentColor"></path><path d="M15 17C13.8954 17 13 17.8954 13 19C13 20.1046 13.8954 21 15 21C16.1046 21 17 20.1046 17 19C17 17.8954 16.1046 17 15 17Z" fill="currentColor"></path>
    """
  end

  # Central Icons IconDotGrid1x3Horizontal — the "…" overflow-menu trigger
  defp icon_path("round", "ellipsis") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M2 12C2 10.8954 2.89543 10 4 10C5.10457 10 6 10.8954 6 12C6 13.1046 5.10457 14 4 14C2.89543 14 2 13.1046 2 12ZM10 12C10 10.8954 10.8954 10 12 10C13.1046 10 14 10.8954 14 12C14 13.1046 13.1046 14 12 14C10.8954 14 10 13.1046 10 12ZM18 12C18 10.8954 18.8954 10 20 10C21.1046 10 22 10.8954 22 12C22 13.1046 21.1046 14 20 14C18.8954 14 18 13.1046 18 12Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "envelope") do
    ~S"""
    <path d="M2.12015 6.20855C2.07321 6.40572 2.04691 6.60508 2.03057 6.80497C1.99997 7.17953 1.99998 7.63426 2 8.16138V15.8385C1.99998 16.3657 1.99997 16.8205 2.03057 17.195C2.06287 17.5904 2.13419 17.9836 2.32698 18.362C2.6146 18.9265 3.07355 19.3854 3.63803 19.673C4.01641 19.8658 4.40963 19.9371 4.80498 19.9694C5.17951 20 5.63422 20 6.16129 20H17.8385C18.3656 20 18.8205 20 19.195 19.9694C19.5904 19.9371 19.9836 19.8658 20.362 19.673C20.9265 19.3854 21.3854 18.9265 21.673 18.362C21.8658 17.9836 21.9371 17.5904 21.9694 17.195C22 16.8205 22 16.3657 22 15.8386V8.16144C22 7.6343 22 7.17954 21.9694 6.80497C21.9531 6.60507 21.9268 6.40572 21.8799 6.20855L13.8997 12.7378C12.7946 13.6419 11.2054 13.6419 10.1003 12.7378L2.12015 6.20855Z" fill="currentColor"></path><path d="M20.7406 4.55656C20.6207 4.47119 20.4943 4.39438 20.362 4.32698C19.9836 4.13419 19.5904 4.06287 19.195 4.03057C18.8205 3.99997 18.3657 3.99998 17.8386 4H6.16146C5.63434 3.99998 5.17953 3.99997 4.80498 4.03057C4.40963 4.06287 4.01641 4.13419 3.63803 4.32698C3.50575 4.39438 3.37927 4.47119 3.25943 4.55656L11.3668 11.1898C11.7351 11.4912 12.2649 11.4912 12.6332 11.1898L20.7406 4.55656Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "folder") do
    ~S"""
    <path d="M5 3C3.34315 3 2 4.34315 2 6V17C2 18.6569 3.34315 20 5 20H19C20.6569 20 22 18.6569 22 17V9C22 7.34315 20.6569 6 19 6L12.5352 6L11.4258 4.3359C10.8694 3.5013 9.93269 3 8.92963 3H5Z" fill="currentColor"></path>
    """
  end

  # Central Icons IconImages1 (aliases images-1/photos/pictures)
  defp icon_path("round", "image") do
    ~S"""
    <path d="M17.5 9C17.5 10.3807 16.3807 11.5 15 11.5C13.6193 11.5 12.5 10.3807 12.5 9C12.5 7.61929 13.6193 6.5 15 6.5C16.3807 6.5 17.5 7.61929 17.5 9Z" fill="currentColor"></path><path fill-rule="evenodd" clip-rule="evenodd" d="M6 3H17.99C19.65 3 20.99 4.34 20.99 6V18C20.99 19.66 19.65 21 17.99 21H6C4.34 21 3 19.66 3 18V6C3 4.34 4.34 3 6 3ZM18 5H6C5.45 5 5 5.45 5 6V12.22L6.27 11.27L6.29 11.25C7.51 10.43 9.15 10.62 10.15 11.7C11.62 13.28 13.09 14.45 15 14.45C16.7 14.45 17.86 13.89 19 12.83V6C19 5.45 18.55 5 18 5Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "globe") do
    ~S"""
    <path d="M14.9834 13C14.8972 15.5438 14.487 17.7937 13.8896 19.4365C13.5509 20.368 13.1711 21.0514 12.7998 21.4834C12.4256 21.9186 12.1522 22 12.001 22C11.8498 22 11.5763 21.9186 11.2021 21.4834C10.8308 21.0514 10.451 20.368 10.1123 19.4365C9.51491 17.7937 9.10476 15.5438 9.01855 13H14.9834Z" fill="currentColor"></path><path d="M7.01758 13C7.10421 15.7329 7.54258 18.2231 8.23242 20.1201C8.40908 20.6059 8.60792 21.0631 8.82617 21.4824C5.16344 20.2566 2.44511 16.9715 2.05078 13H7.01758Z" fill="currentColor"></path><path d="M21.9512 13C21.5568 16.9718 18.838 20.2569 15.1748 21.4824C15.3931 21.063 15.5928 20.6061 15.7695 20.1201C16.4594 18.2231 16.8977 15.7329 16.9844 13H21.9512Z" fill="currentColor"></path><path d="M8.82617 2.5166C8.60776 2.93611 8.40919 3.39378 8.23242 3.87988C7.54258 5.77694 7.10421 8.26715 7.01758 11H2.05078C2.44512 7.02844 5.1633 3.74231 8.82617 2.5166Z" fill="currentColor"></path><path d="M12.001 2C12.1522 2 12.4256 2.08138 12.7998 2.5166C13.1711 2.94858 13.5509 3.63201 13.8896 4.56348C14.487 6.2063 14.8972 8.4562 14.9834 11H9.01855C9.10476 8.4562 9.51491 6.2063 10.1123 4.56348C10.451 3.63201 10.8308 2.94858 11.2021 2.5166C11.5763 2.08138 11.8498 2 12.001 2Z" fill="currentColor"></path><path d="M15.1748 2.5166C18.8381 3.74207 21.5568 7.02812 21.9512 11H16.9844C16.8977 8.26715 16.4594 5.77694 15.7695 3.87988C15.5927 3.39363 15.3933 2.93622 15.1748 2.5166Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "home") do
    ~S"""
    <path d="M13.8918 1.99862C12.7896 1.10308 11.2104 1.10308 10.1082 1.99862L4.10822 6.87362C3.40709 7.44329 3 8.29858 3 9.20197V18C3 19.6569 4.34315 21 6 21H18C19.6569 21 21 19.6569 21 18V9.20197C21 8.29858 20.5929 7.44329 19.8918 6.87362L13.8918 1.99862Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "inbox") do
    ~S"""
    <path d="M6.00004 3.00001L18 3C19.6569 3 21 4.34315 21 6V12H15.874C15.4177 12 15.0193 12.3089 14.9056 12.7507C14.5725 14.0449 13.3965 15 12 15C10.6035 15 9.42755 14.0449 9.09446 12.7507C8.98073 12.3089 8.58231 12 8.12603 12H3.00003L3.00004 6C3.00004 4.34315 4.34319 3.00001 6.00004 3.00001Z" fill="currentColor"></path><path d="M21 14V18C21 19.6569 19.6569 21 18 21H6C4.34314 21 2.99999 19.6569 3 18L3.00003 12V14H7.41638C8.18784 15.7655 9.94878 17 12 17C14.0512 17 15.8122 15.7655 16.5836 14H21Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "newspaper") do
    ~S"""
    <path d="M8 11V9H11V11H8Z" fill="currentColor"></path><path fill-rule="evenodd" clip-rule="evenodd" d="M2 6C2 4.34315 3.34315 3 5 3H14C15.6569 3 17 4.34315 17 6V11H19C20.6569 11 22 12.3431 22 14V17.5C22 19.433 20.433 21 18.5 21H5.5C3.567 21 2 19.433 2 17.5V6ZM18.5 19C19.3284 19 20 18.3284 20 17.5V14C20 13.4477 19.5523 13 19 13H17V17.5C17 18.3284 17.6716 19 18.5 19ZM6 16C6 15.4477 6.44772 15 7 15H12C12.5523 15 13 15.4477 13 16C13 16.5523 12.5523 17 12 17H7C6.44772 17 6 16.5523 6 16ZM7 7C6.44772 7 6 7.44772 6 8V12C6 12.5523 6.44772 13 7 13H12C12.5523 13 13 12.5523 13 12V8C13 7.44772 12.5523 7 12 7H7Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "plug") do
    ~S"""
    <path d="M10 3C10 2.44772 9.55228 2 9 2C8.44772 2 8 2.44772 8 3V6H7C5.34315 6 4 7.34315 4 9V14C4 16.7614 6.23858 19 9 19H11V21C11 21.5523 11.4477 22 12 22C12.5523 22 13 21.5523 13 21V19H15C17.7614 19 20 16.7614 20 14V9C20 7.34315 18.6569 6 17 6H16V3C16 2.44772 15.5523 2 15 2C14.4477 2 14 2.44772 14 3V6H10V3Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "plus") do
    ~S"""
    <path d="M11 18.5V13H5.5C4.94772 13 4.5 12.5523 4.5 12C4.5 11.4477 4.94772 11 5.5 11H11V5.5C11 4.94772 11.4477 4.5 12 4.5C12.5523 4.5 13 4.94772 13 5.5V11H18.5C19.0523 11 19.5 11.4477 19.5 12C19.5 12.5523 19.0523 13 18.5 13H13V18.5C13 19.0523 12.5523 19.5 12 19.5C11.4477 19.5 11 19.0523 11 18.5Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "search") do
    ~S"""
    <path d="M11 15C13.2091 15 15 13.2091 15 11C15 8.79086 13.2091 7 11 7C8.79086 7 7 8.79086 7 11C7 13.2091 8.79086 15 11 15Z" fill="currentColor"></path><path fill-rule="evenodd" clip-rule="evenodd" d="M11 5C7.68629 5 5 7.68629 5 11C5 14.3137 7.68629 17 11 17C14.3137 17 17 14.3137 17 11C17 7.68629 14.3137 5 11 5ZM3 11C3 6.58172 6.58172 3 11 3C15.4183 3 19 6.58172 19 11C19 12.8487 18.3729 14.551 17.3199 15.9056L20.7071 19.2929C21.0976 19.6834 21.0976 20.3166 20.7071 20.7071C20.3166 21.0976 19.6834 21.0976 19.2929 20.7071L15.9056 17.3199C14.551 18.3729 12.8487 19 11 19C6.58172 19 3 15.4183 3 11Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "sparkles") do
    ~S"""
    <path d="M12.9578 2.71265C12.8309 2.28967 12.4416 2 12 2C11.5584 2 11.1691 2.28967 11.0422 2.71265C10.3228 5.11046 9.39036 6.82042 8.10539 8.10539C6.82042 9.39036 5.11046 10.3228 2.71265 11.0422C2.28967 11.1691 2 11.5584 2 12C2 12.4416 2.28967 12.8309 2.71265 12.9578C5.11046 13.6772 6.82042 14.6096 8.10539 15.8946C9.39036 17.1796 10.3228 18.8895 11.0422 21.2873C11.1691 21.7103 11.5584 22 12 22C12.4416 22 12.8309 21.7103 12.9578 21.2873C13.6772 18.8895 14.6096 17.1796 15.8946 15.8946C17.1796 14.6096 18.8895 13.6772 21.2873 12.9578C21.7103 12.8309 22 12.4416 22 12C22 11.5584 21.7103 11.1691 21.2873 11.0422C18.8895 10.3228 17.1796 9.39036 15.8946 8.10539C14.6096 6.82042 13.6772 5.11046 12.9578 2.71265Z" fill="currentColor"></path>
    """
  end

  # IconPencil (aliases: edit, write)
  defp icon_path("round", "pencil") do
    ~S"""
    <path d="M14.8787 3.20681C16.0503 2.03523 17.9497 2.03523 19.1213 3.2068L20.7929 4.87838C21.9645 6.04995 21.9645 7.94944 20.7929 9.12102L19.4141 10.4998L13.5 4.58579L12.0858 6L17.9998 11.9141L8.5 21.4139C8.12493 21.789 7.61622 21.9997 7.08579 21.9997H3C2.44772 21.9997 2 21.552 2 20.9997V16.9139C2 16.3835 2.21071 15.8748 2.58579 15.4997L14.8787 3.20681Z" fill="currentColor"/>
    """
  end

  # IconTrashCanSimple (aliases: delete, remove)
  defp icon_path("round", "trash") do
    ~S"""
    <path fill-rule="evenodd" clip-rule="evenodd" d="M7.22919 5H3.5C2.94772 5 2.5 5.44772 2.5 6C2.5 6.55228 2.94772 7 3.5 7H4.03211L4.87393 19.2064C4.98241 20.7794 6.29007 22 7.86682 22H16.1332C17.7099 22 19.0176 20.7794 19.1261 19.2064L19.9679 7H20.5C21.0523 7 21.5 6.55228 21.5 6C21.5 5.44772 21.0523 5 20.5 5H16.7708C16.1335 2.97145 14.2395 1.5 12 1.5C9.76053 1.5 7.86655 2.97145 7.22919 5ZM9.40105 5H14.599C14.0801 4.10329 13.1099 3.5 12 3.5C10.8901 3.5 9.9199 4.10329 9.40105 5Z" fill="currentColor"/>
    """
  end

  defp icon_path("round", "users") do
    ~S"""
    <path d="M15.5479 12.2988C16.7413 13.3077 17.5 14.8149 17.5 16.5C17.5 17.8807 16.3807 19 15 19H9C7.61929 19 6.5 17.8807 6.5 16.5C6.5 14.8151 7.25803 13.3077 8.45117 12.2988C9.38053 13.1674 10.6277 13.7002 12 13.7002C13.3721 13.7002 14.6186 13.1671 15.5479 12.2988Z" fill="currentColor"></path><path d="M1.0332 12.8164C1.82058 13.5213 2.86012 13.9502 4 13.9502C4.47039 13.9502 4.92317 13.8757 5.34863 13.7402C4.99535 14.59 4.7998 15.5222 4.7998 16.5C4.7998 17.0287 4.89884 17.534 5.07715 18H2.125C0.951395 18 0 17.0486 0 15.875V15.5C0 14.4675 0.390911 13.526 1.0332 12.8164Z" fill="currentColor"></path><path d="M22.9658 12.8164C23.6084 13.5261 24 14.4672 24 15.5V15.875C24 17.0486 23.0486 18 21.875 18H18.9229C19.1012 17.534 19.2002 17.0287 19.2002 16.5C19.2002 15.5218 19.003 14.59 18.6494 13.7402C19.0754 13.8759 19.529 13.9502 20 13.9502C21.1396 13.9502 22.1785 13.521 22.9658 12.8164Z" fill="currentColor"></path><path d="M4 6.75C5.51878 6.75 6.75 7.98122 6.75 9.5C6.75 11.0188 5.51878 12.25 4 12.25C2.48122 12.25 1.25 11.0188 1.25 9.5C1.25 7.98122 2.48122 6.75 4 6.75Z" fill="currentColor"></path><path d="M20 6.75C21.5188 6.75 22.75 7.98122 22.75 9.5C22.75 11.0188 21.5188 12.25 20 12.25C18.4812 12.25 17.25 11.0188 17.25 9.5C17.25 7.98122 18.4812 6.75 20 6.75Z" fill="currentColor"></path><path d="M12 5C13.933 5 15.5 6.567 15.5 8.5C15.5 10.433 13.933 12 12 12C10.067 12 8.5 10.433 8.5 8.5C8.5 6.567 10.067 5 12 5Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "x-mark") do
    ~S"""
    <path d="M16.793 5.79289C17.1835 5.40237 17.8165 5.40237 18.207 5.79289C18.5975 6.18342 18.5975 6.81643 18.207 7.20696L13.414 11.9999L18.207 16.7929C18.5975 17.1834 18.5975 17.8164 18.207 18.207C17.8165 18.5975 17.1835 18.5975 16.793 18.207L12 13.414L7.20702 18.207C6.81649 18.5975 6.18348 18.5975 5.79295 18.207C5.40243 17.8164 5.40243 17.1834 5.79295 16.7929L10.5859 11.9999L5.79295 7.20696C5.40243 6.81643 5.40243 6.18342 5.79295 5.79289C6.18348 5.40237 6.81649 5.40237 7.20702 5.79289L12 10.5859L16.793 5.79289Z" fill="currentColor"></path>
    """
  end

  defp icon_path("round", "zap") do
    ~S"""
    <path d="M14.0019 2.40144C14.0019 0.917322 12.077 0.334547 11.2538 1.5694L3.18804 13.668C2.52349 14.6648 3.23807 16.0001 4.43612 16.0001H10.0019V21.5987C10.0019 23.0828 11.9267 23.6656 12.7499 22.4307L20.8157 10.3321C21.4802 9.33528 20.7656 8.00006 19.5676 8.00006H14.0019V2.40144Z" fill="currentColor"></path>
    """
  end

  defp icon_path(_variant, _name), do: ~S(<circle cx="12" cy="12" r="2.5" fill="currentColor"/>)

  # ============================ Flash ============================

  @doc """
  Renders a single flash kind (`:info` | `:error`) as a Linear-style toast:
  white card, hairline border, status dot, close button. The `Flash` hook
  auto-dismisses after 5s (paused while hovered) by clicking the close
  button, which clears the flash server-side — removal then plays the exit
  transition via phx-remove.
  """
  attr(:flash, :map, default: %{})
  attr(:kind, :atom, values: [:info, :error])
  attr(:id, :string, default: nil)

  def flash(assigns) do
    # Not assign_new: the attr default already puts `:id => nil` in assigns,
    # so assign_new would never fire and the hook would mount without an id.
    assigns = assign(assigns, :id, assigns.id || "flash-#{assigns.kind}")

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-hook="Flash"
      role="alert"
      phx-remove={
        JS.hide(
          transition:
            {"ease-in duration-150", "translate-y-0 opacity-100", "translate-y-1 opacity-0"},
          time: 150
        )
      }
      class="t-toast pointer-events-auto flex items-start gap-2.5 rounded-lg border border-neutral-200 bg-white py-2.5 pl-3 pr-1.5 shadow-popover"
    >
      <span
        class={[
          "mt-[5px] h-2 w-2 shrink-0 rounded-full",
          @kind == :info && "bg-green-500",
          @kind == :error && "bg-red-500"
        ]}
        aria-hidden="true"
      >
      </span>
      <p class="min-w-0 flex-1 pt-px text-[13px] font-medium leading-snug text-neutral-800">
        {msg}
      </p>
      <button
        data-flash-close
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind})}
        aria-label={gettext("Close")}
        class="grid h-6 w-6 shrink-0 place-items-center rounded-md text-neutral-400 transition-colors duration-100 hover:bg-neutral-100 hover:text-neutral-700"
      >
        <.icon name="x-mark" class="h-3.5 w-3.5" />
      </button>
    </div>
    """
  end

  @doc "Renders the standard info/error flash group, fixed bottom-left (Linear's toast corner)."
  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div class="pointer-events-none fixed bottom-4 left-4 z-50 flex w-80 flex-col gap-2">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  # ============================ Error translation ============================

  @doc """
  Translate a changeset error tuple via the Gettext "errors" domain. The English
  source string is the msgid; `count`-bearing errors use the plural form. Plain
  string errors are passed through `dgettext` too.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(BridgeForTeamsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(BridgeForTeamsWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_error(msg) when is_binary(msg),
    do: Gettext.dgettext(BridgeForTeamsWeb.Gettext, "errors", msg)
end
