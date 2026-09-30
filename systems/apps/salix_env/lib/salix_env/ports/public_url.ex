defmodule SalixEnv.Ports.PublicURL do
  @moduledoc """
  Public URL provider for connector install/connect responses.
  """

  @callback connector_server_url() :: String.t()

  def connector_server_url, do: impl().connector_server_url()

  defp impl do
    Application.get_env(:salix_env, :public_url_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixEnv.Ports.PublicURL

    @impl true
    def connector_server_url, do: ""
  end
end
