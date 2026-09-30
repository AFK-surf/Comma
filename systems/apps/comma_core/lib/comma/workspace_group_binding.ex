defmodule Comma.WorkspaceGroupBinding do
  @moduledoc """
  Canonical revision for a Workspace's Salix execution binding.

  The revision changes only when the Workspace's default Salix Group mapping
  changes. An explicit Group Router reassignment is resolved from the live
  control plane and intentionally does not create a new product Chat binding.
  """

  @spec revision(map()) :: String.t()
  def revision(%{
        "salix_tenant_id" => tenant_id,
        "default_group_id" => group_id
      }) do
    revision(tenant_id, group_id)
  end

  @spec revision(String.t(), String.t()) :: String.t()
  def revision(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    :crypto.hash(:sha256, Enum.join([tenant_id, group_id], ":"))
    |> Base.url_encode64(padding: false)
  end
end
