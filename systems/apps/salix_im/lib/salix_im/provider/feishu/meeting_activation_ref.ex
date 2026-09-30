defmodule SalixIM.Provider.Feishu.MeetingActivationRef do
  @moduledoc false

  @prefix "fma1."
  @domain "salix-im/feishu/meeting-activation/v1"
  @max_ref_bytes 128 * 1_024

  @spec max_ref_bytes() :: pos_integer()
  def max_ref_bytes, do: @max_ref_bytes

  def encode(scope, signing_key, grant)
      when is_binary(scope) and scope != "" and is_binary(signing_key) and
             byte_size(signing_key) >= 16 and is_map(grant) do
    payload = Jason.encode!(grant)
    encoded_payload = Base.url_encode64(payload, padding: false)
    encoded_mac = payload |> mac(scope, signing_key) |> Base.url_encode64(padding: false)
    ref = @prefix <> encoded_payload <> "." <> encoded_mac
    if byte_size(ref) <= @max_ref_bytes, do: {:ok, ref}, else: {:error, :ref_too_large}
  rescue
    _ -> {:error, :invalid_meeting_activation_ref}
  end

  def encode(_scope, _signing_key, _grant), do: {:error, :invalid_meeting_activation_ref}

  def decode(ref, scope, signing_key)
      when is_binary(ref) and is_binary(scope) and scope != "" and is_binary(signing_key) and
             byte_size(signing_key) >= 16 do
    with true <- byte_size(ref) <= @max_ref_bytes,
         true <- String.starts_with?(ref, @prefix),
         [encoded_payload, encoded_mac] <-
           ref |> String.replace_prefix(@prefix, "") |> String.split(".", parts: 2),
         {:ok, payload} <- decode_canonical_url64(encoded_payload),
         {:ok, supplied_mac} <- decode_canonical_url64(encoded_mac),
         true <- secure_compare(supplied_mac, mac(payload, scope, signing_key)),
         {:ok, grant} when is_map(grant) <- Jason.decode(payload) do
      {:ok, grant}
    else
      _ -> {:error, :invalid_meeting_activation_ref}
    end
  end

  def decode(_ref, _scope, _signing_key), do: {:error, :invalid_meeting_activation_ref}

  defp decode_canonical_url64(encoded) when is_binary(encoded) do
    with {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(decoded, padding: false) == encoded do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp mac(payload, scope, signing_key),
    do: :crypto.mac(:hmac, :sha256, signing_key, [@domain, <<0>>, scope, <<0>>, payload])

  defp secure_compare(left, right),
    do: byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
end
