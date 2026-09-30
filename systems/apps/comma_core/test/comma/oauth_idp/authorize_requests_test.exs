defmodule Comma.OauthIdp.AuthorizeRequestsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.OauthIdp.AuthorizeRequests
  alias Comma.OauthIdp.AuthorizeRequests.Request
  alias Comma.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-ar@example.com")
    %{user: user}
  end

  defp attrs(user) do
    %{
      user_id: user["id"],
      client_id: Ecto.UUID.generate(),
      redirect_uri: "https://vibe.example.com/callback",
      scope: "openid email profile",
      state: "s",
      nonce: "n",
      code_challenge: "challenge",
      code_challenge_method: "S256"
    }
  end

  defp seed_expired!(user, count) do
    stale = DateTime.add(DateTime.utc_now(), -7_200, :second)

    for _index <- 1..count do
      Repo.insert!(%Request{
        id: Ecto.UUID.generate(),
        csrf_token: "expired",
        user_id: user["id"],
        client_id: Ecto.UUID.generate(),
        redirect_uri: "https://vibe.example.com/callback",
        scope: "openid email profile",
        code_challenge: "challenge",
        code_challenge_method: "S256",
        expires_at: stale
      })
    end
  end

  test "one insert sweeps at most the documented batch bound", %{user: user} do
    seed_expired!(user, 150)

    _request = AuthorizeRequests.create!(attrs(user))

    stale_left =
      Repo.aggregate(from(r in Request, where: r.csrf_token == "expired"), :count)

    # 150 expired rows minus one bounded sweep of 100: the request-path
    # delete is capped; the remainder drains on later inserts.
    assert stale_left == 50

    _request2 = AuthorizeRequests.create!(attrs(user))

    remaining =
      Repo.aggregate(from(r in Request, where: r.csrf_token == "expired"), :count)

    assert remaining == 0
  end

  test "consume is single-use and user-bound", %{user: user} do
    request = AuthorizeRequests.create!(attrs(user))

    assert :error == AuthorizeRequests.consume(request.id, "usr_someone_else")
    assert {:ok, _consumed} = AuthorizeRequests.consume(request.id, user["id"])
    assert :error == AuthorizeRequests.consume(request.id, user["id"])
  end
end
