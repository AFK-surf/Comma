defmodule BridgeForTeams.DailyBrief.Members do
  @moduledoc """
  Links an organization's BFT users to their IM members for the daily brief:
  Slack members, or Feishu or Lark people, by the settings' provider. Each
  Swarm links through its own bot; a user stays one member per provider,
  whose brief one Swarm's bot sends (`project_id`).

  The Swarm's bot resolves each user's email in its workspace or tenant. A
  newly linked member starts with its names there as aliases; later runs
  keep the member's own alias edits. A user is linked once per provider, and
  only the settings' provider's members get a brief.
  """

  import Ecto.Query

  alias BridgeForTeams.{DailyBrief, Memberships, Repo}
  alias BridgeForTeams.DailyBrief.Scope
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting, Organization, Project}

  @batch 50

  @spec sync(DailyBriefSetting.t()) ::
          {:ok, %{linked: non_neg_integer(), unresolved: [String.t()]}} | {:error, term()}
  def sync(%DailyBriefSetting{} = settings) do
    with {:ok, source} <- source(settings) do
      users =
        settings.org_id
        |> Memberships.list_org_members()
        |> Enum.map(& &1.user)
        |> Enum.filter(&(is_binary(&1.email) and &1.status == "active"))

      by_email = Map.new(users, &{normalize(&1.email), &1})

      result =
        by_email
        |> Map.keys()
        |> Enum.chunk_every(@batch)
        |> Enum.reduce_while({:ok, %{linked: 0, unresolved: []}}, fn emails, {:ok, acc} ->
          case Salix.impl().daily_brief_lookup_members(Map.put(source, :emails, emails)) do
            {:ok, found} ->
              linked =
                Enum.count(found, fn {email, person} ->
                  match?({:ok, _}, link(settings, by_email[email], person))
                end)

              {:cont,
               {:ok,
                %{
                  linked: acc.linked + linked,
                  unresolved: acc.unresolved ++ Enum.reject(emails, &Map.has_key?(found, &1))
                }}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      with {:ok, _summary} <- result do
        if provider(settings) in ["feishu", "lark"] do
          sync_sibling_open_ids(settings, by_email)
        end

        result
      end
    end
  end

  defp sync_sibling_open_ids(settings, by_email) do
    provider = provider(settings)

    existing_by_user =
      Repo.all(
        from(m in DailyBriefMember,
          where: m.org_id == ^settings.org_id and m.provider == ^provider
        )
      )
      |> Map.new(&{&1.user_id, &1})

    target_emails =
      for {email, user} <- by_email,
          Map.has_key?(existing_by_user, user.id),
          do: email

    if target_emails != [] do
      Enum.reduce(Scope.sibling_settings(settings), existing_by_user, fn sibling, acc ->
        sync_one_sibling_open_ids(sibling, target_emails, by_email, acc)
      end)
    end

    :ok
  end

  defp sync_one_sibling_open_ids(sibling, emails, by_email, existing_by_user) do
    with {:ok, sibling_source} <- source(sibling) do
      emails
      |> Enum.chunk_every(@batch)
      |> Enum.reduce_while(existing_by_user, fn batch, acc ->
        case Salix.impl().daily_brief_lookup_members(Map.put(sibling_source, :emails, batch)) do
          {:ok, found} ->
            updated =
              Enum.reduce(found, acc, fn {email, person}, members_acc ->
                merge_sibling_open_id(members_acc, by_email[email], person)
              end)

            {:cont, updated}

          {:error, _reason} ->
            {:halt, acc}
        end
      end)
    else
      _unavailable -> existing_by_user
    end
  end

  defp merge_sibling_open_id(members_acc, %{id: user_id}, %{app_id: app_id, open_id: open_id})
       when is_binary(app_id) and is_binary(open_id) do
    case Map.get(members_acc, user_id) do
      %DailyBriefMember{} = member ->
        current = member.app_open_ids || %{}

        if Map.get(current, app_id) == open_id do
          members_acc
        else
          updated_map = Map.put(current, app_id, open_id)

          case member |> Ecto.Changeset.change(app_open_ids: updated_map) |> Repo.update() do
            {:ok, updated} -> Map.put(members_acc, user_id, updated)
            {:error, _} -> members_acc
          end
        end

      nil ->
        members_acc
    end
  end

  defp merge_sibling_open_id(members_acc, _user, _person), do: members_acc

  @doc """
  The Salix identity of the settings' Swarm and IM connection, with the
  provider that routes every read and post.
  """
  @spec source(DailyBriefSetting.t()) :: {:ok, map()} | {:error, :source_unavailable}
  def source(%DailyBriefSetting{org_id: org_id, project_id: project_id})
      when is_nil(org_id) or is_nil(project_id),
      do: {:error, :source_unavailable}

  def source(%DailyBriefSetting{} = settings) do
    with %Organization{salix_tenant_id: tenant_id} when is_binary(tenant_id) <-
           Repo.get(Organization, settings.org_id),
         %Project{salix_group_id: group_id, org_id: org_id} when is_binary(group_id) <-
           Repo.get(Project, settings.project_id),
         true <- org_id == settings.org_id do
      {:ok,
       %{
         tenant_id: tenant_id,
         group_id: group_id,
         provider: provider(settings),
         connect_id: connect_id(settings)
       }}
    else
      _missing -> {:error, :source_unavailable}
    end
  end

  @doc "The settings' provider; a setting from before providers is Slack's."
  @spec provider(DailyBriefSetting.t()) :: String.t()
  def provider(%DailyBriefSetting{provider: provider}) when provider in ["feishu", "lark"],
    do: provider

  def provider(_settings), do: "slack"

  @doc "The settings' connect: Slack's in `slack_connect_id`, Feishu's or Lark's in `connect_id`."
  @spec connect_id(DailyBriefSetting.t()) :: String.t() | nil
  def connect_id(%DailyBriefSetting{} = settings) do
    case provider(settings) do
      "slack" -> settings.slack_connect_id
      _lark -> settings.connect_id
    end
  end

  @doc """
  Enabled members of the settings' provider, with aliases, whichever Swarm
  sends their brief. Given an organization id, its current settings'
  provider (Slack without settings).
  """
  @spec enabled(DailyBriefSetting.t() | Ecto.UUID.t()) :: [DailyBriefMember.t()]
  def enabled(%DailyBriefSetting{org_id: org_id} = settings),
    do: enabled(org_id, provider(settings))

  def enabled(org_id) when is_binary(org_id) do
    case DailyBrief.get_settings(org_id) do
      %DailyBriefSetting{} = settings -> enabled(settings)
      nil -> enabled(org_id, "slack")
    end
  end

  defp enabled(org_id, provider) do
    Repo.all(
      from(m in DailyBriefMember,
        where: m.org_id == ^org_id and m.provider == ^provider and m.enabled,
        order_by: [asc: m.created_at, asc: m.id],
        preload: [:aliases]
      )
    )
  end

  # A user is one member per provider, whichever Swarms' bots find them. The
  # first Swarm to link them sends their brief, until it stops: a Swarm
  # whose settings are gone or off hands it to an enabled one that links
  # them. Every Feishu or Lark app that finds them keeps their open id there.
  defp link(settings, user, person) do
    provider = provider(settings)

    existing =
      Repo.get_by(DailyBriefMember, org_id: settings.org_id, user_id: user.id, provider: provider)

    attrs =
      provider
      |> member_attrs(settings, user, person)
      |> Map.put(:app_open_ids, app_open_ids(provider, existing, person))
      |> then(fn attrs ->
        if sends?(existing, settings),
          do: Map.put(attrs, :project_id, settings.project_id),
          else: Map.take(attrs, [:org_id, :user_id, :provider, :app_open_ids])
      end)

    with {:ok, member} <- DailyBrief.put_member(attrs) do
      if is_nil(existing) do
        DailyBrief.put_aliases(member, Enum.map(person.names, &%{term: &1, kind: "name"}))
      end

      {:ok, member}
    end
  end

  defp app_open_ids("slack", _existing, _person), do: %{}

  defp app_open_ids(_provider, existing, %{app_id: app_id, open_id: open_id}) do
    Map.put((existing && existing.app_open_ids) || %{}, app_id, open_id)
  end

  # Whether this Swarm's bot sends the member's brief from now on.
  defp sends?(nil, _settings), do: true
  defp sends?(%DailyBriefMember{project_id: nil}, _settings), do: true
  defp sends?(%DailyBriefMember{project_id: project_id}, %{project_id: project_id}), do: true

  defp sends?(%DailyBriefMember{} = member, %DailyBriefSetting{enabled: true} = settings) do
    case DailyBrief.get_settings(settings.org_id, member.project_id) do
      %DailyBriefSetting{enabled: true} = sending -> provider(sending) != provider(settings)
      _gone_or_off -> true
    end
  end

  defp sends?(_member, _settings), do: false

  defp member_attrs("slack", settings, user, slack) do
    %{
      org_id: settings.org_id,
      user_id: user.id,
      provider: "slack",
      slack_workspace_id: slack.workspace_id,
      slack_user_id: slack.slack_user_id,
      timezone: slack.timezone
    }
  end

  defp member_attrs(provider, settings, user, person) do
    %{
      org_id: settings.org_id,
      user_id: user.id,
      provider: provider,
      app_id: person.app_id,
      open_id: person.open_id,
      timezone: timezone(person.timezone)
    }
  end

  # A zone the clock does not know would make the member never due.
  defp timezone(zone) when is_binary(zone) do
    case DateTime.shift_zone(SystemsClock.utc_now(), zone) do
      {:ok, _local} -> zone
      _unknown -> "Etc/UTC"
    end
  end

  defp timezone(_zone), do: "Etc/UTC"

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
