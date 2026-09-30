defmodule SalixCalendar.AgentAPILocalReadTest do
  use ExUnit.Case, async: false

  alias SalixCalendar.AgentAPI
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

    principal = %{
      "namespace" => "slack_user",
      "tenant_id" => tenant_id,
      "subject_id" => "U_alice"
    }

    {:ok, item} =
      AgentAPI.create_event(
        group_id,
        %{"title" => "会议", "start" => "2026-08-29T16:00:00", "time_zone" => "Asia/Tokyo"},
        principal,
        "msg1_1"
      )

    {:ok,
     group_id: group_id,
     tenant_id: tenant_id,
     principal: principal,
     calendar_id: item["calendar_id"],
     item_id: item["calendar_item_id"]}
  end

  defp ms(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end

  defp day(ctx) do
    %{
      "calendar_id" => ctx.calendar_id,
      "range_start_ms" => ms("2026-08-29T00:00:00+09:00"),
      "range_end_ms" => ms("2026-08-30T00:00:00+09:00")
    }
  end

  test "get_item reads back the just-created local Event by its returned id", ctx do
    assert {:ok, %{"item" => read}} =
             AgentAPI.get_item(
               ctx.group_id,
               %{"calendar_id" => ctx.calendar_id, "calendar_item_id" => ctx.item_id},
               ctx.principal
             )

    assert read["calendar_item_id"] == ctx.item_id
    assert read["object"]["title"] == "会议"
  end

  test "list_items over the Event's day returns the local Event", ctx do
    assert {:ok, %{"data" => data}} = AgentAPI.list_items(ctx.group_id, day(ctx), ctx.principal)

    assert [entry] = Enum.filter(data, &(get_in(&1, ["item", "calendar_item_id"]) == ctx.item_id))
    assert get_in(entry, ["occurrence", "start_ms"]) == ms("2026-08-29T16:00:00+09:00")
  end

  test "local Events are owner-scoped: another principal cannot read or list them", ctx do
    other = %{ctx.principal | "subject_id" => "U_bob"}

    assert {:error, :not_found} =
             AgentAPI.get_item(
               ctx.group_id,
               %{"calendar_id" => ctx.calendar_id, "calendar_item_id" => ctx.item_id},
               other
             )

    assert {:ok, %{"data" => []}} = AgentAPI.list_items(ctx.group_id, day(ctx), other)
  end

  test "no principal (background read) never surfaces private local Events", ctx do
    assert {:error, :not_found} =
             AgentAPI.get_item(
               ctx.group_id,
               %{"calendar_id" => ctx.calendar_id, "calendar_item_id" => ctx.item_id},
               nil
             )

    assert {:ok, %{"data" => []}} = AgentAPI.list_items(ctx.group_id, day(ctx), nil)
  end

  test "object_type=Task excludes local Events", ctx do
    params = Map.put(day(ctx), "object_type", "Task")
    assert {:ok, %{"data" => []}} = AgentAPI.list_items(ctx.group_id, params, ctx.principal)
  end
end
