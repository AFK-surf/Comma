defmodule BridgeForTeams.LarkSuiteTriage do
  @moduledoc """
  Feishu and Lark group triage for the BFT dashboard: the reads and writes of
  one Swarm's Router (`SalixIM.LarkSuiteTriage.Admin` over the Salix seam),
  the Swarm that holds a shared chat, and the access audit of a message-text
  reveal. Slack triage (`BridgeForTeams.Triage`) is separate.
  """

  require Logger

  alias BridgeForTeams.{Observability, Projects}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, User}

  @audit_action "integration.lark_suite.triage_text_revealed"
  @audit_resource_type "im_triage_message_text"

  @doc """
  Calls one admin function for the Router of `group_id` in `org`'s tenant.
  """
  @spec call(Organization.t(), String.t(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def call(%Organization{salix_tenant_id: tenant_id}, group_id, function, request)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) do
    Client.impl().lark_suite_triage(
      function,
      Map.merge(request, %{tenant_id: tenant_id, group_id: group_id})
    )
  end

  def call(_org, _group_id, _function, _request), do: {:error, :tenant_not_ready}

  @doc "The name of the org's project (Agent Swarm) whose Group is `group_id`, or nil."
  @spec swarm_name(Organization.t(), String.t() | nil) :: String.t() | nil
  def swarm_name(%Organization{id: org_id}, group_id) when is_binary(group_id) do
    org_id
    |> Projects.list_projects()
    |> Enum.find_value(&(&1.salix_group_id == group_id && &1.name))
  end

  def swarm_name(_org, _group_id), do: nil

  @doc """
  Records one access audit row per revealed message of `batch_id`. The text
  may be shown only after `:ok`.
  """
  @spec record_reveals(Organization.t(), User.t(), String.t(), String.t(), [String.t()]) ::
          :ok | {:error, :audit_failed}
  def record_reveals(%Organization{} = org, %User{} = user, batch_id, connect_id, message_ids)
      when is_binary(batch_id) and is_list(message_ids) and message_ids != [] do
    rows =
      Enum.map(message_ids, fn message_id ->
        %{
          org_id: org.id,
          actor_user_id: user.id,
          actor_label: user.email,
          action: @audit_action,
          resource_type: @audit_resource_type,
          resource_id: "#{batch_id}:#{message_id}",
          resource_label: "Feishu / Lark Triage",
          result: "ok",
          request_id: SystemsRuntime.Proc.uuid(),
          metadata: %{
            "batch_id" => batch_id,
            "message_id" => message_id,
            "connect_id" => connect_id,
            "surface" => "lark_triage_timeline"
          }
        }
      end)

    case audit_writer().(rows) do
      {:ok, _audits} ->
        :ok

      {:error, reason} ->
        Logger.warning("lark_suite_triage_reveal_audit_failed reason=#{inspect(reason)}")
        {:error, :audit_failed}
    end
  rescue
    _exception -> {:error, :audit_failed}
  end

  def record_reveals(_org, _user, _batch_id, _connect_id, _message_ids),
    do: {:error, :audit_failed}

  defp audit_writer,
    do:
      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :lark_suite_triage_audit_writer,
        &Observability.record_audits/1
      )
end
