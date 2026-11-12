defmodule Comma.MemberSourceConsents do
  @moduledoc """
  The exact Composio accounts a member authorized through Comma installation.

  A member can consent to several accounts of one toolkit, such as a work and
  a personal Gmail; each receipt names one connected account, and each
  consented account is its own member source.

  A receipt proves consent provenance, not provider identity or current read
  permission. Verified install completion or an owner's confirmed account choice writes it. It does not create
  a Routine profile, change its schedule, or make a provider request.
  """

  import Ecto.Query
  alias Comma.{Repo, Workspaces}
  alias Comma.Data.MemberSourceConsent

  @toolkits ~w(gmail outlook googlecalendar googledrive slack github linear)

  @doc """
  Records the member's consent to one connected account of a toolkit, with
  the provider identity it was checked against when known (`subject`).
  """
  def record(user, session, workspace_id, toolkit, connection_id, subject \\ nil)

  def record(user, session, workspace_id, toolkit, connection_id, subject)
      when toolkit in @toolkits and is_binary(connection_id) and
             byte_size(connection_id) in 1..256 and (is_nil(subject) or is_map(subject)) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      now = SystemsClock.utc_now()

      %MemberSourceConsent{
        workspace_id: workspace_id,
        user_id: user["id"],
        toolkit: toolkit,
        connection_id: connection_id,
        provider_subject: subject,
        inserted_at: now,
        updated_at: now
      }
      |> Repo.insert(
        conflict_target: [:workspace_id, :user_id, :toolkit, :connection_id],
        on_conflict:
          if(subject,
            do: {:replace, [:updated_at, :provider_subject]},
            else: {:replace, [:updated_at]}
          )
      )
      |> case do
        {:ok, _receipt} -> {:ok, :ok}
        {:error, _changeset} -> {:error, :member_source_consent_unavailable}
      end
    end
  end

  def record(_user, _session, _workspace_id, _toolkit, _connection_id, _subject),
    do: {:error, :invalid_member_source_consent}

  @doc """
  Moves one receipt to the account that replaced it, such as after an OAuth
  reconnection of the same provider account. The earlier account's items no
  longer have consent and are deleted.
  """
  def replace(user, session, workspace_id, toolkit, previous_id, connection_id)
      when is_binary(previous_id) and previous_id != connection_id do
    with {:ok, :ok} <- record(user, session, workspace_id, toolkit, connection_id) do
      forget(workspace_id, user["id"], toolkit, previous_id)
      {:ok, :ok}
    end
  end

  def replace(user, session, workspace_id, toolkit, _previous_id, connection_id),
    do: record(user, session, workspace_id, toolkit, connection_id)

  @doc """
  Makes `connection_id` the toolkit's only consented account, as the owner's
  account choice in Plugins does: the toolkit's other receipts and their
  items go.
  """
  def switch(user, session, workspace_id, toolkit, connection_id, subject \\ nil) do
    with {:ok, :ok} <- record(user, session, workspace_id, toolkit, connection_id, subject) do
      for %{"connection_id" => other} <- toolkit_bindings(workspace_id, user["id"], toolkit),
          other != connection_id,
          do: forget(workspace_id, user["id"], toolkit, other)

      {:ok, :ok}
    end
  end

  @doc "Stores the provider identity a receipt was checked against."
  def put_subject(workspace_id, user_id, toolkit, connection_id, subject) when is_map(subject) do
    from(receipt in MemberSourceConsent,
      where:
        receipt.workspace_id == ^workspace_id and receipt.user_id == ^user_id and
          receipt.toolkit == ^toolkit and receipt.connection_id == ^connection_id
    )
    |> Repo.update_all(set: [provider_subject: subject])

    :ok
  end

  @doc "Removes one account's receipt and its pooled items."
  def forget(workspace_id, user_id, toolkit, connection_id) do
    from(receipt in MemberSourceConsent,
      where:
        receipt.workspace_id == ^workspace_id and receipt.user_id == ^user_id and
          receipt.toolkit == ^toolkit and receipt.connection_id == ^connection_id
    )
    |> Repo.delete_all()

    Comma.MemberSourceItems.purge_source(workspace_id, connection_id, user_id)
  end

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

  @doc "The member's receipt for one connected account of a toolkit, or nil."
  def binding(_workspace_id, _user_id, _toolkit, connection_id)
      when not is_binary(connection_id),
      do: nil

  def binding(workspace_id, user_id, toolkit, connection_id) do
    case Repo.get_by(MemberSourceConsent,
           workspace_id: workspace_id,
           user_id: user_id,
           toolkit: toolkit,
           connection_id: connection_id
         ) do
      %MemberSourceConsent{} = receipt -> view(receipt)
      nil -> nil
    end
  end

  @doc "The member's receipts for a toolkit, oldest consent first."
  def toolkit_bindings(workspace_id, user_id, toolkit) do
    from(receipt in MemberSourceConsent,
      where:
        receipt.workspace_id == ^workspace_id and receipt.user_id == ^user_id and
          receipt.toolkit == ^toolkit,
      order_by: [asc: receipt.inserted_at, asc: receipt.connection_id]
    )
    |> Repo.all()
    |> Enum.map(&view/1)
  end

  # Source discovery reads the member's bindings in one bounded query: each
  # toolkit with its consented account IDs, oldest consent first. The returned
  # map is private; provider access still checks each live account.
  def bindings(workspace_id, user_id) do
    from(receipt in MemberSourceConsent,
      where: receipt.workspace_id == ^workspace_id and receipt.user_id == ^user_id,
      order_by: [asc: receipt.inserted_at, asc: receipt.connection_id],
      select: {receipt.toolkit, receipt.connection_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp view(receipt),
    do: %{
      "connection_id" => receipt.connection_id,
      "consent_revision" => DateTime.to_iso8601(receipt.updated_at)
    }

  @doc "The member's receipts for a toolkit with the provider identity each was checked against."
  def toolkit_subjects(workspace_id, user_id, toolkit) do
    from(receipt in MemberSourceConsent,
      where:
        receipt.workspace_id == ^workspace_id and receipt.user_id == ^user_id and
          receipt.toolkit == ^toolkit,
      order_by: [asc: receipt.inserted_at, asc: receipt.connection_id],
      select: {receipt.connection_id, receipt.provider_subject}
    )
    |> Repo.all()
  end
end
