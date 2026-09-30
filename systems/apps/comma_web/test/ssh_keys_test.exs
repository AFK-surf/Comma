defmodule CommaWeb.SSHKeysTest do
  use Comma.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  alias Comma.Accounts.SSHIdentities

  test "account API lists and revokes owned keys and excludes restricted sessions" do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "keys-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, foreign} =
      Comma.Accounts.get_or_create_user_by_email(
        "foreign-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, login} = Comma.Accounts.create_session(user["id"])
    {:ok, other_login} = Comma.Accounts.create_session(foreign["id"])

    {:ok, restricted} =
      Comma.Accounts.create_session(user["id"], session_source: "ops_api", restricted: true)

    key = :crypto.strong_rand_bytes(64)
    {:ok, identity} = SSHIdentities.enroll(user, key)
    {:ok, ssh_token} = SSHIdentities.login(key)
    assert {:ok, detail} = Comma.Admin.get_user(user["id"])
    assert %{"method" => "ssh_public_key"} in detail["login_methods"]

    response = request(:get, "/v1/comma/auth/ssh-keys", login["token"])
    assert response.status == 200

    assert %{"data" => [%{"id" => id, "fingerprint" => fingerprint} = public]} =
             Jason.decode!(response.resp_body)

    assert id == identity.id
    assert fingerprint == SSHIdentities.fingerprint(key)
    refute Map.has_key?(public, "public_key")
    assert request(:get, "/v1/comma/auth/ssh-keys", restricted["token"]).status == 403
    assert request(:delete, "/v1/comma/auth/ssh-keys/#{id}", other_login["token"]).status == 404
    assert request(:delete, "/v1/comma/auth/ssh-keys/#{id}", restricted["token"]).status == 403
    assert {:ok, _, _} = Comma.Accounts.resolve_session(ssh_token)
    assert request(:delete, "/v1/comma/auth/ssh-keys/#{id}", login["token"]).status == 200
    assert {:error, :revoked} = Comma.Accounts.resolve_session(ssh_token)
  end

  defp request(method, path, token) do
    conn(method, path)
    |> put_req_header("x-comma-session-transport", "bearer")
    |> put_req_header("authorization", "Bearer #{token}")
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end
end
