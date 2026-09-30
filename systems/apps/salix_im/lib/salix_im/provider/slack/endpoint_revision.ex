defmodule SalixIM.Provider.Slack.EndpointRevision do
  @moduledoc "Canonical credential-free Slack endpoint identity revision."

  alias SalixIM.Triage.CanonicalJSON

  @fields ~w(
    app_id
    bot_user_id
    connect_generation
    connect_id
    group_id
    inbound_agent_id
    provider
    tenant_id
    workspace_id
  )

  @spec sha256(map()) :: {:ok, String.t()} | {:error, :invalid_slack_endpoint_identity}
  def sha256(endpoint) when is_map(endpoint) do
    projection = Map.take(endpoint, @fields)

    with true <- Map.keys(projection) |> Enum.sort() == @fields,
         true <- projection["provider"] == "slack",
         true <- is_binary(projection["bot_user_id"]),
         true <-
           @fields
           |> List.delete("bot_user_id")
           |> Enum.all?(&present?(projection[&1])),
         {:ok, bytes} <- CanonicalJSON.encode(projection) do
      {:ok, CanonicalJSON.sha256(bytes)}
    else
      _other -> {:error, :invalid_slack_endpoint_identity}
    end
  end

  def sha256(_endpoint), do: {:error, :invalid_slack_endpoint_identity}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
