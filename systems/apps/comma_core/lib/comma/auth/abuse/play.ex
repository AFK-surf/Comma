defmodule Comma.Auth.Abuse.Play do
  @moduledoc false
  alias Comma.Auth.Abuse.HTTP
  @scope "https://www.googleapis.com/auth/playintegrity"

  def configured? do
    config()[:project_number] not in [nil, ""] and config()[:package_name] not in [nil, ""] and
      config()[:decoder_service_account] not in [nil, ""] and
      match?([_ | _], config()[:certificate_digests])
  end

  def project_number, do: config()[:project_number]

  def verify(token, proof_bytes) when is_binary(token) and byte_size(token) in 1..16_384 do
    with true <- configured?(),
         {:ok, access_token} <- access_token(),
         {:ok, %{status: 200, body: body}} <-
           request(
             method: :post,
             url:
               "https://playintegrity.googleapis.com/v1/#{URI.encode(config()[:package_name], &URI.char_unreserved?/1)}:decodeIntegrityToken",
             auth: {:bearer, access_token},
             json: %{integrity_token: token}
           ),
         {:ok, %{"tokenPayloadExternal" => payload}} <- Jason.decode(body),
         true <- verdict?(payload, proof_bytes) do
      :ok
    else
      _ -> {:error, :native_proof_rejected}
    end
  rescue
    _ -> {:error, :native_proof_rejected}
  catch
    :exit, _ -> {:error, :native_proof_rejected}
  end

  def verify(_, _), do: {:error, :native_proof_rejected}

  defp verdict?(payload, proof_bytes) do
    details = payload["requestDetails"] || %{}
    app = payload["appIntegrity"] || %{}
    device = payload["deviceIntegrity"] || %{}

    with {issued, ""} <- Integer.parse(details["timestampMillis"] || ""),
         now <- SystemsClock.system_time(:millisecond),
         true <- issued <= now and now - issued <= 120_000 do
      details["requestPackageName"] == config()[:package_name] and
        details["requestHash"] ==
          Base.url_encode64(:crypto.hash(:sha256, proof_bytes), padding: false) and
        app["appRecognitionVerdict"] == "PLAY_RECOGNIZED" and
        app["packageName"] == config()[:package_name] and
        is_list(app["certificateSha256Digest"]) and
        Enum.any?(app["certificateSha256Digest"], &(&1 in config()[:certificate_digests])) and
        "MEETS_DEVICE_INTEGRITY" in (device["deviceRecognitionVerdict"] || [])
    else
      _ -> false
    end
  end

  defp access_token do
    case config()[:token_provider] do
      provider when is_function(provider, 0) ->
        provider.()

      nil ->
        with {:ok, bootstrap} <-
               Goth.Token.fetch(source: :metadata, http_client: {&request/1, []}),
             {:ok, %{status: 200, body: body}} <-
               request(
                 method: :post,
                 url:
                   "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/#{URI.encode(config()[:decoder_service_account], &URI.char_unreserved?/1)}:generateAccessToken",
                 auth: {:bearer, bootstrap.token},
                 json: %{scope: [@scope]}
               ),
             {:ok, %{"accessToken" => token}} <- Jason.decode(body),
             true <- is_binary(token) and token != "" do
          {:ok, token}
        else
          _ -> {:error, :provider_unavailable}
        end
    end
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    :exit, _ -> {:error, :provider_unavailable}
  end

  defp request(options) do
    transport = Keyword.put(config()[:request_options] || [], :redirect, false)
    HTTP.request(options, transport)
  end

  defp config, do: SystemsRuntime.get_env(:comma_core, :auth_abuse, [])[:play] || []
end
