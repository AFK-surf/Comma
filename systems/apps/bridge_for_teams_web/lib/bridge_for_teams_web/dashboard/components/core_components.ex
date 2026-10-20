defmodule BridgeForTeamsWeb.Dashboard.CoreComponents do
  @moduledoc """
  Function components for the remaining server-rendered dashboard pages
  (login, sign-up and impersonation; light theme, neutral gray, brand blue
  `#205BFF` accent). Imported via `use BridgeForTeamsWeb.Dashboard, :html`.

  Component set: `button/1`, `input/1` (+ `field_label/1`, `error/1`) and
  `org_avatar/1`, plus `translate_error/1` for changeset errors.
  """
  use Phoenix.Component

  # ============================ Button ============================

  @doc """
  A `<button>`.

  ## Attrs
    * `:variant` — `"primary"` | `"secondary"` | `"ghost"` | `"danger"` (default "secondary")
    * `:size` — `"sm"` (h-7) | `"md"` (h-8) (default "md")
    * `:type` — button type (default "button")
    * any global attr (`disabled`, `class`, `form`, ...)
  """
  attr(:variant, :string, default: "secondary", values: ~w(primary secondary ghost danger))
  attr(:size, :string, default: "md", values: ~w(sm md))
  attr(:type, :string, default: "button")
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(disabled form name value))

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
    <button type={@type} class={@computed_class} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
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
