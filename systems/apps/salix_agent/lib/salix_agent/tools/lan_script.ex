defmodule SalixAgent.Tools.LanScript do
  @moduledoc """
  `device.lan_script`: runs a JavaScript function on a LAN gateway (`lan_script`
  in `capabilities.lan_gateway.methods`), for device protocols that take more
  than one request, such as Gree air conditioners and Xiaomi miIO lamps. The
  gateway runs it in Micro QuickJS with its own `http_request`, `udp_request`
  and `lan_discover` and the bytes and crypto helpers (AFK-surf/Hardware
  docs/lan-script.md); Salix runs no script.

  The script comes from a file the Agent sees (a built-in skill's, such as
  `/.runtime/skills/gree-ac/gree.js`) or inline. `secrets` names saved device
  secrets (`SalixAgent.DeviceSecrets`) whose values Salix puts into `args` at
  dispatch, so the model never handles them; their values are removed from
  what the script returns. `files` puts workspace files into `args` as base64
  the same way, for bytes too big to write into a call (a JPEG to print).
  """

  alias SalixAgent.{DeviceSecrets, EnvDispatch, FileBackend}
  alias SalixAgent.Tools.DeviceSecrets, as: SecretTools
  alias SalixAgent.Tools.LanGateway

  @default_timeout_ms 10_000
  @max_timeout_ms 30_000
  # The smallest gateway's source limit, for a gateway that does not say its own.
  @default_max_source 8_192
  @max_secrets 8
  @max_files 4
  # The smallest gateway's request limit, for a gateway that does not say its own.
  @default_max_request 16_384
  # Room for the request's envelope (id, method) around its params.
  @envelope_bytes 256
  @redacted "[saved secret]"

  @doc false
  def max_timeout_ms, do: @max_timeout_ms

  def defs do
    [
      {"device.lan_script",
       "Run a JavaScript function on a gateway device on the user's local network, for device protocols that take several requests or encryption, such as Gree air conditioners and Xiaomi miIO lamps. Device skills name the script file to run and its args; use it as they say. The gateway must list lan_script in capabilities.lan_gateway.methods.

The script is the body of function (args) and returns a JSON value. It reaches the network only through the gateway: lan.http(request) and lan.udp(request) take the params of device.lan_request's HTTP and udp modes and return their results; bytes.* and crypto.* (AES ECB/CBC/GCM, MD5, SHA-1, SHA-256, HMAC) work on base64 strings. The language is ES5 strict (Micro QuickJS).

Give secrets to put saved device secrets into args by name: {\"token\": \"bedside-lamp\"} sets args.token to that secret's value, and args.host to its saved host when args has none. Never put a secret's value into args yourself. Give files to put workspace files into args as base64 the same way: {\"image\": \"/out/page.jpg\"} sets args.image; never copy file bytes into args yourself. The whole request must fit the gateway's lan_gateway.script.max_request_bytes. Every call counts as a write. Read the device state back after a change.",
       schema(), &__MODULE__.run/2, SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [safety: "write"]}
    ]
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["device_id"],
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" => "Gateway device_id from device.list or device.get."
        },
        "script" => %{
          "type" => "string",
          "description" =>
            "Path of the script file, such as /.runtime/skills/gree-ac/gree.js. Give script or source."
        },
        "source" => %{"type" => "string", "description" => "The script itself, inline."},
        "args" => %{"type" => "object", "description" => "The script's args."},
        "secrets" => %{
          "type" => "object",
          "maxProperties" => @max_secrets,
          "additionalProperties" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
          "description" => "args key -> name of a saved device secret (device.secret_list)."
        },
        "files" => %{
          "type" => "object",
          "maxProperties" => @max_files,
          "additionalProperties" => %{"type" => "string", "minLength" => 1},
          "description" => "args key -> workspace file path; its bytes go into args as base64."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1_000,
          "maximum" => @max_timeout_ms,
          "default" => @default_timeout_ms
        }
      }
    }
  end

  @doc false
  def run(args, ctx) do
    device_id = required!(args, "device_id")
    source = source!(args, ctx)
    script_args = Map.get(args, "args") || %{}
    unless is_map(script_args), do: raise("args must be an object")

    timeout_ms =
      case Map.get(args, "timeout_ms", @default_timeout_ms) do
        ms when is_integer(ms) and ms in 1_000..@max_timeout_ms -> ms
        _ -> raise "timeout_ms must be an integer from 1000 to #{@max_timeout_ms}"
      end

    with {:ok, target, gateway} <- gateway(device_id, ctx),
         :ok <- fits(device_id, source, gateway),
         {:ok, script_args} <- put_files(script_args, Map.get(args, "files"), ctx),
         {:ok, script_args, used} <- put_secrets(script_args, Map.get(args, "secrets"), ctx),
         params = %{"source" => source, "args" => script_args, "timeout_ms" => timeout_ms},
         :ok <- request_fits(device_id, params, gateway) do
      case EnvDispatch.request(ctx.agent_id, target, "lan_script", params) do
        {:ok, outcome} ->
          Enum.each(used, fn {group_id, secret, _value} ->
            DeviceSecrets.touch(group_id, secret)
          end)

          present(device_id, redact(outcome, Enum.map(used, &elem(&1, 2))))

        {:error, reason} ->
          LanGateway.request_failure(device_id, reason)
      end
    end
  end

  defp source!(args, ctx) do
    case {Map.get(args, "script"), Map.get(args, "source")} do
      {path, nil} when is_binary(path) and path != "" ->
        case FileBackend.read(ctx, path) do
          {:ok, body, _} when is_binary(body) and body != "" -> body
          _ -> raise "the script file #{path} was not found"
        end

      {nil, source} when is_binary(source) and source != "" ->
        source

      _ ->
        raise "give script (a file path) or source, not both"
    end
  end

  defp gateway(device_id, ctx) do
    case LanGateway.resolve_gateway(ctx.agent_id, device_id, ["lan_script"]) do
      {:ok, target, gateway, _method} -> {:ok, target, gateway}
      {:error, code, message} -> LanGateway.failure(device_id, code, message)
    end
  end

  defp fits(device_id, source, gateway) do
    max = get_in(gateway, ["script", "max_source_bytes"]) || @default_max_source

    if byte_size(source) <= max,
      do: :ok,
      else:
        LanGateway.failure(
          device_id,
          "script_too_large",
          "The script is #{byte_size(source)} bytes; this gateway takes at most #{max}."
        )
  end

  defp request_fits(device_id, params, gateway) do
    max = get_in(gateway, ["script", "max_request_bytes"]) || @default_max_request
    size = byte_size(Jason.encode!(params)) + @envelope_bytes

    if size <= max,
      do: :ok,
      else:
        LanGateway.failure(
          device_id,
          "script_request_too_large",
          "The script with its args and files is about #{size} bytes; this gateway takes at most #{max} in one request. Send a smaller file (a lower resolution or quality) or split the work."
        )
  end

  defp put_files(script_args, nil, _ctx), do: {:ok, script_args}

  defp put_files(script_args, files, ctx) when is_map(files) do
    if map_size(files) > @max_files, do: raise("at most #{@max_files} files")

    Enum.reduce(Enum.sort(files), {:ok, script_args}, fn
      {key, path}, {:ok, acc} when is_binary(key) and key != "" and is_binary(path) ->
        case FileBackend.read(ctx, path) do
          {:ok, body, _} when is_binary(body) -> {:ok, Map.put(acc, key, Base.encode64(body))}
          _ -> raise "the file #{path} was not found"
        end

      _, _ ->
        raise "files maps an args key to a workspace file path"
    end)
  end

  defp put_files(_script_args, _files, _ctx), do: raise("files must be an object")

  defp put_secrets(script_args, nil, _ctx), do: {:ok, script_args, []}

  defp put_secrets(script_args, secrets, ctx) when is_map(secrets) do
    if map_size(secrets) > @max_secrets, do: raise("at most #{@max_secrets} secrets")
    group_id = SecretTools.group_id!(ctx)

    Enum.reduce_while(Enum.sort(secrets), {:ok, script_args, []}, fn
      {key, name}, {:ok, acc, used} when is_binary(key) and key != "" and is_binary(name) ->
        case DeviceSecrets.resolve(group_id, name) do
          {:ok, value, secret} ->
            acc = Map.put(acc, key, value)

            acc =
              if is_binary(secret["host"]) and not Map.has_key?(acc, "host"),
                do: Map.put(acc, "host", secret["host"]),
                else: acc

            {:cont, {:ok, acc, [{group_id, secret, value} | used]}}

          {:error, reason} ->
            {:halt, SecretTools.failure(reason)}
        end

      _, _ ->
        raise "secrets maps an args key to a saved secret's name"
    end)
  end

  defp put_secrets(_script_args, _secrets, _ctx), do: raise("secrets must be an object")

  # A script can return what it was given: a secret's value never comes back,
  # in any letter case.
  defp redact(value, []), do: value

  defp redact(value, secrets) when is_binary(value) do
    Enum.reduce(secrets, value, fn secret, text ->
      String.replace(text, ~r/#{Regex.escape(secret)}/i, @redacted)
    end)
  end

  defp redact(value, secrets) when is_list(value), do: Enum.map(value, &redact(&1, secrets))

  defp redact(value, secrets) when is_map(value),
    do: Map.new(value, fn {k, v} -> {redact(k, secrets), redact(v, secrets)} end)

  defp redact(value, _secrets), do: value

  defp present(device_id, %{"error" => error} = outcome) when is_binary(error) do
    LanGateway.failure(device_id, "script_failed", String.slice(error, 0, 2_000), logs(outcome))
  end

  defp present(_device_id, %{"result" => _} = outcome) do
    outcome
    |> Map.take(~w(result logs logs_truncated))
    |> Map.reject(fn {key, value} -> key == "logs" and value == [] end)
    |> Jason.encode!()
  end

  defp present(device_id, _outcome) do
    LanGateway.failure(
      device_id,
      "gateway_request_failed",
      "The gateway answered the script with something else than a result. Read the target device's state before retrying."
    )
  end

  defp logs(%{"logs" => [_ | _] = logs} = outcome),
    do: Map.take(%{outcome | "logs" => logs}, ~w(logs logs_truncated))

  defp logs(_outcome), do: %{}

  defp required!(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "#{key} is required"
    end
  end
end
