defmodule SalixCalendar.LocalItemTest do
  use ExUnit.Case, async: false

  alias SalixCalendar.Server
  alias SalixStore.{Ids, Keys, S3}

  setup do
    S3.Fake.reset()

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, _} =
             S3.put(
               Keys.ctl_group(group_id),
               Jason.encode!(%{"group_id" => group_id, "tenant_id" => tenant_id}),
               if_none_match: "*"
             )

    assert {:ok, calendar} =
             Server.create_calendar(group_id, %{name: "Team", default_time_zone: "Asia/Shanghai"})

    owner = %{
      "namespace" => "feishu_user",
      "tenant_id" => tenant_id,
      "subject_id" => "subject-a"
    }

    {:ok,
     group_id: group_id, calendar_id: calendar["calendar_id"], tenant_id: tenant_id, owner: owner}
  end

  test "creates a local Event with sealed owner, and a stranger cannot see it", ctx do
    proposal = %{
      "title" => "与 XX 开会",
      "start" => "2026-09-15T19:00:00",
      "time_zone" => "Asia/Tokyo",
      "duration" => "PT30M",
      "attendees" => [%{"display_name" => "XX"}]
    }

    assert {:ok, item} =
             Server.create_local_item(ctx.group_id, ctx.calendar_id, proposal, ctx.owner, "req-1")

    assert item["origin"]["kind"] == "local"
    assert item["owner_principal_ref"] == ctx.owner
    assert item["object"]["@type"] == "Event"
    assert item["object"]["uid"] == "urn:comma:calendar-item:#{item["calendar_item_id"]}"
    assert item["object"]["timeZone"] == "Asia/Tokyo"
    assert item["object"]["privacy"] == "private"
    assert item["object"]["participants"]["p1"]["x-comma-resolution"] == "unresolved"
    assert item["object"]["participants"]["p1"]["name"] == "XX"
    refute Map.has_key?(item["object"]["participants"]["p1"], "principal_ref")

    assert {:ok, ^item} =
             Server.get_local_item(ctx.group_id, ctx.calendar_id, item["calendar_item_id"])

    from = ms("2026-01-01T00:00:00Z")
    to = ms("2027-01-01T00:00:00Z")

    assert {:ok, [owned]} =
             Server.list_owner_items(ctx.group_id, ctx.calendar_id, ctx.owner, from, to)

    assert owned["calendar_item_id"] == item["calendar_item_id"]

    stranger = Map.put(ctx.owner, "subject_id", "subject-b")
    assert {:ok, []} = Server.list_owner_items(ctx.group_id, ctx.calendar_id, stranger, from, to)
  end

  test "an exact retry with the same creation_request_id does not duplicate the Event", ctx do
    proposal = %{
      "title" => "交报告",
      "start" => "2026-10-01T09:00:00",
      "time_zone" => "Asia/Tokyo",
      "duration" => "PT1H"
    }

    assert {:ok, first} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               proposal,
               ctx.owner,
               "req-dup"
             )

    assert {:ok, second} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               proposal,
               ctx.owner,
               "req-dup"
             )

    assert first["calendar_item_id"] == second["calendar_item_id"]

    from = ms("2026-01-01T00:00:00Z")
    to = ms("2027-01-01T00:00:00Z")

    assert {:ok, items} =
             Server.list_owner_items(ctx.group_id, ctx.calendar_id, ctx.owner, from, to)

    assert length(items) == 1
  end

  test "rejects bad timezone, offset/UTC start, empty title, and an unsealed owner", ctx do
    base = %{
      "title" => "ok",
      "start" => "2026-09-15T19:00:00",
      "time_zone" => "Asia/Tokyo",
      "duration" => "PT30M"
    }

    assert {:error, :invalid_time_zone} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               %{base | "time_zone" => "Not/AZone"},
               ctx.owner,
               "r1"
             )

    assert {:error, :invalid_event_start} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               %{base | "start" => "2026-09-15T19:00:00Z"},
               ctx.owner,
               "r2"
             )

    assert {:error, :invalid_event_title} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               %{base | "title" => "   "},
               ctx.owner,
               "r3"
             )

    assert {:error, :invalid_owner_principal_ref} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               base,
               Map.delete(ctx.owner, "subject_id"),
               "r4"
             )
  end

  test "a replay with the same request id but different content is rejected, not collapsed",
       ctx do
    base = %{
      "title" => "会议A",
      "start" => "2026-09-15T19:00:00",
      "time_zone" => "Asia/Tokyo",
      "duration" => "PT30M"
    }

    assert {:ok, first} =
             Server.create_local_item(ctx.group_id, ctx.calendar_id, base, ctx.owner, "req-fp")

    # Same request id, different proposal -> conflict (never returns the first item).
    assert {:error, :calendar_local_item_conflict} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               %{base | "title" => "会议B"},
               ctx.owner,
               "req-fp"
             )

    # Exact same request and content -> idempotent, the same item.
    assert {:ok, ^first} =
             Server.create_local_item(ctx.group_id, ctx.calendar_id, base, ctx.owner, "req-fp")

    # A distinct request id -> a distinct Event.
    assert {:ok, second} =
             Server.create_local_item(ctx.group_id, ctx.calendar_id, base, ctx.owner, "req-other")

    assert second["calendar_item_id"] != first["calendar_item_id"]
  end

  test "a repeated request resumes the pinned item without duplicating it", ctx do
    proposal = %{
      "title" => "会",
      "start" => "2026-10-01T09:00:00",
      "time_zone" => "Asia/Tokyo",
      "duration" => "PT30M"
    }

    # Each call drives the intent -> ensure_item recovery path (create-once yields
    # the already-written item on the second call), so a resumed request never
    # allocates a second item.
    assert {:ok, first} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               proposal,
               ctx.owner,
               "req-resume"
             )

    assert {:ok, ^first} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               proposal,
               ctx.owner,
               "req-resume"
             )

    from = ms("2026-01-01T00:00:00Z")
    to = ms("2027-01-01T00:00:00Z")

    assert {:ok, [only]} =
             Server.list_owner_items(ctx.group_id, ctx.calendar_id, ctx.owner, from, to)

    assert only["calendar_item_id"] == first["calendar_item_id"]
  end

  test "a lost owner marker is restored on a repeated request, with no duplicate item", ctx do
    proposal = %{
      "title" => "会",
      "start" => "2026-10-01T09:00:00",
      "time_zone" => "Asia/Tokyo",
      "duration" => "PT30M"
    }

    assert {:ok, item} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               proposal,
               ctx.owner,
               "req-marker"
             )

    # Simulate a crash after the item was written but before the owner marker: drop
    # the marker directly, then the Feed can no longer find the (still-stored) item.
    marker_key =
      Keys.ctl_calendar_query_owner_month(
        ctx.group_id,
        ctx.calendar_id,
        SalixCalendar.LocalItem.owner_digest(ctx.owner),
        "2026-10",
        item["calendar_item_id"]
      )

    :ok = S3.delete(marker_key)

    from = ms("2026-01-01T00:00:00Z")
    to = ms("2027-01-01T00:00:00Z")
    assert {:ok, []} = Server.list_owner_items(ctx.group_id, ctx.calendar_id, ctx.owner, from, to)

    # Repeating the request resumes the same item id and re-ensures the marker.
    assert {:ok, ^item} =
             Server.create_local_item(
               ctx.group_id,
               ctx.calendar_id,
               proposal,
               ctx.owner,
               "req-marker"
             )

    assert {:ok, [only]} =
             Server.list_owner_items(ctx.group_id, ctx.calendar_id, ctx.owner, from, to)

    assert only["calendar_item_id"] == item["calendar_item_id"]
  end

  defp ms(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end
end
