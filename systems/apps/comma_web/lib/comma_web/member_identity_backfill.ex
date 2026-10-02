defmodule CommaWeb.MemberIdentityBackfill do
  @moduledoc """
  One-time repair of Routine member provenance on connections created before
  Comma recorded it (#1919): the member stamp on managed OAuth connections and
  the consent receipt for Composio accounts.

  `RecommendationMemberIdentity` reads a member's work only from a connection
  that names its Comma member. Older connections lack that stamp, so their
  Routine sources failed closed until the member reconnected. The owner
  decided that the system repairs this instead of the member.

  The authority for the stamp is Workspace membership: a Workspace with the
  owner as its only member, and a binding in that Workspace's default group,
  can only hold a connection the owner authorized through Comma. Any other
  shape is left for a reconnect. Writes use the store's `If-Match` update, so
  a concurrent token refresh is never overwritten.

  A Composio receipt also needs the toolkit to have exactly one active account
  (more than one leaves the choice to the owner) and, at write time, the
  provider's own identity read to accept it as a personal account.
  """

  import Ecto.Query

  require Logger

  alias Comma.Data.{RecommendationProfile, WorkspaceMembership}
  alias Comma.Repo
  alias Salix.Control.OAuthBindings

  @providers ~w(github linear notion slack)
  @composio_toolkits ~w(slack gmail googlecalendar googledrive)

  @page 100

  @doc """
  Lists the connections a stamp would repair. Writes only with `dry_run: false`.
  Each call reads at most `limit` profiles (default #{@page}) after the `after`
  profile ID; pass the returned `next_after` to continue until it is nil.
  """
  def run(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)
    limit = opts |> Keyword.get(:limit, @page) |> max(1) |> min(@page)

    profiles =
      RecommendationProfile
      |> order_by(asc: :id)
      |> then(fn query ->
        case Keyword.get(opts, :after) do
          nil -> query
          after_id -> where(query, [profile], profile.id > ^after_id)
        end
      end)
      |> limit(^limit)
      |> Repo.all()

    candidates =
      profiles
      |> Enum.flat_map(fn profile ->
        Enum.flat_map(profile.sources, &candidate(profile, &1))
      end)
      |> Enum.uniq_by(& &1["connection_id"])

    results = if dry_run, do: [], else: Enum.map(candidates, &repair/1)

    {:ok,
     %{
       "dry_run" => dry_run,
       "candidates" =>
         Enum.map(candidates, &Map.take(&1, ~w(app connection_id kind workspace_id))),
       "stamped" => Enum.count(results, &(&1 == :stamped)),
       "unchanged" => Enum.count(results, &(&1 == :unchanged)),
       "skipped" => Enum.count(results, &(&1 == :skipped)),
       "failed" => Enum.count(results, &match?({:error, _}, &1)),
       "next_after" => if(length(profiles) == limit, do: List.last(profiles).id)
     }}
  end

  defp candidate(profile, %{"kind" => "managed_oauth", "appId" => app} = source)
       when app in @providers do
    with {:ok, workspace} <- Comma.Workspaces.get(profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         true <- sole_member?(workspace["id"], profile.user_id),
         {:ok, binding} <-
           OAuthBindings.get(workspace["default_group_id"], source["connectionId"]),
         true <- binding["tenant_id"] == workspace["salix_tenant_id"],
         true <- binding["group_id"] == workspace["default_group_id"],
         true <- binding["provider"] == app and binding["alias"] == app,
         true <- binding["enabled"] != false,
         {:ok, connection} <- SalixStore.OAuth.get(binding["connection_id"]),
         true <- unstamped?(connection, workspace, app) do
      [
        %{
          "kind" => "managed_oauth",
          "app" => app,
          "connection_id" => binding["connection_id"],
          "tenant_id" => workspace["salix_tenant_id"],
          "user_id" => profile.user_id,
          "workspace_id" => workspace["id"]
        }
      ]
    else
      _ -> []
    end
  end

  defp candidate(profile, %{"kind" => "composio", "toolkit" => toolkit} = source)
       when toolkit in @composio_toolkits do
    with {:ok, workspace} <- Comma.Workspaces.get(profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         true <- sole_member?(workspace["id"], profile.user_id),
         nil <- Comma.MemberSourceConsents.binding(workspace["id"], profile.user_id, toolkit),
         {:ok, [%{"id" => id}]} <-
           CommaWeb.PluginConnections.active_member_accounts(workspace, toolkit),
         true <- id == source["connectionId"] do
      [
        %{
          "kind" => "composio",
          "app" => toolkit,
          "connection_id" => id,
          "profile_id" => profile.id,
          "user_id" => profile.user_id,
          "workspace" => workspace,
          "workspace_id" => workspace["id"]
        }
      ]
    else
      _ -> []
    end
  end

  defp candidate(_profile, _source), do: []

  # Every membership row counts, whatever its status: a member who left could
  # have authorized the connection.
  defp sole_member?(workspace_id, owner_id) do
    from(membership in WorkspaceMembership,
      where: membership.workspace_id == ^workspace_id,
      select: membership.user_id
    )
    |> Repo.all() == [owner_id]
  end

  defp unstamped?(connection, workspace, app) do
    is_nil(connection["comma_member"]) and connection["status"] == "active" and
      connection["provider"] == app and connection["tenant"] == workspace["salix_tenant_id"]
  end

  defp repair(%{"kind" => "composio"} = candidate) do
    %{"workspace" => workspace, "app" => toolkit, "connection_id" => id} = candidate
    user = %{"id" => candidate["user_id"]}

    with {:ok, _identity} <-
           CommaWeb.RecommendationComposioMemberSource.identify(workspace, toolkit, id),
         nil <- Comma.MemberSourceConsents.binding(workspace["id"], user["id"], toolkit),
         {:ok, :ok} <- Comma.MemberSourceConsents.record(user, %{}, workspace["id"], toolkit, id) do
      _ = Comma.Recommendations.enqueue_source_sync(candidate["profile_id"])
      :stamped
    else
      %{} ->
        :unchanged

      # A bot account is not the member's own; the owner chooses another.
      {:error, :member_account_not_personal} ->
        :skipped

      {:error, reason} = error ->
        Logger.warning(
          "member identity backfill failed connection=#{id} reason=#{inspect(reason, limit: 3)}"
        )

        error
    end
  end

  defp repair(candidate), do: stamp(candidate)

  defp stamp(candidate) do
    member = %{"user_id" => candidate["user_id"], "workspace_id" => candidate["workspace_id"]}

    candidate["connection_id"]
    |> SalixStore.OAuth.update(fn connection ->
      if is_nil(connection["comma_member"]) and connection["tenant"] == candidate["tenant_id"],
        do: {:ok, Map.put(connection, "comma_member", member)},
        else: :skip
    end)
    |> case do
      {:ok, _connection} ->
        :stamped

      :skipped ->
        :unchanged

      {:error, reason} = error ->
        Logger.warning(
          "member identity backfill failed connection=#{candidate["connection_id"]} " <>
            "reason=#{inspect(reason, limit: 3)}"
        )

        error
    end
  end
end
