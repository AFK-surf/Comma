defmodule Salix.Bindings.EnvPublicURL do
  @moduledoc false

  @behaviour SalixEnv.Ports.PublicURL

  @impl true
  def connector_server_url do
    base = SalixWeb.Application.public_base_url() |> String.trim() |> String.trim_trailing("/")

    case base do
      "https://" <> rest -> "wss://" <> rest
      "http://" <> rest -> "ws://" <> rest
      other -> other
    end
  end
end
