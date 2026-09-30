defmodule SalixStore.SlackCommandControl do
  @moduledoc """
  Low-volume admin serialization and sealed Slack configuration credentials.
  The PostgreSQL session lock spans remote calls, not a database transaction.
  Other callers fail immediately instead of occupying a waiting pool connection.
  A process/connection exit releases the lock. No lease can expire mid-request.
  """

  alias SalixStore.{Crypto, Repo, TenantConfigs}

  # One bounded admin operation across nodes. This also serializes credentials
  # shared by several Apps. Slack mutations never run inside a retried CAS.
  def exclusive(fun) do
    Repo.checkout(
      fn ->
        case Repo.query!("SELECT pg_try_advisory_lock(1397501270, 1)", [], log: false).rows do
          [[true]] ->
            try do
              fun.()
            after
              Repo.query!("SELECT pg_advisory_unlock(1397501270, 1)", [], log: false)
            end

          _ ->
            {:error, :command_admin_busy}
        end
      end,
      timeout: 60_000
    )
  end

  def profiles(tenant_id) do
    case profile_records(tenant_id) do
      {:ok, profiles} -> {:ok, profiles |> Map.keys() |> Enum.sort()}
      error -> error
    end
  end

  def valid_profile?(name),
    do: is_binary(name) and Regex.match?(~r/^[a-z0-9_-]{1,48}$/, name)

  def credential(tenant_id, profile \\ "default") do
    with {:ok, profiles} <- profile_records(tenant_id),
         sealed when is_binary(sealed) <- profiles[profile],
         {:ok, json} <-
           Crypto.unseal_slack_configuration(sealed, Jason.encode!([tenant_id, profile])),
         {:ok, value} when is_map(value) <- Jason.decode(json) do
      {:ok, value}
    else
      nil -> {:error, :configuration_credentials_missing}
      _ -> {:error, :configuration_credentials_unavailable}
    end
  end

  # Persist each rotated token before the next external call. A later remote
  # failure must not roll back a refresh token that Slack already consumed.
  def put_credential(tenant_id, value, profile \\ "default") do
    with {:ok, profiles} <- profile_records(tenant_id),
         true <-
           valid_profile?(profile) and
             (map_size(profiles) < 50 or Map.has_key?(profiles, profile)),
         {:ok, sealed} <-
           Crypto.seal_slack_configuration(
             Jason.encode!(value),
             Jason.encode!([tenant_id, profile])
           ),
         {:ok, _} <-
           TenantConfigs.put(%{
             "tenant_id" => tenant_id,
             "name" => "slack_command_configuration",
             "value" => %{"profiles" => Map.put(profiles, profile, sealed)},
             "updated_at" => System.system_time(:second)
           }) do
      :ok
    else
      false -> {:error, :invalid_credential_profile}
      error -> error
    end
  end

  defp profile_records(tenant_id) do
    case TenantConfigs.get(tenant_id, "slack_command_configuration") do
      {:ok, %{"value" => %{"profiles" => profiles}}} when is_map(profiles) -> {:ok, profiles}
      {:error, :not_found} -> {:ok, %{}}
      _ -> {:error, :configuration_credentials_unavailable}
    end
  end
end
