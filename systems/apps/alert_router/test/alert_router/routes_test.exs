defmodule AlertRouter.RoutesTest do
  use SystemsClock.Case, async: false

  alias AlertRouter.Routes

  import AlertRouter.TestFixtures

  setup do
    previous = SystemsRuntime.fetch_env!(:alert_router, :slack)
    on_exit(fn -> SystemsRuntime.put_env(:alert_router, :slack, previous) end)
    :ok
  end

  test "live delivery uses the reviewed public alert channel without shadow marking" do
    assert {:ok,
            %{
              route_id: "live",
              route_revision: 1,
              channel_id: "C0BJ1699HSN",
              shadow: false
            }} =
             Routes.resolve(gcp_event("open", project: "example-staging-project"), :live)
  end

  test "a staging Router does not post production alerts" do
    assert {:error, {:unapproved_route_environment, "live", "production"}} =
             Routes.resolve(gcp_event(), :live)
  end

  test "a production Router posts production alerts and not staging ones" do
    previous = SystemsRuntime.get_env(:alert_router, :environment)
    SystemsRuntime.put_env(:alert_router, :environment, "production")
    on_exit(fn -> SystemsRuntime.put_env(:alert_router, :environment, previous) end)

    assert {:ok, %{route_id: "live", channel_id: "C0BJ1699HSN", shadow: false}} =
             Routes.resolve(gcp_event(), :live)

    assert {:error, {:unapproved_route_environment, "live", "staging"}} =
             Routes.resolve(gcp_event("open", project: "example-staging-project"), :live)
  end

  test "live delivery rejects a missing, private, or malformed destination" do
    slack = SystemsRuntime.fetch_env!(:alert_router, :slack)

    for channel_id <- [nil, "", "GPRIVATE", "Cbad-channel"] do
      SystemsRuntime.put_env(
        :alert_router,
        :slack,
        Keyword.put(slack, :routes, %{"live" => channel_id})
      )

      assert {:error, _reason} =
               Routes.resolve(gcp_event("open", project: "example-staging-project"), :live)
    end
  end

  test "shadow remains pinned to xp-test" do
    slack = SystemsRuntime.fetch_env!(:alert_router, :slack)

    SystemsRuntime.put_env(
      :alert_router,
      :slack,
      Keyword.put(slack, :routes, %{"shadow" => "C0BJ1699HSN"})
    )

    assert {:error, {:unapproved_route_destination, "shadow", "C0BJ1699HSN"}} =
             Routes.resolve(gcp_event(), :shadow)
  end
end
