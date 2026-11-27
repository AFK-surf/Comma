defmodule SalixAgent.Tools.LiveActivity do
  @moduledoc "Generalized Dynamic Island / Live Activity controls (`live_status_v1`) for Router, Worker, and Background Loops."

  @categories ~w(car delivery flight train transit package order timer progress)
  @statuses ~w(active attention)
  @outcomes ~w(done cancelled failed)
  @accents ~w(auto brand green amber blue red neutral)

  def defs do
    [
      tool(
        "upsert",
        "Show or update a real-time Dynamic Island / Lock Screen Live Activity on the user's iPhone for ongoing real-world or long-running status.\n\nUse for ride-hailing (car), food or drink delivery (delivery), flights (flight), trains (train), public transit (transit), parcels (package), coffee/restaurant pickup queues (order), countdowns (timer), or long-running builds/downloads/tasks (progress). Provide a stable `key` (e.g. `ride:didi-8821`, `flight:CA1501`) and reuse the same key for subsequent updates. Supply `eta_at` (RFC3339 timestamp) whenever a concrete arrival/departure/completion time is known so iOS renders a native live countdown without extra pushes. Include `alert` only on major state transitions (e.g. driver arrived, boarding started, ready for pickup) so the phone chimes/lights up without spamming. Pair with a Background Loop (`loop.create`) when polling an external API so the Loop can call `live_activity.upsert` directly without waking the LLM on every poll. Always call `live_activity.end` when the activity completes, is cancelled, or fails. At most 5 active live activities per workspace.",
        %{
          "key" => %{
            "type" => "string",
            "pattern" => "^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,63}$",
            "description" => "Stable identifier for this live activity, e.g. ride:didi-123."
          },
          "category" => %{"type" => "string", "enum" => @categories},
          "title" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 80,
            "description" => "Short primary headline shown on Lock Screen and expanded Island."
          },
          "subtitle" => %{"type" => "string", "maxLength" => 100},
          "compact_label" => %{
            "type" => "string",
            "maxLength" => 16,
            "description" =>
              "Ultra-short trailing label for compact Dynamic Island when no ETA is set."
          },
          "eta_at" => %{
            "type" => "string",
            "description" => "RFC3339 UTC timestamp for native iOS countdown timer."
          },
          "status" => %{"type" => "string", "enum" => @statuses},
          "accent" => %{"type" => "string", "enum" => @accents},
          "progress" => %{"type" => "number", "minimum" => 0.0, "maximum" => 1.0},
          "step" => %{
            "type" => "object",
            "properties" => %{
              "current" => %{"type" => "integer", "minimum" => 1, "maximum" => 8},
              "total" => %{"type" => "integer", "minimum" => 2, "maximum" => 8},
              "label" => %{"type" => "string", "maxLength" => 24}
            },
            "required" => ["current", "total"],
            "additionalProperties" => false
          },
          "detail_left" => %{"type" => "string", "maxLength" => 48},
          "detail_right" => %{"type" => "string", "maxLength" => 32},
          "alert" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{"type" => "string", "maxLength" => 48},
              "body" => %{"type" => "string", "minLength" => 1, "maxLength" => 120}
            },
            "required" => ["body"],
            "additionalProperties" => false
          },
          "ttl_minutes" => %{"type" => "integer", "minimum" => 5, "maximum" => 480},
          "stale_minutes" => %{"type" => "integer", "minimum" => 1, "maximum" => 120}
        },
        ~w(key category title),
        :upsert,
        "write"
      ),
      tool(
        "end",
        "End an active Dynamic Island / Lock Screen Live Activity when its tracked event finishes, is cancelled, or fails.\n\nPass the exact `key` used in `live_activity.upsert`. Optionally provide a final `title` (e.g. \"已到达目的地\"), `subtitle`, `alert` for a completion chime, and `dismiss_after_seconds` (0..300; defaults to 15 for `done` and 0 for `cancelled`/`failed`).",
        %{
          "key" => %{
            "type" => "string",
            "pattern" => "^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,63}$"
          },
          "outcome" => %{"type" => "string", "enum" => @outcomes},
          "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 80},
          "subtitle" => %{"type" => "string", "maxLength" => 100},
          "alert" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{"type" => "string", "maxLength" => 48},
              "body" => %{"type" => "string", "minLength" => 1, "maxLength" => 120}
            },
            "required" => ["body"],
            "additionalProperties" => false
          },
          "dismiss_after_seconds" => %{"type" => "integer", "minimum" => 0, "maximum" => 300}
        },
        ~w(key),
        :end_activity,
        "write"
      ),
      tool(
        "list",
        "List currently active Dynamic Island / Lock Screen Live Activities in this workspace.",
        %{},
        [],
        :list,
        "read"
      )
    ]
  end

  def upsert(args, ctx), do: call(:upsert, args, ctx)
  def end_activity(args, ctx), do: call(:end_activity, args, ctx)
  def list(args, ctx), do: call(:list, args, ctx)

  defp call(operation, args, ctx) do
    module = SystemsRuntime.get_env(:salix_agent, :live_activity_adapter)
    if is_nil(module), do: raise("Comma live activity controls are unavailable")

    case apply(module, operation, [args, ctx]) do
      {:ok, result} ->
        SalixAgent.IFC.ConnectorLabels.group_audience(Jason.encode!(result), ctx)

      {:error, reason} ->
        raise "Live activity #{operation} failed: #{inspect(reason)}" <> hint(reason)
    end
  end

  defp hint(:live_activity_limit_reached),
    do: ". At most 5 active live activities are allowed per workspace; end an older one first."

  defp hint(:not_found),
    do: ". No live activity with that key exists in this workspace."

  defp hint(:workspace_required),
    do: ". Live activities require an active Comma workspace group."

  defp hint(_reason), do: ""

  defp tool(name, description, properties, required, function, safety) do
    {"live_activity." <> name, description,
     %{
       "type" => "object",
       "properties" => properties,
       "required" => required,
       "additionalProperties" => false
     }, Function.capture(__MODULE__, function, 2), 30, [safety: safety]}
  end
end
