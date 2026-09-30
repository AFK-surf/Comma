defmodule SalixMCP.ExecutionPolicy do
  @moduledoc false

  @trusted_sources ["operator_policy", "system_builtin"]
  @runner_app_env :server_process_runner

  def validate_server_process(definition, _binding, config) do
    cond do
      config["kind"] != "package" ->
        :ok

      not trusted_system_definition?(definition) ->
        not_runnable(
          "server-side MCP process execution requires a trusted system definition; use device placement or a remote MCP endpoint"
        )

      server_process_runner_configured?() ->
        :ok

      true ->
        not_runnable(
          "server-side MCP process execution requires a configured server process runner; use device placement or a remote MCP endpoint"
        )
    end
  end

  def server_process_spawn(config, binding \\ %{}) do
    with {:ok, runner} <- server_process_runner(),
         command <- string(runner["command"]),
         true <- command != "",
         runner_env <- normalize_map(runner["env"]),
         {:ok, executable} <- runner_executable(command, runner_env),
         working_dir <- server_working_dir(runner["working_dir"], binding),
         :ok <- ensure_server_working_dir(working_dir) do
      env =
        runner_env
        |> Map.merge(normalize_map(config["env"]))
        |> Map.merge(server_process_context_env(config, working_dir))
        |> valid_env()

      {:ok,
       %{
         executable: executable,
         args: list(runner["args"]) ++ [config["command"] | list(config["args"])],
         cd: working_dir,
         # MCP secrets belong in the exec environment block, not in argv.
         env: env
       }}
    else
      false ->
        {:error, {:bad_request, "server process runner command is required"}}

      {:error, _} = err ->
        err
    end
  end

  def trusted_system_definition?(definition) when is_map(definition) do
    system_definition?(definition) and server_process_trusted?(definition)
  end

  def trusted_system_definition?(_definition), do: false

  defp system_definition?(definition), do: string(definition["tenant_id"]) == ""

  defp server_process_trusted?(definition) do
    trust = get_in(definition, ["salix_metadata", "trust"]) || definition["trust"] || %{}

    truthy?(trust["server_process_execution"]) and trusted_source?(trust["source"])
  end

  defp trusted_source?(source), do: string(source) in @trusted_sources

  defp truthy?(value) when value in [true, "true", 1, "1", "allowed", "trusted"], do: true
  defp truthy?(_value), do: false

  defp server_process_runner_configured? do
    match?({:ok, _runner}, server_process_runner())
  end

  defp server_process_runner do
    case Application.get_env(:salix_mcp, @runner_app_env) do
      nil ->
        not_runnable(
          "server-side MCP process execution requires a configured server process runner; use device placement or a remote MCP endpoint"
        )

      false ->
        not_runnable(
          "server-side MCP process execution requires a configured server process runner; use device placement or a remote MCP endpoint"
        )

      value ->
        runner = normalize_runner(value)

        case string(runner["command"]) do
          "" ->
            not_runnable("server process runner command is required")

          _command ->
            {:ok, runner}
        end
    end
  end

  defp ensure_server_working_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> not_runnable("server process working_dir failed: #{reason}")
    end
  end

  defp server_working_dir(value, binding) do
    value = string(value)

    if value == "" do
      Path.join([
        System.tmp_dir!(),
        "salix-mcp-server-process",
        safe_binding_segment(binding)
      ])
    else
      value
    end
  end

  defp safe_binding_segment(%{"binding_id" => binding_id}) do
    binding_id
    |> string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp safe_binding_segment(_binding), do: "unknown"

  defp server_process_context_env(config, working_dir) do
    args = list(config["args"])

    %{
      "SALIX_MCP_COMMAND" => string(config["command"]),
      "SALIX_MCP_ARGS_JSON" => Jason.encode!(args),
      "SALIX_MCP_WORKING_DIR" => string(working_dir)
    }
  end

  defp runner_executable(command, _runner_env) when command == "",
    do: not_runnable("server process runner command is required")

  defp runner_executable(command, runner_env) do
    cond do
      Path.type(command) == :absolute ->
        if File.exists?(command) do
          {:ok, command}
        else
          not_runnable("server process runner command does not exist")
        end

      Path.type(command) == :relative and Path.dirname(command) != "." ->
        not_runnable(
          "server process runner command must be absolute or resolvable from runner PATH"
        )

      true ->
        case find_executable_in_path(command, runner_env_path(runner_env)) do
          nil ->
            not_runnable(
              "server process runner command must be absolute or resolvable from runner PATH"
            )

          executable ->
            {:ok, executable}
        end
    end
  end

  defp runner_env_path(env), do: string(env["PATH"] || env["Path"] || env["path"])

  defp find_executable_in_path(_command, ""), do: nil

  defp find_executable_in_path(command, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.find_value(fn dir ->
      candidate = Path.join(dir, command)
      if File.exists?(candidate), do: candidate, else: nil
    end)
  end

  defp valid_env(env) do
    env
    |> Enum.filter(fn {key, _value} -> valid_env_key?(key) end)
    |> Map.new()
  end

  defp valid_env_key?(key),
    do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, to_string(key))

  defp not_runnable(reason), do: {:error, {:not_runnable, reason}}

  defp normalize_runner(value) when is_binary(value), do: %{"command" => value}

  defp normalize_runner(value) when is_list(value) do
    if Keyword.keyword?(value), do: value |> Map.new() |> normalize_map(), else: %{}
  end

  defp normalize_runner(value), do: normalize_map(value)

  defp normalize_map(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {to_string(key), normalize_value(value)} end)

  defp normalize_map(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list(_value), do: []

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(value), do: value |> to_string() |> String.trim()
end
