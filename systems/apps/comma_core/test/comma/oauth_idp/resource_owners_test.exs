defmodule Comma.OauthIdp.ResourceOwnersTest do
  @moduledoc """
  The ResourceOwners adapter resolves only active `comma_users` and never
  accepts a password (Comma is passwordless; the password grant stays
  disabled on every client as defense in depth).
  """

  use SystemsClock.Case, async: false

  alias Boruta.Oauth.ResourceOwner
  alias Comma.OauthIdp.ResourceOwners

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Comma.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, {:shared, SystemsRuntime.Proc.self()})

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-ro@example.com")
    {:ok, _} = Comma.Accounts.update_user(user["id"], %{"name" => "RO Test"})
    %{user: user}
  end

  test "resolves an active user by sub with usr_* identity", %{user: user} do
    assert {:ok, %ResourceOwner{sub: sub, username: "idp-ro@example.com"}} =
             ResourceOwners.get_by(sub: user["id"])

    assert sub == user["id"]
    assert String.starts_with?(sub, "usr_")
  end

  test "a disabled user fails closed on both lookups", %{user: user} do
    {:ok, _} = Comma.Accounts.update_user(user["id"], %{"status" => "disabled"})

    assert {:error, _} = ResourceOwners.get_by(sub: user["id"])
    assert {:error, _} = ResourceOwners.get_by(username: "idp-ro@example.com")
  end

  test "check_password always fails", %{user: user} do
    {:ok, owner} = ResourceOwners.get_by(sub: user["id"])

    assert {:error, _} = ResourceOwners.check_password(owner, "any-password")
    assert {:error, _} = ResourceOwners.check_password(owner, "")
  end

  test "claims follow the granted scope, never exceeding it", %{user: user} do
    ro = %ResourceOwner{sub: user["id"], username: user["email"]}

    full = ResourceOwners.claims(ro, "openid email profile")
    assert full["email"] == "idp-ro@example.com"
    assert full["email_verified"] == true
    assert full["name"] == "RO Test"

    openid_only = ResourceOwners.claims(ro, "openid")
    refute Map.has_key?(openid_only, "email")
    refute Map.has_key?(openid_only, "email_verified")
    refute Map.has_key?(openid_only, "name")

    email_only = ResourceOwners.claims(ro, "openid email")
    assert email_only["email"] == "idp-ro@example.com"
    refute Map.has_key?(email_only, "name")

    assert ResourceOwners.claims(ro, nil) == %{}
  end
end
