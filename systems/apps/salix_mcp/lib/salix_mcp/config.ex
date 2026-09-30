defmodule SalixMCP.Config do
  @moduledoc false

  @placeholder ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/
  @url_placeholder ~r/(?<!\$)\{([A-Za-z_][A-Za-z0-9_]*)\}/

  def resolve(definition, binding) when is_map(definition) and is_map(binding) do
    with {:ok, entry} <- SalixMCP.Store.target_entry(definition, binding),
         {:ok, credential_values, remote_headers} <- resolve_credentials(definition, binding),
         values <-
           binding
           |> Map.get("config_values", %{})
           |> normalize_map()
           |> Map.merge(credential_values),
         {:ok, config} <- resolve_entry(entry, binding, values, remote_headers) do
      {:ok, Map.put(config, "entry", entry)}
    end
  end

  def resolve_entry(entry, binding) when is_map(entry) and is_map(binding) do
    values = binding |> Map.get("config_values", %{}) |> normalize_map()

    resolve_entry(entry, binding, values, %{})
  end

  defp resolve_credentials(definition, binding) do
    case SalixMCP.Credentials.resolve_remote_headers(definition, binding) do
      {:ok, headers} when is_map(headers) and map_size(headers) > 0 ->
        {:ok, %{}, headers}

      {:ok, _headers} ->
        with {:ok, values} <- SalixMCP.Credentials.resolve(binding),
             do: {:ok, values, %{}}

      {:error, remote_error} ->
        case SalixMCP.Credentials.resolve(binding) do
          {:ok, values} when is_map(values) and map_size(values) > 0 ->
            {:ok, values, %{}}

          _ ->
            {:error, remote_error}
        end
    end
  end

  defp resolve_entry(entry, binding, values, remote_headers)
       when is_map(entry) and is_map(binding) do
    entry = stringify(entry)

    case entry_kind(entry) do
      :remote -> resolve_remote(entry, values, normalize_map(remote_headers))
      :package -> resolve_package(entry, binding, values)
      :unknown -> {:error, {:bad_request, "MCP target entry must be remote or package"}}
    end
  end

  def entry_kind(%{"url" => url}) when is_binary(url) and url != "", do: :remote
  def entry_kind(%{"command" => command}) when is_binary(command) and command != "", do: :package

  def entry_kind(%{"registry_type" => type, "identifier" => id})
      when is_binary(type) and type != "" and is_binary(id) and id != "",
      do: :package

  def entry_kind(_entry), do: :unknown

  defp resolve_remote(entry, values, remote_headers) do
    entry = apply_remote_target_override(entry)

    with {:ok, variables} <- resolve_schema_map(entry["variables_schema"], values),
         value_scope <- Map.merge(values, variables),
         {:ok, url} <- interpolate_url(entry["url"], value_scope),
         {:ok, headers} <-
           entry["headers_schema"]
           |> headers_without_runtime_values(remote_headers)
           |> resolve_schema_map(value_scope) do
      {:ok,
       %{
         "kind" => "remote",
         "transport" => entry["transport"] || "streamable-http",
         "url" => url,
         "headers" => merge_headers(headers, remote_headers),
         "variables" => variables
       }}
    end
  end

  defp apply_remote_target_override(entry) do
    overrides = Application.get_env(:salix_mcp, :remote_target_overrides, %{}) || %{}

    case overrides[entry["target_ref"]] do
      url when is_binary(url) and url != "" -> Map.put(entry, "url", url)
      _ -> entry
    end
  end

  defp resolve_package(entry, binding, values) do
    with :ok <- require_package_command(entry),
         {:ok, env} <- resolve_schema_map(entry["environment_variables_schema"], values) do
      {:ok,
       %{
         "kind" => "package",
         "transport" => entry["transport"] || "stdio",
         "command" => entry["command"],
         "args" => list(entry["runtime_arguments"]) ++ list(entry["package_arguments"]),
         "env" => mcp_env(env, binding),
         "working_dir" => working_dir(entry, values, binding)
       }}
    end
  end

  defp require_package_command(%{"command" => command}) when is_binary(command) and command != "",
    do: :ok

  defp require_package_command(entry) do
    registry_type = entry["registry_type"] || "package"
    {:error, {:not_runnable, "MCP #{registry_type} entry has no runnable command"}}
  end

  def missing_config(definition, binding) do
    case resolve(definition, binding) do
      {:ok, _} -> []
      {:error, {:missing_config, missing}} -> missing
      {:error, _} -> []
    end
  end

  def redaction_values(definition, binding) when is_map(definition) and is_map(binding) do
    values = binding |> Map.get("config_values", %{}) |> normalize_map()

    credential_values =
      case SalixMCP.Credentials.resolve(binding) do
        {:ok, resolved} when is_map(resolved) -> normalize_map(resolved)
        _ -> %{}
      end

    schema_secret_keys =
      case SalixMCP.Store.target_entry(definition, binding) do
        {:ok, entry} -> secret_schema_keys(entry)
        _ -> MapSet.new()
      end

    config_values =
      values
      |> Enum.filter(fn {key, _value} ->
        SalixMCP.Secrets.secret_name?(key) or MapSet.member?(schema_secret_keys, key)
      end)
      |> Enum.map(fn {_key, value} -> value end)

    root_values = List.wrap(binding["root_grants"])

    remote_values = SalixMCP.Credentials.redaction_values(definition, binding)

    (config_values ++ Map.values(credential_values) ++ root_values ++ remote_values)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort_by(&{-String.length(&1), &1})
  end

  def redaction_values(_definition, _binding), do: []

  defp resolve_schema_map(value, config_values) when is_map(value) do
    value
    |> stringify()
    |> Enum.reduce_while({:ok, %{}, []}, fn {key, spec}, {:ok, acc, missing} ->
      spec = if is_map(spec), do: stringify(spec), else: %{"value" => spec}

      case resolve_schema_value(key, spec, config_values) do
        {:ok, ""} ->
          {:cont, {:ok, acc, missing}}

        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, key, value), missing}}

        {:missing, name} ->
          {:cont, {:ok, acc, [name | missing]}}
      end
    end)
    |> case do
      {:ok, acc, []} -> {:ok, acc}
      {:ok, _acc, missing} -> {:error, {:missing_config, Enum.reverse(missing)}}
    end
  end

  defp resolve_schema_map(_value, _config_values), do: {:ok, %{}}

  defp headers_without_runtime_values(schema, remote_headers) when is_map(schema) do
    Enum.reject(schema, fn {name, _spec} -> header_present?(remote_headers, name) end)
    |> Map.new()
  end

  defp headers_without_runtime_values(_schema, _remote_headers), do: %{}

  defp merge_headers(headers, remote_headers) do
    Enum.reduce(remote_headers, headers, fn {name, value}, acc ->
      existing = Enum.find(Map.keys(acc), &same_header?(&1, name))
      Map.put(acc, existing || name, value)
    end)
  end

  defp header_present?(headers, name), do: Enum.any?(Map.keys(headers), &same_header?(&1, name))

  defp same_header?(left, right),
    do: String.downcase(to_string(left)) == String.downcase(to_string(right))

  defp secret_schema_keys(entry) when is_map(entry) do
    entry = stringify(entry)

    ["headers_schema", "variables_schema", "environment_variables_schema"]
    |> Enum.flat_map(fn key ->
      entry
      |> Map.get(key, %{})
      |> normalize_map()
      |> Enum.flat_map(fn {name, spec} ->
        spec = if is_map(spec), do: stringify(spec), else: %{}

        if SalixMCP.Secrets.secret_name?(name) or spec["isSecret"] in [true, "true", 1, "1"] do
          [name]
        else
          []
        end
      end)
    end)
    |> MapSet.new()
  end

  defp secret_schema_keys(_entry), do: MapSet.new()

  defp resolve_schema_value(key, spec, config_values) do
    candidates =
      [key, spec["name"], spec["env"], spec["variable"]]
      |> Enum.reject(&blank?/1)
      |> Enum.map(&to_string/1)

    case find_config(config_values, candidates) do
      {:ok, value} ->
        value = to_string(value)

        if String.trim(value) == "" and required?(spec) do
          {:missing, List.first(candidates) || key}
        else
          {:ok, value}
        end

      :error ->
        value = spec["value"] || spec["default"]

        cond do
          is_binary(value) and placeholder_names(value) != [] ->
            case interpolate(value, config_values) do
              {:ok, interpolated} -> {:ok, interpolated}
              {:error, {:missing_config, [name | _]}} -> {:missing, name}
            end

          required?(spec) ->
            {:missing, List.first(candidates) || key}

          is_nil(value) ->
            {:ok, ""}

          true ->
            {:ok, value}
        end
    end
  end

  defp interpolate(value, config_values) when is_binary(value) do
    names = placeholder_names(value)
    missing = Enum.reject(names, fn name -> Map.has_key?(config_values, name) end)

    if missing == [] do
      rendered =
        value
        |> replace_placeholders(@placeholder, config_values)
        |> replace_placeholders(@url_placeholder, config_values)

      {:ok, rendered}
    else
      {:error, {:missing_config, missing}}
    end
  end

  defp interpolate(value, _config_values), do: {:ok, to_string(value || "")}

  defp interpolate_url(value, config_values) when is_binary(value) do
    interpolate(value, config_values)
  end

  defp interpolate_url(value, config_values), do: interpolate(value, config_values)

  defp placeholder_names(value) when is_binary(value) do
    [@placeholder, @url_placeholder]
    |> Enum.flat_map(fn regex ->
      regex
      |> Regex.scan(value)
      |> Enum.map(&List.last/1)
    end)
    |> Enum.uniq()
  end

  defp replace_placeholders(value, regex, config_values) do
    Regex.replace(regex, value, fn _all, name ->
      config_values |> Map.get(name, "") |> to_string()
    end)
  end

  defp find_config(config_values, candidates) do
    Enum.find_value(candidates, :error, fn key ->
      case Map.fetch(config_values, key) do
        {:ok, value} when not is_nil(value) -> {:ok, value}
        _ -> nil
      end
    end)
  end

  defp required?(spec) do
    spec["isRequired"] in [true, "true", 1, "1"] or
      spec["required"] in [true, "true", 1, "1"]
  end

  defp working_dir(entry, values, binding) do
    values["working_dir"] || entry["working_dir"] || default_working_dir(binding)
  end

  defp default_working_dir(%{"placement" => "device", "root_grants" => [first | _]})
       when is_binary(first) do
    first
  end

  defp default_working_dir(_binding), do: "."

  defp mcp_env(env, %{"placement" => "device"} = binding) do
    root_grants = List.wrap(binding["root_grants"])

    if root_grants == [] do
      env
    else
      Map.put_new(env, "SALIX_MCP_ROOT_GRANTS", Jason.encode!(root_grants))
    end
  end

  defp mcp_env(env, _binding), do: env

  defp list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list(_), do: []

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp normalize_map(value) when is_map(value), do: stringify(value)
  defp normalize_map(_value), do: %{}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
