defmodule SalixIM.Ports.Organizations do
  @moduledoc """
  The organization a Salix tenant belongs to, as Salix IM reaches its owner
  (`BridgeForTeams.Orgs`, in the product). Salix cannot depend on the product,
  so the product sets the module at start (`config :salix_im, :organizations`).
  A tenant without one, or no module, has no name: `nil`.
  """

  @callback organization_name(tenant_id :: String.t()) :: String.t() | nil

  def name(tenant_id) when is_binary(tenant_id) do
    case SystemsRuntime.get_env(:salix_im, :organizations) do
      nil -> nil
      module -> module.organization_name(tenant_id)
    end
  end

  def name(_tenant_id), do: nil
end
