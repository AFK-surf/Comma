defmodule Comma.Accounts.RepositoryTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts.{Identity, Repository, User}

  test "exact trim-plus-lowercase email converges to one user" do
    assert {:ok, first, :created} = Repository.ensure_user_by_email("  Peng@Example.COM ")
    assert {:ok, second, :existing} = Repository.ensure_user_by_email("peng@example.com")

    assert first.id == second.id
    assert second.email == "peng@example.com"

    assert Repo.aggregate(from(user in User, where: user.email == "peng@example.com"), :count) ==
             1
  end

  test "provider subject and per-user provider links are unique and idempotent" do
    assert {:ok, first_user, :created} = Repository.ensure_user_by_email("first@example.com")
    assert {:ok, second_user, :created} = Repository.ensure_user_by_email("second@example.com")

    attrs = %{
      provider: " Google ",
      issuer: " https://accounts.google.com ",
      subject: "google-subject-1",
      email_snapshot: " FIRST@EXAMPLE.COM ",
      email_verified: true,
      hosted_domain: " EXAMPLE.COM "
    }

    assert {:ok, identity} = Repository.ensure_identity(first_user.id, attrs)
    assert {:ok, repeated} = Repository.ensure_identity(first_user.id, attrs)
    assert identity.id == repeated.id
    assert identity.email_snapshot == "first@example.com"
    assert identity.hosted_domain == "example.com"

    assert {:error, :identity_conflict} =
             Repository.ensure_identity(second_user.id, attrs)

    assert {:error, :provider_already_linked} =
             Repository.ensure_identity(first_user.id, %{attrs | subject: "google-subject-2"})

    assert Repo.aggregate(Identity, :count) == 1
  end

  @tag sandbox: false
  test "24 concurrent exact-email creates commit one winner" do
    email = "race-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.delete_all(from(user in User, where: user.email == ^email))
      after
        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end
    end)

    results =
      1..24
      |> Task.async_stream(
        fn _index ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            Repository.ensure_user_by_email(email)
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end,
        max_concurrency: 24,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %User{}, :created}, &1)) == 1

    assert Enum.all?(results, &match?({:ok, %User{}, _creation}, &1))

    assert results
           |> Enum.map(fn {:ok, user, _creation} -> user.id end)
           |> Enum.uniq()
           |> length() == 1

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    try do
      assert Repo.aggregate(from(user in User, where: user.email == ^email), :count) == 1
    after
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end
end
