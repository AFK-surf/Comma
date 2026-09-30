defmodule Comma.Accounts.SSHIdentitiesTest do
  use Comma.DataCase, async: false
  alias Comma.Accounts.SSHIdentities

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    :ok
  end

  test "enrollment binds the verified code to a connection and supports revocation" do
    attrs = %{"email" => "ssh-#{System.unique_integer([:positive])}@example.com"}
    {:ok, challenge} = Comma.AuthChallenges.request_ssh_enrollment(attrs, "connection-a")

    assert {:error, :invalid_verification_code} =
             Comma.AuthChallenges.verify_ssh_enrollment(
               challenge["challenge_id"],
               challenge["code"],
               "connection-b"
             )

    {:ok, challenge} =
      Comma.AuthChallenges.request_ssh_enrollment(
        %{"email" => "other-#{System.unique_integer([:positive])}@example.com"},
        "connection-a"
      )

    assert {:ok, user} =
             Comma.AuthChallenges.verify_ssh_enrollment(
               challenge["challenge_id"],
               challenge["code"],
               "connection-a"
             )

    assert {:error, :invalid_verification_code} =
             Comma.AuthChallenges.verify_ssh_enrollment(
               challenge["challenge_id"],
               challenge["code"],
               "connection-a"
             )

    key = :crypto.strong_rand_bytes(64)
    assert {:ok, identity} = SSHIdentities.enroll(user, key)
    assert {:ok, token} = SSHIdentities.login(key)
    assert {:ok, _, session} = Comma.Accounts.resolve_session(token)
    assert session["auth_method"] == "ssh_public_key"
    assert :ok = SSHIdentities.revoke(user["id"], identity.id)
    assert {:error, :revoked} = Comma.Accounts.resolve_session(token)
    assert {:error, :revoked} = SSHIdentities.login(key)
    assert {:error, :key_conflict} = SSHIdentities.enroll(user, key)
  end

  test "a regular login code cannot enroll a key and one key cannot change accounts" do
    {:ok, challenge} =
      Comma.AuthChallenges.request_email_login(%{
        "email" => "regular-#{System.unique_integer([:positive])}@example.com"
      })

    assert {:error, :invalid_verification_code} =
             Comma.AuthChallenges.verify_ssh_enrollment(
               challenge["challenge_id"],
               challenge["code"],
               "connection"
             )

    {:ok, a} =
      Comma.Accounts.get_or_create_user_by_email(
        "a-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, b} =
      Comma.Accounts.get_or_create_user_by_email(
        "b-#{System.unique_integer([:positive])}@example.com"
      )

    key = :crypto.strong_rand_bytes(64)
    {:ok, identity} = SSHIdentities.enroll(a, key)
    assert {:error, :key_conflict} = SSHIdentities.enroll(b, key)
    assert {:error, :not_found} = SSHIdentities.revoke(b["id"], identity.id)
    assert {:ok, _} = SSHIdentities.login(key)
    assert {:ok, _} = SSHIdentities.enroll(a, :crypto.strong_rand_bytes(64))
    assert length(SSHIdentities.list(a["id"])) == 2
  end

  test "host key persists as readable PEM and survives reload without extra secrets" do
    key = Comma.SSHHostKey.load_or_create!()
    row = Comma.Repo.get!(Comma.SSHHostKey.Key, "default")
    [entry] = :public_key.pem_decode(row.private_key_pem)
    assert :public_key.pem_entry_decode(entry) == key
    assert Comma.SSHHostKey.load_or_create!() == key

    row |> Ecto.Changeset.change(private_key_pem: "invalid") |> Comma.Repo.update!()
    assert_raise RuntimeError, ~r/Cannot decode/, &Comma.SSHHostKey.load_or_create!/0
    assert Comma.Repo.get!(Comma.SSHHostKey.Key, "default").private_key_pem == "invalid"
  end
end
