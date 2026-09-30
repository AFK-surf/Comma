defmodule Salix.Drive.Handle do
  @moduledoc """
  One group's Drive as `Salix.Drive.Files` reaches it: the control plane
  origin, the org slug and network the file API routes by, the space the
  group's devices publish, and the org API key.

  Holds a bearer secret: never log, encode, or store a handle. `inspect/1`
  redacts the token.
  """

  @derive {Inspect, except: [:token]}
  @enforce_keys [:group_id, :base_url, :org_slug, :network, :space, :token]
  defstruct [:group_id, :base_url, :org_slug, :network, :space, :token, req_options: []]

  @type t :: %__MODULE__{
          group_id: String.t(),
          base_url: String.t(),
          org_slug: String.t(),
          network: String.t(),
          space: String.t(),
          token: String.t(),
          req_options: keyword()
        }
end
