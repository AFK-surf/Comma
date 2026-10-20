defmodule SalixIM.LarkChecks do
  @moduledoc """
  On-demand checks of one Lark connect, for the BridgeForTeams Run checks
  surface.

  A Lark connect holds its app's own credentials, so every check takes a
  `connect_id` and reads the Verification Token and the Encrypt Key from the
  connect record inside Salix. The caller never passes a secret.

    * `bot_identity/1`: the connect knows the bot's `open_id`, which a group
      mention names the bot by.
    * `callback_preflight_for_connect/1`: posts a URL verification to the
      connect's own request URL (`/v1/im/lark/events?app_id=<id>`) and expects
      the challenge back.

  The preflight sends what Lark sends. With an Encrypt Key the envelope is
  `{"encrypt": ...}`, AES-256-CBC with a random 16-byte IV before the
  ciphertext, and the request has the `X-Lark-Signature` headers. Without one
  the envelope is plain and has the Verification Token.

  Each function returns `{:ok, evidence}` or `{:error, reason_class}`. The
  evidence has states and IDs only, never a secret or a message.
  """

  alias SalixIM.ProviderConnects

  @doc """
  Checks that the connect knows the bot's `open_id`.

  Returns `{:ok, evidence}` with a fingerprint of the `open_id`, or
  `{:error, :bot_identity_missing | :connect_not_found | :connect_inactive}`.
  """
  @spec bot_identity(map()) :: {:ok, map()} | {:error, atom()}
  def bot_identity(params) when is_map(params) do
    with {:ok, connect} <- resolve_connect(params) do
      case trim(connect["bot_open_id"]) do
        "" ->
          {:error, :bot_identity_missing}

        open_id ->
          {:ok,
           %{
             "ok" => true,
             "redacted" => true,
             "identity" => "lark_bot_open_id",
             "open_id_fingerprint" => fingerprint(open_id),
             "app_id" => trim(connect["app_id"]),
             "connect_id" => trim(connect["connect_id"]),
             "checked_at" => checked_at()
           }}
      end
    end
  end

  @doc """
  Posts a URL verification to a Lark request URL and expects the challenge
  back.

  `params` keys (string or atom):

    * `"webhook_url"`: the request URL; by default this deployment's
      `/v1/im/lark/events`.
    * `"app_id"`: set as the `app_id` query parameter, which names the connect.
    * `"verification_token"`: the token of the envelope.
    * `"encrypt_key"`: when present, the envelope is encrypted and signed.

  Returns `{:ok, evidence}`, or `{:error, reason_class}` with one of
  `:token_mismatch | :decrypt_signature | :callback_unreachable |
  :unexpected_response`.
  """
  @spec callback_preflight(map()) :: {:ok, map()} | {:error, atom()}
  def callback_preflight(params) when is_map(params) do
    encrypt_key = trim(get(params, "encrypt_key"))
    encrypted? = encrypt_key != ""
    challenge = "lark_preflight_" <> nonce()

    plain =
      Jason.encode!(%{
        "type" => "url_verification",
        "challenge" => challenge,
        "token" => trim(get(params, "verification_token"))
      })

    {raw, headers} =
      if encrypted? do
        raw = Jason.encode!(%{"encrypt" => encrypt(plain, encrypt_key)})
        {raw, [{"content-type", "application/json"} | signature_headers(raw, encrypt_key)]}
      else
        {plain, [{"content-type", "application/json"}]}
      end

    case post(webhook_url(params), headers, raw) do
      {:ok, status, body} ->
        if challenge_round_trips?(status, body, challenge) do
          {:ok,
           %{
             "ok" => true,
             "checked_at" => checked_at(),
             "http_status" => status,
             "challenge_mode" => if(encrypted?, do: "encrypted", else: "plain"),
             "redacted" => true
           }}
        else
          {:error, classify_failure(status, body, encrypted?)}
        end

      {:error, :unreachable} ->
        {:error, :callback_unreachable}
    end
  end

  @doc """
  Runs `callback_preflight/1` for the connect `"connect_id"`, with the
  connect's own request URL, Verification Token and Encrypt Key.

  Adds `:connect_not_found | :connect_inactive | :secrets_not_configured` to
  the reasons of `callback_preflight/1`.
  """
  @spec callback_preflight_for_connect(map()) :: {:ok, map()} | {:error, atom()}
  def callback_preflight_for_connect(params) when is_map(params) do
    with {:ok, connect} <- resolve_connect(params),
         :ok <- ensure_verification_material(connect) do
      callback_preflight(%{
        "webhook_url" => connect["webhook_url"],
        "app_id" => connect["app_id"],
        "verification_token" => connect["verification_token"],
        "encrypt_key" => connect["encrypt_key"]
      })
    end
  end

  @doc false
  # The reason a response without the challenge stands for. The Lark endpoint
  # answers 401 with "invalid Lark token" or "invalid Lark signature".
  @spec classify_failure(non_neg_integer(), map() | binary() | nil, boolean()) :: atom()
  def classify_failure(401, body, _encrypted?) do
    if error_mentions?(body, "token"), do: :token_mismatch, else: :decrypt_signature
  end

  def classify_failure(404, _body, _encrypted?), do: :callback_unreachable

  def classify_failure(status, _body, _encrypted?) when status in 500..599,
    do: :callback_unreachable

  def classify_failure(_status, _body, _encrypted?), do: :unexpected_response

  # ---- connect ----

  # `find_active_im_connect_by_id/1` leaves out deleted and disabled connects.
  defp resolve_connect(params) do
    with connect_id when connect_id != "" <- trim(get(params, "connect_id")),
         {:ok, connect} <- ProviderConnects.find_active_im_connect_by_id(connect_id),
         true <- trim(connect["provider"]) == "lark" do
      if trim(connect["status"]) == "connected",
        do: {:ok, connect},
        else: {:error, :connect_inactive}
    else
      _missing -> {:error, :connect_not_found}
    end
  end

  # A callback is accepted against one of these two values.
  defp ensure_verification_material(connect) do
    if trim(connect["verification_token"]) == "" and trim(connect["encrypt_key"]) == "",
      do: {:error, :secrets_not_configured},
      else: :ok
  end

  # ---- envelope ----

  # base64(iv ++ AES-256-CBC(sha256(encrypt_key), iv, pkcs7(plain))) with a
  # random 16-byte iv, as `SalixIM.LarkInbound` reads it.
  defp encrypt(plain, encrypt_key) do
    key = :crypto.hash(:sha256, encrypt_key)
    iv = SystemsRuntime.Proc.random_bytes(16)
    pad = 16 - rem(byte_size(plain), 16)
    padded = plain <> :binary.copy(<<pad>>, pad)
    Base.encode64(iv <> :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, true))
  end

  # Lark signs a request with the Encrypt Key only.
  defp signature_headers(raw, encrypt_key) do
    timestamp = Integer.to_string(SystemsClock.system_time(:second))
    request_nonce = nonce()

    signature =
      :crypto.hash(:sha256, timestamp <> request_nonce <> encrypt_key <> raw)
      |> Base.encode16(case: :lower)

    [
      {"x-lark-request-timestamp", timestamp},
      {"x-lark-request-nonce", request_nonce},
      {"x-lark-signature", signature}
    ]
  end

  defp challenge_round_trips?(200, %{"challenge" => echoed}, challenge) when is_binary(echoed),
    do: echoed == challenge

  defp challenge_round_trips?(_status, _body, _challenge), do: false

  defp error_mentions?(%{"error" => error}, needle) when is_binary(error),
    do: String.contains?(error, needle)

  defp error_mentions?(body, needle) when is_binary(body), do: String.contains?(body, needle)
  defp error_mentions?(_body, _needle), do: false

  # ---- HTTP ----

  defp post(url, headers, raw) do
    case Req.post(url, headers: headers, body: raw, retry: false) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, _reason} -> {:error, :unreachable}
    end
  end

  defp webhook_url(params) do
    base =
      case trim(get(params, "webhook_url")) do
        "" -> ProviderConnects.public_base_url() <> "/v1/im/lark/events"
        url -> url
      end

    case trim(get(params, "app_id")) do
      "" ->
        base

      app_id ->
        uri = URI.parse(base)
        query = (uri.query || "") |> URI.decode_query() |> Map.put("app_id", app_id)
        URI.to_string(%{uri | query: URI.encode_query(query)})
    end
  end

  # ---- values ----

  defp get(params, key), do: Map.get(params, key) || Map.get(params, String.to_atom(key))

  defp checked_at,
    do: SystemsClock.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp nonce, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp fingerprint(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
