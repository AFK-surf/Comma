defmodule Comma.Accounts.UserPaginationTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts.User

  @cursor_secret "comma-admin-user-page-test-secret"

  test "keyset pages are stable when users share the same timestamp" do
    inserted = insert_users(4, "tie")
    expected_ids = inserted |> Enum.map(& &1.id) |> Enum.sort(:desc)

    assert {:ok, first} =
             Comma.Accounts.list_users(limit: 2, cursor_secret: @cursor_secret)

    assert Enum.map(first["data"], & &1["id"]) == Enum.take(expected_ids, 2)
    assert first["has_more"]
    assert is_binary(first["next_cursor"])

    assert {:ok, second} =
             Comma.Accounts.list_users(
               limit: 2,
               cursor: first["next_cursor"],
               cursor_secret: @cursor_secret
             )

    assert Enum.map(second["data"], & &1["id"]) == Enum.drop(expected_ids, 2)
    refute second["has_more"]
    assert second["next_cursor"] == nil

    all_ids = Enum.map(first["data"] ++ second["data"], & &1["id"])
    assert all_ids == expected_ids
    assert Enum.uniq(all_ids) == all_ids
  end

  test "cursor tampering and reuse with another filter fail closed" do
    [first_user | _] = insert_users(3, "filter")

    assert {:ok, first} =
             Comma.Accounts.list_users(limit: 1, cursor_secret: @cursor_secret)

    cursor = first["next_cursor"]
    assert is_binary(cursor)

    assert {:error, :invalid_cursor} =
             Comma.Accounts.list_users(
               limit: 1,
               cursor: cursor <> "x",
               cursor_secret: @cursor_secret
             )

    assert {:error, :invalid_cursor} =
             Comma.Accounts.list_users(
               cursor: "",
               cursor_secret: @cursor_secret
             )

    assert {:error, :invalid_cursor} =
             Comma.Accounts.list_users(
               limit: 1,
               cursor: cursor,
               email: first_user.email,
               cursor_secret: @cursor_secret
             )
  end

  test "exact email lookup uses normalized filter semantics" do
    [user | _] = insert_users(2, "email")

    assert {:ok, page} =
             Comma.Accounts.list_users(
               email: "  #{String.upcase(user.email)} ",
               cursor_secret: @cursor_secret
             )

    assert [%{"id" => id, "email" => email}] = page["data"]
    assert id == user.id
    assert email == user.email
    refute page["has_more"]
    assert page["next_cursor"] == nil

    assert {:error, :invalid_filter} =
             Comma.Accounts.list_users(
               email: "not-an-email",
               cursor_secret: @cursor_secret
             )

    assert {:error, :invalid_filter} =
             Comma.Accounts.list_users(
               email: "",
               cursor_secret: @cursor_secret
             )
  end

  test "user list clamps every requested page to the hard maximum" do
    insert_users(102, "limit")

    assert {:ok, page} =
             Comma.Accounts.list_users(limit: 10_000, cursor_secret: @cursor_secret)

    assert length(page["data"]) == 100
    assert page["has_more"]
    assert is_binary(page["next_cursor"])
  end

  test "user list applies its hard limit at the database query boundary" do
    insert_users(2, "query-boundary")
    handler_id = "comma-user-page-query-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma, :repo, :query],
        &__MODULE__.capture_user_page_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, page} =
             Comma.Accounts.list_users(limit: 10_000, cursor_secret: @cursor_secret)

    assert length(page["data"]) == 2
    assert_receive {:user_page_query, query, [101]}
    assert query =~ ~r/ORDER BY .*inserted_at.*DESC, .*id.*DESC LIMIT \$1/
    refute_receive {:user_page_query, _query, _params}
  end

  def capture_user_page_query(_event, _measurements, metadata, test_pid) do
    if metadata[:source] == "comma_users" and
         String.starts_with?(metadata[:query] || "", "SELECT") do
      send(test_pid, {:user_page_query, metadata[:query], metadata[:params]})
    end
  end

  defp insert_users(count, label) do
    timestamp = DateTime.utc_now()
    nonce = System.unique_integer([:positive])

    rows =
      for index <- 1..count do
        %{
          id: "usr_#{label}_#{nonce}_#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          email: "#{label}-#{nonce}-#{index}@example.com",
          name: "User #{index}",
          status: "active",
          auth_epoch: 0,
          created_at: timestamp,
          updated_at: timestamp
        }
      end

    {^count, nil} = Repo.insert_all(User, rows)
    Enum.map(rows, &struct!(User, &1))
  end
end
