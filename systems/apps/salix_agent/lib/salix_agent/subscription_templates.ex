defmodule SalixAgent.SubscriptionTemplates do
  @moduledoc "Credential-free organization editor for subscription templates."
  alias SalixAgent.Templates

  def list(tenant) do
    with {:ok, templates} <- Templates.list_private(tenant) do
      {:ok, Enum.map(templates, &public/1)}
    end
  end

  def discover(tenant, pool) when pool in ["codex", "claude"],
    do: SalixAgent.ModelDiscovery.discover(%{"account_pool" => pool}, tenant)

  def save(tenant, id, params) do
    with {:ok, attrs} <- attributes(params),
         :ok <- editable(tenant, id),
         {:ok, template} <- persist(tenant, id, attrs) do
      {:ok, public(template)}
    end
  end

  def delete(tenant, id) when is_binary(id) do
    with :ok <- editable(tenant, id), do: Templates.delete_private(id, tenant)
  end

  defp persist(tenant, nil, attrs), do: Templates.create_private(attrs, tenant)
  defp persist(tenant, id, attrs), do: Templates.update_private(id, attrs, tenant)
  defp editable(_tenant, nil), do: :ok

  defp editable(tenant, id) do
    with {:ok, template} <- Templates.get(id, tenant) do
      if template["tenant_id"] == tenant and
           get_in(template, ["provider_config", "account_pool"]) in ["codex", "claude"],
         do: :ok,
         else:
           {:error,
            {:bad_request, "Only organization subscription templates can be changed here."}}
    end
  end

  defp attributes(params) do
    provider = params["subscription_provider"]
    name = String.trim(params["name"] || "")
    model = String.trim(params["model"] || "")

    with true <- provider in ["codex", "claude"],
         true <- byte_size(name) in 1..120 and byte_size(model) in 1..160,
         {max_tokens, ""} <- Integer.parse(to_string(params["max_tokens"] || "65536")),
         true <- max_tokens in 1..1_000_000 do
      {:ok,
       %{
         "name" => name,
         "model" => model,
         "model_display_name" => params["model_display_name"],
         "model_vendor" => params["model_vendor"],
         "max_tokens" => max_tokens,
         "provider" => if(provider == "codex", do: "openai", else: "anthropic"),
         "provider_config" => %{"account_pool" => provider}
       }}
    else
      _ ->
        {:error, {:bad_request, "Enter a name, a model ID, and a valid output token limit."}}
    end
  end

  defp public(template) do
    template
    |> Templates.public_json()
    |> Map.put("subscription_provider", get_in(template, ["provider_config", "account_pool"]))
  end
end
