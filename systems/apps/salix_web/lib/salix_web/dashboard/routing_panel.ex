defmodule SalixWeb.Dashboard.RoutingPanel do
  use Phoenix.Component
  import SalixWeb.Dashboard.CoreComponents
  alias SalixWeb.Dashboard.RoutingForm

  attr(:enabled, :boolean, required: true)
  attr(:learning, :boolean, default: false)
  attr(:learned, :map, default: %{})
  attr(:rows, :map, required: true)
  attr(:policy, :any, default: nil)
  attr(:error, :any, default: nil)
  attr(:dirty, :boolean, default: false)
  attr(:models, :list, required: true)
  attr(:loading, :boolean, default: false)
  attr(:saving, :boolean, default: false)
  attr(:models_error, :any, default: nil)
  attr(:truncated, :boolean, default: false)
  # "group": a Group's table; "platform": the platform route table, whose
  # models are the ones the platform's API keys serve.
  attr(:scope, :string, default: "group")

  def panel(assigns) do
    assigns =
      assign(assigns,
        fallback:
          if(assigns.scope == "platform",
            do: "Tasks run the Worker tier's model",
            else: "Tasks use the Worker's model settings"
          ),
        arms:
          if(assigns.scope == "platform",
            do: "the models the platform's API keys serve",
            else: "the models and reasoning efforts this workspace can use"
          )
      )

    ~H"""
    <form id="model-routing-form" phx-change="change-routing" phx-submit="save-routing" class="space-y-4">
      <.card>
        <:title>Model routing</:title>
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-2xl space-y-2">
            <p class="text-sm text-neutral-700">Describe each task category and choose its model.</p>
            <p class="text-xs text-neutral-500">Changes apply to new tasks. Existing tasks keep their model.</p>
          </div>
          <div>
            <input type="hidden" name="routing[enabled]" value="false" />
            <.toggle id="routing-enabled" name="routing[enabled]" value="true" checked={@enabled} label="Enable routing" disabled={@saving} />
          </div>
        </div>
        <p :if={!@enabled} class="mt-4 text-sm text-neutral-500">Routing is off. {@fallback}. Saved entries are kept.</p>
        <p :if={@enabled and RoutingForm.editable?(@policy) and map_size(@rows) == 0} class="mt-4 text-sm text-neutral-500">The route table is empty. {@fallback}, just as when routing is off.</p>
      </.card>
      <.card :if={RoutingForm.editable?(@policy)}>
        <:title>Route table</:title>
        <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
          <p class="text-xs text-neutral-500">Keys are unique and case-sensitive. Descriptions guide selection. Row order does not set priority.</p>
          <div id="routing-transfer" phx-hook="RoutingTransfer" data-max-bytes={RoutingForm.max_file_bytes()} class="flex flex-wrap gap-2">
            <input id="routing-import-file" type="file" accept=".json,application/json" class="hidden" disabled={@saving} aria-label="Import route table JSON" />
            <.button id="routing-import" data-routing-import disabled={@saving} size="sm">Import JSON</.button>
            <.button id="routing-export" phx-click="export-routing" disabled={@saving} size="sm">Export JSON</.button>
            <.button phx-click="refresh-routing-models" disabled={@loading or @saving} size="sm">{if @loading, do: "Loading models…", else: "Refresh models"}</.button>
          </div>
        </div>
        <div class="mb-4 flex flex-wrap items-start justify-between gap-4 rounded-lg border border-neutral-200 p-4">
          <div class="max-w-2xl space-y-1">
            <p class="text-sm font-medium text-neutral-700">Learn from task results</p>
            <p class="text-xs text-neutral-500">Each entry tries {@arms} and moves to the one with the lowest cost per completed task. Accepted reviews count as completed, failed tasks as failed. At most one task in ten tries another model.</p>
          </div>
          <div>
            <input type="hidden" name="routing[learning]" value="false" />
            <.toggle id="routing-learning" name="routing[learning]" value="true" checked={@learning} label="Learn from task results" disabled={@saving} />
          </div>
        </div>
        <p class="mb-4 text-xs text-neutral-500">Import replaces the entries in this editor. Save to apply them. JSON files contain entries only. The routing switch and Profile stay unchanged.</p>
        <p :if={@models_error} role="alert" class="mb-4 text-sm text-red-600">{@models_error}</p>
        <p :if={!@loading and @models == [] and !@models_error and @scope == "platform"} class="mb-4 text-sm text-neutral-500">No platform API key serves a model. Add a platform Profile to select a model.</p>
        <p :if={!@loading and @models == [] and !@models_error and @scope != "platform"} class="mb-4 text-sm text-neutral-500">No models match this group's enabled accounts, Profile and model policy. Configure an account to select a model.</p>
        <p :if={@truncated} class="mb-4 text-xs text-amber-700">The model lookup returned a partial list. A saved choice outside this list cannot be verified.</p>
        <p :if={@policy && @policy["profile_id"]} class="mb-4 text-xs text-neutral-500">Using the route table's saved Profile. Only models served by that Profile are listed.</p>
        <div :if={map_size(@rows) == 0} class="rounded-lg border border-dashed border-neutral-200 p-6 text-center">
          <p class="text-sm font-medium text-neutral-700">No routing entries</p>
          <p class="mt-2 text-sm text-neutral-500">Add an entry to route tasks, or leave the table empty: {@fallback}.</p>
        </div>
        <div :if={map_size(@rows) > 0} class="overflow-x-auto">
          <div class="min-w-[56rem]">
            <div class="grid grid-cols-12 items-center gap-3 border-b border-neutral-200 pb-3 text-xs font-medium text-neutral-500" aria-hidden="true">
              <span class="col-span-2">Key</span><span class="col-span-4">Description</span><span class="col-span-3">Model</span><span class="col-span-3">Reasoning effort</span>
            </div>
            <div :for={{id, row} <- RoutingForm.ordered(@rows)} id={"routing-row-#{id}"} class="grid h-16 grid-cols-12 items-center gap-3 border-b border-neutral-100">
              <.input class="col-span-2 min-w-0" id={"routing-key-#{id}"} name={"routing[rows][#{id}][key]"} value={row["key"]} aria-label="Key" placeholder="e.g. quick-edit" disabled={@saving} />
              <.input class="col-span-4 min-w-0 [&_input]:text-ellipsis [&_input:focus]:text-clip" id={"routing-description-#{id}"} name={"routing[rows][#{id}][description]"} value={row["description"]} aria-label="Description" title={row["description"]} placeholder="Describe the tasks for this model" disabled={@saving} />
              <.select class="col-span-3 min-w-0" id={"routing-model-#{id}"} name={"routing[rows][#{id}][model]"} value={row["model"]} options={RoutingForm.model_options(@models, row["model"])} prompt="Choose a model" aria-label="Model" disabled={@loading or @saving or @models == []} />
              <div class="col-span-3 flex min-w-0 items-center gap-2">
                <.select class="min-w-0 flex-1" id={"routing-effort-#{id}"} name={"routing[rows][#{id}][effort]"} value={row["effort"]} options={RoutingForm.efforts(@models, row["model"], row["effort"])} prompt="Choose effort" aria-label="Reasoning effort" disabled={@loading or @saving or RoutingForm.efforts(@models, row["model"]) == []} />
                <.button variant="ghost" size="sm" class="!h-8 !w-8 !p-0 shrink-0 text-neutral-500 hover:text-red-600" phx-click="remove-routing" phx-value-id={id} disabled={@saving} aria-label={"Delete entry #{row["key"]}"} title="Delete entry"><.icon name="trash" class="h-4 w-4" /></.button>
              </div>
            </div>
          </div>
        </div>
        <div :if={@learning and map_size(@learned) > 0} id="routing-learned" class="mt-4 space-y-1">
          <p class="text-xs font-medium text-neutral-500">Learned so far</p>
          <p :for={{key, learned} <- Enum.sort(@learned)} class="text-xs text-neutral-600"><span class="font-mono">{key}</span>: {learned["label"]} · {learned["tasks"]} results</p>
        </div>
        <div class="mt-4 flex flex-wrap items-center justify-between gap-3">
          <.button phx-click="add-routing" disabled={@saving or map_size(@rows) >= 32} size="sm">Add entry</.button>
          <span class="text-xs text-neutral-500">{map_size(@rows)} / 32 entries</span>
        </div>
      </.card>
      <.card :if={!RoutingForm.editable?(@policy)}>
        <:title>Existing routing strategy</:title>
        <p class="text-sm text-neutral-700">This configuration uses another routing format. Its entries are preserved. Supported strategies can be turned on or off here.</p>
      </.card>
      <div :if={Enum.any?(@rows, fn {_id, row} -> row["model"] != "" and not RoutingForm.valid_row?(row, @models) end) and not @loading and is_nil(@models_error)} class="text-sm text-amber-700" role="status">Some saved entries use unavailable models or efforts. Replace them before enabling routing, or delete the entries.</div>
      <div :if={@error} role="alert"><.error>{@error}</.error></div>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <p class="text-xs text-neutral-500">{if @dirty, do: "Unsaved changes", else: "Changes apply after you save."}</p>
        <div class="flex gap-2">
          <.button phx-click="reset-routing" disabled={!@dirty or @saving}>Discard changes</.button>
          <.button type="submit" variant="primary" disabled={!@dirty or @saving or (@enabled and map_size(@rows) > 0 and @loading)} phx-disable-with="Saving…">Save changes</.button>
        </div>
      </div>
    </form>
    """
  end
end
