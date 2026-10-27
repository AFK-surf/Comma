defmodule CommaWeb.Coding.L4ESAssertions do
  @moduledoc """
  Workspace assertions for L4ES (l4h-sandbox DESIGN.md §28.2): short-lived
  RS256 tokens, signed by the Comma OAuth IdP's signing key
  (`Comma.OauthIdp.signing_key!/0`, published in its JWKS), with which L4ES
  admits Salix to a Workspace's L4ES workspace's API. People are no
  assertions' subjects: a Workspace's members sign in to L4ES with Comma.

  The JOSE `typ` `comma-l4es+jwt` and the audience (the L4ES URL) keep an
  assertion apart from the IdP's ID tokens. `ws` is the Workspace's Salix
  Group id, which names its L4ES workspace (`comma:<group>`).

  Salix calls `sign/1` (`config :salix_web, :l4es_assertion_signer`).
  Without the IdP's signing key, no assertion is made.
  """

  @typ "comma-l4es+jwt"
  @lifetime_s 300

  @doc """
  Salix's assertion for `audience` (the L4ES URL) and `workspace_id` (the
  Group id), with an optional `max_sandboxes`, valid for five minutes.
  """
  def sign(%{audience: audience, workspace_id: ws} = claims) do
    with {:ok, issuer} <- issuer() do
      now = SystemsClock.system_time(:second)

      payload =
        %{
          "iss" => issuer,
          "aud" => audience,
          "sub" => "salix",
          "ws" => ws,
          "role" => "salix",
          "use" => "api",
          "jti" => SystemsRuntime.Proc.uuid(),
          "iat" => now,
          "exp" => now + @lifetime_s
        }
        |> put_present(
          "limits",
          claims[:max_sandboxes] && %{"max_sandboxes" => claims[:max_sandboxes]}
        )

      {pem, kid} = Comma.OauthIdp.signing_key!()

      token =
        pem
        |> JOSE.JWK.from_pem()
        |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid, "typ" => @typ}, payload)
        |> JOSE.JWS.compact()
        |> elem(1)

      {:ok, token}
    end
  rescue
    _ -> {:error, :assertion_unavailable}
  end

  defp issuer do
    case Boruta.Config.issuer() do
      issuer when is_binary(issuer) and issuer != "" and issuer != "boruta" -> {:ok, issuer}
      _ -> {:error, :assertion_unavailable}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
