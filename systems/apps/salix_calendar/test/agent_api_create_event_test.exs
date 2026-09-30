defmodule SalixCalendar.AgentAPICreateEventTest do
  use ExUnit.Case, async: false

  alias SalixCalendar.{AgentAPI, Server}
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

    params = %{
      "title" => "与 XX 开会",
      "start" => "2026-09-15T19:00:00",
      "time_zone" => "Asia/Tokyo",
      "attendees" => [%{"display_name" => "XX"}]
    }

    {:ok, group_id: group_id, tenant_id: tenant_id, principal: principal, params: params}
  end

  test "creates a local Event in the group's canonical calendar and leaks no owner id", ctx do
    assert {:ok, item} = AgentAPI.create_event(ctx.group_id, ctx.params, ctx.principal, "msg1_1")

    assert item["object"]["title"] == "与 XX 开会"
    # Default duration applied when omitted.
    assert item["object"]["duration"] == "PT30M"
    assert Ids.valid_calendar_id?(item["calendar_id"])
    # The public projection never exposes owner identity or origin internals.
    refute Map.has_key?(item, "owner_principal_ref")
    refute Map.has_key?(item, "origin")

    # The Event is readable by its owner and is in the horizon.
    from = ms("2026-01-01T00:00:00Z")
    to = ms("2027-01-01T00:00:00Z")
    owner = ctx.principal

    assert {:ok, [owned]} =
             Server.list_owner_items(ctx.group_id, item["calendar_id"], owner, from, to)

    assert owned["calendar_item_id"] == item["calendar_item_id"]
  end

  test "the canonical calendar is stable and retries are idempotent", ctx do
    assert {:ok, first} =
             AgentAPI.create_event(ctx.group_id, ctx.params, ctx.principal, "msg1_dup")

    assert {:ok, again} =
             AgentAPI.create_event(ctx.group_id, ctx.params, ctx.principal, "msg1_dup")

    assert first["calendar_item_id"] == again["calendar_item_id"]

    other = %{ctx.params | "title" => "另一个会"}
    assert {:ok, second} = AgentAPI.create_event(ctx.group_id, other, ctx.principal, "msg1_2")
    # Different request → different Event, but same canonical calendar.
    assert second["calendar_item_id"] != first["calendar_item_id"]
    assert second["calendar_id"] == first["calendar_id"]
  end

  test "fails closed without a principal and rejects a tenant mismatch", ctx do
    assert {:error, :missing_principal} =
             AgentAPI.create_event(ctx.group_id, ctx.params, nil, "msg1_x")

    assert {:error, :missing_principal} =
             AgentAPI.create_event(
               ctx.group_id,
               ctx.params,
               %{"namespace" => "slack_user"},
               "msg1_x"
             )

    foreign = %{ctx.principal | "tenant_id" => Ids.new_tenant_id()}

    assert {:error, :principal_tenant_mismatch} =
             AgentAPI.create_event(ctx.group_id, ctx.params, foreign, "msg1_x")
  end

  test "rejects a blank creation request id", ctx do
    assert {:error, :invalid_creation_request} =
             AgentAPI.create_event(ctx.group_id, ctx.params, ctx.principal, "")
  end

  defp ms(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end
end
