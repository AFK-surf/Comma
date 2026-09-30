defmodule SalixMeet.ProviderDispatcher do
  @moduledoc """
  Routes Router-authorized meeting joins and terminal publication to the
  originating provider.

  Production wiring disables manual webhook interception so human Slack and
  Feishu messages reach the Router first. The legacy event entry remains here
  as provider-domain behavior; provider-specific modules also validate the
  Router tool call's sealed current source. The meeting runtime and durable
  state remain shared.
  """

  alias SalixMeet.{FeishuProvider, SlackProvider, Store}

  @spec handle_event(map(), map()) :: {:ok, :handled} | :ignored | {:error, term()}
  def handle_event(connect, envelope) when is_map(connect) and is_map(envelope) do
    case provider(connect) do
      "slack" -> SlackProvider.handle_event(connect, envelope)
      "feishu" -> FeishuProvider.handle_event(connect, envelope)
      _ -> :ignored
    end
  end

  @spec join_from_router(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def join_from_router(connect, source, params)
      when is_map(connect) and is_map(source) and is_map(params) do
    case {provider(connect), source["provider"]} do
      {"slack", "slack"} -> SlackProvider.join_from_router(connect, source, params)
      {"feishu", "feishu"} -> FeishuProvider.join_from_router(connect, source, params)
      _ -> {:error, :meeting_source_connect_mismatch}
    end
  end

  @spec publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish(meeting_agent, payload) when is_map(meeting_agent) and is_map(payload) do
    meeting_id = value(payload, "meeting_id")

    with true <- meeting_id != "" or {:error, :meeting_id_required},
         {:ok, %{"state" => state}, _etag} <- Store.get(meeting_id) do
      case value(state, "provider") do
        "slack" -> SlackProvider.publish(meeting_agent, payload)
        "feishu" -> FeishuProvider.publish(meeting_agent, payload)
        provider -> {:error, {:unsupported_meeting_provider, provider}}
      end
    else
      {:error, :not_found} -> {:error, "meeting not found"}
      {:error, _} = error -> error
    end
  end

  @spec notify(String.t(), map(), map()) :: :ok | {:error, term()}
  def notify(meeting_id, state, event)
      when is_binary(meeting_id) and is_map(state) and is_map(event) do
    case value(state, "provider") do
      "feishu" -> FeishuProvider.notify_status(meeting_id, state, event)
      _ -> :ok
    end
  end

  defp provider(connect), do: value(connect, "provider")

  defp value(map, key) do
    map
    |> Map.get(key, Map.get(map, String.to_existing_atom(key)))
    |> to_string()
    |> String.trim()
  rescue
    ArgumentError -> map |> Map.get(key) |> to_string() |> String.trim()
  end
end
