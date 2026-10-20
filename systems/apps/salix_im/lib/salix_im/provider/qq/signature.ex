defmodule SalixIM.Provider.QQ.Signature do
  @moduledoc """
  Ed25519 signatures of the QQ bot webhook.

  QQ derives one key pair from the bot's AppSecret: the secret is repeated
  until it holds 32 bytes, and its first 32 bytes are the Ed25519 seed. QQ
  signs each callback over `timestamp <> body` and sends the hex signature in
  `X-Signature-Ed25519` with the timestamp in `X-Signature-Timestamp`. When
  the callback address is saved, QQ sends `op: 13` and expects a signature
  over `event_ts <> plain_token` made with the same key.
  """

  @seed_size 32
  @signature_size 64
  @max_plain_token_bytes 128
  @max_event_ts_bytes 20

  @doc "True when `signature_hex` signs `timestamp <> body` under the secret's key."
  @spec valid?(String.t(), String.t(), String.t(), binary()) :: boolean()
  def valid?(app_secret, signature_hex, timestamp, body)
      when is_binary(app_secret) and is_binary(signature_hex) and is_binary(timestamp) and
             is_binary(body) do
    with {:ok, {public_key, _private_key}} <- key_pair(app_secret),
         {:ok, signature} <- Base.decode16(signature_hex, case: :mixed),
         true <- byte_size(signature) == @signature_size and timestamp != "" do
      :crypto.verify(:eddsa, :none, timestamp <> body, signature, [public_key, :ed25519])
    else
      _invalid -> false
    end
  end

  def valid?(_app_secret, _signature_hex, _timestamp, _body), do: false

  @doc """
  Signs the address validation challenge.

  This call signs values that the request names, before any signature can be
  checked. It therefore accepts only a digit timestamp and a token of ASCII
  letters and digits: such a pair is never `timestamp <> body` of a callback,
  whose body is a JSON object, so the answer cannot be replayed as an event.
  """
  @spec validation(String.t(), term(), term()) :: {:ok, String.t()} | {:error, :invalid_envelope}
  def validation(app_secret, event_ts, plain_token)
      when is_binary(app_secret) and is_binary(event_ts) and is_binary(plain_token) do
    with true <- Regex.match?(~r/\A[0-9]{1,#{@max_event_ts_bytes}}\z/, event_ts),
         true <- Regex.match?(~r/\A[A-Za-z0-9]{1,#{@max_plain_token_bytes}}\z/, plain_token),
         {:ok, {_public_key, private_key}} <- key_pair(app_secret) do
      signature =
        SystemsRuntime.Proc.sign(:eddsa, :none, event_ts <> plain_token, [private_key, :ed25519])

      {:ok, Base.encode16(signature, case: :lower)}
    else
      _invalid -> {:error, :invalid_envelope}
    end
  end

  def validation(_app_secret, _event_ts, _plain_token), do: {:error, :invalid_envelope}

  defp key_pair(""), do: :error

  defp key_pair(app_secret) do
    seed =
      app_secret
      |> String.duplicate(div(@seed_size, byte_size(app_secret)) + 1)
      |> binary_part(0, @seed_size)

    {:ok, SystemsRuntime.Proc.generate_key(:eddsa, :ed25519, seed)}
  end
end
