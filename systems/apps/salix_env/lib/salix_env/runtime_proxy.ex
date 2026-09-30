defmodule SalixEnv.RuntimeProxy do
  @moduledoc """
  Server-side handler seam for connector-originated runtime capability requests.

  A connector may expose a local loopback capability URL to a hosted runtime. When
  that runtime calls the local URL, the connector sends a `runtime_proxy` request
  back over the connector protocol. The socket owner calls this module and returns
  the handler result to the connector as the matching response frame.
  """

  @callback handle(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}

  @spec handle(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def handle(env_id, params, meta \\ %{}) do
    handler().handle(env_id, params || %{}, meta || %{})
  end

  defp handler do
    Application.get_env(:salix_env, :runtime_proxy_handler, __MODULE__.Unconfigured)
  end

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixEnv.RuntimeProxy

    @impl true
    def handle(_env_id, _params, _meta), do: {:error, :not_configured}
  end
end
