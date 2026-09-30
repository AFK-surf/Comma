defmodule SalixIM.WeChatAPI do
  @moduledoc """
  iLink transport used by the existing WeChat provider and its QR login.

  Wire reference: Tencent's @tencent-weixin/openclaw-weixin 2.4.8.
  That package is an OpenClaw/Node plugin, not an Elixir SDK; this adapter uses
  Req and shares the provider's existing transport rather than running another bot.
  """

  @base_url "https://ilinkai.weixin.qq.com"
  @version "2.4.8"

  def base_url, do: Application.get_env(:salix_im, :wechat_api_base_url, @base_url)

  def headers(token \\ nil) do
    <<uin::32>> = :crypto.strong_rand_bytes(4)

    headers = [
      {"ilink-app-id", "bot"},
      {"ilink-app-clientversion", "132104"},
      {"authorizationtype", "ilink_bot_token"},
      {"x-wechat-uin", Base.encode64(Integer.to_string(uin))}
    ]

    if is_binary(token) and token != "",
      do: [{"authorization", "Bearer " <> token} | headers],
      else: headers
  end

  def base_info, do: %{"channel_version" => @version, "bot_agent" => "Comma/1.0"}

  def start_login do
    request(:post, base_url(), "/ilink/bot/get_bot_qrcode",
      params: [bot_type: "3"],
      json: %{"local_token_list" => []}
    )
  end

  def poll_login(base, qrcode, verify_code \\ nil) do
    params =
      if verify_code, do: [qrcode: qrcode, verify_code: verify_code], else: [qrcode: qrcode]

    case request(:get, base, "/ilink/bot/get_qrcode_status", params: params) do
      {:error, :wechat_timeout} -> {:ok, %{"status" => "wait"}}
      other -> other
    end
  end

  # The QR response is Tencent's authority for its serving region. Confining
  # that origin prevents credentials or pairing codes going to an arbitrary
  # redirect/SSRF target. Invalid origins fail the login before activation.
  def validate_origin(value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      value == base_url() ->
        {:ok, String.trim_trailing(value, "/")}

      uri.scheme == "https" and uri.port == 443 and is_nil(uri.userinfo) and
        is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "", "/"] and
        is_binary(uri.host) and String.ends_with?(uri.host, ".weixin.qq.com") ->
        {:ok, "https://" <> uri.host}

      true ->
        {:error, :invalid_wechat_response}
    end
  end

  def validate_origin(_), do: {:error, :invalid_wechat_response}

  defp request(method, base, path, opts) do
    with {:ok, base} <- validate_origin(base) do
      opts =
        Keyword.merge(opts,
          method: method,
          url: base <> path,
          headers: headers(),
          retry: false,
          redirect: false,
          receive_timeout: 15_000,
          connect_options: [timeout: 5_000]
        )

      case Req.request(opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          with {:ok, body} <- decode_body(body),
               true <- body["ret"] in [nil, 0] and body["errcode"] in [nil, 0] do
            {:ok, body}
          else
            _ -> {:error, :wechat_unavailable}
          end

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, :wechat_timeout}

        _ ->
          {:error, :wechat_unavailable}
      end
    end
  end

  @doc "Decodes iLink JSON objects, including application/octet-stream responses."
  def decode_body(body) when is_map(body), do: {:ok, body}

  def decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :wechat_unavailable}
    end
  end

  def decode_body(_), do: {:error, :wechat_unavailable}
end
