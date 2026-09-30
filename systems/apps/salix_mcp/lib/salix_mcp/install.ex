defmodule SalixMCP.Install do
  @moduledoc """
  Normalizes common MCP installation inputs into Salix MCP definition metadata.
  """

  @registry_types ~w(npm pypi nuget oci mcpb direct)

  @doc false
  def normalize(attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    cond do
      is_map(attrs["server_metadata"]) ->
        from_server_metadata(attrs)

      is_map(attrs["server_json"]) ->
        from_server_metadata(Map.put(attrs, "server_metadata", attrs["server_json"]))

      is_binary(attrs["server_json_url"]) ->
        from_server_json_url(attrs)

      is_binary(attrs["registry_base_url"]) and is_binary(attrs["server_name"]) ->
        from_registry(attrs)

      is_map(attrs["mcpServers"]) ->
        from_client_config(attrs)

      is_binary(attrs["url"]) or is_binary(attrs["remote_url"]) ->
        from_remote(attrs)

      is_binary(attrs["identifier"]) or is_binary(attrs["image"]) or is_binary(attrs["command"]) ->
        from_package(attrs)

      true ->
        {:error,
         {:bad_request,
          "install input must include server_metadata, server_json, server_json_url, registry reference, mcpServers, url, identifier, image, or command"}}
    end
  end

  def normalize(_attrs), do: {:error, {:bad_request, "install input must be an object"}}

  defp from_server_metadata(attrs) do
    metadata = stringify(attrs["server_metadata"])
    name = nonblank(attrs["name"], metadata["name"] || metadata["id"] || "MCP")
    metadata = normalize_server_metadata(metadata, name)

    with :ok <- validate_package_registry_types(metadata) do
      {:ok,
       %{
         "name" => name,
         "description" => string(attrs["description"] || metadata["description"]),
         "install_source" => attrs["install_source"] || %{"type" => "server_metadata"},
         "server_metadata" => metadata,
         "supports_server" => bool(supports_server_value(attrs, metadata), false),
         "server_support_note" => string(server_support_note_value(attrs, metadata)),
         "trust" => normalize_map(attrs["trust"]),
         "created_by" => string(attrs["created_by"])
       }}
    end
  end

  defp from_server_json_url(attrs) do
    with {:ok, metadata} <- fetch_json(attrs["server_json_url"]) do
      attrs
      |> Map.put("server_metadata", metadata["server"] || metadata)
      |> Map.put("install_source", %{
        "type" => "server_json_url",
        "url" => attrs["server_json_url"]
      })
      |> from_server_metadata()
    end
  end

  defp from_registry(attrs) do
    base = attrs["registry_base_url"] |> string() |> String.trim_trailing("/")
    server_name = string(attrs["server_name"])
    version = string(attrs["server_version"] || attrs["version"])

    candidates =
      [
        registry_url(base, server_name, version),
        registry_url(base, server_name, "")
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    with {:ok, metadata, source_url} <- fetch_first_json(candidates) do
      attrs
      |> Map.put("server_metadata", metadata["server"] || metadata)
      |> Map.put("install_source", %{
        "type" => "registry",
        "registry_base_url" => base,
        "server_name" => server_name,
        "server_version" => version,
        "url" => source_url
      })
      |> from_server_metadata()
    end
  end

  defp from_client_config(%{"mcpServers" => servers} = attrs) when is_map(servers) do
    case servers |> Enum.sort_by(fn {alias_name, _} -> to_string(alias_name) end) do
      [] ->
        {:error, {:bad_request, "mcpServers must include one server entry"}}

      [_first, _second | _] ->
        {:error,
         {:bad_request, "mcpServers import accepts exactly one server entry per MCP definition"}}

      [{alias_name, %{} = cfg}] ->
        cfg = stringify(cfg)
        alias_name = to_string(alias_name)

        cond do
          remote_config?(cfg) ->
            from_remote(
              attrs
              |> Map.merge(cfg)
              |> Map.put("name", nonblank(attrs["name"], alias_name))
              |> Map.put("client_config_alias", alias_name)
            )

          string(cfg["command"]) != "" ->
            from_package(
              attrs
              |> Map.merge(cfg)
              |> Map.put("name", nonblank(attrs["name"], alias_name))
              |> Map.put("client_config_alias", alias_name)
            )

          true ->
            {:error, {:bad_request, "mcpServers entry must include url or command"}}
        end

      _ ->
        {:error, {:bad_request, "mcpServers entry must be an object"}}
    end
  end

  defp from_remote(attrs) do
    name =
      nonblank(
        attrs["name"],
        attrs["client_config_alias"] || host_name(attrs["url"] || attrs["remote_url"])
      )

    url = string(attrs["url"] || attrs["remote_url"])
    transport = normalize_transport(attrs["transport"] || attrs["type"] || "streamable-http")

    if url == "" do
      {:error, {:bad_request, "remote MCP url is required"}}
    else
      target_ref = "remote:" <> slug(name)

      {:ok,
       %{
         "name" => name,
         "description" => string(attrs["description"]),
         "install_source" => %{
           "type" => if(attrs["client_config_alias"], do: "client_config", else: "remote"),
           "alias" => attrs["client_config_alias"]
         },
         "server_metadata" =>
           Map.merge(source_metadata(attrs), %{
             "name" => name,
             "description" => string(attrs["description"]),
             "remotes" => [
               %{
                 "target_ref" => target_ref,
                 "transport" => transport,
                 "url" => url,
                 "headers_schema" =>
                   schema_from_value(attrs["headers"] || attrs["headers_schema"]),
                 "variables_schema" =>
                   schema_from_value(attrs["variables"] || attrs["variables_schema"])
               }
             ]
           }),
         "supports_server" => bool(supports_server_value(attrs), true),
         "server_support_note" => string(server_support_note_value(attrs)),
         "trust" => normalize_map(attrs["trust"]),
         "created_by" => string(attrs["created_by"])
       }}
    end
  end

  defp from_package(attrs) do
    name =
      nonblank(
        attrs["name"],
        attrs["client_config_alias"] || attrs["identifier"] || attrs["image"] || attrs["command"] ||
          "mcp"
      )

    target_ref = "package:" <> slug(name)
    registry_type = package_registry_type(attrs)
    identifier = string(attrs["identifier"] || attrs["image"] || attrs["command"])
    version = string(attrs["version"])
    command = package_command(attrs, registry_type, identifier, version)

    args =
      normalize_command_args(command, package_args(attrs, registry_type, identifier, version))

    cond do
      registry_type not in @registry_types ->
        {:error,
         {:bad_request, "unsupported MCP package registry_type #{inspect(registry_type)}"}}

      command == "" and registry_type != "mcpb" ->
        {:error, {:bad_request, "package MCP command is required"}}

      true ->
        {:ok,
         %{
           "name" => name,
           "description" => string(attrs["description"]),
           "install_source" => %{
             "type" => if(attrs["client_config_alias"], do: "client_config", else: "package"),
             "alias" => attrs["client_config_alias"]
           },
           "server_metadata" =>
             Map.merge(source_metadata(attrs), %{
               "name" => name,
               "description" => string(attrs["description"]),
               "packages" => [
                 package_entry(
                   attrs,
                   target_ref,
                   registry_type,
                   identifier,
                   version,
                   command,
                   args
                 )
               ]
             }),
           "supports_server" =>
             bool(
               supports_server_value(attrs),
               registry_type in ["npm", "pypi", "nuget", "oci", "direct"]
             ),
           "server_support_note" => string(server_support_note_value(attrs)),
           "trust" => normalize_map(attrs["trust"]),
           "created_by" => string(attrs["created_by"])
         }}
    end
  end

  defp normalize_server_metadata(metadata, name) do
    metadata
    |> Map.put_new("name", name)
    |> Map.update("packages", [], &package_entry_ids(&1, name))
    |> Map.update("remotes", [], &remote_entry_ids(&1, name))
  end

  defp source_metadata(attrs) do
    %{}
    |> maybe_put("repository", attrs["repository"])
    |> maybe_put("websiteUrl", attrs["websiteUrl"] || attrs["website_url"])
    |> maybe_put("icons", attrs["icons"])
    |> maybe_put("_meta", attrs["_meta"])
  end

  defp package_entry(attrs, target_ref, registry_type, identifier, version, command, args) do
    %{
      "target_ref" => target_ref,
      "registry_type" => registry_type,
      "identifier" => identifier,
      "version" => version,
      "transport" => normalize_transport(attrs["transport"] || "stdio"),
      "command" => command,
      "runtime_arguments" => args,
      "package_arguments" => list(attrs["package_arguments"]),
      "environment_variables_schema" =>
        schema_from_value(attrs["env"] || attrs["environment_variables_schema"]),
      "working_dir" => string(attrs["working_dir"])
    }
    |> maybe_put("registryBaseUrl", attrs["registryBaseUrl"] || attrs["registry_base_url"])
    |> maybe_put("fileSha256", attrs["fileSha256"] || attrs["file_sha256"])
    |> maybe_put("runtimeHint", attrs["runtimeHint"] || attrs["runtime_hint"])
  end

  defp remote_entry_ids(entries, name) when is_list(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, idx} ->
      entry = stringify(entry)

      entry
      |> normalize_remote_entry()
      |> Map.put_new(
        "target_ref",
        "remote:" <> slug(entry["name"] || name) <> "-" <> to_string(idx)
      )
    end)
  end

  defp remote_entry_ids(_entries, _name), do: []

  defp package_entry_ids(entries, name) when is_list(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, idx} ->
      entry = stringify(entry)

      entry
      |> normalize_package_entry()
      |> Map.put_new(
        "target_ref",
        "package:" <> slug(entry["name"] || name) <> "-" <> to_string(idx)
      )
    end)
  end

  defp package_entry_ids(_entries, _name), do: []

  defp normalize_remote_entry(entry) do
    entry
    |> move_key("targetRef", "target_ref")
    |> put_transport_type()
    |> normalize_schema_alias("headers", "headers_schema")
    |> normalize_schema_alias("variables", "variables_schema")
    |> sanitize_schema_field("headers_schema")
    |> sanitize_schema_field("variables_schema")
  end

  defp normalize_package_entry(entry) do
    registry_type = normalize_registry_type(entry["registryType"] || entry["registry_type"])
    identifier = string(entry["identifier"] || entry["image"] || entry["command"])
    version = string(entry["version"])
    command = string(entry["command"])

    runtime_args =
      list(entry["runtimeArguments"] || entry["runtime_arguments"] || entry["args"])

    {command, runtime_args} =
      if command == "" and identifier != "" and registry_type != "mcpb" do
        command = package_command(%{}, registry_type, identifier, version)

        {command,
         normalize_command_args(command, package_args(%{}, registry_type, identifier, version))}
      else
        {command, normalize_command_args(command, runtime_args)}
      end

    entry
    |> move_key("targetRef", "target_ref")
    |> put_registry_type(registry_type)
    |> put_transport_type()
    |> Map.put("identifier", identifier)
    |> Map.put("version", version)
    |> Map.put("command", command)
    |> Map.put("runtime_arguments", runtime_args)
    |> Map.put("package_arguments", list(entry["packageArguments"] || entry["package_arguments"]))
    |> normalize_schema_alias("env", "environment_variables_schema")
    |> normalize_schema_alias("environmentVariables", "environment_variables_schema")
    |> normalize_schema_alias("environment_variables", "environment_variables_schema")
    |> sanitize_schema_field("environment_variables_schema")
  end

  defp validate_package_registry_types(%{"packages" => packages}) when is_list(packages) do
    case Enum.find(packages, fn package ->
           registry_type = string(package["registry_type"])
           registry_type != "" and registry_type not in @registry_types
         end) do
      nil ->
        :ok

      package ->
        {:error,
         {:bad_request,
          "unsupported MCP package registry_type #{inspect(package["registry_type"])}"}}
    end
  end

  defp validate_package_registry_types(_metadata), do: :ok

  defp normalize_schema_alias(entry, source_key, target_key) do
    if is_map(entry[source_key]) or is_list(entry[source_key]) do
      entry
      |> Map.put_new(target_key, entry[source_key])
      |> Map.delete(source_key)
    else
      entry
    end
  end

  defp sanitize_schema_field(entry, field) do
    if is_map(entry[field]) or is_list(entry[field]) do
      Map.put(entry, field, schema_from_value(entry[field]))
    else
      entry
    end
  end

  defp move_key(entry, source_key, target_key) do
    if Map.has_key?(entry, source_key) do
      entry
      |> Map.put_new(target_key, entry[source_key])
      |> Map.delete(source_key)
    else
      entry
    end
  end

  defp put_transport_type(entry) do
    transport =
      case entry["transport"] do
        %{} = map -> map["type"] || map[:type]
        value -> value || entry["type"]
      end

    entry
    |> Map.put("transport", normalize_transport(transport))
    |> Map.delete("type")
  end

  defp put_registry_type(entry, ""), do: entry
  defp put_registry_type(entry, registry_type), do: Map.put(entry, "registry_type", registry_type)

  defp remote_config?(cfg) do
    string(cfg["url"]) != "" or cfg["type"] in ["http", "sse", "streamable-http"]
  end

  defp package_registry_type(%{"registry_type" => type}), do: normalize_registry_type(type)
  defp package_registry_type(%{"image" => image}) when is_binary(image) and image != "", do: "oci"
  defp package_registry_type(%{"identifier" => id}) when is_binary(id) and id != "", do: "npm"
  defp package_registry_type(%{"command" => _}), do: "direct"
  defp package_registry_type(_), do: "direct"

  defp normalize_registry_type(type) do
    case string(type) |> String.downcase() do
      value when value in @registry_types -> value
      "" -> "direct"
      value -> value
    end
  end

  defp package_command(attrs, "npm", _identifier, _version), do: string(attrs["command"] || "npx")

  defp package_command(attrs, "pypi", _identifier, _version),
    do: string(attrs["command"] || "uvx")

  defp package_command(attrs, "nuget", _identifier, _version),
    do: string(attrs["command"] || "dnx")

  defp package_command(attrs, "oci", _identifier, _version),
    do: string(attrs["command"] || "docker")

  defp package_command(attrs, _type, _identifier, _version), do: string(attrs["command"])

  defp package_args(attrs, "npm", identifier, version) do
    case list(attrs["args"] || attrs["runtime_arguments"]) do
      [] -> ["-y", package_identifier(identifier, version)]
      args -> args
    end
  end

  defp package_args(attrs, "pypi", identifier, version) do
    case list(attrs["args"] || attrs["runtime_arguments"]) do
      [] -> [package_identifier(identifier, version)]
      args -> args
    end
  end

  defp package_args(attrs, "nuget", identifier, version) do
    case list(attrs["args"] || attrs["runtime_arguments"]) do
      [] -> [package_identifier(identifier, version), "--yes"]
      args -> args
    end
  end

  defp package_args(attrs, "oci", image, _version) do
    case list(attrs["args"] || attrs["runtime_arguments"]) do
      [] -> ["run", "-i", "--rm", image]
      args -> args
    end
  end

  defp package_args(attrs, _type, _identifier, _version),
    do: list(attrs["args"] || attrs["runtime_arguments"])

  defp package_identifier(identifier, ""), do: identifier
  defp package_identifier(identifier, version), do: identifier <> "@" <> version

  defp normalize_command_args(command, args) when is_list(args) do
    case Path.basename(string(command)) do
      "npx" ->
        if Enum.any?(args, &(&1 in ["-y", "--yes"])) do
          args
        else
          ["-y" | args]
        end

      _ ->
        args
    end
  end

  defp normalize_command_args(_command, _args), do: []

  defp schema_from_value(value) when is_map(value), do: schema_from_map(value)

  defp schema_from_value(value) when is_list(value) do
    value
    |> Enum.flat_map(fn
      %{} = spec ->
        spec = stringify(spec)
        name = string(spec["name"] || spec["env"] || spec["variable"])

        if name == "" do
          []
        else
          [{name, sanitize_schema_spec(name, Map.delete(spec, "name"))}]
        end

      _ ->
        []
    end)
    |> Map.new()
  end

  defp schema_from_value(_value), do: %{}

  defp schema_from_map(value) when is_map(value) do
    value
    |> stringify()
    |> Map.new(fn
      {key, %{} = spec} ->
        {key, sanitize_schema_spec(key, spec)}

      {key, value} ->
        {key, schema_value(key, value)}
    end)
  end

  defp fetch_first_json([]),
    do: {:error, {:bad_request, "MCP registry reference did not resolve"}}

  defp fetch_first_json([url | rest]) do
    case fetch_json(url) do
      {:ok, json} -> {:ok, json, url}
      {:error, _} -> fetch_first_json(rest)
    end
  end

  defp fetch_json(url) do
    with {:ok, target} <- SalixMCP.URLPolicy.public_http_target(url) do
      headers = [{"accept", "application/json"}, {"host", target.host_header}]

      case Req.get(
             target.url,
             headers: headers,
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}}
        when status in 200..299 and is_map(body) ->
          {:ok, stringify(body)}

        {:ok, %Req.Response{status: status, body: body}}
        when status in 200..299 and is_binary(body) ->
          case Jason.decode(body) do
            {:ok, %{} = decoded} -> {:ok, stringify(decoded)}
            _ -> {:error, {:bad_request, "MCP metadata response is not JSON"}}
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, {:bad_request, "fetch MCP metadata failed with HTTP #{status}"}}

        {:error, err} ->
          {:error, {:bad_request, Exception.message(err)}}
      end
    end
  end

  defp registry_url("", _server_name, _version), do: ""
  defp registry_url(_base, "", _version), do: ""

  defp registry_url(base, server_name, "") do
    base <> "/v0/servers/" <> URI.encode(server_name)
  end

  defp registry_url(base, server_name, version) do
    base <> "/v0/servers/" <> URI.encode(server_name) <> "/versions/" <> URI.encode(version)
  end

  defp schema_value(key, value) do
    secret? = SalixMCP.Secrets.secret_name?(key)

    %{"description" => key, "isSecret" => secret?}
    |> maybe_put_schema_value(secret?, value)
    |> maybe_required_secret(secret?)
  end

  defp sanitize_schema_spec(key, spec) do
    secret? = spec["isSecret"] in [true, "true", 1, "1"] or SalixMCP.Secrets.secret_name?(key)

    spec
    |> Map.put("isSecret", secret?)
    |> maybe_strip_secret_value(secret?)
    |> maybe_required_secret(secret?)
  end

  defp maybe_put_schema_value(schema, true, value) do
    if placeholder_value?(value) do
      Map.put(schema, "value", value)
    else
      schema
    end
  end

  defp maybe_put_schema_value(schema, false, value), do: Map.put(schema, "value", value)

  defp maybe_strip_secret_value(spec, false), do: spec

  defp maybe_strip_secret_value(spec, true) do
    if placeholder_value?(spec["value"] || spec["default"]) do
      spec
    else
      Map.drop(spec, ["value", "default"])
    end
  end

  defp maybe_required_secret(spec, true), do: Map.put_new(spec, "isRequired", true)
  defp maybe_required_secret(spec, false), do: spec

  defp placeholder_value?(value) when is_binary(value),
    do: Regex.match?(~r/\$\{[A-Za-z_][A-Za-z0-9_]*\}|(?<!\$)\{[A-Za-z_][A-Za-z0-9_]*\}/, value)

  defp placeholder_value?(_value), do: false

  defp normalize_transport("http"), do: "streamable-http"
  defp normalize_transport("streamable_http"), do: "streamable-http"

  defp normalize_transport(value) do
    case string(value) do
      "" -> "stdio"
      transport -> transport
    end
  end

  defp host_name(url) do
    case URI.parse(string(url)) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "mcp"
    end
  end

  defp slug(value) do
    value
    |> string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-_")
    |> case do
      "" -> "mcp"
      slug -> slug
    end
  end

  defp normalize_map(value) when is_map(value), do: stringify(value)
  defp normalize_map(_value), do: %{}

  defp list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list(_), do: []

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, stringify(value))

  defp nonblank(value, fallback) do
    case string(value) do
      "" -> string(fallback)
      value -> value
    end
  end

  defp bool(value, _default) when value in [true, "true", 1, "1"], do: true
  defp bool(value, _default) when value in [false, "false", 0, "0"], do: false
  defp bool(_value, default), do: default

  defp supports_server_value(attrs, metadata \\ %{}) do
    attrs["supports_server"] || attrs["supportsServer"] ||
      metadata["supports_server"] || metadata["supportsServer"]
  end

  defp server_support_note_value(attrs, metadata \\ %{}) do
    attrs["server_support_note"] || attrs["serverSupportNote"] ||
      metadata["server_support_note"] || metadata["serverSupportNote"]
  end

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
