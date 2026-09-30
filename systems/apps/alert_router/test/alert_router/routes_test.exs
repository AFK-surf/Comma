defmodule AlertRouter.RoutesTest do
  use ExUnit.Case, async: false

  alias AlertRouter.Routes

  import AlertRouter.TestFixtures

  setup do
    previous = Application.fetch_env!(:alert_router, :slack)
    on_exit(fn -> Application.put_env(:alert_router, :slack, previous) end)
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

  test "live delivery rejects production events in the staging-only route" do
    assert {:error, {:unapproved_route_environment, "live", "production"}} =
             Routes.resolve(gcp_event(), :live)
  end

  test "live delivery rejects a missing, private, or malformed destination" do
    slack = Application.fetch_env!(:alert_router, :slack)

    for channel_id <- [nil, "", "GPRIVATE", "Cbad-channel"] do
      Application.put_env(
        :alert_router,
        :slack,
        Keyword.put(slack, :routes, %{"live" => channel_id})
      )

      assert {:error, _reason} =
               Routes.resolve(gcp_event("open", project: "example-staging-project"), :live)
    end
  end

  test "shadow remains pinned to xp-test" do
    slack = Application.fetch_env!(:alert_router, :slack)

    Application.put_env(
      :alert_router,
      :slack,
      Keyword.put(slack, :routes, %{"shadow" => "C0BJ1699HSN"})
    )

    assert {:error, {:unapproved_route_destination, "shadow", "C0BJ1699HSN"}} =
             Routes.resolve(gcp_event(), :shadow)
  end
end
