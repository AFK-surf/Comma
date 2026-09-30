defmodule SalixAgent.MeetingSummaryScope do
  @moduledoc "Tool scope of a product-owned meeting summary event, never transcript instructions."

  @reads ~w(help meeting.get meeting.read_summary_materials memory.get memory.search history.get history.list history.search tool_call.get_result tool_call.get_status)

  def origin(ctx, params) do
    Enum.find(origins(ctx), fn origin ->
      context = origin["provider_context"] || %{}

      summary_origin?(origin) and context["meeting_id"] == params["meeting_id"] and
        context["summary_request_id"] == params["request_id"] and
        origin["source_message_id"] ==
          "meeting-summary:#{params["meeting_id"]}:#{params["request_id"]}"
    end)
  end

  def authorize_tool!(name, ctx) do
    if Enum.any?(origins(ctx), &summary_origin?/1) and
         name not in ["meeting.submit_summary" | @reads] do
      raise "meeting summary activation does not authorize #{name}"
    end

    :ok
  end

  defp summary_origin?(origin) do
    origin["source_actor_type"] == "provider_system" and
      get_in(origin, ["provider_context", "event_type"]) == "meeting.summary_requested"
  end

  defp origins(ctx) do
    primary = ctx[:trusted_origin] || ctx["trusted_origin"]
    rest = ctx[:trusted_origins] || ctx["trusted_origins"] || []
    rest = if is_map(rest), do: Map.values(rest), else: List.wrap(rest)
    Enum.filter([primary | rest], &is_map/1)
  end
end
