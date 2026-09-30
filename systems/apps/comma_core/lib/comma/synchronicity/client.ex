defmodule Comma.Synchronicity.Client do
  @moduledoc """
  Behaviour for the Synchronicity server-to-server calls Comma makes under the
  provisioning secret, so the transport can be swapped for a stub in tests via
  `Application.get_env(:comma_core, :synchronicity_client, ...)`.
  """

  @type owner :: %{subject: String.t(), email: String.t(), name: String.t() | nil}

  @type ok ::
          {:ok,
           %{
             sync_org_id: String.t(),
             sync_org_slug: String.t() | nil,
             sync_network_id: String.t(),
             sync_user_id: String.t(),
             created: boolean()
           }}
  @type error ::
          {:error, :explicit_link_required}
          | {:error, :auth}
          | {:error, {:retryable, term()}}
          | {:error, {:invalid, term()}}

  @callback provision_workspace(
              workspace_id :: String.t(),
              workspace_name :: String.t(),
              owner :: owner()
            ) :: ok() | error()

  @type device_ok ::
          {:ok,
           %{
             device_id: String.t(),
             network: String.t(),
             domain: String.t(),
             created: boolean()
           }}
  @type device_error ::
          {:error, :not_provisioned}
          | {:error, :auth}
          | {:error, {:retryable, term()}}
          | {:error, {:invalid, term()}}

  @callback enroll_device(
              workspace_id :: String.t(),
              nk :: String.t(),
              label :: String.t(),
              owner :: owner()
            ) :: device_ok() | device_error()

  @typedoc """
  A freshly minted member org key for the Workspace's org. `token` exists only
  in this reply; the control plane keeps its hash.
  """
  @type key_ok ::
          {:ok,
           %{
             key_id: String.t(),
             token: String.t(),
             prefix: String.t(),
             org_id: String.t(),
             org_slug: String.t(),
             network: String.t(),
             expires_at: non_neg_integer()
           }}
  @type key_error ::
          {:error, :not_provisioned}
          | {:error, :auth}
          | {:error, {:retryable, term()}}
          | {:error, {:invalid, term()}}

  @callback mint_api_key(
              workspace_id :: String.t(),
              owner :: owner(),
              name :: String.t()
            ) :: key_ok() | key_error()

  @typedoc """
  `:not_found` means the key is already gone (or was never this Workspace's),
  which a caller converging on "this key no longer works" reads as done.
  """
  @type revoke_error ::
          {:error, :not_found}
          | {:error, :not_provisioned}
          | {:error, :auth}
          | {:error, {:retryable, term()}}
          | {:error, {:invalid, term()}}

  @callback revoke_api_key(workspace_id :: String.t(), key_id :: String.t()) ::
              :ok | revoke_error()
end
