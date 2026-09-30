defmodule Comma.OauthIdpTestKeys do
  @moduledoc """
  Installs the OAuth IdP key infrastructure for tests: a process-local
  KEK plus a signing key row created through the real
  `Comma.OauthIdp.SigningKeys.provision_initial!/0` path, so tests exercise the same
  encrypt-store-decrypt cycle production uses. No key material is
  checked into the repository.

  Call `install/0` from a test's setup after the SQL sandbox checkout
  (suites touching the IdP run `async: false` because the KEK lives in
  application configuration).
  """

  @kek :crypto.hash(:sha256, "comma-oauth-idp-test-kek")

  @doc """
  Configures the test KEK and provisions a signing key through the real
  rotation path. Returns the new kid.
  """
  def install do
    install_kek()
    Comma.OauthIdp.SigningKeys.provision_initial!()
  end

  @doc "Configures the KEK only, for tests that provision keys themselves."
  def install_kek do
    previous = Application.get_env(:comma_core, :oauth_idp)
    Application.put_env(:comma_core, :oauth_idp, kek: @kek)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:comma_core, :oauth_idp)
        config -> Application.put_env(:comma_core, :oauth_idp, config)
      end
    end)

    :ok
  end

  @doc "The public verification JWK for the given kid, read from the JWKS."
  def public_jwk(kid) do
    Enum.find(Comma.OauthIdp.public_jwks!(), fn jwk -> jwk.fields["kid"] == kid end)
  end
end
