defmodule Comma.MemberSourceConsents do
  @moduledoc """
  The exact Composio account a member authorized through Comma installation.

  A receipt proves consent provenance, not provider identity or current read
  permission. Verified install completion or an owner's confirmed account choice writes it. It does not create
  a Routine profile, change its schedule, or make a provider request.
  """

  import Ecto.Query
  alias Comma.{Repo, Workspaces}
  alias Comma.Data.MemberSourceConsent

  def record(user, session, workspace_id, toolkit, connection_id)
      when toolkit in ~w(gmail googlecalendar googledrive slack github linear) and
             is_binary(connection_id) and byte_size(connection_id) in 1..256 do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      now = DateTime.utc_now()
      previous = connection_id(workspace_id, user["id"], toolkit)

      %MemberSourceConsent{
        workspace_id: workspace_id,
        user_id: user["id"],
        toolkit: toolkit,
        connection_id: connection_id,
        inserted_at: now,
        updated_at: now
      }
      |> Repo.insert(
        conflict_target: [:workspace_id, :user_id, :toolkit],
        on_conflict: {:replace, [:connection_id, :updated_at]}
      )
      |> case do
        {:ok, _receipt} ->
          # A rebound app no longer authorizes the earlier account's items.
          if previous not in [nil, connection_id],
            do: Comma.MemberSourceItems.purge_source(workspace_id, previous, user["id"])

          {:ok, :ok}

        {:error, _changeset} ->
          {:error, :member_source_consent_unavailable}
      end
    end
  end

  def record(_user, _session, _workspace_id, _toolkit, _connection_id),
    do: {:error, :invalid_member_source_consent}

  # Called after an authorized Comma disconnect, only for the deleted account.
  # Revocation also deletes the account's pooled source items.
  def forget_connection(workspace_id, connection_id) do
    from(receipt in MemberSourceConsent,
      where: receipt.workspace_id == ^workspace_id and receipt.connection_id == ^connection_id
    )
    |> Repo.delete_all()

    Comma.MemberSourceItems.purge_source(workspace_id, connection_id)
  end

  def forget_toolkits(workspace_id, toolkits) do
    from(receipt in MemberSourceConsent,
      where: receipt.workspace_id == ^workspace_id and receipt.toolkit in ^toolkits
    )
    |> Repo.delete_all()

    Comma.MemberSourceItems.purge_toolkits(workspace_id, toolkits)
  end

  def binding(workspace_id, user_id, toolkit) do
    case Repo.get_by(MemberSourceConsent,
           workspace_id: workspace_id,
           user_id: user_id,
           toolkit: toolkit
         ) do
      %MemberSourceConsent{} = receipt ->
        %{
          "connection_id" => receipt.connection_id,
          "consent_revision" => DateTime.to_iso8601(receipt.updated_at)
        }

      nil ->
        nil
    end
  end

  # Source discovery reads the member's bindings in one bounded query. The
  # returned map is private; provider access still checks each live account.
  def bindings(workspace_id, user_id) do
    from(receipt in MemberSourceConsent,
      where: receipt.workspace_id == ^workspace_id and receipt.user_id == ^user_id,
      select: {receipt.toolkit, receipt.connection_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Internal projection only. Callers must separately authorize the workspace
  # and check the current provider account before they use this connection.
  def connection_id(workspace_id, user_id, toolkit) do
    case Repo.get_by(MemberSourceConsent,
           workspace_id: workspace_id,
           user_id: user_id,
           toolkit: toolkit
         ) do
      %MemberSourceConsent{connection_id: id} -> id
      nil -> nil
    end
  end
end
