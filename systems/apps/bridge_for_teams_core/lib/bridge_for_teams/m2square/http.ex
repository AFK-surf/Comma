defmodule BridgeForTeams.M2square.HTTP do
  @moduledoc """
  HTTP client implementing `BridgeForTeams.M2square.Client`.

  Encodes the JSON payload once, signs and sends that exact binary, uses
  `Jason.decode(raw, floats: :decimals)`, and classifies `pay/2` failures into:
    * `{:error, {:uncertain, reason}}` — transport timeouts/disconnects, 5xx,
      or ambiguous gateway codes (`999998`, `999999`, `999994`, `400000`) where
      the gateway may have created the order;
    * `{:error, {:rejected, code, msg}}` — deterministic rejections (e.g.
      `999997`, `100000`, `999992`, etc.).
  """

  @behaviour BridgeForTeams.M2square.Client

  alias BridgeForTeams.M2square.Signing

  @service_name "api.pay"
  @sign_type "SHA512"
  @connect_timeout_ms 3_000
  @receive_timeout_ms 5_000
  @uncertain_codes MapSet.new(["999998", "999999", "999994", "400000"])

  @impl true
  def pay(%{} = payload, %{} = config) do
    case post_biz("pay", payload, config) do
      {:ok, status, raw_body} ->
        parse_pay_response(status, raw_body)

      {:error, :m2square_not_configured} ->
        {:error, :m2square_not_configured}

      {:error, reason} ->
        {:error, {:uncertain, {:transport, reason}}}
    end
  end

  @impl true
  def verify_status(provider_order_id, %{} = config)
      when is_binary(provider_order_id) and provider_order_id != "" do
    case post_biz("verifyStatus", %{"orderId" => provider_order_id}, config) do
      {:ok, 200, raw_body} ->
        parse_verify_response(raw_body)

      {:ok, status, raw_body} ->
        case Jason.decode(raw_body, floats: :decimals) do
          {:ok, %{"errorCode" => error_code, "errorMsg" => error_msg}} ->
            {:error, {:gateway_error, error_code, error_msg}}

          _ ->
            {:error, {:http_error, status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_status(_provider_order_id, _config), do: {:error, :invalid_order_id}

  defp post_biz(method, payload, config) do
    base_url = Map.get(config, :base_url)
    mch_id = Map.get(config, :mch_id)
    secret_key = Map.get(config, :secret_key)

    if non_empty_binary?(base_url) and non_empty_binary?(mch_id) and non_empty_binary?(secret_key) do
      raw_json = Jason.encode!(payload)
      timestamp = SystemsClock.utc_now() |> DateTime.to_unix(:second) |> Integer.to_string()

      sign =
        Signing.sign_request(
          mch_id,
          @service_name,
          method,
          timestamp,
          @sign_type,
          raw_json,
          secret_key
        )

      headers = [
        {"content-type", "application/json"},
        {"method", method},
        {"signType", @sign_type},
        {"serviceName", @service_name},
        {"mchId", mch_id},
        {"timestamp", timestamp},
        {"sign", sign}
      ]

      req_opts =
        [
          headers: headers,
          body: raw_json,
          decode_body: false,
          retry: false,
          connect_options: [timeout: @connect_timeout_ms],
          receive_timeout: @receive_timeout_ms
        ]
        |> Keyword.merge(Map.get(config, :req_options, []))

      case Req.post(base_url, req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when is_binary(body) ->
          {:ok, status, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:ok, status, to_string(body)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :m2square_not_configured}
    end
  end

  defp parse_pay_response(status, raw_body) do
    case Jason.decode(raw_body, floats: :decimals) do
      {:ok, %{} = body} ->
        result_code = body["resultCode"]
        error_code = body["errorCode"]
        error_msg = body["errorMsg"]

        cond do
          status == 200 and result_code == "000000" and error_code == "000000" ->
            extract_pay_item(body["data"])

          status in 500..599 ->
            {:error, {:uncertain, {:http_status, status, error_code || result_code, error_msg}}}

          uncertain_code?(result_code) or uncertain_code?(error_code) ->
            {:error,
             {:uncertain, {:gateway_code, effective_code(error_code, result_code), error_msg}}}

          is_binary(effective_code(error_code, result_code)) ->
            {:error, {:rejected, effective_code(error_code, result_code), error_msg}}

          true ->
            {:error, {:uncertain, {:http_status, status}}}
        end

      {:ok, _other} ->
        {:error, {:uncertain, :invalid_pay_response}}

      {:error, _reason} ->
        {:error, {:uncertain, {:invalid_json, status}}}
    end
  end

  defp extract_pay_item([%{} = item]), do: validate_pay_item(item)
  defp extract_pay_item(_other), do: {:error, {:uncertain, :invalid_pay_data}}

  defp validate_pay_item(item) do
    order_id = item["orderId"]
    checkout_url = item["checkoutUrl"]
    currency = item["currency"]

    cond do
      not non_empty_binary?(order_id) ->
        {:error, {:uncertain, :missing_order_id}}

      not valid_https_url?(checkout_url) ->
        {:error, {:uncertain, :invalid_checkout_url}}

      true ->
        {:ok,
         %{
           order_id: order_id,
           checkout_url: checkout_url,
           currency: currency,
           raw_item: item
         }}
    end
  end

  defp parse_verify_response(raw_body) do
    case Jason.decode(raw_body, floats: :decimals) do
      {:ok, %{"resultCode" => "000000", "errorCode" => "000000", "data" => data}}
      when is_list(data) ->
        {:ok, data}

      {:ok, %{"resultCode" => result_code, "errorCode" => error_code} = body} ->
        {:error, {:gateway_error, effective_code(error_code, result_code), body["errorMsg"]}}

      {:ok, _other} ->
        {:error, :invalid_verify_response}

      {:error, _reason} ->
        {:error, :invalid_verify_json}
    end
  end

  defp uncertain_code?(code) when is_binary(code), do: MapSet.member?(@uncertain_codes, code)
  defp uncertain_code?(_), do: false

  defp effective_code(error_code, _result_code)
       when is_binary(error_code) and error_code not in ["", "000000"],
       do: error_code

  defp effective_code(_error_code, result_code)
       when is_binary(result_code) and result_code not in ["", "000000"],
       do: result_code

  defp effective_code(_, _), do: nil

  defp valid_https_url?(url) when is_binary(url) do
    if String.starts_with?(url, "https://") do
      case URI.parse(url) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
        _ -> false
      end
    else
      false
    end
  end

  defp valid_https_url?(_), do: false

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
end
