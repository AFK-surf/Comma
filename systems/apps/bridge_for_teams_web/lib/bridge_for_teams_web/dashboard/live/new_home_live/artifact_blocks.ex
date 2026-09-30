defmodule BridgeForTeamsWeb.Dashboard.NewHomeLive.ArtifactBlocks do
  @moduledoc """
  Native renderers for the structured artifact block vocabulary
  (`BridgeForTeams.Artifacts.Blocks`).

  `block/1` takes one normalized block map — a task payload `"hero"`, or the
  inner map of a `BridgeForTeams.Artifacts.Document` `{:block, block}`
  segment (the tuple itself is also accepted) — and dispatches to the typed
  component for its `"type"`. `variant={:compact}` is the dense rail-card
  treatment (kpis keep the oversized-hero-number style the metrics widget
  used, and carry their own `px-2` like the other widget rows);
  `variant={:full}` is the roomier drawer / full-page treatment.

  Anything that is not a recognized normalized block — the `:invalid_block`
  atom, a Document `{:invalid_block, raw}` segment, an unknown `"type"`, or a
  map missing the shape `Blocks.normalize/1` guarantees — renders the quiet
  "Unrecognized content" card. Raw JSON never reaches the page.

  Every string renders as an escaped HEEx interpolation. Link `href`s are
  only ever the http(s)-with-host URLs `Blocks.normalize/1` validated, and
  always open with `rel="noreferrer" target="_blank"`.
  """
  use Phoenix.Component

  use Gettext, backend: BridgeForTeamsWeb.Gettext

  import BridgeForTeamsWeb.Dashboard.CoreComponents, only: [icon: 1]

  @doc """
  One artifact block, rendered by its `"type"`.

  Unrecognized or invalid input falls back to the quiet card — this component
  never raises on agent-shaped data.
  """
  attr(:block, :any, required: true)
  attr(:variant, :atom, default: :full, values: [:compact, :full])

  def block(%{block: {:block, inner}} = assigns), do: block(%{assigns | block: inner})

  def block(assigns) do
    assigns = assign(assigns, :title, block_title(assigns.block))

    ~H"""
    <div>
      <div
        :if={@title}
        class={["mb-1 text-xs font-semibold text-neutral-500", @variant == :compact && "px-2"]}
      >
        {@title}
      </div>
      <.typed block={@block} variant={@variant} />
    </div>
    """
  end

  # The optional agent-supplied caption `Blocks.normalize/1` kept on the block.
  defp block_title(%{"type" => _type, "title" => title}) when is_binary(title) and title != "",
    do: title

  defp block_title(_block), do: nil

  attr(:block, :any, required: true)
  attr(:variant, :atom, required: true)

  defp typed(assigns) do
    case assigns.block do
      %{"type" => "kpis", "items" => [_ | _]} -> kpis(assigns)
      %{"type" => "table", "columns" => [_ | _], "rows" => [_ | _]} -> table(assigns)
      %{"type" => "list", "items" => [_ | _]} -> list(assigns)
      %{"type" => "links", "items" => [_ | _]} -> links(assigns)
      %{"type" => "timeline", "items" => [_ | _]} -> timeline(assigns)
      %{"type" => "entities", "items" => [_ | _]} -> entities(assigns)
      _invalid -> invalid(assigns)
    end
  end

  # KPIs, compact: the first item is the card's hero fact — one oversized
  # tabular number with its delta beside it; the rest stay quiet rows (the
  # exact treatment the metrics widget used).
  defp kpis(%{variant: :compact} = assigns) do
    [hero | rest] = assigns.block["items"]
    assigns = assigns |> assign(:hero, hero) |> assign(:rest, rest)

    ~H"""
    <div>
      <div class="px-2 pb-1">
        <div class="text-xs text-neutral-500">{@hero["label"]}</div>
        <div class="mt-0.5 flex items-baseline gap-2">
          <span class="text-2xl font-semibold tabular-nums tracking-[-0.16px] text-neutral-900">
            {@hero["value"]}
          </span>
          <span :if={@hero["delta"]} class="text-xs font-medium text-green-600">
            {@hero["delta"]}
          </span>
        </div>
      </div>
      <div :if={@rest != []} class="mt-1 divide-y divide-neutral-100">
        <div :for={item <- @rest} class="flex items-baseline justify-between gap-3 px-2 py-1.5">
          <span class="truncate text-xs text-neutral-500">{item["label"]}</span>
          <span class="flex shrink-0 items-baseline gap-1.5">
            <span class="text-sm font-semibold tabular-nums text-neutral-900">
              {item["value"]}
            </span>
            <span :if={item["delta"]} class="text-xs font-medium text-green-600">
              {item["delta"]}
            </span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # KPIs, full: the drawer's two-up stat grid, plus per-item delta and note.
  defp kpis(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2">
      <div :for={item <- @block["items"]} class="rounded-md bg-neutral-100 px-3 py-2">
        <div class="text-xs text-neutral-500">{item["label"]}</div>
        <div class="flex items-baseline gap-1.5">
          <span class="text-lg font-semibold tabular-nums text-neutral-900">{item["value"]}</span>
          <span :if={item["delta"]} class="text-xs font-medium text-green-600">
            {item["delta"]}
          </span>
        </div>
        <div :if={item["note"]} class="mt-0.5 text-xs text-neutral-400">{item["note"]}</div>
      </div>
    </div>
    """
  end

  # Rows are already padded/truncated to the column count by
  # `Blocks.normalize/1`, so header and cells always line up.
  defp table(assigns) do
    ~H"""
    <div class={["overflow-x-auto", @variant == :compact && "px-2"]}>
      <table class="w-full text-left">
        <thead>
          <tr>
            <th
              :for={column <- @block["columns"]}
              class="whitespace-nowrap border-b border-neutral-100 py-1.5 pr-3 text-xs font-semibold text-neutral-500 last:pr-0"
            >
              {column}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-neutral-100">
          <tr :for={row <- @block["rows"]}>
            <td
              :for={cell <- row}
              class={[
                "py-1.5 pr-3 tabular-nums text-neutral-800 last:pr-0",
                (@variant == :compact && "text-xs") || "text-sm"
              ]}
            >
              {cell}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # The list style only tints the leading dot — risks red, actions brand,
  # watch amber, plain neutral. Text stays quiet either way.
  defp list(assigns) do
    assigns = assign(assigns, :dot, list_dot_class(assigns.block["style"]))

    ~H"""
    <div class={[(@variant == :compact && "space-y-1 px-2") || "space-y-1.5"]}>
      <div
        :for={item <- @block["items"]}
        class={[
          "flex items-start gap-2.5",
          (@variant == :compact && "text-xs") || "text-sm"
        ]}
      >
        <span
          class={[
            "h-1.5 w-1.5 shrink-0 rounded-full",
            (@variant == :compact && "mt-1") || "mt-1.5",
            @dot
          ]}
          aria-hidden="true"
        >
        </span>
        <span class={["min-w-0 text-neutral-800", @variant == :compact && "truncate"]}>
          {item}
        </span>
      </div>
    </div>
    """
  end

  # Only URLs that survived `Blocks.normalize/1` (absolute http/https with a
  # host) ever reach the href.
  defp links(assigns) do
    ~H"""
    <div class={[(@variant == :compact && "space-y-0.5 px-2") || "space-y-1"]}>
      <a
        :for={item <- @block["items"]}
        href={item["url"]}
        target="_blank"
        rel="noreferrer"
        class={[
          "flex items-center gap-1.5 font-medium text-brand-600 hover:underline",
          (@variant == :compact && "text-xs") || "text-sm"
        ]}
      >
        <span class="truncate">{item["title"]}</span>
        <.icon name="arrow-up-right" class="h-3.5 w-3.5 shrink-0" />
      </a>
    </div>
    """
  end

  defp timeline(assigns) do
    ~H"""
    <div class={[(@variant == :compact && "space-y-1 px-2") || "space-y-1.5"]}>
      <div
        :for={item <- @block["items"]}
        class={[
          "flex items-baseline gap-3",
          (@variant == :compact && "text-xs") || "text-sm"
        ]}
      >
        <span class="shrink-0 tabular-nums text-xs text-neutral-400">{item["date"]}</span>
        <span class={["min-w-0 text-neutral-800", @variant == :compact && "truncate"]}>
          {item["event"]}
        </span>
      </div>
    </div>
    """
  end

  defp entities(assigns) do
    ~H"""
    <div class={[(@variant == :compact && "space-y-1 px-2") || "space-y-2"]}>
      <div
        :for={item <- @block["items"]}
        class={[(@variant == :compact && "truncate text-xs") || "text-sm"]}
      >
        <span class="font-medium text-neutral-800">{item["name"]}</span>
        <span :if={item["detail"]} class="text-neutral-500">— {item["detail"]}</span>
      </div>
    </div>
    """
  end

  # The quiet fallback for anything unrenderable: a fence the agent got wrong,
  # an unknown type, a shape that never went through `Blocks.normalize/1`.
  # Never the raw content.
  defp invalid(assigns) do
    ~H"""
    <div class={[
      "rounded-md border border-dashed border-neutral-200 bg-neutral-50 px-3 py-2 text-xs text-neutral-400",
      @variant == :compact && "mx-2"
    ]}>
      {gettext("Unrecognized content")}
    </div>
    """
  end

  defp list_dot_class("risks"), do: "bg-red-500"
  defp list_dot_class("actions"), do: "bg-brand-500"
  defp list_dot_class("watch"), do: "bg-amber-500"
  defp list_dot_class(_plain), do: "bg-neutral-300"
end
