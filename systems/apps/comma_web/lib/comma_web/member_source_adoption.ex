defmodule CommaWeb.MemberSourceAdoption do
  @moduledoc """
  In a Workspace whose owner is its only member, every active Composio
  account of a member toolkit in the default group is the owner's, also one
  the Router connected. Source discovery adopts each such account as a member
  source: each provider identity keeps one consent receipt, on its newest
  active connection, so a reconnected account that Composio keeps beside its
  replacement is not read twice. A shared Workspace adopts nothing; there
  only installation completion or the owner's confirmation records consent.
  """

  import Ecto.Query
  require Logger
  alias Comma.Data.WorkspaceMembership
  alias Comma.{MemberSourceConsents, Repo}
  alias CommaWeb.RecommendationComposioMemberSource

  @toolkits ~w(gmail googlecalendar googledrive outlook)

  @doc """
  Adopts the member toolkits' active `accounts` (`%{toolkit, id,
  connected_at}`, as source discovery lists them) and returns the member's
  bindings afterwards. Each provider identity keeps one receipt, on its newest
  active connection; a receipt of an older connection of that identity goes.
  Only accounts without a stored identity are read from the provider.
  """
  def adopt(workspace, user_id, accounts) do
    if adopts?(workspace, user_id) do
      accounts
      |> Enum.filter(&(&1.toolkit in @toolkits))
      |> Enum.group_by(& &1.toolkit)
      |> Enum.each(fn {toolkit, active} -> adopt_toolkit(workspace, user_id, toolkit, active) end)
    end

    MemberSourceConsents.bindings(workspace["id"], user_id)
  end

  defp adopt_toolkit(workspace, user_id, toolkit, active) do
    receipts = Map.new(MemberSourceConsents.toolkit_subjects(workspace["id"], user_id, toolkit))

    active
    |> Enum.map(fn account ->
      subject =
        case Map.fetch(receipts, account.id) do
          {:ok, stored} when is_map(stored) ->
            stored

          {:ok, nil} ->
            with subject when is_map(subject) <- subject(workspace, toolkit, account.id) do
              MemberSourceConsents.put_subject(
                workspace["id"],
                user_id,
                toolkit,
                account.id,
                subject
              )

              subject
            end

          :error ->
            subject(workspace, toolkit, account.id)
        end

      {account, subject}
    end)
    |> Enum.reject(fn {_account, subject} -> is_nil(subject) end)
    |> Enum.group_by(fn {_account, subject} -> subject end, fn {account, _} -> account end)
    |> Enum.each(fn {subject, connections} ->
      [newest | older] = Enum.sort_by(connections, &{-&1.connected_at, &1.id})

      # The older receipts go only once the newest connection holds one.
      adopted =
        Map.has_key?(receipts, newest.id) or
          case MemberSourceConsents.record(
                 %{"id" => user_id},
                 %{},
                 workspace["id"],
                 toolkit,
                 newest.id,
                 subject
               ) do
            {:ok, :ok} ->
              true

            {:error, reason} ->
              Logger.warning("member source adoption failed reason=#{inspect(reason)}")
              false
          end

      if adopted,
        do:
          for(
            account <- older,
            Map.has_key?(receipts, account.id),
            do: MemberSourceConsents.forget(workspace["id"], user_id, toolkit, account.id)
          )
    end)
  end

  # A bot account or one Comma cannot identify is not the owner's.
  defp subject(workspace, toolkit, id) do
    case RecommendationComposioMemberSource.identify(workspace, toolkit, id) do
      {:ok, %{"subject" => subject}} when is_map(subject) and map_size(subject) > 0 -> subject
      _ -> nil
    end
  end

  @doc "Whether the Workspace adopts the member's accounts: its owner is its only member."
  def adopts?(workspace, user_id),
    do: workspace["owner_user_id"] == user_id and sole_member?(workspace["id"], user_id)

  @doc "Whether the Workspace adopts the member's accounts of `toolkit`."
  def adopts?(workspace, user_id, toolkit),
    do: toolkit in @toolkits and adopts?(workspace, user_id)

  # Every membership row counts, whatever its status: a member who left could
  # have connected the account.
  defp sole_member?(workspace_id, owner_id) do
    from(membership in WorkspaceMembership,
      where: membership.workspace_id == ^workspace_id,
      select: membership.user_id
    )
    |> Repo.all() == [owner_id]
  end
end
