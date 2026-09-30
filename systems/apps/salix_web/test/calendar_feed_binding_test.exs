defmodule Salix.Bindings.CalendarFeedTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.CalendarFeed
  alias SalixCalendar.Server
  alias SalixStore.{CalendarFeedSubscriptions, Ids, Keys, Repo, S3}

  setup do
    S3.Fake.reset()
    Repo.query!("TRUNCATE calendar_feed_subscriptions")

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, _} =
             S3.put(
               Keys.ctl_group(group_id),
               Jason.encode!(%{"group_id" => group_id, "tenant_id" => tenant_id}),
               if_none_match: "*"
             )

    assert {:ok, calendar} =
             Server.create_calendar(group_id, %{name: "Team", default_time_zone: "Asia/Tokyo"})

    calendar_id = calendar["calendar_id"]

    owner = %{
      "namespace" => "feishu_user",
      "tenant_id" => tenant_id,
      "subject_id" => "subject-a"
    }

    assert {:ok, _item} =
             Server.create_local_item(
               group_id,
               calendar_id,
               %{
                 "title" => "与 XX 开会",
                 "start" => "2026-09-15T19:00:00",
                 "time_zone" => "Asia/Tokyo",
                 "duration" => "PT30M"
               },
               owner,
               "req-feed"
             )

    scope = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "calendar_id" => calendar_id,
      "subject_namespace" => owner["namespace"],
      "subject_id" => owner["subject_id"]
    }

    assert {:ok, %{"id" => feed_id, "secret" => secret}} =
             CalendarFeedSubscriptions.issue(scope, System.system_time(:millisecond))

    {:ok, feed_id: feed_id, secret: secret}
  end

  test "serves the owner's Event as iCalendar and honors conditional requests", ctx do
    assert {:ok, %{body: body, etag: etag}} = CalendarFeed.serve(ctx.feed_id, ctx.secret, "")

    assert String.contains?(body, "BEGIN:VCALENDAR")
    assert String.contains?(body, "BEGIN:VTIMEZONE")
    assert String.contains?(body, "TZID:Asia/Tokyo")
    assert String.contains?(body, "DTSTART;TZID=Asia/Tokyo:20260915T190000")
    assert String.contains?(body, "SUMMARY:与 XX 开会")
    assert String.contains?(body, "CLASS:PRIVATE")

    # A matching If-None-Match returns not-modified without re-serializing.
    assert {:not_modified, ^etag} = CalendarFeed.serve(ctx.feed_id, ctx.secret, etag)
  end

  test "rejects a wrong secret and a revoked subscription without disclosure", ctx do
    assert {:error, :unauthorized} = CalendarFeed.serve(ctx.feed_id, "wrong-secret", "")

    assert :ok = CalendarFeedSubscriptions.revoke(ctx.feed_id, System.system_time(:millisecond))
    assert {:error, :revoked} = CalendarFeed.serve(ctx.feed_id, ctx.secret, "")
  end
end
