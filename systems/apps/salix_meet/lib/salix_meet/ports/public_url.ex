defmodule SalixMeet.Ports.PublicURL do
  @moduledoc """
  Public URL provider for meeting runtime callbacks.
  """

  @callback base_url() :: String.t()

  def base_url, do: impl().base_url()

  defp impl do
    Application.get_env(:salix_meet, :public_url_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.PublicURL

    @impl true
    def base_url, do: ""
  end
end
