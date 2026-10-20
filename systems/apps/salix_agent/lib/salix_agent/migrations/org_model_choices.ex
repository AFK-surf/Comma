defmodule SalixAgent.Migrations.OrgModelChoices do
  @moduledoc """
  The model choice (`SalixAgent.ModelChoice`) that a BridgeForTeams
  Organization's stored template reference stands for. The BridgeForTeams
  migration that converts `allowed_template_ids`, `default_template_id` and
  `default_router_template_id` calls `choice/3` for each reference.

    * A Tenant-private subscription-pool template (`account_pool` codex or
      claude) stands for the catalog choice of its model, with its reasoning
      effort when the model takes it.
    * A Tenant-private own-endpoint template stands for the catalog choice of
      its model on the Custom Profile that
      `SalixAgent.Migrations.TemplatePinChoices` made for it. Without that
      Profile it stands for nothing.
    * A global template stands for the platform model of the role for a
      default, and for nothing in an allow list.
    * A template that is gone, or a choice the Tenant's catalog refuses,
      stands for nothing.

  Reads only; it creates no Profile and changes no template.
  """

  alias SalixAgent.ModelChoice
  alias SalixAgent.Migrations.TemplateRecords

  @doc """
  The choice for `template_id` of `tenant_id`. `role` is `"router"` or
  `"worker"` for a default and `nil` for an allow-list entry. `{:ok, nil}`
  when the reference stands for nothing.
  """
  @spec choice(String.t(), String.t(), String.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  def choice(template_id, tenant_id, role) do
    case TemplateRecords.get(template_id, tenant_id) do
      {:ok, %{"tenant_id" => owner} = template} when is_binary(owner) ->
        private_choice(template, tenant_id)

      {:ok, _global} ->
        {:ok, platform(role)}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  defp platform(role) when role in ~w(router worker), do: %{"kind" => "platform", "tier" => role}
  defp platform(_role), do: nil

  defp private_choice(
         %{"model" => model, "provider_config" => %{"account_pool" => pool} = config},
         tenant_id
       )
       when pool in ~w(codex claude) and is_binary(model) do
    {:ok, chosen(%{"kind" => "catalog", "model" => model}, config["reasoning_effort"], tenant_id)}
  end

  defp private_choice(
         %{"model" => model, "provider_config" => %{"base_url" => url, "api_key" => key} = config} =
           template,
         tenant_id
       )
       when is_binary(model) and is_binary(url) and is_binary(key) and key != "" do
    case TemplateRecords.custom_profile(tenant_id, template) do
      {:ok, profile_id} ->
        choice = %{"kind" => "catalog", "model" => model, "profile_id" => profile_id}
        {:ok, chosen(choice, config["reasoning_effort"], tenant_id)}

      :none ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  defp private_choice(_template, _tenant_id), do: {:ok, nil}

  # The template's effort when the model takes it; else the model's default;
  # nil when the catalog refuses the model.
  defp chosen(choice, effort, tenant_id) do
    with_effort =
      if is_binary(effort) and effort != "",
        do: Map.put(choice, "reasoning_effort", effort),
        else: choice

    with {:error, _} <- ModelChoice.choose(with_effort, tenant_id),
         {:error, _} <- ModelChoice.choose(choice, tenant_id) do
      nil
    else
      {:ok, value} -> value
    end
  end
end
