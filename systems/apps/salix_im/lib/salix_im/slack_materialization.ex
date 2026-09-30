defmodule SalixIM.SlackMaterialization do
  @moduledoc """
  Materializes a pre-authorized Slack installation into one group-scoped connect.

  The caller supplies the same app credentials and bot token that the normal OAuth
  flow would persist. Slack identity is resolved again with `auth.test`; no caller-
  supplied workspace or bot identity is trusted.
  """

  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.{GroupDirectory, ProviderConnects, ProviderIdentity}

  @required ~w(app_id client_id client_secret signing_secret bot_token inbound_agent_id)

  def materialize(tenant_id, group_id, attrs) when is_map(attrs) do
    with :ok <- require_attrs(attrs),
         {:ok, group} <- GroupDirectory.get_group(group_id, tenant_id),
         :ok <- require_group_router(group, attrs),
         {:ok, installation} <- verify_bot_installation(attrs),
         {:ok, connect} <- reuse_or_create_connect(tenant_id, group_id, attrs, installation) do
      {:ok, connect}
    end
  rescue
    error in SlackAPI.Error ->
      {:error, {:provider, "Slack auth.test failed: #{SlackAPI.error_message(error)}"}}
  end

  def materialize(_tenant_id, _group_id, _attrs),
    do: {:error, {:bad_request, "invalid request body"}}

  defp reuse_or_create_connect(tenant_id, group_id, attrs, installation) do
    app_id = trim(attrs["app_id"])

    case ProviderIdentity.find_reserved_slack_connect_by_app_id(app_id) do
      {:ok, connect} ->
        with :ok <- validate_reusable_connect(connect, tenant_id, group_id, attrs, installation),
             {:ok, _completed} <- ensure_oauth_completed(connect, installation) do
          ProviderConnects.get_im_connect_public(tenant_id, group_id, connect["connect_id"])
        end

      {:error, :not_found} ->
        create_and_complete(tenant_id, group_id, attrs, installation)

      # Competing live records with no explicit authority: the write
      # target would be decided by physical LIST order, so refuse
      # (round-13). The previous release surfaced the same situation as
      # an identity conflict from its create path.
      {:error, :ambiguous_identity} ->
        {:error,
         {:conflict,
          "Slack app_id is carried by multiple connects; settle the duplicates before reuse"}}

      # Resolver capacity rejection / storage faults are retryable
      # conditions, not "no reservation": propagate them instead of
      # falling into a conflicting create (round-12).
      {:error, _reason} = error ->
        error
    end
  end

  defp create_and_complete(tenant_id, group_id, attrs, installation) do
    create_attrs =
      attrs
      |> Map.take(~w(app_id client_id client_secret signing_secret inbound_agent_id app_name))
      |> Map.put("inbound_event_not_before_ms", installation["server_time_ms"])

    with {:ok, pending} <-
           ProviderConnects.create_slack_im_connect(tenant_id, group_id, create_attrs),
         {:ok, completed} <- complete_connect_oauth(group_id, pending, installation) do
      {:ok, completed}
    else
      error -> error
    end
  end

  defp complete_connect_oauth(group_id, %{"connect_id" => connect_id}, installation) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack") do
      ProviderConnects.complete_slack_im_connect_oauth(connect, installation)
    end
  end

  defp ensure_oauth_completed(connect, installation) do
    if (connect["oauth_completed_at"] || 0) > 0 do
      ProviderConnects.put_slack_bot_identity(
        connect,
        installation["bot_id"],
        installation["bot_user_id"],
        installation["bot_username"]
      )
    else
      ProviderConnects.complete_slack_im_connect_oauth(connect, installation)
    end
  end

  defp validate_reusable_connect(connect, tenant_id, group_id, attrs, installation) do
    cond do
      connect["tenant_id"] != tenant_id or connect["group_id"] != group_id ->
        {:error, {:conflict, "Slack app_id is already used by another group connect"}}

      trim(connect["inbound_agent_id"]) != trim(attrs["inbound_agent_id"]) ->
        {:error, {:conflict, "existing Slack connect uses a different inbound agent"}}

      trim(connect["workspace_id"]) not in ["", installation["workspace_id"]] ->
        {:error, {:conflict, "existing Slack connect uses a different workspace"}}

      trim(connect["bot_user_id"]) not in ["", installation["bot_user_id"]] ->
        {:error, {:conflict, "existing Slack connect uses a different bot user"}}

      true ->
        :ok
    end
  end

  defp verify_bot_installation(attrs) do
    bot_token = trim(attrs["bot_token"])
    {identity, response_date_ms} = SlackAPI.auth_test_with_response_date_ms(bot_token)
    bot_id = trim(identity["bot_id"])
    bot_user_id = trim(identity["user_id"])
    bot_username = trim(identity["user"])
    workspace_id = trim(identity["team_id"])

    cond do
      bot_id == "" or bot_user_id == "" or workspace_id == "" ->
        {:error, {:provider, "Slack auth.test response is missing bot or workspace identity"}}

      not is_integer(response_date_ms) or response_date_ms <= 0 ->
        {:error, {:provider, "Slack auth.test response is missing a valid server time"}}

      true ->
        {:ok,
         %{
           "bot_token" => bot_token,
           "bot_id" => bot_id,
           "bot_user_id" => bot_user_id,
           "bot_username" => bot_username,
           "workspace_id" => workspace_id,
           "workspace_name" => identity["team"],
           "enterprise_id" => identity["enterprise_id"],
           "owner_user_id" => identity["user_id"],
           "server_time_ms" => response_date_ms
         }}
    end
  end

  defp require_group_router(group, attrs) do
    inbound_agent_id = trim(attrs["inbound_agent_id"])

    if inbound_agent_id != "" and inbound_agent_id == trim(group["router_agent_id"]) do
      :ok
    else
      {:error, {:bad_request, "inbound_agent_id must be the group router"}}
    end
  end

  defp require_attrs(attrs) do
    missing = Enum.filter(@required, &(trim(attrs[&1]) == ""))

    if missing == [] do
      :ok
    else
      {:error, {:bad_request, "missing required fields: #{Enum.join(missing, ", ")}"}}
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
