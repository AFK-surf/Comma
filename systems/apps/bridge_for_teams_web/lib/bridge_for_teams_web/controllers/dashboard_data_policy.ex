defmodule BridgeForTeamsWeb.DashboardDataPolicy do
  @moduledoc """
  The Data policy page for `DashboardAPIController`: what the assistant may
  carry between conversations of one Agent Swarm (`docs/verification.md`
  §3.6, §10).

  `BridgeForTeams.InformationFlow` resolves the Agent Swarm inside the org
  before any group id reaches Salix, so a forged id cannot write another
  organization's settings. The controller admits owners and admins only. Every
  write answers with the settings read again, because the reader is looking at
  the row they changed. Salix returns at most 200 rows per list and connect,
  and flags a connect with more as `truncated`.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.InformationFlow

  @doc "Every setting of one Agent Swarm, by chat workspace, and its SSH hosts."
  def overview(org, project_id) do
    case InformationFlow.overview(org, project_id) do
      {:ok, overview} ->
        {:ok,
         overview
         |> Map.take(~w(mode language audience_modes))
         |> Map.put("supervisors", Enum.flat_map(overview["supervisors"] || [], &supervisor/1))
         |> Map.put("connects", Enum.map(overview["connects"] || [], &public_connect/1))
         |> Map.merge(ssh_hosts(overview["ssh_hosts"]))}

      {:error, :project_not_found} ->
        error(:project_not_found)

      {:error, _reason} ->
        {:error, 503, "runtime_unavailable",
         gettext("These settings could not be read just now. Nothing has changed."), %{}}
    end
  end

  @doc """
  The people of one connect for the person picker: by `query` (name, email
  or id), or the names and emails of `ids` (comma-separated) the overview
  showed without one.
  """
  def people(org, project_id, connect_id, %{"query" => query}) when is_binary(query) do
    case InformationFlow.people(org, project_id, connect_id, query) do
      {:ok, people} -> {:ok, %{"people" => Enum.map(people, &public_person/1)}}
      {:error, reason} -> error(reason)
    end
  end

  def people(org, project_id, connect_id, %{"ids" => ids}) when is_binary(ids) do
    ids = ids |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case InformationFlow.describe_people(org, project_id, connect_id, ids) do
      {:ok, people} ->
        {:ok, %{"people" => Map.new(people, fn {id, p} -> {id, public_person(p)} end)}}

      {:error, reason} ->
        error(reason)
    end
  end

  def people(_org, _project_id, _connect_id, _params), do: error(:invalid_query)

  @doc "Apply one change, then read the settings again."
  def change(org, project_id, change, params) do
    case apply_change(org, project_id, change, params) do
      :ok -> overview(org, project_id)
      {:ok, _result} -> overview(org, project_id)
      {:error, reason} -> error(reason)
    end
  end

  # The mode is written through the group control API, which validates it;
  # the language is a separate settings write that leaves the mode alone.
  defp apply_change(org, id, :group, %{"mode" => mode}),
    do: InformationFlow.set_mode(org, id, mode)

  defp apply_change(org, id, :group, %{"language" => language}),
    do: InformationFlow.set_language(org, id, language)

  defp apply_change(org, id, :group, %{"supervisors" => supervisors}),
    do: InformationFlow.set_supervisors(org, id, supervisors)

  defp apply_change(_org, _id, :group, _params), do: {:error, :invalid_mode}

  defp apply_change(org, id, :classify, params) do
    InformationFlow.put_scope_label(org, id, params["connect_id"], params["scope_id"], %{
      "tags" => tags(params["tags"]),
      "audience_mode" => params["audience_mode"],
      "sealed" => params["sealed"] == true
    })
  end

  defp apply_change(org, id, :reset, params),
    do: InformationFlow.delete_scope_label(org, id, params["connect_id"], params["scope_id"])

  defp apply_change(org, id, :grant, params),
    do:
      InformationFlow.put_tag_clearance(
        org,
        id,
        params["connect_id"],
        params["tag"],
        params["user"]
      )

  defp apply_change(org, id, :withdraw, params) do
    InformationFlow.delete_tag_clearance(
      org,
      id,
      params["connect_id"],
      params["tag"],
      params["principal"]
    )
  end

  # A blank placement drops the override and restores the provider's answer.
  defp apply_change(org, id, :place, params) do
    placement = if params["placement"] in ["internal", "external"], do: params["placement"]

    InformationFlow.put_placement_override(
      org,
      id,
      params["connect_id"],
      params["user_id"],
      placement
    )
  end

  # Restricts one SSH host key to a tag, or lifts it with a blank tag.
  defp apply_change(org, id, :ssh_host, params),
    do: InformationFlow.restrict_ssh_host(org, id, params["fingerprint"], params["tag"])

  # One unavailable read leaves the rest of the page usable, as one
  # unavailable connect does.
  defp ssh_hosts({:ok, hosts}) when is_list(hosts),
    do: %{"ssh_hosts_available" => true, "ssh_hosts" => Enum.map(hosts, &public_ssh_host/1)}

  defp ssh_hosts(_unavailable), do: %{"ssh_hosts_available" => false, "ssh_hosts" => []}

  defp public_ssh_host(host) do
    %{
      "name" => host["name"],
      "key_type" => host["key_type"],
      "fingerprint" => host["fingerprint"],
      "first_seen_at" => host["first_seen_at"],
      "tag" => host["ifc_tag"]
    }
  end

  defp public_connect(connect) do
    connect
    |> Map.take(~w(connect_id provider name available scopes clearances truncated))
    |> Map.put(
      "principals",
      for principal <- connect["principals"] || [] do
        %{
          "id" => principal["user_id"],
          "observed" => principal["placement_observed"],
          "override" => principal["placement_override"]
        }
      end
    )
  end

  defp public_person(person), do: Map.take(person, ~w(id name email))

  defp supervisor(key) do
    case String.split(key, "|", parts: 3) do
      ["provider_user", connect_id, user_id] -> [%{"connect_id" => connect_id, "id" => user_id}]
      _other -> []
    end
  end

  defp tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp tags(_tags), do: []

  defp error(:project_not_found),
    do:
      {:error, 404, "project_not_found", gettext("That Agent Swarm is no longer available."), %{}}

  defp error(:connect_not_found),
    do:
      {:error, 404, "connect_not_found",
       gettext("That connect is no longer part of this organization."), %{}}

  defp error(:scope_not_found),
    do:
      {:error, 404, "scope_not_found",
       gettext("That conversation is no longer available. Refresh the page."), %{}}

  defp error(:directory_incomplete),
    do:
      {:error, 503, "directory_incomplete",
       gettext(
         "The directory could not be read in full, so this person may still exist. Search by email, or check the app's contacts permission range."
       ), %{}}

  defp error(reason) when reason in [:unavailable, :timeout, :tenant_not_ready],
    do:
      {:error, 503, "runtime_unavailable",
       gettext("These settings could not be read just now. Nothing has changed."), %{}}

  defp error(reason) do
    case invalid_message(reason) do
      nil -> {:error, 500, "write_failed", gettext("That change could not be saved."), %{}}
      message -> {:error, 422, "invalid_data_policy", message, %{}}
    end
  end

  defp invalid_message(:invalid_tag),
    do: gettext("A tag cannot be empty or contain the | character.")

  defp invalid_message(:invalid_fingerprint), do: gettext("Choose a host from the list.")
  defp invalid_message(:invalid_audience_mode), do: gettext("Choose a valid audience.")
  defp invalid_message(:invalid_principal), do: gettext("Choose a person from the list.")
  defp invalid_message(:invalid_query), do: gettext("Type a name, email or user id to search.")
  defp invalid_message(:invalid_mode), do: gettext("Choose a valid mode.")
  defp invalid_message(:invalid_language), do: gettext("Choose a valid language.")
  defp invalid_message(_reason), do: nil
end
