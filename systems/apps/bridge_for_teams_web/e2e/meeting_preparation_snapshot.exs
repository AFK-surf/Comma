# Read-only local rendering of captured staging Dashboard responses.
# This file contains no staging data or credentials. The snapshot stays outside Git.
defmodule BridgeForTeamsWeb.MeetingPreparationSnapshot do
  alias BridgeForTeams.{Accounts, Memberships, Orgs, UserOnboardings}

  def start(path) do
    snapshot = path |> File.read!() |> Jason.decode!()
    stamp = System.system_time(:second)

    {:ok, user} =
      Accounts.create_user(%{
        "name" => "Staging preview",
        "email" => "meeting-staging-#{stamp}@example.test"
      })

    {:ok, user} = Accounts.update_locale(user, "zh_Hans")
    {:ok, onboarding} = UserOnboardings.ensure_onboarding(user.id)
    {:ok, _} = UserOnboardings.complete(onboarding)

    {:ok, org} =
      Orgs.create_org(%{
        "name" =>
          snapshot["organization_name"] <> " · Staging 只读快照 · " <> snapshot["captured_at"],
        "slug" => "meeting-staging-#{stamp}"
      })

    {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")

    project =
      BridgeForTeams.Repo.insert!(%BridgeForTeams.Schema.Project{
        org_id: org.id,
        name: snapshot["project_name"],
        slug: "staging-meeting-preview",
        salix_group_id: SalixStore.Ids.new_group_id(org.salix_tenant_id)
      })

    :persistent_term.put(
      {__MODULE__, :snapshot},
      Map.put(snapshot, "preview_group_id", project.salix_group_id)
    )

    Application.put_env(:bridge_for_teams_core, :salix_client, __MODULE__)

    url =
      "http://127.0.0.1:4411/dev/login?" <>
        URI.encode_query(%{
          "email" => user.email,
          "to" => "/orgs/#{org.slug}/meetings/settings?project=#{project.id}"
        })

    IO.puts("MEETING_PREVIEW_URL=" <> url)
    Process.sleep(:infinity)
  end

  def meeting_preparation(%{"group_id" => group, "action" => action, "attrs" => attrs}) do
    snapshot = :persistent_term.get({__MODULE__, :snapshot})

    if group == snapshot["preview_group_id"] do
      read(snapshot, action, attrs)
    else
      {:error, :project_not_found}
    end
  end

  defp read(snapshot, "history", attrs),
    do: result(get_in(snapshot, ["history_pages", attrs["cursor"] || "first"]))

  defp read(snapshot, "overview", _attrs), do: {:ok, snapshot["overview"]}

  defp read(snapshot, "catalog", attrs),
    do: result(get_in(snapshot, ["bots", attrs["connect_id"], "catalog"]))

  defp read(snapshot, "channels", attrs),
    do: result(get_in(snapshot, ["bots", attrs["connect_id"], "channel_pages", attrs["cursor"]]))

  defp read(_snapshot, _action, _attrs), do: {:error, :preview_read_only}
  defp result(nil), do: {:error, :unavailable}
  defp result(value), do: {:ok, value}

  # Keep local login and dashboard shell behavior; only the meeting read seam
  # consumes the snapshot. Every meeting write is rejected above.
  for {name, arity} <- BridgeForTeams.Salix.Erpc.__info__(:functions),
      name != :meeting_preparation do
    args = Macro.generate_arguments(arity, __MODULE__)
    defdelegate unquote(name)(unquote_splicing(args)), to: BridgeForTeams.Salix.Erpc
  end
end
