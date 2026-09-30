defmodule SalixStore.CalendarFeedSubscriptionsTest do
  use ExUnit.Case, async: false

  alias SalixStore.{CalendarFeedSubscriptions, Ids, Repo}

  setup do
    Repo.query!("TRUNCATE calendar_feed_subscriptions")
    :ok
  end

  test "issue returns a one-time secret and authenticates the exact owner scope" do
    now = 1_900_000_000_000
    scope = scope()

    assert {:ok, %{"id" => id, "secret" => secret}} = CalendarFeedSubscriptions.issue(scope, now)
    assert Ids.valid_calendar_feed_id?(id)
    assert is_binary(secret) and secret != ""

    assert {:ok, authorized} = CalendarFeedSubscriptions.authenticate(id, secret)
    assert authorized["calendar_id"] == scope["calendar_id"]
    assert authorized["subject_id"] == scope["subject_id"]

    # Metadata read never exposes the secret or digest.
    assert {:ok, record} = CalendarFeedSubscriptions.get(id)
    refute Map.has_key?(record, "secret")
    refute Map.has_key?(record, "token_digest")
    assert record["created_at"] == now
  end

  test "a wrong secret, unknown id, and malformed id all fail without disclosure" do
    now = 1_900_000_000_000
    assert {:ok, %{"id" => id}} = CalendarFeedSubscriptions.issue(scope(), now)

    assert {:error, :unauthorized} = CalendarFeedSubscriptions.authenticate(id, "not-the-secret")

    assert {:error, :not_found} =
             CalendarFeedSubscriptions.authenticate(Ids.new_calendar_feed_id(), "x")

    assert {:error, :not_found} = CalendarFeedSubscriptions.authenticate("nope", "x")
  end

  test "a duplicate active subscription for one subject and calendar is rejected" do
    now = 1_900_000_000_000
    scope = scope()

    assert {:ok, _} = CalendarFeedSubscriptions.issue(scope, now)

    assert {:error, :calendar_feed_active_exists} =
             CalendarFeedSubscriptions.issue(scope, now + 1)
  end

  test "revocation is immediate and idempotent, and frees a new active subscription" do
    now = 1_900_000_000_000
    scope = scope()

    assert {:ok, %{"id" => id, "secret" => secret}} = CalendarFeedSubscriptions.issue(scope, now)
    assert {:ok, _} = CalendarFeedSubscriptions.authenticate(id, secret)

    assert :ok = CalendarFeedSubscriptions.revoke(id, now + 1)
    assert {:error, :revoked} = CalendarFeedSubscriptions.authenticate(id, secret)
    # Idempotent.
    assert :ok = CalendarFeedSubscriptions.revoke(id, now + 2)

    # The partial unique index only covers active rows, so a fresh one is allowed.
    assert {:ok, %{"id" => new_id}} = CalendarFeedSubscriptions.issue(scope, now + 3)
    assert new_id != id
  end

  test "rotation invalidates the old secret and rejects a revoked row" do
    now = 1_900_000_000_000
    scope = scope()

    assert {:ok, %{"id" => id, "secret" => old_secret}} =
             CalendarFeedSubscriptions.issue(scope, now)

    assert {:ok, %{"secret" => new_secret}} = CalendarFeedSubscriptions.rotate(id, now + 1)
    assert new_secret != old_secret

    assert {:error, :unauthorized} = CalendarFeedSubscriptions.authenticate(id, old_secret)
    assert {:ok, _} = CalendarFeedSubscriptions.authenticate(id, new_secret)

    assert :ok = CalendarFeedSubscriptions.revoke(id, now + 2)
    assert {:error, :calendar_feed_revoked} = CalendarFeedSubscriptions.rotate(id, now + 3)
  end

  test "invalid scope or empty subject components are rejected before insert" do
    now = 1_900_000_000_000

    assert {:error, :invalid_scope} =
             CalendarFeedSubscriptions.issue(Map.delete(scope(), "calendar_id"), now)

    assert {:error, :invalid_subject} =
             CalendarFeedSubscriptions.issue(Map.put(scope(), "subject_id", ""), now)
  end

  test "postgres rejects a non-32-byte digest and empty subject components" do
    id = Ids.new_calendar_feed_id()

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        """
        INSERT INTO calendar_feed_subscriptions
          (id, tenant_id, group_id, calendar_id, subject_namespace,
           subject_id, token_digest, created_at, updated_at)
        VALUES ($1, 'ten1_x', 'grp1_x', 'cal1_x', 'feishu_user', 'subj',
                decode('00', 'hex'), now(), now())
        """,
        [id]
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        """
        INSERT INTO calendar_feed_subscriptions
          (id, tenant_id, group_id, calendar_id, subject_namespace,
           subject_id, token_digest, created_at, updated_at)
        VALUES ($1, 'ten1_x', 'grp1_x', 'cal1_x', '', 'subj',
                decode(repeat('00', 32), 'hex'), now(), now())
        """,
        [Ids.new_calendar_feed_id()]
      )
    end
  end

  test "the feed table has no foreign key to Comma or BFT user tables" do
    %{rows: rows} =
      Repo.query!("""
      SELECT count(*) FROM information_schema.table_constraints
      WHERE table_name = 'calendar_feed_subscriptions' AND constraint_type = 'FOREIGN KEY'
      """)

    assert rows == [[0]]
  end

  test "rotate_to is a compare-and-swap: a stale fence cannot overwrite a newer secret" do
    now = 1_900_000_000_000
    scope = scope()

    assert {:ok, %{"id" => id}} = CalendarFeedSubscriptions.issue(scope, now)
    assert {:ok, %{"id" => ^id, "fence" => fence0}} = CalendarFeedSubscriptions.active(scope)

    a = CalendarFeedSubscriptions.new_secret()
    b = CalendarFeedSubscriptions.new_secret()

    # Two reissues both observed fence0. The first commit wins; the second is a
    # stale write and is fenced off rather than overwriting the newer credential.
    assert :ok = CalendarFeedSubscriptions.rotate_to(id, fence0, a, now + 1)

    assert {:error, :calendar_feed_stale} =
             CalendarFeedSubscriptions.rotate_to(id, fence0, b, now + 2)

    assert {:ok, _} = CalendarFeedSubscriptions.authenticate(id, a)
    assert {:error, :unauthorized} = CalendarFeedSubscriptions.authenticate(id, b)
  end

  defp scope do
    %{
      "tenant_id" => "ten1_0000000000000000001",
      "group_id" => "grp1_0000000000000000001_0000000000000000002",
      "calendar_id" => "cal1_0000000000000000003",
      "subject_namespace" => "feishu_user",
      "subject_id" =>
        "subject-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    }
  end
end
