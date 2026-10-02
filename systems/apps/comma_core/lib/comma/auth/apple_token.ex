defmodule Comma.Auth.AppleToken do
  @moduledoc "Strict JOSE validation of a native Apple ID token against its server-issued attempt."

  @issuer "https://appleid.apple.com"

  def verify(token, attempt) when is_binary(token) and byte_size(token) in 1..16_384 do
    with %JOSE.JWS{fields: %{"kid" => kid}} <- JOSE.JWT.peek_protected(token),
         {:ok, key} <- Comma.Auth.AppleKeys.key(kid),
         {true, %JOSE.JWT{fields: claims}, _} <-
           JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token),
         true <- valid_claims?(claims, attempt) do
      {:ok, claims}
    else
      {:error, :apple_provider_unavailable} = error -> error
      _ -> {:error, :invalid_apple_credential}
    end
  rescue
    _ -> {:error, :invalid_apple_credential}
  end

  def verify(_token, _attempt), do: {:error, :invalid_apple_credential}

  defp valid_claims?(claims, attempt) do
    now = System.system_time(:second)

    claims["iss"] == @issuer and claims["aud"] == attempt["client_id"] and
      claims["nonce"] == attempt["nonce"] and
      is_integer(claims["exp"]) and claims["exp"] > now and
      is_integer(claims["iat"]) and claims["iat"] <= now + 60 and
      claims["iat"] >= attempt["issued_at"] - 60 and
      is_binary(claims["sub"]) and byte_size(claims["sub"]) in 1..500 and
      String.trim(claims["sub"]) == claims["sub"] and
      claims["sub"] != ""
  end
end
