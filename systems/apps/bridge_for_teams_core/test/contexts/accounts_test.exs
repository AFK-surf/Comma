defmodule BridgeForTeams.AccountsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, Memberships, Orgs}
  alias BridgeForTeams.Schema.User

  test "create_user/1 and unique citext email" do
    assert {:ok, %User{} = user} = Accounts.create_user(%{email: "A@Example.com", name: "A"})
    assert user.status == "active"
    # citext: case-insensitive uniqueness
    assert {:error, cs} = Accounts.create_user(%{email: "a@example.com"})
    assert %{email: _} = errors_on(cs)
  end

  test "create_user/1 still requires email outside subject-based SSO" do
    assert {:error, cs} = Accounts.create_user(%{name: "No Email"})
    assert %{email: ["can't be blank"]} = errors_on(cs)
  end

  test "get_user_by_email is case-insensitive (citext)" do
    {:ok, user} = Accounts.create_user(%{email: "Mixed@Case.com"})
    assert {:ok, found} = Accounts.get_user_by_email("mixed@case.com")
    assert found.id == user.id
  end

  test "get_user not found" do
    assert {:error, :not_found} = Accounts.get_user(Ecto.UUID.generate())
  end

  describe "provision_from_claims/2" do
    test "creates a new user from claims" do
      assert {:ok, user} =
               Accounts.provision_from_claims(%{"email" => "new@x.com", "name" => "New"})

      assert user.email == "new@x.com"
      assert user.name == "New"
    end

    test "is idempotent on email" do
      {:ok, u1} = Accounts.provision_from_claims(%{"email" => "same@x.com"})
      {:ok, u2} = Accounts.provision_from_claims(%{"email" => "same@x.com"})
      assert u1.id == u2.id
    end

    test "missing email errors" do
      assert {:error, :missing_email} = Accounts.provision_from_claims(%{"name" => "x"})
    end

    test "provisions org membership when org_id given" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})

      assert {:ok, user} =
               Accounts.provision_from_claims(%{"email" => "jit@x.com"},
                 org_id: org.id,
                 role: "admin"
               )

      assert {:ok, "admin"} = Memberships.org_role(org.id, user.id)
    end
  end
end
