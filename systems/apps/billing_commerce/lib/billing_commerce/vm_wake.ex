defmodule BillingCommerce.VMWake.SalixCloudVM do
  @moduledoc """
  Best-effort bridge from commerce grant issuance to the Salix VM reconciler.
  """

  @spec billing_grant_issued(map()) :: :ok
  def billing_grant_issued(_payload) do
    cloud_vm = Module.concat([:SalixWeb, :CloudVM])

    if Code.ensure_loaded?(cloud_vm) and function_exported?(cloud_vm, :sweep_once, 1) do
      _ = apply(cloud_vm, :sweep_once, [[entrypoint: "billing_commerce.grant_issued"]])
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
