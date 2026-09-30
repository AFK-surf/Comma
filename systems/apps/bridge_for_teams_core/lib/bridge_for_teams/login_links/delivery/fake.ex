defmodule BridgeForTeams.LoginLinks.Delivery.Fake do
  @moduledoc """
  In-memory `BridgeForTeams.LoginLinks.Delivery` for tests: no network,
  records deliveries in the process dictionary (parallel tests don't
  interfere; Phoenix.ConnTest dispatches in the test process). Injected via
  `config :bridge_for_teams_core, :login_link_delivery, BridgeForTeams.LoginLinks.Delivery.Fake`.

  `script_result/1` makes the next deliveries fail for error-path tests.
  """
  @behaviour BridgeForTeams.LoginLinks.Delivery

  @deliveries_key {__MODULE__, :deliveries}
  @result_key {__MODULE__, :result}

  @doc "Deliveries recorded for the current test process, oldest first."
  @spec deliveries() :: [%{email: String.t(), org_name: String.t(), url: String.t()}]
  def deliveries, do: Enum.reverse(Process.get(@deliveries_key, []))

  @doc "Override the result future deliveries return for the current test process."
  @spec script_result(:ok | {:error, term()}) :: :ok
  def script_result(result) do
    Process.put(@result_key, result)
    :ok
  end

  @impl true
  def configured?, do: true

  @impl true
  def deliver_login_link(email, org_name, url) do
    Process.put(@deliveries_key, [
      %{email: email, org_name: org_name, url: url} | Process.get(@deliveries_key, [])
    ])

    Process.get(@result_key, :ok)
  end
end
