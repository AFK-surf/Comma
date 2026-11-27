defmodule CommaWeb.RaycastPairingHttpTest do
  use Comma.DataCase, async: false
  setup {Comma.AuthAbuseTestSupport, :setup}

  alias Comma.Accounts
  alias Comma.Accounts.AuthSession

  @verifier "raycast-verifier-0123456789-abcdefghijklmnopqrstuvwxyz"

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    :ok
  end

  test "desktop pairing, extension exchange, and the paired bearer cross the HTTP boundary" do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "raycast-http-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, desktop} =
      Accounts.create_session(user["id"], client_kind: "electron", client_platform: "macos")

    challenge = Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)
    body = %{"challenge" => challenge}

    assert post("/v1/comma/auth/raycast/pairing", body).status == 401
    assert post("/v1/comma/auth/raycast/pairing", %{}, desktop["token"]).status == 400

    grant = post("/v1/comma/auth/raycast/pairing", body, desktop["token"])
    assert grant.status == 201
    grant = Jason.decode!(grant.resp_body)
    refute Map.has_key?(grant, "token")

    raycast =
      post(
        "/v1/comma/auth/raycast/exchange",
        Map.merge(grant, %{"verifier" => @verifier, "client_platform" => "windows"})
      )

    assert raycast.status == 200
    raycast = Jason.decode!(raycast.resp_body)
    assert raycast["user"]["id"] == user["id"]
    stored = Repo.get!(AuthSession, raycast["session_id"])
    assert stored.auth_method == "raycast_pairing"
    assert stored.client_kind == "raycast"
    assert stored.client_platform == "windows"
    assert stored.parent_session_id == desktop["id"]
    assert get("/v1/comma/auth/session", raycast["token"]).status == 200

    assert post("/v1/comma/auth/raycast/exchange", Map.put(grant, "verifier", @verifier)).status ==
             401

    assert post("/v1/comma/auth/raycast/pairing", body, raycast["token"]).status == 403
    assert post("/v1/comma/auth/logout", %{}, raycast["token"]).status == 200
    assert get("/v1/comma/auth/session", desktop["token"]).status == 200
  end

  defp post(path, attrs, token \\ nil) do
    Plug.Test.conn(:post, path, Jason.encode!(attrs))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")
    |> bearer(token)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
    |> CommaWeb.AuthAbuseTestSupport.continue_http()
  end

  defp get(path, token),
    do:
      Plug.Test.conn(:get, path)
      |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")
      |> bearer(token)
      |> CommaWeb.Router.call(CommaWeb.Router.init([]))
      |> CommaWeb.AuthAbuseTestSupport.continue_http()

  defp bearer(conn, nil), do: conn

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
end
