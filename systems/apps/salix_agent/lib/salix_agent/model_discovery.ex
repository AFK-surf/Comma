defmodule SalixAgent.ModelDiscovery do
  @moduledoc "Bounded, read-only discovery of a user's provider models."

  @protocols ~w(responses chat_completions anthropic)
  @body_limit 2_000_000

  def discover(%{"template_id" => id} = attrs, tenant)
      when map_size(attrs) == 1 and is_binary(tenant) and is_binary(id) and
             byte_size(id) in 1..200 do
    with {:ok, template} <- SalixAgent.Templates.get(id, tenant),
         true <- template["tenant_id"] == tenant do
      config = template["provider_config"] || %{}

      if config["account_pool"] in ["codex", "claude"] do
        discover(%{"account_pool" => config["account_pool"]}, tenant)
      else
        discover(Map.take(config, ~w(base_url api_key protocol)))
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def discover(%{"account_pool" => pool} = attrs, tenant)
      when pool in ["codex", "claude"] and map_size(attrs) == 1 do
    case SalixAgent.AccountPool.models(tenant, pool) do
      {:ok, result} ->
        {:ok,
         Map.merge(result, %{
           "base_url" => "",
           "provider" => if(pool == "codex", do: "openai", else: "anthropic"),
           "protocol" => if(pool == "codex", do: "responses", else: "anthropic")
         })}

      {:error, :model_discovery_no_account} = error ->
        error

      _ ->
        {:error, :model_discovery_unavailable}
    end
  end

  def discover(attrs, _tenant), do: discover(attrs)

  def discover(attrs) do
    with {:ok, connection} <- connection(attrs) do
      task = Task.async(fn -> pages(connection, nil, [], 5) end)

      case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} -> {:ok, Map.merge(connection |> Map.drop(["api_key"]), result)}
        {:ok, error} -> error
        _ -> {:error, :model_discovery_timeout}
      end
    end
  end

  def connection(attrs) when is_map(attrs) do
    base = attrs["base_url"]
    # A keyless endpoint (Ollama, a self-hosted gateway) lists its models with
    # no key; a key that is given must be usable.
    key = if attrs["api_key"] in [nil, ""], do: nil, else: attrs["api_key"]

    with true <- Enum.all?(Map.keys(attrs), &(&1 in ~w(base_url api_key protocol))),
         true <- endpoint?(base),
         true <-
           is_nil(key) or
             (is_binary(key) and byte_size(key) in 1..8192 and String.trim(key) != "") do
      uri = URI.parse(String.trim(base))

      inferred =
        case uri.host do
          "api.anthropic.com" -> "anthropic"
          "api.openai.com" -> "responses"
          _ -> "chat_completions"
        end

      protocol = attrs["protocol"] || inferred

      if protocol in @protocols do
        {:ok,
         %{
           "base_url" => normalize_url(base, protocol),
           "api_key" => key,
           "protocol" => protocol,
           "provider" => if(protocol == "anthropic", do: "anthropic", else: "openai")
         }}
      else
        {:error, :invalid_model_configuration}
      end
    else
      _ -> {:error, :invalid_model_configuration}
    end
  end

  def connection(_), do: {:error, :invalid_model_configuration}

  def endpoint?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def endpoint?(_), do: false

  def normalize_url(value, protocol) do
    base = value |> String.trim() |> String.trim_trailing("/")

    cond do
      protocol == "anthropic" -> String.trim_trailing(base, "/v1")
      URI.parse(base).path in [nil, ""] -> base <> "/v1"
      true -> base
    end
  end

  defp pages(connection, cursor, accumulated, remaining) do
    anthropic = connection["protocol"] == "anthropic"
    url = connection["base_url"] <> if(anthropic, do: "/v1/models", else: "/models")

    key = connection["api_key"]

    headers =
      cond do
        anthropic and is_binary(key) -> [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}]
        anthropic -> [{"anthropic-version", "2023-06-01"}]
        is_binary(key) -> [{"authorization", "Bearer " <> key}]
        true -> []
      end

    params =
      if anthropic,
        do: [{:limit, 200}] ++ if(cursor, do: [{:after_id, cursor}], else: []),
        else: []

    with {:ok, response} <- request(url, headers, params),
         {:ok, body} <- decode(response),
         %{"data" => data} when is_list(data) <- body do
      choices =
        (accumulated ++ Enum.flat_map(Enum.take(data, 1000), &model(&1, connection)))
        |> Enum.uniq_by(& &1["id"])

      models =
        Enum.take(choices, 1000)
        |> Enum.map(fn model ->
          Map.update!(model, "vendor", fn vendor ->
            vendor ||
              SalixAgent.ModelPresentation.vendor(%{
                "model" => model["id"],
                "provider_config" => connection
              })
          end)
        end)

      more = body["has_more"] == true
      next = body["last_id"]

      cond do
        more and anthropic and remaining > 1 and length(models) < 1000 and
          is_binary(next) and byte_size(next) in 1..200 and next != cursor ->
          pages(connection, next, models, remaining - 1)

        true ->
          {:ok,
           %{
             "data" => models,
             "truncated" => more or length(data) > 1000 or length(choices) > 1000
           }}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :model_discovery_invalid_response}
    end
  end

  defp request(url, headers, params) do
    result =
      Req.get(url,
        headers: headers ++ [{"accept-encoding", "identity"}],
        params: params,
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 3_000],
        into: fn {:data, chunk}, {req, resp} ->
          if byte_size(resp.body) + byte_size(chunk) > @body_limit do
            {:halt, {req, %{resp | body: :too_large}}}
          else
            {:cont, {req, %{resp | body: resp.body <> chunk}}}
          end
        end
      )

    case result do
      {:error, %{reason: :timeout}} -> {:error, :model_discovery_timeout}
      {:error, _} -> {:error, :model_discovery_unavailable}
      response -> response
    end
  rescue
    _ -> {:error, :model_discovery_unavailable}
  end

  defp decode(%{body: :too_large}), do: {:error, :model_discovery_too_large}

  defp decode(%{status: 200, body: body}) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :model_discovery_invalid_response}
    end
  end

  defp decode(%{status: status}) when status in [401, 403],
    do: {:error, :model_discovery_unauthorized}

  defp decode(%{status: status}) when status in [404, 405],
    do: {:error, :model_discovery_unsupported}

  defp decode(%{status: 429}), do: {:error, :model_discovery_rate_limited}
  defp decode(_), do: {:error, :model_discovery_unavailable}

  defp model(%{"id" => id} = item, connection) when is_binary(id) and byte_size(id) in 1..200 do
    capabilities = if is_map(item["capabilities"]), do: item["capabilities"], else: %{}

    name =
      if is_binary(item["display_name"]) and byte_size(item["display_name"]) in 1..200,
        do: item["display_name"],
        else: SalixAgent.ModelPresentation.display_name(item["name"], id)

    [
      SalixAgent.ModelCatalog.normalize(
        connection["base_url"],
        Map.merge(Map.take(item, ~w(supported_protocols)), %{
          "id" => id,
          "name" => name,
          "vendor" =>
            SalixAgent.ModelPresentation.vendor(%{
              "model_vendor" => item["owned_by"] || item["vendor"]
            }),
          "supports_images" => match?(%{"supported" => true}, capabilities["image_input"])
        })
      )
    ]
  end

  defp model(_, _), do: []
end
