defmodule CommaWeb.AppleClientAuthTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts.AuthSession
  alias Comma.Accounts

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    :ok
  end

  test "native email login, Watch grant exchange, independent bearer, and phone logout cross the HTTP boundary" do
    email = "native-watch-#{System.unique_integer([:positive])}@example.test"
    challenge = post("/v1/comma/auth/email/login", %{"email" => email})
    assert challenge.status == 200
    challenge = Jason.decode!(challenge.resp_body)

    phone =
      post("/v1/comma/auth/email/verify", %{
        "challenge_id" => challenge["challenge_id"],
        "code" => challenge["code"],
        "client_kind" => "ios",
        "client_platform" => "ios"
      })

    assert phone.status == 200
    phone = Jason.decode!(phone.resp_body)
    assert phone["token"] != nil

    grant = post("/v1/comma/auth/watch/pairing", %{}, phone["token"])
    assert grant.status == 201
    grant = Jason.decode!(grant.resp_body)
    refute Map.has_key?(grant, "token")
    assert post("/v1/comma/auth/watch/pairing", %{}).status == 401
    watch = post("/v1/comma/auth/watch/exchange", grant)
    assert watch.status == 200
    watch = Jason.decode!(watch.resp_body)
    assert watch["user"]["id"] == phone["user"]["id"]
    refute watch["token"] == phone["token"]
    stored_watch = Repo.get!(AuthSession, watch["session_id"])
    assert stored_watch.auth_method == "watch_pairing"
    assert stored_watch.session_source == "user_login"
    assert stored_watch.parent_session_id == phone["session_id"]
    assert get("/v1/comma/auth/session", watch["token"]).status == 200
    assert post("/v1/comma/auth/watch/exchange", grant).status == 401
    assert post("/v1/comma/auth/watch/pairing", %{}, watch["token"]).status == 403
    assert post("/v1/comma/auth/logout", %{}, phone["token"]).status == 200
    assert get("/v1/comma/auth/session", watch["token"]).status == 401
    assert Repo.get!(AuthSession, watch["session_id"]).revoked_at != nil
  end

  test "restricted session cannot delegate Watch account authority" do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "restricted-watch-#{System.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], restricted: true, session_source: "ops_api")

    assert post("/v1/comma/auth/watch/pairing", %{}, session["token"]).status == 403
  end

  test "unconfigured Sign in with Apple returns an actionable error" do
    previous = Application.get_env(:comma_core, :apple_auth)
    Application.delete_env(:comma_core, :apple_auth)

    on_exit(fn ->
      if previous, do: Application.put_env(:comma_core, :apple_auth, previous)
    end)

    result = post("/v1/comma/auth/apple/attempt", %{})
    assert result.status == 503

    assert %{"error" => "apple_not_configured", "message" => message} =
             Jason.decode!(result.resp_body)

    assert message =~ "COMMA_APPLE_CLIENT_ID"
  end

  defp post(path, attrs, token \\ nil) do
    Plug.Test.conn(:post, path, Jason.encode!(attrs))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")
    |> bearer(token)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp get(path, token),
    do:
      Plug.Test.conn(:get, path)
      |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")
      |> bearer(token)
      |> CommaWeb.Router.call(CommaWeb.Router.init([]))

  defp bearer(conn, nil), do: conn

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
end
