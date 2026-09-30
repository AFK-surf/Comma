defmodule BridgeForTeams.OrgSignalNumber do
  @moduledoc """
  The organization's own Signal number (docs/messaging-voice.md).

  An org maps 1:1 to a Salix tenant. Salix owns the setting
  (`Salix.Control.Signal`): a registered Signal account that the org's new
  Signal connections message instead of the platform number. BridgeForTeams
  owns org authorization, forwards the change over erpc and records an audit
  event. An empty number returns the org to the platform number. A client
  without the optional Signal callbacks yields `{:error, :unsupported}`.
  """
  require Logger

  alias BridgeForTeams.{Observability, Orgs}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Organization

  @doc "The org's Signal number view: `override`, `platform` and `effective`."
  @spec get(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def get(org_id) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      Client.call_optional(:get_signal_number, [org.salix_tenant_id])
    end
  end

  @doc "Sets (or with an empty number clears) the org's own Signal number."
  @spec put(Ecto.UUID.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def put(org_id, number, opts \\ []) do
    number = if is_binary(number), do: String.trim(number), else: ""

    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      case Client.call_optional(:put_signal_number, [org.salix_tenant_id, number]) do
        {:ok, view} ->
          with {:ok, _audit} <- record_audit(org, number, view, opts), do: {:ok, view}

        {:error, reason} = error ->
          Logger.warning("org_signal_number_save_failed reason=#{inspect(reason)}",
            org_id: org.id
          )

          error
      end
    end
  end

  defp record_audit(%Organization{} = org, number, view, opts) do
    if Keyword.get(opts, :actor_user_id) || Keyword.get(opts, :actor_label) do
      Observability.record_audit(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: "signal_number.saved",
        resource_type: "signal_number",
        resource_id: org.salix_tenant_id,
        resource_label: "signal",
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{"salix_tenant_id" => org.salix_tenant_id},
        redacted_diff: %{
          "number" => %{
            "from" => nil,
            "to" => if(number == "", do: nil, else: get_in(view, ["override", "e164"]))
          }
        }
      })
    else
      {:ok, nil}
    end
  end
end
