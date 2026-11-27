defmodule SalixAgent.Ports.OwnerAlerts do
  @moduledoc """
  Problems a Group's owners must fix, handed to the product that knows the
  owners and emails them (`BridgeForTeams.OwnerNotifications`). Salix cannot
  depend on the product, so the product sets the module at start
  (`config :salix_agent, :owner_alerts`). Without one, an alert goes nowhere.

  Kinds and their facts:

    * `"model_failing"` — an agent's model calls failed until its session
      parked. `ref` is the agent id; facts `"agent_id"`, `"category"`,
      `"status"` (HTTP status or `nil`) and `"quota_exhausted"`.
    * `"reauthorization_required"` — an OAuth connection's refresh was refused.
      `ref` is `"provider/alias"`; facts `"provider"` and `"alias"`.

  An alert never changes the caller's result: a failing or raising module is
  logged and ignored.
  """

  require Logger

  @callback owner_alert(
              group_id :: String.t(),
              kind :: String.t(),
              ref :: String.t(),
              facts :: map()
            ) :: :ok

  @spec notify(String.t() | nil, String.t(), String.t(), map()) :: :ok
  def notify(group_id, kind, ref, facts)
      when is_binary(group_id) and group_id != "" and is_binary(ref) and is_map(facts) do
    case SystemsRuntime.get_env(:salix_agent, :owner_alerts) do
      nil ->
        :ok

      module ->
        try do
          module.owner_alert(group_id, kind, ref, facts)
        rescue
          exception ->
            Logger.warning("owner_alert_failed kind=#{kind} #{Exception.message(exception)}")
        catch
          kind_of, reason ->
            Logger.warning(
              "owner_alert_failed kind=#{kind} #{kind_of} #{inspect(reason, limit: 5)}"
            )
        end

        :ok
    end
  end

  def notify(_group_id, _kind, _ref, _facts), do: :ok

  @doc "The Group an agent id belongs to (`agt1_<tenant>_<group>_<n>`), or `nil`."
  @spec group_of_agent(term()) :: String.t() | nil
  def group_of_agent("agt1_" <> rest) do
    case String.split(rest, "_") do
      [tenant, group, _agent] -> "grp1_" <> tenant <> "_" <> group
      _other -> nil
    end
  end

  def group_of_agent(_agent_id), do: nil
end
