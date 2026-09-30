defmodule BridgeForTeams.Auth.SessionsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Schema.User

  defp user! do
    %User{}
    |> User.changeset(%{email: "s#{System.unique_integer([:positive])}@example.test", name: "S"})
    |> Repo.insert!()
  end

  test "create returns a one-time token and stores only its hash" do
    user = user!()
    assert {:ok, %{token: token, session: session}} = Sessions.create(user)

    assert is_binary(token)
    assert session.token_hash == Sessions.hash_token(token)
    refute session.token_hash == token
    assert session.user_id == user.id
    assert DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt
  end

  test "create accepts a user id and custom ttl/device" do
    user = user!()

    assert {:ok, %{session: session}} =
             Sessions.create(user.id, ttl_seconds: 60, device: "cli", client_name: "local")

    assert session.device == "cli"
    assert session.client_name == "local"
    assert DateTime.diff(session.expires_at, DateTime.utc_now()) <= 61
  end

  test "fetch resolves a valid token and touches last_seen_at" do
    user = user!()
    {:ok, %{token: token, session: created}} = Sessions.create(user)
    Process.sleep(2)

    assert {:ok, fetched} = Sessions.fetch(token)
    assert fetched.id == created.id
    assert DateTime.compare(fetched.last_seen_at, created.last_seen_at) in [:gt, :eq]
  end

  test "fetch rejects unknown tokens" do
    assert {:error, :invalid} = Sessions.fetch("nope")
    assert {:error, :invalid} = Sessions.fetch(123)
  end

  test "fetch rejects and deletes expired sessions" do
    user = user!()
    {:ok, %{token: token}} = Sessions.create(user, ttl_seconds: -1)
    assert {:error, :expired} = Sessions.fetch(token)
    # second fetch is now :invalid since the expired row was deleted
    assert {:error, :invalid} = Sessions.fetch(token)
  end

  test "revoke deletes the session and is idempotent" do
    user = user!()
    {:ok, %{token: token}} = Sessions.create(user)
    assert :ok = Sessions.revoke(token)
    assert {:error, :invalid} = Sessions.fetch(token)
    assert :ok = Sessions.revoke(token)
    assert :ok = Sessions.revoke(nil)
  end

  test "revoke_cli_session only revokes CLI device sessions" do
    user = user!()
    {:ok, %{token: cli_token}} = Sessions.create(user, device: "bft-cli")
    {:ok, %{token: web_token}} = Sessions.create(user, device: "web")

    assert :ok = CLILogin.revoke_cli_session(web_token)
    assert {:ok, web_session} = Sessions.fetch(web_token)
    assert web_session.device == "web"

    assert :ok = CLILogin.revoke_cli_session(cli_token)
    assert {:error, :invalid} = Sessions.fetch(cli_token)
  end
end
