defmodule CommaWeb.Coding.L4ESAssertionsTest do
  # async: false: IdP suites share the KEK in application config.
  use ExUnit.Case, async: false

  alias CommaWeb.Coding.L4ESAssertions

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    {:ok, kid: Comma.OauthIdpTestKeys.install()}
  end

  defp verify(token, kid) do
    jwk = Comma.OauthIdpTestKeys.public_jwk(kid)

    {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{fields: header}} =
      JOSE.JWT.verify_strict(jwk, ["RS256"], token)

    {header, claims}
  end

  test "Salix's API assertion: signed by the IdP key, typed apart from ID tokens, five minutes at most",
       %{kid: kid} do
    assert {:ok, token} =
             L4ESAssertions.sign(%{
               audience: "https://l4es.test",
               workspace_id: "grp_1",
               max_sandboxes: 3
             })

    {header, claims} = verify(token, kid)
    assert header["typ"] == "comma-l4es+jwt"
    assert header["kid"] == kid
    assert claims["iss"] == Boruta.Config.issuer()
    assert claims["aud"] == "https://l4es.test"
    assert %{"sub" => "salix", "ws" => "grp_1", "role" => "salix", "use" => "api"} = claims
    assert claims["limits"] == %{"max_sandboxes" => 3}
    assert claims["exp"] - claims["iat"] == 300
    assert is_binary(claims["jti"])
  end
end
