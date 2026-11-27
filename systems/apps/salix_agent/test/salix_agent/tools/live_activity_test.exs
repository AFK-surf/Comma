defmodule SalixAgent.Tools.LiveActivityTest.Adapter do
  def upsert(%{"key" => "limit"} = _args, _ctx), do: {:error, :live_activity_limit_reached}

  def upsert(args, ctx),
    do: {:ok, %{"status" => "ok", "key" => args["key"], "role" => ctx[:role]}}

  def end_activity(%{"key" => "missing"}, _ctx), do: {:error, :not_found}
  def end_activity(args, _ctx), do: {:ok, %{"status" => "ended", "key" => args["key"]}}

  def list(_args, ctx), do: {:ok, %{"status" => "ok", "group_id" => ctx[:group_id]}}
end

defmodule SalixAgent.Tools.LiveActivityTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{GuestPolicy, Tools}
  alias SalixAgent.Loops.Capabilities
  alias SalixAgent.Tools.LiveActivity

  setup do
    prior = SystemsRuntime.get_env(:salix_agent, :live_activity_adapter)
    SystemsRuntime.put_env(:salix_agent, :live_activity_adapter, __MODULE__.Adapter)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_agent, :live_activity_adapter, prior)
    end)

    :ok
  end

  test "tools are registered, available to Router and Worker, and denied to Guests" do
    names = Tools.registry() |> Enum.map(&Tools.entry_name/1)
    assert "live_activity.upsert" in names
    assert "live_activity.end" in names
    assert "live_activity.list" in names

    guest_ctx = %{guest_policy: :restricted}
    refute GuestPolicy.allowed_tool?(guest_ctx, "live_activity.upsert")
    refute GuestPolicy.allowed_tool?(guest_ctx, "live_activity.end")
    refute GuestPolicy.allowed_tool?(guest_ctx, "live_activity.list")

    ordinary_ctx = %{guest_policy: :ordinary}
    assert GuestPolicy.allowed_tool?(ordinary_ctx, "live_activity.upsert")
    assert GuestPolicy.allowed_tool?(ordinary_ctx, "live_activity.end")
    assert GuestPolicy.allowed_tool?(ordinary_ctx, "live_activity.list")
  end

  test "tools are exposed to Background Loops allowlist" do
    allowed = Capabilities.allowed_names()
    assert "live_activity.upsert" in allowed
    assert "live_activity.end" in allowed
    assert "live_activity.list" in allowed

    assert Enum.sort(Capabilities.live_activity_tool_names()) == [
             "live_activity.end",
             "live_activity.list",
             "live_activity.upsert"
           ]
  end

  test "upsert, end, and list delegate to adapter with IFC group audience and clear error hints" do
    router_ctx = %{agent_id: "agt_1", group_id: "grp_1", role: "router"}
    worker_ctx = %{agent_id: "agt_2", group_id: "grp_1", role: "worker"}

    router_out =
      LiveActivity.upsert(
        %{"key" => "ride:1", "category" => "car", "title" => "On the way"},
        router_ctx
      )

    assert is_binary(router_out)
    assert router_out =~ "ride:1"
    assert router_out =~ "router"

    worker_out = LiveActivity.end_activity(%{"key" => "ride:1"}, worker_ctx)
    assert is_binary(worker_out)
    assert worker_out =~ "ended"

    list_out = LiveActivity.list(%{}, router_ctx)
    assert is_binary(list_out)
    assert list_out =~ "grp_1"

    assert_raise RuntimeError, ~r/At most 5 active live activities/, fn ->
      LiveActivity.upsert(
        %{"key" => "limit", "category" => "car", "title" => "Too many"},
        router_ctx
      )
    end

    assert_raise RuntimeError, ~r/No live activity with that key exists/, fn ->
      LiveActivity.end_activity(%{"key" => "missing"}, router_ctx)
    end
  end
end
