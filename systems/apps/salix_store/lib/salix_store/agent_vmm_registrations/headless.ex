defmodule SalixStore.AgentVMMRegistrations.Headless do
  @moduledoc "Command and script projections of the existing Registration delivery."

  @bootstrap_path "/v1/compute/agent-vmm/install.sh"
  @script_path "/v1/compute/agent-vmm/registrations/install.sh"
  @claim_path "/v1/compute/agent-vmm/registrations/claim"
  # Stage 2 per platform the bootstrap reports: `uname` on the machine picks it.
  @platforms %{"linux-arm64" => "linux-install.sh", "darwin-arm64" => "darwin-install.sh"}
  @installers Map.new(@platforms, fn {platform, file} ->
                {platform, Path.expand("../../../priv/agent_vmm/" <> file, __DIR__)}
              end)
  for {_platform, path} <- @installers, do: @external_resource(path)
  @scripts Map.new(@installers, fn {platform, path} -> {platform, File.read!(path)} end)
  @bootstrapper Path.expand("../../../priv/agent_vmm/bootstrap.sh", __DIR__)
  @external_resource @bootstrapper
  @bootstrap File.read!(@bootstrapper)

  def platforms, do: Map.keys(@platforms)

  @doc "The release's Host artifact for a platform the install command serves."
  def target(platform) when is_map_key(@platforms, platform),
    do: SalixStore.ServerReleaseDescriptor.target("agent-vmm-host", platform)

  def target(_platform), do: {:error, :unsupported_platform}

  def delivery(base_url) do
    with {:ok, origin} <- origin(base_url),
         true <- Enum.any?(platforms(), &match?({:ok, _}, target(&1))) do
      {:ok, origin}
    else
      _ -> {:error, :install_delivery_unavailable}
    end
  end

  def command(descriptor, base_url) do
    with {:ok, origin} <- origin(base_url) do
      # The token joins the Registration ID and ticket with one dot. The bootstrap
      # script sends it in a POST body, never in a URL.
      token = if descriptor.ticket, do: descriptor.registration.id <> "." <> descriptor.ticket

      command =
        "curl -fsSL #{quote_shell(origin <> @bootstrap_path)} | sh -s -- #{token}"

      {:ok,
       %{
         registration: descriptor.registration,
         command: if(token, do: String.trim(command)),
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

  def script(handoff, secret, platform, target, base_url) do
    with {:ok, origin} <- origin(base_url) do
      descriptor =
        if handoff.expires_at do
          Jason.encode!(%{
            version: 1,
            registration_id: handoff.registration_id,
            request_id: handoff.request_id,
            claim_url: origin <> @claim_path,
            ticket: secret,
            expires_at: DateTime.to_iso8601(handoff.expires_at)
          })
        else
          ""
        end

      values = %{
        "URL" => quote_shell(target.source),
        "SHA" => quote_shell(target.sha256),
        "SIZE" => Integer.to_string(target.size),
        "REGISTRATION_ID" => quote_shell(handoff.registration_id),
        "REQUEST_ID" => quote_shell(handoff.request_id),
        "DESCRIPTOR" => descriptor,
        "CAN_CLAIM" => if(handoff.expires_at, do: "1", else: "0")
      }

      {:ok,
       Regex.replace(
         ~r/@(URL|SHA|SIZE|REGISTRATION_ID|REQUEST_ID|DESCRIPTOR|CAN_CLAIM)@/,
         Map.fetch!(@scripts, platform),
         fn _, name ->
           Map.fetch!(values, name)
         end
       )}
    end
  end

  def error_script do
    "#!/bin/sh\nprintf '%s\\n' 'The Compute Host install operation is unavailable. Return to Compute settings and check its status.' >&2\nexit 1\n"
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
