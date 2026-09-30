defmodule Salix.Bindings.MeetingActivationProvenance do
  @moduledoc false

  @behaviour SalixAgent.MeetingActivationProvenance

  alias SalixIM.Provider.Feishu.MeetingActivationAuthorization

  @impl true
  def authorize_schedule(ctx) do
    reject_when_activation_bound(ctx, :meeting_activation_schedule_not_authorized)
  end

  defp reject_when_activation_bound(ctx, reason) do
    case MeetingActivationAuthorization.provenance_for_tool_context(context_group_id(ctx), ctx) do
      {:ok, refs} when map_size(refs) == 0 -> :ok
      {:ok, _refs} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  defp context_group_id(ctx), do: ctx[:group_id] || ctx["group_id"] || ""
end
