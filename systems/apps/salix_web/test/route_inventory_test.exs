defmodule SalixWeb.RouteInventoryTest do
  use ExUnit.Case, async: true

  alias SalixWeb.RouteInventory

  @router Path.expand("../lib/salix_web/router.ex", __DIR__)

  test "every explicit router route is classified" do
    routes = router_routes()

    assert routes != []

    unknown =
      for {method, path} <- routes,
          RouteInventory.classify(method, path) == :unknown,
          do: {method, path}

    assert unknown == []
  end

  test "representative routes keep their intended surface buckets" do
    assert RouteInventory.classify("get", "/live") == :public_infra
    assert RouteInventory.classify("get", "/ready") == :public_infra
    assert RouteInventory.classify("get", "/health") == :public_infra
    assert RouteInventory.classify("get", "/v1/connect") == :public_site_connector
    assert RouteInventory.classify("post", "/v1/im/slack/events") == :public_callback
    assert RouteInventory.classify("post", "/v1/im/slack/interactions") == :public_callback

    assert RouteInventory.classify(
             "post",
             "/v1/calendar/google/notifications/:group_id/:calendar_id/:source_id"
           ) == :public_callback

    assert RouteInventory.classify("post", "/v1/agent-groups/:id/meeting-agent/runtime-events") ==
             :public_callback

    assert RouteInventory.classify("get", "/v1/e2e-report-sessions/:token/*path") ==
             :public_callback

    assert RouteInventory.classify("get", "/v1/admin/templates") == :admin
    assert RouteInventory.classify("get", "/v1/runtime/agents") == :internal_runtime
    assert RouteInventory.classify("post", "/v1/compute/commands/claim") == :internal_runtime

    assert RouteInventory.classify("get", "/v1/compute-node/work-activity/:registration_id") ==
             :internal_runtime

    assert RouteInventory.classify("get", "/v1/agent-groups/:id/capability-requests") == :client

    assert RouteInventory.classify("post", "/v1/agent-groups/:id/router/post-message") ==
             :client
  end

  defp router_routes do
    regex = ~r/^\s*(get|post|put|patch|delete)\s+"([^"]+)"/

    @router
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Regex.run(regex, line) do
        [_, method, path] -> [{method, path}]
        _ -> []
      end
    end)
  end
end
