defmodule SalixWeb.RouterAgentPageTest do
  use SystemsClock.Case, async: false

  alias Salix.Control.Tenants
  alias SalixAgent.{Control, TaskAgent, TestSupport}
  alias SalixStore.S3

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_token = SystemsRuntime.get_env(:salix_web, :api_token)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.put_env(:salix_web, :api_token, "test-token")
    Comma.PodLifecycle.reset_for_test()
    SalixCluster.NodeLifecycle.reset()

    if SystemsRuntime.Proc.whereis(S3.Fake),
      do: S3.Fake.reset(),
      else: start_supervised!(S3.Fake)

    TestSupport.configure_platform_models!()
    {tenant, key} = tenant!()
    group = request(key, :post, "/v1/runtime/agent-groups", json: %{name: "Page group"}).body

    on_exit(fn ->
      TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
      SystemsRuntime.put_env(:salix_web, :api_token, previous_token)
      Comma.PodLifecycle.reset_for_test()
      SalixCluster.NodeLifecycle.reset()
    end)

    %{tenant: tenant, key: key, group: group["group_id"]}
  end

  test "native pages preserve order, scope and list visibility", c do
    visible = for n <- 1..5, do: agent!(c, %{"name" => "Worker #{n}"})
    router = agent!(c, %{"name" => "Router", "role" => "router"})
    {:ok, task} = TaskAgent.ensure(%{tenant_id: c.tenant, group_id: c.group})
    hidden = agent!(c, %{"hidden" => true})
    archived = agent!(c)
    assert {:ok, _} = Control.archive_permanently(archived["agent_id"], c.tenant)

    other_group = request(c.key, :post, "/v1/runtime/agent-groups", json: %{name: "Other"}).body
    agent!(%{c | group: other_group["group_id"]})
    {other_tenant, other_key} = tenant!()

    foreign_group =
      request(other_key, :post, "/v1/runtime/agent-groups", json: %{name: "Foreign"}).body

    agent!(%{c | tenant: other_tenant, group: foreign_group["group_id"]})

    expected = Enum.sort(Enum.map([router | visible], & &1["agent_id"]) ++ [task])
    assert collect(c, %{limit: 2}, nil, 10) == expected
    assert length(expected) == MapSet.size(MapSet.new(expected))

    page = page(c, %{})
    assert page.status == 200
    assert Enum.map(page.body["data"], & &1["agent_id"]) == expected
    assert page.body["next_cursor"] == nil
    assert page.body["has_more"] == false
    refute hidden["agent_id"] in expected

    assert collect(c, %{limit: 2, include_archived: true}, nil, 10) ==
             Enum.sort([archived["agent_id"] | expected])

    # The existing endpoint retains its array response and default visibility.
    legacy = request(c.key, :get, "/v1/runtime/agents", params: %{group_id: c.group})
    assert legacy.status == 200
    assert is_list(legacy.body)
    assert Enum.sort(Enum.map(legacy.body, & &1["agent_id"])) == expected
    assert page(%{c | key: other_key}, %{}).status == 404
  end

  test "an empty status-filtered page retains its native continuation", c do
    first = agent!(c)
    second = agent!(c)
    assert first["agent_id"] < second["agent_id"]
    assert {:ok, _} = Control.cancel(second["agent_id"], c.tenant)

    response = page(c, %{limit: 1, status: "cancelled"})
    assert response.status == 200
    assert response.body["data"] == []
    assert response.body["has_more"] == true
    assert is_binary(response.body["next_cursor"])

    next = page(c, %{limit: 1, status: "cancelled", cursor: response.body["next_cursor"]})
    assert next.status == 200
    assert Enum.map(next.body["data"], & &1["agent_id"]) == [second["agent_id"]]
    assert collect(c, %{limit: 1, status: "cancelled"}, nil, 5) == [second["agent_id"]]
  end

  test "invalid bounds and cursors fail without crossing group or visibility scopes", c do
    agent!(c)
    agent!(c)
    assert request(c.key, :get, "/v1/runtime/agents/page").status == 400

    for limit <- ["0", "101", "no", "1tail"] do
      assert page(c, %{limit: limit}).status == 400
    end

    assert page(c, %{cursor: "not-a-native-cursor"}).status == 400
    response = page(c, %{limit: 1})
    cursor = response.body["next_cursor"]
    assert is_binary(cursor)
    assert page(c, %{limit: 1, cursor: cursor, include_archived: true}).status == 400

    group = request(c.key, :post, "/v1/runtime/agent-groups", json: %{name: "Other"}).body
    assert page(%{c | group: group["group_id"]}, %{limit: 1, cursor: cursor}).status == 400
  end

  defp tenant! do
    {:ok, tenant} = Tenants.create(%{"name" => "Agent page tenant"})
    {:ok, key} = Tenants.create_api_key(tenant["tenant_id"], %{"name" => "page test"})
    {tenant["tenant_id"], key["key"]}
  end

  defp agent!(c, attrs \\ %{}),
    do: TestSupport.create_control_agent_in_group!(c.tenant, c.group, attrs)

  defp page(c, params),
    do:
      request(c.key, :get, "/v1/runtime/agents/page", params: Map.put(params, :group_id, c.group))

  defp collect(_c, _params, _cursor, 0), do: flunk("agent pagination did not finish")

  defp collect(c, params, cursor, remaining) do
    params = if cursor, do: Map.put(params, :cursor, cursor), else: params
    response = page(c, params)
    assert response.status == 200
    data = Enum.map(response.body["data"], & &1["agent_id"])
    next = response.body["next_cursor"]
    assert response.body["has_more"] == not is_nil(next)

    if next do
      assert next != cursor
      data ++ collect(c, params, next, remaining - 1)
    else
      data
    end
  end

  defp request(key, method, path, opts \\ []) do
    Req.request!(
      [
        method: method,
        url: SalixWeb.Application.base_url() <> path,
        headers: [{"authorization", "Bearer " <> key}],
        retry: false
      ] ++ opts
    )
  end
end
