defmodule SalixStore.ProviderCredentialsReadiness do
  @moduledoc """
  Process-local proof that the provider-credentials cutover (Composio settings +
  Feishu bot apps) has completed on this pod.

  Mirrors `SalixStore.TenantApiKeyReadiness`: the bounded check starts after
  `SalixStore.Repo` and stays false until the `provider_credentials_v1` marker
  exists. Kubernetes keeps the pod out of service (via
  `Comma.PodLifecycle.ready(:salix)`) until it is true, so request handlers read
  Postgres directly and never re-check the marker.
  """

  use GenServer

  alias SalixStore.ProviderCredentialsCutover

  @name __MODULE__
  @retry_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "True once the provider-credentials cutover marker is present; false otherwise."
  @spec ready?() :: boolean()
  def ready? do
    case Process.whereis(@name) do
      nil -> false
      pid -> GenServer.call(pid, :ready?)
    end
  catch
    :exit, _reason -> false
  end

  @impl true
  def init(_opts) do
    {:ok, check(%{ready?: false})}
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  @impl true
  def handle_info(:recheck, state), do: {:noreply, check(state)}

  defp check(state) do
    ready? = ProviderCredentialsCutover.marker_present?()
    unless ready?, do: Process.send_after(self(), :recheck, @retry_ms)
    %{state | ready?: ready?}
  end
end
