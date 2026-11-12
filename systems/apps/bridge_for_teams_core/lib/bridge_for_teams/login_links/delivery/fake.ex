defmodule BridgeForTeams.LoginLinks.Delivery.Fake do
  @moduledoc """
  In-memory `BridgeForTeams.LoginLinks.Delivery` for tests: no network,
  records deliveries in the process dictionary (parallel tests don't
  interfere; Phoenix.ConnTest dispatches in the test process). Injected via
  `config :bridge_for_teams_core, :login_link_delivery, BridgeForTeams.LoginLinks.Delivery.Fake`.

  `script_result/1` makes the next deliveries fail for error-path tests;
  `script_evidence/2` sets what the provider lookups answer.
  """
  @behaviour BridgeForTeams.LoginLinks.Delivery

  @deliveries_key {__MODULE__, :deliveries}
  @result_key {__MODULE__, :result}
  @evidence_key {__MODULE__, :evidence}

  @doc "Deliveries recorded for the current test process, oldest first."
  @spec deliveries() :: [%{email: String.t(), org_name: String.t(), url: String.t()}]
  def deliveries, do: Enum.reverse(Process.get(@deliveries_key, []))

  @doc "Override the result future deliveries return for the current test process."
  @spec script_result(:ok | {:error, term()}) :: :ok
  def script_result(result) do
    Process.put(@result_key, result)
    :ok
  end

  @doc """
  Override what `message_events/1` (`:message_events`) or
  `recipient_suppression/1` (`:suppression`) answer for the current test process.
  """
  @spec script_evidence(:message_events | :suppression, {:ok, term()} | {:error, term()}) :: :ok
  def script_evidence(kind, result) when kind in [:message_events, :suppression] do
    Process.put({@evidence_key, kind}, result)
    :ok
  end

  @impl true
  def configured?, do: true

  @impl true
  def deliver_login_link(email, org_name, url) do
    Process.put(@deliveries_key, [
      %{email: email, org_name: org_name, url: url} | Process.get(@deliveries_key, [])
    ])

    deliveries = Process.get(@deliveries_key)
    Process.get(@result_key, {:ok, %{provider_message_id: "fake-message-#{length(deliveries)}"}})
  end

  @impl true
  def message_events(_provider_message_id),
    do: Process.get({@evidence_key, :message_events}, {:ok, %{status: "Sent", events: []}})

  @impl true
  def recipient_suppression(_email), do: Process.get({@evidence_key, :suppression}, {:ok, nil})
end
