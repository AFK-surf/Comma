defmodule BillingStripe.PortalSyncTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)

    previous =
      for key <- [:stripe_api, :portal_configuration_id],
          do: {key, Application.get_env(:billing_stripe, key)}

    Application.put_env(:billing_stripe, :stripe_api, __MODULE__.API)
    Application.delete_env(:billing_stripe, :portal_configuration_id)

    start_supervised!(%{
      id: __MODULE__.State,
      start: {Agent, :start_link, [fn -> %{} end, [name: __MODULE__.State]]}
    })

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:billing_stripe, key, value),
          else: Application.delete_env(:billing_stripe, key)
      end)
    end)

    :ok
  end

  test "bootstrap creates a disabled nondefault portal and rerun reuses it" do
    assert {:ok, %{action: :create}} =
             BillingStripe.PortalSync.sync(%{}, bootstrap: true, dry_run: true)

    assert Agent.get(__MODULE__.State, & &1) == %{}
    assert {:ok, portal} = BillingStripe.PortalSync.sync(%{}, bootstrap: true)
    assert portal.features.subscription_update.enabled == false
    assert portal.features.subscription_cancel.mode == "at_period_end"
    assert portal.login_page.enabled == false
    assert {:ok, again} = BillingStripe.PortalSync.sync(%{}, bootstrap: true)
    assert portal.id == again.id

    assert {:ok, %{action: :verified}} =
             BillingStripe.PortalSync.sync(%{}, bootstrap: true, dry_run: true, verify: true)
  end

  test "management convergence preserves disabled plan changes and repairs configuration drift" do
    catalog = Comma.Billing.PricingV1.catalog()
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.TestAPI)

    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })

    assert {:ok, _} = BillingStripe.sync_prices(catalog)
    Application.put_env(:billing_stripe, :stripe_api, __MODULE__.API)
    assert {:ok, initial} = BillingStripe.PortalSync.sync(%{}, bootstrap: true)
    Application.put_env(:billing_stripe, :portal_configuration_id, initial.id)
    assert {:ok, portal} = BillingStripe.PortalSync.sync(catalog)
    assert portal.features.subscription_update.enabled == false
    assert {:ok, _} = BillingStripe.PortalSync.sync(catalog, dry_run: true, verify: true)

    Agent.update(__MODULE__.State, fn state ->
      put_in(state[portal.id].business_profile.headline, "BFT")
    end)

    assert {:error, :portal_configuration_drift} =
             BillingStripe.PortalSync.sync(catalog, dry_run: true, verify: true)

    assert {:ok, _} = BillingStripe.PortalSync.sync(catalog)
    assert {:ok, _} = BillingStripe.PortalSync.sync(catalog, dry_run: true, verify: true)
  end

  test "an explicit default portal is never changed" do
    default = %{id: "bpc_bft", is_default: true, metadata: %{}}
    Agent.update(__MODULE__.State, &Map.put(&1, default.id, default))

    assert {:error, :portal_not_comma} =
             BillingStripe.PortalSync.sync(%{}, configuration_id: default.id, bootstrap: true)

    assert Agent.get(__MODULE__.State, & &1[default.id]) == default
  end

  defmodule API do
    def list_portal_configurations(_, _),
      do:
        {:ok,
         %{data: Agent.get(BillingStripe.PortalSyncTest.State, &Map.values/1), has_more: false}}

    def retrieve_portal_configuration(id, _, _),
      do: {:ok, Agent.get(BillingStripe.PortalSyncTest.State, & &1[id])}

    def create_portal_configuration(params, _) do
      portal =
        Map.merge(params, %{
          id: "bpc_comma",
          active: true,
          is_default: false
        })

      Agent.update(BillingStripe.PortalSyncTest.State, &Map.put(&1, portal.id, portal))
      {:ok, portal}
    end

    def update_portal_configuration(id, params, _) do
      Agent.get_and_update(BillingStripe.PortalSyncTest.State, fn state ->
        portal = Map.merge(state[id], params)
        {{:ok, portal}, Map.put(state, id, portal)}
      end)
    end
  end
end
