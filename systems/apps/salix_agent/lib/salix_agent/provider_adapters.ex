defmodule SalixAgent.ProviderAdapters do
  @moduledoc """
  What a source needs on each request beyond its endpoint and key. A Profile
  holds only those two; a provider that also asks for a header gets it here,
  so no operator types it.

    * `lmhub`: the internal LMHub gateway admits a deployment by its user
      agent, `SALIX_LMHUB_USER_AGENT` (config `:lmhub_user_agent`).
  """

  @doc "The headers a source's requests carry."
  @spec headers(String.t() | nil) :: map()
  def headers("lmhub") do
    case SystemsRuntime.get_env(:salix_agent, :lmhub_user_agent) do
      agent when is_binary(agent) and agent != "" -> %{"user-agent" => agent}
      _ -> %{}
    end
  end

  def headers(_source), do: %{}
end
