defmodule BridgeForTeams.Subscriptions do
  @moduledoc "Organization-authorized access to Salix subscription accounts and templates."
  alias BridgeForTeams.{Memberships, Orgs, Projects}
  alias BridgeForTeams.Salix.Client

  def authorize({org_id, user_id}) do
    with {:ok, org} <- Orgs.get_org(org_id),
         {:ok, role} when role in ["owner", "admin"] <- Memberships.org_role(org_id, user_id) do
      {:ok, org}
    else
      _ -> {:error, :forbidden}
    end
  end

  def list(scope, cursor), do: account(scope, :list, [cursor])

  def list_bindings({org_id, user_id} = scope, account_id, cursor \\ 0) do
    with {:ok, org} <- authorize(scope),
         {:ok, page} <-
           Client.impl().subscription_operation(
             org.salix_tenant_id,
             :list_bindings,
             [account_id, cursor]
           ) do
      {visible, hidden_count} =
        Enum.reduce(page["bindings"], {[], 0}, fn binding, {visible, hidden_count} ->
          case visible_binding(org_id, user_id, binding) do
            {:ok, projected} -> {[projected | visible], hidden_count}
            :hidden -> {visible, hidden_count + 1}
          end
        end)

      {:ok,
       %{
         "bindings" => Enum.reverse(visible),
         "hidden_count" => hidden_count,
         "next" => page["next"]
       }}
    end
  end

  def create(scope, %{"credential_kind" => "provider_api_key"} = attrs),
    do:
      account(scope, :create, [
        Map.take(attrs, ~w(credential_kind name connection credentials))
      ])

  def create(scope, attrs),
    do:
      account(scope, :create, [
        attrs
        |> Map.take(~w(provider credentials))
        |> Map.put("credential_kind", "subscription_oauth")
      ])

  def update(scope, id, attrs) do
    allowed =
      if Map.has_key?(attrs, "connection") or Map.has_key?(attrs, "name"),
        do: ~w(version name connection credentials),
        else: ~w(version disabled credentials)

    account(scope, :update, [id, Map.take(attrs, allowed)])
  end

  def delete(scope, id, version), do: account(scope, :delete, [id, version])
  def quota(scope, id), do: account(scope, :quota, [id])

  def reset_quota(scope, id, attrs),
    do: account(scope, :reset_quota, [id, Map.take(attrs, ~w(version request_id))])

  def begin_oauth(scope, attrs),
    do: account(scope, :begin_oauth, [Map.take(attrs, ~w(provider account_id version mode))])

  def complete_oauth(scope, id, attrs),
    do: account(scope, :complete_oauth, [id, Map.take(attrs, ~w(code))])

  defp account(scope, action, args) do
    with {:ok, org} <- authorize(scope) do
      Client.impl().subscription_operation(org.salix_tenant_id, action, args)
    end
  end

  defp visible_binding(org_id, user_id, %{"project_id" => project_id} = binding)
       when is_binary(project_id) do
    with {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org_id,
         :ok <- Memberships.authorize(user_id, :read, %{project_id: project_id}) do
      {:ok,
       binding
       |> Map.drop(["project_id", "group_id", "device_id", "device_runtime_id"])
       |> Map.put("project", %{
         "id" => project.id,
         "name" => project.name,
         "slug" => project.slug
       })}
    else
      _ -> :hidden
    end
  end

  defp visible_binding(_org_id, _user_id, _binding), do: :hidden

  def templates(scope) do
    with {:ok, org} <- authorize(scope) do
      Client.impl().private_template_operation(org.salix_tenant_id, :list, [])
    end
  end

  def discover_models(scope, pool) when pool in ["codex", "claude"] do
    with {:ok, org} <- authorize(scope) do
      Client.impl().private_template_operation(org.salix_tenant_id, :discover, [pool])
    end
  end

  def save_template(scope, id, attrs) do
    with {:ok, org} <- authorize(scope) do
      Client.impl().private_template_operation(org.salix_tenant_id, :save, [
        id,
        Map.take(
          attrs,
          ~w(name model model_display_name model_vendor subscription_provider max_tokens)
        )
      ])
    end
  end

  def delete_template(scope, id) do
    with {:ok, org} <- authorize(scope) do
      if id in [org.default_template_id, org.default_router_template_id] or
           id in (org.allowed_template_ids || []) do
        {:error,
         {:conflict,
          "Remove this template from the organization's default and allowed models first."}}
      else
        Client.impl().private_template_operation(org.salix_tenant_id, :delete, [id])
      end
    end
  end
end
