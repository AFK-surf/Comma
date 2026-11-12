defmodule Comma.Auth.Registration do
  @moduledoc "New-user OAuth continuations in the existing one-time Auth Challenge owner."

  alias Comma.Accounts.SessionClientMetadata
  alias Comma.Auth.{Abuse, OneTimeCredentials}

  @purpose "app_registration"
  @ttl_seconds 300

  def required?(platform, attrs),
    do: Abuse.enforced?() or Abuse.collect?(platform, attrs["native_proof"])

  def start(provider, claims, email, platform, attrs) do
    metadata =
      SessionClientMetadata.attributes(attrs)
      |> Map.put("remote_ip", attrs["remote_ip"] || "unknown")

    operation = fn -> start_challenge(provider, claims, email, platform, attrs, metadata) end

    result =
      if Abuse.enforced?(),
        do: operation.(),
        else: Abuse.observe("registration", platform, operation)

    case result do
      {:challenge, _, _} -> result
      :ok -> finish(provider, claims, metadata)
      _ -> result
    end
  end

  defp start_challenge(provider, claims, email, platform, attrs, metadata) do
    with {:ok, grant} <-
           OneTimeCredentials.issue(
             @purpose,
             %{
               "provider" => provider,
               "claims" => claims,
               "metadata" => metadata,
               "platform" => platform
             },
             @ttl_seconds,
             attrs["remote_ip"] || "unknown",
             Abuse.peer_limits()
           ) do
      continuation = OneTimeCredentials.pack(grant)

      case Abuse.check("registration", email, platform, nil, context(attrs, continuation)) do
        {:challenge, reason, challenge} -> challenge(reason, challenge, continuation)
        result -> result
      end
    end
  end

  def complete(attrs) when is_map(attrs) do
    continuation = attrs["registration_continuation"]

    with {:ok, id, secret} <- OneTimeCredentials.unpack(continuation),
         :ok <-
           Abuse.check("registration", nil, nil, attrs["abuse"], context(attrs, continuation)),
         {:ok, state} <- OneTimeCredentials.consume(@purpose, id, secret) do
      case state do
        %{"provider" => provider, "claims" => claims, "metadata" => metadata} ->
          finish(provider, claims, metadata)

        _ ->
          {:error, :invalid_registration_continuation}
      end
    else
      {:challenge, reason, challenge} -> challenge(reason, challenge, continuation)
      {:error, :invalid_one_time_credential} -> {:error, :invalid_registration_continuation}
      error -> error
    end
  end

  def complete(_attrs), do: {:error, :invalid_registration_continuation}

  def context(attrs, continuation \\ nil) do
    %{
      "api_origin" => attrs["api_origin"] || SystemsRuntime.get_env(:salix_web, :public_base_url),
      "remote_ip" => attrs["remote_ip"] || "unknown",
      "native_proof" => attrs["native_proof"],
      "registration_continuation" => continuation
    }
  end

  defp finish("google", claims, metadata),
    do: Comma.GoogleAuth.finish_registration(claims, metadata)

  defp finish("apple", claims, metadata),
    do: Comma.AppleAuth.finish_registration(claims, metadata)

  defp finish(_, _, _), do: {:error, :invalid_registration_continuation}

  defp challenge(reason, challenge, continuation) do
    {:challenge, reason, %{"challenge" => challenge, "registration_continuation" => continuation}}
  end
end
