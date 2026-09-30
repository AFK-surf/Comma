defmodule SalixAgent.MediaResolver do
  @moduledoc """
  Live per-agent auxiliary media/provider resolution seam.

  Willow stores image generation, video generation, vision describer, and
  JavaScript analyzer configuration on the agent template, separate from the
  primary LLM provider. The web/control plane wires an implementation here so
  runtime tools can resolve the agent record -> template -> auxiliary configs
  at execution time without making `salix_agent` depend on `salix_web`.
  """

  @callback resolve(agent_id :: String.t()) :: {:ok, map() | nil} | {:error, term()}

  @spec resolve(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def resolve(agent_id) do
    case Application.get_env(:salix_agent, :media_resolver) do
      nil -> {:ok, nil}
      mod -> mod.resolve(agent_id)
    end
  end

  @doc "Whether a generation configuration can be used by the media tools."
  def generation_configured?(%{
        "provider" => "openai",
        "model" => "gpt-image-2",
        "provider_config" => %{"account_pool" => "codex"},
        "account_pool_tenant" => tenant
      }),
      do: SalixStore.Ids.valid_tenant_id?(tenant)

  def generation_configured?(%{
        "provider" => p,
        "model" => m,
        "provider_config" => %{"base_url" => b}
      }),
      do:
        String.trim(to_string(p)) != "" and String.trim(to_string(m)) != "" and
          String.trim(to_string(b)) != ""

  def generation_configured?(_), do: false

  @doc """
  Does this agent's template declare a model that accepts native image input?

  Requests and their tools use the capability captured with the selected model.
  Callers without a request snapshot resolve the current template. Missing or
  unresolvable capability fails closed.
  """
  def supports_images?(subject, ctx) do
    case Map.fetch(ctx, :model_supports_images) do
      {:ok, value} -> value == true
      :error -> supports_images?(subject)
    end
  end

  @doc "Resolve native image support from the current template or media configuration."
  @spec supports_images?(String.t() | map() | nil) :: boolean()
  def supports_images?(%{} = media), do: media["supports_images"] == true
  def supports_images?(nil), do: false

  def supports_images?(agent_id) when is_binary(agent_id) do
    case resolve(agent_id) do
      {:ok, media} -> supports_images?(media)
      _ -> false
    end
  end

  def supports_images?(_agent_id), do: false
end
