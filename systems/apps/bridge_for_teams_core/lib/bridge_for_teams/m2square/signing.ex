defmodule BridgeForTeams.M2square.Signing do
  @moduledoc """
  Isolated SHA512 request-signing and webhook-verification adapter for M2square.

  M2square does not publish an official Elixir SDK (its documentation only
  provides Java, PHP, and Python snippets), so the protocol signing logic is
  isolated in this module and covered by vector tests against the official
  API signing and webhook specifications.

  Security boundary (webhook verification):
    * Concrete threat: forged or tampered HTTP callbacks attempting to grant
      paid Teams seats or reverse valid allocations.
    * Independent authority: the M2square merchant `secret_key` configured for
      this deployment.
    * Verification owner: `BridgeForTeams.M2square.Signing.verify_webhook/3`,
      invoked by the webhook boundary on raw request bytes before JSON decoding.
    * Fail-closed result: rejects missing/invalid signatures with
      `{:error, :invalid_signature}` and unconfigured secrets with
      `{:error, :webhook_not_configured}`, never logging or interpolating the
      secret key or full string-to-sign.
  """

  @doc """
  Computes the lowercase hex SHA512 request signature for M2square API calls.

  Signature input order:
  `mchId <> serviceName <> method <> timestamp <> signType <> raw_json <> secret_key`
  """
  @spec sign_request(
          String.t(),
          String.t(),
          String.t(),
          String.t() | integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: String.t()
  def sign_request(mch_id, service_name, method, timestamp, sign_type, raw_json, secret_key)
      when is_binary(mch_id) and is_binary(service_name) and is_binary(method) and
             (is_binary(timestamp) or is_integer(timestamp)) and
             is_binary(sign_type) and is_binary(raw_json) and is_binary(secret_key) do
    ts = if is_integer(timestamp), do: Integer.to_string(timestamp), else: timestamp

    :crypto.hash(
      :sha512,
      [mch_id, service_name, method, ts, sign_type, raw_json, secret_key]
    )
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies a M2square webhook `sign` header against raw request bytes using
  constant-time comparison (`Plug.Crypto.secure_compare/2`).

  Signature input: `raw_body <> secret_key`, hashed with lowercase hex SHA512.
  """
  @spec verify_webhook(term(), term(), term()) ::
          :ok | {:error, :invalid_signature | :webhook_not_configured}
  def verify_webhook(_raw_body, _sign_header, secret_key)
      when not is_binary(secret_key) or secret_key == "" do
    {:error, :webhook_not_configured}
  end

  def verify_webhook(raw_body, sign_header, secret_key)
      when is_binary(raw_body) and is_binary(sign_header) do
    normalized = sign_header |> String.trim() |> String.downcase()

    expected =
      :crypto.hash(:sha512, [raw_body, secret_key])
      |> Base.encode16(case: :lower)

    if byte_size(normalized) == byte_size(expected) and
         Plug.Crypto.secure_compare(expected, normalized) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  def verify_webhook(_raw_body, _sign_header, _secret_key) do
    {:error, :invalid_signature}
  end
end
