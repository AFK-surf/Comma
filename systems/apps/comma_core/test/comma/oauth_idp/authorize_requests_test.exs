defmodule Comma.OauthIdp.AuthorizeRequestsTest do
  use SystemsClock.Case, async: false

  import Ecto.Query

  alias Comma.OauthIdp.AuthorizeRequests
  alias Comma.OauthIdp.AuthorizeRequests.Request
  alias Comma.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, SystemsRuntime.Proc.self()})

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-ar@example.com")
    %{user: user}
  end

  defp attrs(user) do
    %{
      user_id: user["id"],
      client_id: SystemsRuntime.Proc.uuid(),
      redirect_uri: "https://vibe.example.com/callback",
      scope: "openid email profile",
      state: "s",
      nonce: "n",
      code_challenge: "challenge",
      code_challenge_method: "S256"
    }
  end

  test "consume is single-use and user-bound", %{user: user} do
    request = AuthorizeRequests.create!(attrs(user))

    assert :error == AuthorizeRequests.consume(request.id, "usr_someone_else")
    assert {:ok, _consumed} = AuthorizeRequests.consume(request.id, user["id"])
    assert :error == AuthorizeRequests.consume(request.id, user["id"])
  end
end
