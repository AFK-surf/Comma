defmodule SalixAgent.Tools.Miio do
  @moduledoc """
  `device.miio_request`: one miIO command to a Xiaomi device (Mi lamps,
  Yeelight family) on the user's network, sent through a LAN gateway's
  `udp_request`. Salix encrypts and decrypts (`SalixAgent.LanCodec.Miio`);
  the gateway only carries the datagrams.

  The device token is a saved Group secret (`SalixAgent.DeviceSecrets`)
  named by `token_ref`. It is read at dispatch and used only as the codec
  key, so it never enters the call, its result or the transcript.
  """

  alias SalixAgent.{DeviceSecrets, LanCodec}
  alias SalixAgent.Tools.DeviceSecrets, as: SecretTools

  def defs do
    [
      {"device.miio_request",
       "Send one miIO command (UDP 54321, encrypted with the device token) to a Xiaomi device on the user's network, such as a Mi bedside lamp, through a gateway device whose lan_gateway methods include udp_request. token_ref names a miio_token saved with device.secret_save; the platform reads the token itself. Returns the device's decoded reply. Read the state back after a change.",
       schema(), &__MODULE__.request/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(), [safety: "write"]}
    ]
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(device_id token_ref method),
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" => "Gateway device_id from device.list or device.get."
        },
        "host" => %{
          "type" => "string",
          "description" =>
            "IP address of the Xiaomi device on the gateway's network. Defaults to the host saved with the secret."
        },
        "token_ref" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 64,
          "description" => "Name of the saved miio_token (device.secret_list)."
        },
        "method" => %{"type" => "string", "description" => "miIO method, such as get_prop."},
        "params" => %{
          "type" => ["array", "object"],
          "default" => [],
          "description" => "Method parameters."
        }
      }
    }
  end

  @doc false
  def request(args, ctx) do
    device_id = required!(args, "device_id")
    token_ref = required!(args, "token_ref")
    method = required!(args, "method")

    params =
      case Map.get(args, "params", []) do
        params when is_list(params) or is_map(params) -> params
        _ -> raise "params must be an array or an object"
      end

    group_id = SecretTools.group_id!(ctx)

    with {:ok, token, secret} <- resolve(group_id, token_ref),
         {:ok, host} <- host(args, secret) do
      # A saved miio_token always has the codec's format.
      {:ok, key} = LanCodec.Miio.key(token)

      case LanCodec.request(
             LanCodec.Miio,
             device_id,
             host,
             key,
             %{"method" => method, "params" => params},
             ctx
           ) do
        {:ok, payload} ->
          DeviceSecrets.touch(group_id, secret)
          Jason.encode!(%{"host" => host, "result" => Map.get(payload, "result")})

        failure ->
          failure
      end
    end
  end

  defp resolve(group_id, token_ref) do
    case DeviceSecrets.resolve(group_id, token_ref, "miio_token") do
      {:ok, token, secret} -> {:ok, token, secret}
      {:error, reason} -> SecretTools.failure(reason)
    end
  end

  defp host(args, secret) do
    case Map.get(args, "host") || secret["host"] do
      host when is_binary(host) and host != "" -> {:ok, host}
      _ -> raise "host is required: the saved secret has no host"
    end
  end

  defp required!(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "#{key} is required"
    end
  end
end
