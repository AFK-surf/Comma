defmodule BridgeForTeams.DailyBrief.DirectMessages do
  @moduledoc """
  A member's own choice to let their daily brief read their direct and group
  direct messages.

  Reading is off until the member turns it on with their own read-only Slack
  authorization. The brief reads the window's direct messages when it is
  written and stores none of them; only the written brief is kept. Turning it
  off stops reading at once and revokes the grant. A grant Slack reports as
  revoked turns it off too.
  """

  alias BridgeForTeams.DailyBrief.Members
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting}

  @doc """
  Starts the member's own Slack authorization. Returns the Slack URL to open.
  `return_url` receives the `state` query parameter when Slack returns.
  """
  @spec start_connect(DailyBriefSetting.t(), DailyBriefMember.t(), String.t()) ::
          {:ok, %{authorization_url: String.t(), state: String.t()}} | {:error, term()}
  def start_connect(%DailyBriefSetting{} = settings, %DailyBriefMember{} = member, return_url) do
    with :ok <- not_on(member),
         {:ok, source} <- Members.source(settings),
         {:ok, %{"authorization_url" => url, "state" => state}} <-
           Salix.impl().daily_brief_dm_start(%{
             tenant_id: source.tenant_id,
             group_id: source.group_id,
             connect_id: source.connect_id,
             bft_member: owner(member),
             redirect_after: return_url
           }) do
      {:ok, %{authorization_url: url, state: state}}
    end
  end

  @doc """
  Finishes an authorization that the same member started. The grant must come
  from the member's own Slack account; any other grant is deleted, not used.
  """
  @spec complete_connect(DailyBriefSetting.t(), DailyBriefMember.t(), String.t()) ::
          {:ok, DailyBriefMember.t()} | {:error, term()}
  def complete_connect(%DailyBriefSetting{} = settings, %DailyBriefMember{} = member, state) do
    with {:ok, source} <- Members.source(settings),
         {:ok, %{status: "completed"} = grant} <-
           Salix.impl().daily_brief_dm_result(%{
             tenant_id: source.tenant_id,
             state: state,
             bft_member: owner(member)
           }) do
      if grant.slack_user_id == member.slack_user_id and
           grant.slack_workspace_id == member.slack_workspace_id do
        # A grant that cannot be turned on is revoked, never left behind.
        with {:error, reason} <- enable(member, grant.connection_id) do
          _ = delete_grant(source, member, grant.connection_id)
          {:error, reason}
        end
      else
        _ = delete_grant(source, member, grant.connection_id)
        {:error, :slack_account_mismatch}
      end
    else
      {:ok, %{status: status}} -> {:error, {:authorization_not_completed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Turns direct messages off and revokes the member's grant."
  @spec disconnect(DailyBriefSetting.t(), DailyBriefMember.t()) ::
          {:ok, DailyBriefMember.t()} | {:error, term()}
  def disconnect(%DailyBriefSetting{} = settings, %DailyBriefMember{} = member) do
    connection_id = member.oauth_connection_id

    with {:ok, member} <- disable(member) do
      with true <- is_binary(connection_id),
           {:ok, source} <- Members.source(settings) do
        _ = delete_grant(source, member, connection_id)
      end

      {:ok, member}
    end
  end

  @doc """
  The member's direct and group direct messages in `window`, as the shared
  stream's message maps with `kind` set to "im" or "mpim". Empty when reading
  is off. A grant Slack reports as revoked turns reading off.
  """
  @spec read(DailyBriefSetting.t(), DailyBriefMember.t(), map()) ::
          {:ok, %{messages: [map()], complete?: boolean()}} | {:error, term()}
  def read(settings, %DailyBriefMember{dm_status: "on"} = member, %{after: from, before: to}) do
    with {:ok, source} <- Members.source(settings) do
      case Salix.impl().daily_brief_direct_messages(%{
             tenant_id: source.tenant_id,
             connection_id: member.oauth_connection_id,
             slack_user_id: member.slack_user_id,
             bft_member: owner(member),
             after_us: DateTime.to_unix(from, :microsecond),
             before_us: DateTime.to_unix(to, :microsecond)
           }) do
        {:ok, %{messages: messages, complete?: complete?}} ->
          {:ok, %{messages: Enum.map(messages, &message/1), complete?: complete?}}

        {:error, :grant_revoked} ->
          _ = disable(member)
          {:error, :grant_revoked}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def read(_settings, _member, _window), do: {:ok, %{messages: [], complete?: true}}

  defp message(m) do
    %{
      channel_id: m.channel_id,
      kind: m.kind,
      ts: m.ts,
      thread_ts: m.thread_ts,
      actor_kind: if(m.bot?, do: "bot", else: "user"),
      actor_id: m.author,
      subtype: nil,
      text: m.text,
      permalink: m.permalink
    }
  end

  @spec enable(DailyBriefMember.t(), String.t()) :: {:ok, DailyBriefMember.t()} | {:error, term()}
  def enable(%DailyBriefMember{} = member, oauth_connection_id)
      when is_binary(oauth_connection_id) and oauth_connection_id != "" do
    member
    |> DailyBriefMember.dm_changeset(%{dm_status: "on", oauth_connection_id: oauth_connection_id})
    |> Repo.update()
  end

  @spec disable(DailyBriefMember.t()) :: {:ok, DailyBriefMember.t()} | {:error, term()}
  def disable(%DailyBriefMember{} = member) do
    member
    |> DailyBriefMember.dm_changeset(%{dm_status: "off", oauth_connection_id: nil})
    |> Repo.update()
  end

  defp not_on(%DailyBriefMember{dm_status: "on"}), do: {:error, :dm_enabled}
  defp not_on(_member), do: :ok

  defp delete_grant(source, member, connection_id),
    do:
      Salix.impl().daily_brief_dm_delete(%{
        tenant_id: source.tenant_id,
        connection_id: connection_id,
        bft_member: owner(member)
      })

  defp owner(member), do: %{org_id: member.org_id, member_id: member.id, user_id: member.user_id}
end
