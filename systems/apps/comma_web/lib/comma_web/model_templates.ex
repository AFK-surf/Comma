defmodule CommaWeb.ModelTemplates do
  @moduledoc "Workspace model configuration with credential-free product responses."

  alias SalixAgent.Templates

  @fields ~w(name model model_display_name model_vendor provider protocol base_url api_key max_tokens context_tokens supports_images reasoning_effort account_pool)
  @protocols ~w(anthropic responses chat_completions)

  def list(workspace) do
    with {:ok, templates} <- Templates.list_private(workspace["salix_tenant_id"]) do
      {:ok, %{"data" => Enum.map(templates, &public/1)}}
    end
  end

  def create(workspace, attrs) do
    with {:ok, config} <- configuration(attrs, nil),
         {:ok, template} <- Templates.create_private(config, workspace["salix_tenant_id"]) do
      {:ok, public(template)}
    end
  end

  def resolve_subscription(workspace, attrs) when is_map(attrs) do
    pool = attrs["account_pool"]

    if pool in ["codex", "claude"] and
         Enum.all?(
           Map.keys(attrs),
           &(&1 in ~w(account_pool model reasoning_effort model_display_name supports_images))
         ) do
      effort_label =
        if is_binary(attrs["reasoning_effort"]), do: attrs["reasoning_effort"], else: "default"

      with {:ok, config} <-
             configuration(
               Map.merge(attrs, %{
                 "name" => Enum.join([String.capitalize(pool), effort_label], " · "),
                 "provider" => if(pool == "codex", do: "openai", else: "anthropic"),
                 "context_tokens" => 500_000
               }),
               nil
             ),
           {:ok, template} <-
             Templates.resolve_private_subscription(config, workspace["salix_tenant_id"]) do
        {:ok, public(template)}
      end
    else
      {:error, :invalid_model_configuration}
    end
  end

  def update(workspace, id, attrs) do
    with {:ok, template} <-
           Templates.update_private(
             id,
             fn old -> configuration(attrs, old) end,
             workspace["salix_tenant_id"]
           ) do
      {:ok, public(template)}
    end
  end

  def delete(workspace, id) do
    with :ok <- Templates.delete_private(id, workspace["salix_tenant_id"], 1000) do
      {:ok, %{"deleted" => true}}
    end
  end

  defp configuration(attrs, old) when is_map(attrs) do
    attrs = SalixAgent.ModelPresentation.refresh(attrs, if(old, do: public(old), else: %{}))
    previous = if old, do: public(old), else: %{}
    values = Map.merge(previous, attrs)
    key = Map.get(attrs, "api_key", get_in(old || %{}, ["provider_config", "api_key"]))
    pool = values["account_pool"]
    pooled = pool in ["codex", "claude"]

    protocol =
      if pooled,
        do: if(pool == "codex", do: "responses", else: "anthropic"),
        else: values["protocol"]

    base_url = values["base_url"]
    max_tokens = values["max_tokens"] || 4096
    context_tokens = values["context_tokens"] || 0
    images = Map.get(values, "supports_images", false)
    effort = values["reasoning_effort"]
    endpoint_changed = not is_nil(old) and base_url != previous["base_url"]
    key_supplied = text?(attrs["api_key"], 8192)

    if Enum.all?(Map.keys(attrs), &(&1 in @fields)) and
         text?(values["name"], 120) and text?(values["model"], 200) and
         text?(values["provider"], 80) and protocol in @protocols and
         (is_nil(pool) or pool == "" or pooled) and
         (pooled or
            (text?(key, 8192) and SalixAgent.ModelDiscovery.endpoint?(base_url) and
               (not endpoint_changed or key_supplied))) and
         (is_nil(effort) or (pool == "codex" and text?(effort, 64)) or
            effort in ~w(none minimal low medium high xhigh max)) and
         (protocol != "anthropic" or is_nil(effort) or effort in ~w(low medium high xhigh max)) and
         is_integer(max_tokens) and max_tokens > 0 and max_tokens <= 1_000_000 and
         is_integer(context_tokens) and context_tokens >= 0 and context_tokens <= 10_000_000 and
         is_boolean(images) do
      {:ok,
       %{
         "name" => String.trim(values["name"]),
         "model" => String.trim(values["model"]),
         "model_display_name" => values["model_display_name"],
         "model_vendor" => values["model_vendor"],
         "provider" =>
           if(pooled,
             do: if(pool == "codex", do: "openai", else: "anthropic"),
             else: String.trim(values["provider"])
           ),
         "provider_config" =>
           if(pooled,
             do: %{"account_pool" => pool, "protocol" => protocol, "reasoning_effort" => effort},
             else: %{
               "protocol" => protocol,
               "base_url" => SalixAgent.ModelDiscovery.normalize_url(base_url, protocol),
               "api_key" => key,
               "reasoning_effort" => effort
             }
           ),
         "max_tokens" => max_tokens,
         "context_tokens" => context_tokens,
         "supports_images" => images
       }}
    else
      {:error, :invalid_model_configuration}
    end
  end

  defp configuration(_, _), do: {:error, :invalid_model_configuration}

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) <= limit and String.trim(value) != ""

  defp public(template) do
    config = template["provider_config"] || %{}

    template
    |> Templates.public_json()
    |> Map.merge(%{
      "account_pool" => config["account_pool"],
      "protocol" => config["protocol"] || "chat_completions",
      "base_url" => config["base_url"] || "",
      "has_api_key" => text?(config["api_key"], 8192),
      "supports_images" => template["supports_images"] == true
    })
  end
end
