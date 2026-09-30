defmodule SalixAgent.PlatformCapabilities do
  @moduledoc """
  Current-source interaction capabilities, intersecting the platform, product
  adapter and live connection. Cached tool disclosure is never authorization.
  """
  @interactive ~w(question.request permission.request location.request oauth.request_authorization)
  @types %{
    "question.request" => "question",
    "permission.request" => "permission",
    "location.request" => "location",
    "oauth.request_authorization" => "oauth"
  }

  def capabilities(ctx) do
    origin = ctx[:trusted_origin] || %{}

    case origin["provider"] do
      "telegram" ->
        mod = Application.get_env(:salix_agent, :telegram_interaction_mod)

        if is_atom(mod) and not is_nil(mod) and Code.ensure_loaded?(mod) and
             function_exported?(mod, :capabilities, 1), do: mod.capabilities(ctx), else: %{}

      provider when provider in [nil, "internal"] ->
        %{"permission" => true, "location" => true, "oauth" => true}

      _ ->
        # Other providers can carry an OAuth browser URL, but cannot promise a
        # host permission/location prompt. Ordinary text questions remain valid.
        %{"oauth" => true}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  def allowed?(ctx, tool) when tool in @interactive,
    do: capabilities(ctx)[@types[tool]] == true

  def allowed?(_, _), do: true

  def scope_config(config, ctx) do
    if external_source?(ctx[:trusted_origin]),
      do: scope_external_config(config, ctx),
      else: config
  end

  def request_prompt(prompt, disclosure, origin),
    do:
      SalixAgent.InternalSession.request_projection(
        {:platform_prompt, prompt, disclosure, origin}
      )

  defp external_source?(origin), do: (origin || %{})["provider"] not in [nil, "internal"]

  defp scope_external_config(config, ctx) do
    capabilities = capabilities(ctx)

    tools =
      config.tool_disclosure["tools"]
      |> Enum.filter(fn entry ->
        entry["name"] not in @interactive or capabilities[@types[entry["name"]]] == true
      end)
      |> Enum.map(&location_schema/1)

    disclosure = Map.put(config.tool_disclosure, "tools", tools)

    %{
      config
      | tool_disclosure: disclosure,
        tool_specs: SalixAgent.ToolDisclosure.internal_llm_specs(config.role, disclosure)
    }
  end

  # Only Telegram exposes location to an external source. Reuse the existing
  # disclosed-parameter validator; internal host requests keep their schema.
  defp location_schema(%{"name" => "location.request", "input_schema" => schema} = entry)
       when is_map(schema) do
    schema = Map.update(schema, "required", ["locale"], &Enum.uniq(&1 ++ ["locale"]))
    Map.put(entry, "input_schema", schema)
  end

  defp location_schema(entry), do: entry

  def reminder(disclosure),
    do: SalixAgent.InternalSession.request_projection({:platform_reminder, disclosure})
end
