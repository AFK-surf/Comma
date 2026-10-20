defmodule SalixStore.Stations.Credential do
  @moduledoc """
  The member credential (contract §4): a compact EdDSA JWS that stations verify
  offline with the presence `grant_keys`, exactly as still.fail's
  `station/src/mesh/credential.ts` does with `iss = "comma"` and
  `typ = "comma-member+jwt"`. It binds the account, the Group (`ws`: the
  workspace id the Group's stations are told), the role, the client's iroh
  key and the session that asked for it, so ending that session revokes it.
  It never outlives that session: `exp` is capped at the session's expiry.
  """

  alias SalixStore.Stations.SigningKeys

  @issuer "comma"
  @type_header "comma-member+jwt"
  @ttl_seconds 30 * 24 * 60 * 60

  def issuer, do: @issuer
  def type_header, do: @type_header

  def issue(claims, session_expires_at, now \\ SystemsClock.system_time(:second))

  def issue(claims, session_expires_at, now)
      when is_map(claims) and is_integer(session_expires_at) do
    with true <- session_expires_at > now || {:error, :forbidden},
         {:ok, {seed, kid}} <- SigningKeys.signer() do
      expires_at = min(now + @ttl_seconds, session_expires_at)
      header = %{"alg" => "EdDSA", "typ" => @type_header, "kid" => kid}

      payload =
        claims
        |> Map.take(~w(sub email name ws role device sid))
        |> Map.merge(%{"iss" => @issuer, "iat" => now, "exp" => expires_at})

      input = encode(header) <> "." <> encode(payload)
      signature = SystemsRuntime.Proc.sign(:eddsa, :none, input, [seed, :ed25519])

      {:ok,
       %{
         "credential" => input <> "." <> Base.url_encode64(signature, padding: false),
         "issued_at" => now,
         "expires_at" => expires_at
       }}
    end
  end

  def issue(_claims, _session_expires_at, _now), do: {:error, :forbidden}

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
end
