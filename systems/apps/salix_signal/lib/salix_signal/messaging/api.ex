defmodule SalixSignal.Messaging.Api do
  @moduledoc """
  Request bodies and response parsing of the message endpoints (CRS-07 §3,
  CRS-06 §3.6 and §10.2, CRS-03 §9.5).

  | Request | Path |
  | --- | --- |
  | single-recipient send | `PUT /v1/messages/{service id}` |
  | multi-recipient send | `PUT /v1/messages/multi_recipient?ts=&online=&urgent=&story=` |
  | sender certificate | `GET /v1/certificate/delivery?includeE164=false` |
  | pre-key bundles | `GET /v2/keys/{service id}/{device id or *}` |
  """

  alias SalixSignal.Service.Response

  @typedoc "One per-device entry of a single-recipient send (CRS-07 §3.1)."
  @type device_message :: %{
          type: 1 | 3 | 6 | 8,
          device_id: 1..127,
          registration_id: non_neg_integer(),
          content: binary()
        }

  @doc "The path of a single-recipient send."
  @spec send_path(String.t()) :: String.t()
  def send_path(service_id), do: "/v1/messages/" <> service_id

  @doc """
  The JSON body of a single-recipient send. `content` is standard base64 with
  padding.
  """
  @spec send_body([device_message()], non_neg_integer(), boolean(), boolean()) :: map()
  def send_body(messages, timestamp, online, urgent) do
    %{
      "messages" =>
        Enum.map(messages, fn message ->
          %{
            "type" => message.type,
            "destinationDeviceId" => message.device_id,
            "destinationRegistrationId" => message.registration_id,
            "content" => Base.encode64(message.content)
          }
        end),
      "online" => online,
      "urgent" => urgent,
      "timestamp" => timestamp
    }
  end

  @doc "The path of a multi-recipient send with all four query parameters (CRS-06 §10.2)."
  @spec multi_recipient_path(non_neg_integer(), boolean(), boolean()) :: String.t()
  def multi_recipient_path(timestamp, online, urgent),
    do:
      "/v1/messages/multi_recipient?ts=#{timestamp}&online=#{online}&urgent=#{urgent}&story=false"

  @doc "The media type of a multi-recipient upload."
  def multi_recipient_content_type, do: "application/vnd.signal-messenger.mrm"

  @doc "The sender certificate path; Comma asks for a certificate without the phone number."
  def certificate_path, do: "/v1/certificate/delivery?includeE164=false"

  @doc "The pre-key bundle path for one device, or `:all` devices."
  @spec keys_path(String.t(), 1..127 | :all) :: String.t()
  def keys_path(service_id, :all), do: "/v2/keys/#{service_id}/*"
  def keys_path(service_id, device_id), do: "/v2/keys/#{service_id}/#{device_id}"

  @typedoc "A classified send response."
  @type send_result ::
          :ok
          | {:mismatch, %{missing: [1..127], extra: [1..127]}}
          | {:stale, [1..127]}
          | :unauthorized
          | :not_found
          | :too_large
          | :invalid_request
          | {:challenge_required, Response.challenge()}
          | {:rate_limited, non_neg_integer() | nil}
          | {:server_error, non_neg_integer()}
          | {:http_error, non_neg_integer()}

  @doc """
  Classifies the response to a single-recipient send (CRS-07 §3.2). A 409
  or 410 whose body does not parse is `{:http_error, status}`.
  """
  @spec send_result(Response.t()) :: send_result()
  def send_result(%Response{status: status}) when status in 200..299, do: :ok

  def send_result(%Response{status: 409} = response) do
    case Response.json(response) do
      {:ok, %{} = body} ->
        with {:ok, missing} <- device_list(Map.get(body, "missingDevices", [])),
             {:ok, extra} <- device_list(Map.get(body, "extraDevices", [])) do
          {:mismatch, %{missing: missing, extra: extra}}
        else
          _ -> {:http_error, 409}
        end

      _ ->
        {:http_error, 409}
    end
  end

  def send_result(%Response{status: 410} = response) do
    with {:ok, %{"staleDevices" => stale}} <- Response.json(response),
         {:ok, stale} <- device_list(stale) do
      {:stale, stale}
    else
      _ -> {:http_error, 410}
    end
  end

  def send_result(%Response{status: 401}), do: :unauthorized
  def send_result(%Response{status: 404}), do: :not_found
  def send_result(%Response{status: 413}), do: :too_large
  def send_result(%Response{status: status}) when status in [400, 403, 422], do: :invalid_request

  def send_result(%Response{} = response) do
    case Response.outcome(response) do
      {:challenge_required, challenge} -> {:challenge_required, challenge}
      {:rate_limited, seconds} -> {:rate_limited, seconds}
      {:server_error, status} -> {:server_error, status}
      _ -> {:http_error, response.status}
    end
  end

  @typedoc "A classified multi-recipient send response (CRS-07 §3.3)."
  @type multi_result ::
          {:ok, [String.t()]}
          | {:mismatch, [%{service_id: String.t(), missing: [1..127], extra: [1..127]}]}
          | {:stale, [%{service_id: String.t(), stale: [1..127]}]}
          | :unauthorized
          | :not_found
          | :too_large
          | :invalid_request
          | {:challenge_required, Response.challenge()}
          | {:rate_limited, non_neg_integer() | nil}
          | {:server_error, non_neg_integer()}
          | {:http_error, non_neg_integer()}

  @doc """
  Classifies the response to a multi-recipient send (CRS-07 §3.3). A 200
  lists unregistered recipients in `uuids404` (absent means none).
  """
  @spec multi_result(Response.t()) :: multi_result()
  def multi_result(%Response{status: status} = response) when status in 200..299 do
    case Response.json(response) do
      {:ok, %{"uuids404" => list}} when is_list(list) -> {:ok, Enum.filter(list, &is_binary/1)}
      _ -> {:ok, []}
    end
  end

  def multi_result(%Response{status: 409} = response) do
    entries(response, 409, fn devices ->
      with {:ok, missing} <- device_list(Map.get(devices, "missingDevices", [])),
           {:ok, extra} <- device_list(Map.get(devices, "extraDevices", [])) do
        {:ok, %{missing: missing, extra: extra}}
      end
    end)
    |> tag(:mismatch)
  end

  def multi_result(%Response{status: 410} = response) do
    entries(response, 410, fn devices ->
      with {:ok, stale} <- device_list(Map.get(devices, "staleDevices", [])),
           do: {:ok, %{stale: stale}}
    end)
    |> tag(:stale)
  end

  def multi_result(%Response{status: 400}), do: :invalid_request
  def multi_result(%Response{} = response), do: send_result(response)

  defp entries(response, status, parse) do
    with {:ok, list} when is_list(list) <- Response.json(response),
         {:ok, parsed} <-
           Enum.reduce_while(list, {:ok, []}, fn
             %{"uuid" => id, "devices" => %{} = devices}, {:ok, acc} when is_binary(id) ->
               case parse.(devices) do
                 {:ok, entry} -> {:cont, {:ok, [Map.put(entry, :service_id, id) | acc]}}
                 _ -> {:halt, :error}
               end

             _other, _acc ->
               {:halt, :error}
           end) do
      {:ok, Enum.reverse(parsed)}
    else
      _ -> {:error, status}
    end
  end

  defp tag({:ok, entries}, tag), do: {tag, entries}
  defp tag({:error, status}, _tag), do: {:http_error, status}

  defp device_list(list) when is_list(list) do
    if Enum.all?(list, &(is_integer(&1) and &1 in 1..127)), do: {:ok, list}, else: :error
  end

  defp device_list(_other), do: :error

  @doc "Reads the sender certificate from a `GET /v1/certificate/delivery` response (CRS-06 §3.6)."
  @spec certificate(Response.t()) :: {:ok, binary()} | {:error, :malformed}
  def certificate(%Response{status: 200} = response) do
    with {:ok, %{"certificate" => encoded}} when is_binary(encoded) <- Response.json(response),
         {:ok, bytes} <- Base.decode64(encoded) do
      {:ok, bytes}
    else
      _ -> {:error, :malformed}
    end
  end

  def certificate(%Response{}), do: {:error, :malformed}
end
