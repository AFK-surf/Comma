defmodule SalixStore.AgentVMMInstallations.Headless do
  @moduledoc "Command and script projections of the existing installation handoff."

  @bootstrap_path "/v1/compute/agent-vmm/install.sh"
  @script_path "/v1/compute/agent-vmm/install-operations/install.sh"
  @exchange_path "/v1/compute/agent-vmm/install-operations/exchange"
  @installer Path.expand("../../../priv/agent_vmm/linux-install.sh", __DIR__)
  @external_resource @installer
  @script File.read!(@installer)
  @bootstrapper Path.expand("../../../priv/agent_vmm/linux-bootstrap.sh", __DIR__)
  @external_resource @bootstrapper
  @bootstrap File.read!(@bootstrapper)

  def delivery(base_url) do
    with {:ok, origin} <- origin(base_url),
         {:ok, _target} <-
           SalixStore.ServerReleaseDescriptor.target("agent-vmm-host", "linux-arm64") do
      {:ok, origin}
    else
      _ -> {:error, :install_delivery_unavailable}
    end
  end

  def command(descriptor, base_url) do
    with {:ok, origin} <- origin(base_url) do
      # The token joins the operation id and secret with one dot. The bootstrap
      # script sends it in a POST body, never in a URL.
      token = descriptor.operation.id <> "." <> descriptor.one_time_secret

      command =
        "curl -fsSL #{quote_shell(origin <> @bootstrap_path)} | sudo sh -s -- #{token}"

      {:ok,
       %{
         operation: descriptor.operation,
         command: String.trim(command),
         expires_at: DateTime.to_iso8601(descriptor.expires_at)
       }}
    end
  end

  @doc "Secret-free stage 1 script. It posts the command token to the stage 2 script route."
  def bootstrap(base_url) do
    with {:ok, origin} <- origin(base_url) do
      {:ok, String.replace(@bootstrap, "@STAGE2_URL@", quote_shell(origin <> @script_path))}
    end
  end

  def script(handoff, secret, target, base_url) do
    with {:ok, origin} <- origin(base_url) do
      descriptor =
        if handoff.expires_at do
          Jason.encode!(%{
            version: 1,
            operation_id: handoff.operation_id,
            exchange_url: origin <> @exchange_path,
            one_time_secret: secret,
            expires_at: DateTime.to_iso8601(handoff.expires_at)
          })
        else
          ""
        end

      values = %{
        "URL" => quote_shell(target.source),
        "SHA" => quote_shell(target.sha256),
        "SIZE" => Integer.to_string(target.size),
        "OPERATION_ID" => quote_shell(handoff.operation_id),
        "DESCRIPTOR" => descriptor,
        "CAN_EXCHANGE" => if(handoff.expires_at, do: "1", else: "0")
      }

      {:ok,
       Regex.replace(~r/@(URL|SHA|SIZE|OPERATION_ID|DESCRIPTOR|CAN_EXCHANGE)@/, @script, fn _,
                                                                                            name ->
         Map.fetch!(values, name)
       end)}
    end
  end

  def error_script do
    "#!/bin/sh\nprintf '%s\\n' 'The Linux install operation is unavailable. Return to Compute settings and check its status.' >&2\nexit 1\n"
  end

  defp origin(base_url) when is_binary(base_url) do
    case URI.new(base_url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when is_binary(host) and host != "" ->
        if is_nil(uri.userinfo) and
             (scheme == "https" or
                (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"])) do
          {:ok, URI.to_string(%{uri | path: nil, query: nil, fragment: nil})}
        else
          {:error, :install_delivery_unavailable}
        end

      _ ->
        {:error, :install_delivery_unavailable}
    end
  end

  defp origin(_), do: {:error, :install_delivery_unavailable}

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
