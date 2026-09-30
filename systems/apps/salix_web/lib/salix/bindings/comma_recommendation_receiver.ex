defmodule Salix.Bindings.CommaRecommendationReceiver do
  @moduledoc "A scheduled Routine ACK means its generation is durably queued."

  def receive(%{"profile_id" => profile_id}, status, opts) when status in [:claimed, :exists] do
    result =
      Application.fetch_env!(:salix_agent, :recommendation_adapter_mod).begin_schedule_occurrence(
        profile_id,
        Keyword.fetch!(opts, :schedule_id),
        Keyword.fetch!(opts, :scheduled_for)
      )

    case result do
      {:ok, _} -> {:ok, :fired}
      {:error, :no_recommendation_sources} -> {:ok, :fired}
      {:error, _} = error -> error
    end
  end

  def receive(_payload, {:error, reason}, _opts), do: {:error, reason}

  def receive(_payload, _status, _opts),
    do: {:ok, :undeliverable, :invalid_recommendation_schedule}
end
