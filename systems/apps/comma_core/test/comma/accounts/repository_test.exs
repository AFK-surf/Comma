defmodule Comma.Accounts.RepositoryTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts.{Identity, Repository, User}

  test "exact trim-plus-lowercase email converges to one user" do
    assert {:ok, first} = Repository.ensure_user_by_email("  Peng@Example.COM ")
    assert {:ok, second} = Repository.ensure_user_by_email("peng@example.com")

    assert first.id == second.id
    assert second.email == "peng@example.com"

    assert Repo.aggregate(from(user in User, where: user.email == "peng@example.com"), :count) ==
             1
  end

  test "Gmail dot and plus aliases stay separate business accounts" do
    users =
      for email <- ["peng+comma@gmail.com", "pengcue@gmail.com", "p.engcue@gmail.com"] do
        assert {:ok, user} = Repository.ensure_user_by_email(email)
        user
      end

    assert users |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3

    assert Enum.map(users, & &1.email) == [
             "peng+comma@gmail.com",
             "pengcue@gmail.com",
             "p.engcue@gmail.com"
           ]
  end

  test "the physical email column preserves the 320-byte account-key contract" do
    email = String.duplicate("a", 308) <> "@example.com"
    assert byte_size(email) == 320

    assert {:ok, user} = Repository.ensure_user_by_email(email)
    assert user.email == email
    assert {:ok, same_user} = Repository.get_user_by_email(email)
    assert same_user.id == user.id
  end

  test "new accounts reject grandfathered public ID formats" do
    for {id, email} <- [
          {"usr-codex-electron-staging-smoke", "new-legacy-prefix@example.com"},
          {"7f659052-4028-460b-b9e8-79dca0d7be3d", "new-uuid@example.com"}
        ] do
      assert {:error, changeset} =
               Comma.Accounts.create_user(%{
                 "id" => id,
                 "email" => email
               })

      assert {"has invalid format", _metadata} = Keyword.fetch!(changeset.errors, :id)
      refute Repo.get(User, id)
    end
  end

  test "provider subject and per-user provider links are unique and idempotent" do
    assert {:ok, first_user} = Repository.ensure_user_by_email("first@example.com")
    assert {:ok, second_user} = Repository.ensure_user_by_email("second@example.com")

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
    email = "race-#{System.unique_integer([:positive])}@example.com"

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

    assert Enum.all?(results, &match?({:ok, %User{}}, &1))

    assert results
           |> Enum.map(fn {:ok, user} -> user.id end)
           |> Enum.uniq()
           |> length() == 1

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    try do
      assert Repo.aggregate(from(user in User, where: user.email == ^email), :count) == 1
    after
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  test "account foreign keys stay inside Comma-owned tables" do
    foreign_targets =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT parent.relname
        FROM pg_constraint AS constraint_row
        JOIN pg_class AS child ON child.oid = constraint_row.conrelid
        JOIN pg_class AS parent ON parent.oid = constraint_row.confrelid
        WHERE constraint_row.contype = 'f'
          AND child.relname IN ('comma_users', 'comma_user_identities')
        ORDER BY parent.relname
        """,
        []
      ).rows

    assert foreign_targets == [["comma_user_avatars"], ["comma_users"]]
  end

  test "migration exposes only the account indexes required by bounded lookups" do
    index_names =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename IN ('comma_users', 'comma_user_identities')
        ORDER BY indexname
        """,
        []
      ).rows
      |> List.flatten()
      |> MapSet.new()

    for expected <- [
          "comma_users_normalized_email_index",
          "comma_users_inserted_at_id_index",
          "comma_user_identities_provider_subject_unique",
          "comma_user_identities_user_provider_unique"
        ] do
      assert MapSet.member?(index_names, expected)
    end

    refute MapSet.member?(index_names, "comma_user_identities_user_id_index")
  end

  test "Comma Repo queries use the redacted product database telemetry boundary" do
    Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [])

    assert SystemsObservability.scrape() =~
             ~s(comma_system_db_queries_total{component="comma_product",operation="query",outcome="ok",repo="comma"})
  end
end
