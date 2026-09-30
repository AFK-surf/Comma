defmodule CommaWeb.RecommendationSources do
  @moduledoc false

  alias CommaWeb.RecommendationSourceCatalog

  def discover(workspace), do: discover(workspace, nil, "generic", [])

  def discover(workspace, user_id, mode), do: discover(workspace, user_id, mode, [])

  def discover(
        %{"salix_tenant_id" => tenant_id, "default_group_id" => group_id} = workspace,
        user_id,
        mode,
        existing_sources
      )
      when mode in ~w(generic member) and is_list(existing_sources) do
    with :ok <- member_scope(workspace, user_id, mode),
         native = discover_oauth(tenant_id, group_id),
         {:ok, composio} <- discover_composio(workspace, user_id, mode, existing_sources, native) do
      {:ok,
       (native ++ composio)
       |> Enum.uniq_by(& &1["connectionId"])
       |> Enum.sort_by(&{&1["appName"], &1["label"], &1["connectionId"]})
       |> Enum.take(12)}
    end
  end

  defp member_scope(_, _, "generic"), do: :ok

  defp member_scope(%{"owner_user_id" => user_id}, user_id, "member")
       when is_binary(user_id),
       do: :ok

  defp member_scope(_, _, "member"), do: {:error, :forbidden}

  defp discover_oauth(_tenant_id, group_id) do
    group_id
    |> Salix.Control.OAuthBindings.list()
    |> Enum.filter(fn binding ->
      binding["provider"] in ~w(github linear notion slack) and
        binding["alias"] == binding["provider"] and binding["status"] == "active" and
        binding["enabled"] != false
    end)
    |> Enum.map(fn binding ->
      source(
        "managed_oauth",
        binding["provider"],
        binding["binding_id"],
        if(present?(binding["provider_account_name"]),
          do: binding["provider_account_name"],
          else: RecommendationSourceCatalog.app_name(binding["provider"])
        ),
        %{"toolkit" => binding["provider"]}
      )
    end)
  end

  defp discover_composio(
         %{"salix_tenant_id" => tenant_id, "default_group_id" => group_id} = workspace,
         user_id,
         mode,
         existing_sources,
         native
       ) do
    case Salix.Composio.list_all_group_connected_accounts(tenant_id, group_id) do
      {:ok, accounts} when is_list(accounts) ->
        bindings =
          if mode == "member",
            do: Comma.MemberSourceConsents.bindings(workspace["id"], user_id),
            else: %{}

        bindings =
          if Enum.any?(native, &(&1["appId"] == "slack")),
            do: Map.delete(bindings, "slack"),
            else: bindings

        {:ok,
         accounts
         |> Enum.filter(&(&1["user_id"] == group_id))
         |> Enum.flat_map(&usable_composio_account/1)
         |> Enum.reject(fn account ->
           account.toolkit == "slack" and Enum.any?(native, &(&1["appId"] == "slack"))
         end)
         |> selected_accounts(bindings, mode)
         |> Enum.map(&composio_source/1)}

      {:error, :not_configured} when mode == "member" ->
        if existing_composio_choice?(workspace["id"], user_id, existing_sources, native),
          do: {:error, {:composio_source_discovery_failed, :not_configured}},
          else: {:ok, []}

      {:error, :not_configured} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:composio_source_discovery_failed, reason}}

      other ->
        {:error, {:composio_source_discovery_failed, other}}
    end
  end

  defp existing_composio_choice?(workspace_id, user_id, sources, native) do
    slack_managed? = Enum.any?(native, &(&1["appId"] == "slack"))
    bindings = Comma.MemberSourceConsents.bindings(workspace_id, user_id)
    bindings = if slack_managed?, do: Map.delete(bindings, "slack"), else: bindings

    Enum.any?(sources, fn source ->
      source["kind"] == "composio" and
        not (slack_managed? and source["appId"] == "slack")
    end) or map_size(bindings) > 0
  end

  defp selected_accounts(accounts, _bindings, "generic"),
    do: newest_account_per_toolkit(accounts)

  defp selected_accounts(accounts, bindings, "member") do
    candidates = Map.new(newest_account_per_toolkit(accounts), &{&1.toolkit, &1})

    bindings
    |> Enum.reduce(candidates, fn {toolkit, id}, selected ->
      case Enum.find(accounts, &(&1.toolkit == toolkit and &1.id == id)) do
        nil -> Map.put(selected, toolkit, %{toolkit: toolkit, id: id})
        account -> Map.put(selected, toolkit, account)
      end
    end)
    |> Map.values()
  end

  defp usable_composio_account(account) when is_map(account) do
    status = clean(account["status"]) |> String.downcase()

    toolkit =
      clean(get_in(account, ["toolkit", "slug"]) || account["toolkit_slug"] || account["toolkit"])
      |> String.downcase()

    id = clean(account["id"] || account["connected_account_id"])

    if status in ["active", "connected", "ready"] and present?(toolkit) and present?(id) and
         RecommendationSourceCatalog.supported_composio_toolkit?(toolkit) and
         toolkit not in ~w(github linear notion),
       do: [%{toolkit: toolkit, id: id, connected_at: connected_at(account)}],
       else: []
  end

  defp usable_composio_account(_account), do: []

  # Composio can retain several active accounts after reauthorization. Select
  # the newest per toolkit to avoid duplicate facts. Without timestamps, the
  # first listed account wins. Native OAuth sources use Group bindings above.
  defp newest_account_per_toolkit(accounts) do
    accounts
    |> Enum.with_index()
    |> Enum.sort_by(fn {account, index} -> {-account.connected_at, index} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq_by(& &1.toolkit)
  end

  defp connected_at(account) do
    [account["created_at"], account["updated_at"]]
    |> Enum.find_value(0, fn
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp composio_source(%{toolkit: toolkit, id: id}),
    do: source("composio", toolkit, id, toolkit, %{"toolkit" => toolkit})

  defp source(kind, app, connection_id, label, private) do
    Map.merge(
      %{
        "appId" => app,
        "appName" => RecommendationSourceCatalog.app_name(app),
        "connectionId" => connection_id,
        "kind" => kind,
        "label" => label
      },
      private
    )
  end

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value), do: value |> to_string() |> String.trim()
  defp present?(value), do: is_binary(value) and value != ""
end
