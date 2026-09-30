defmodule BridgeForTeamsWeb.MacMiniRelease do
  @moduledoc """
  Read-only projection of the artifacts bound to the running Server image.

  R2 is only a byte channel. Every expected digest and size comes from the
  image descriptor owned by `ServerReleaseDescriptor`; the installer verifies
  the downloaded bytes before replacing a component.
  """

  alias SalixStore.ServerReleaseDescriptor

  @install_platform "darwin-arm64"
  @install_components ~w(runner salix-connect agent-vmm-host)
  @salix_connect "salix-connect"
  @agent_vmm "agent-vmm"

  @doc "Return the current Server-bound release for the install wrapper."
  def install_release(conn \\ nil) do
    with {:ok, server_build_id} <- ServerReleaseDescriptor.server_build_id(),
         {:ok, targets} <- targets(@install_platform) do
      {:ok,
       %{
         server_build_id: server_build_id,
         api_base_url: api_base_url(conn),
         install_prefix: "$HOME/.bridge-for-teams",
         state_dir: "$HOME/.bridge-for-teams/state",
         launchd_label: "com.bridgeforteams.runner",
         targets: %{@install_platform => targets}
       }}
    end
  end

  def server_build_id, do: ServerReleaseDescriptor.server_build_id()

  def api_base_url(conn \\ nil) do
    conn
    |> dashboard_base_url()
    |> String.trim_trailing("/")
  end

  def update_available?(observed_release_id, target_release_id) do
    observed_release_id = string(observed_release_id)
    target_release_id = string(target_release_id)

    observed_release_id != "" and target_release_id != "" and
      observed_release_id != target_release_id
  end

  def component_update_available?(capabilities, component, target)
      when is_map(capabilities) and is_binary(component) and is_map(target) do
    update_available?(component_release_id(capabilities, component), target["release_id"])
  end

  def component_update_available?(_capabilities, _component, _target), do: false

  def component_release_id(capabilities, component)
      when is_map(capabilities) and is_binary(component) do
    capabilities
    |> Map.get("component_releases", %{})
    |> case do
      releases when is_map(releases) ->
        releases
        |> Map.get(component, %{})
        |> case do
          release when is_map(release) ->
            release |> Map.get("release_id") |> string() |> blank_to_nil()

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  def component_release_id(_capabilities, _component), do: nil

  def component_versions_label(capabilities) when is_map(capabilities) do
    capabilities
    |> Map.get("component_versions", %{})
    |> case do
      versions when is_map(versions) ->
        versions
        |> Enum.sort_by(fn {component, _version} -> component end)
        |> Enum.flat_map(fn {component, version} ->
          case string(version) do
            "" -> []
            version -> ["#{component}=#{version}"]
          end
        end)

      _ ->
        []
    end
    |> case do
      [] -> "—"
      values -> Enum.join(values, ", ")
    end
  end

  def component_versions_label(_capabilities), do: "—"

  def observed_component_version(capabilities, component)
      when is_map(capabilities) and is_binary(component) do
    capabilities
    |> Map.get("component_versions", %{})
    |> case do
      versions when is_map(versions) ->
        versions |> Map.get(component) |> string() |> blank_to_nil()

      _ ->
        nil
    end
  end

  def observed_component_version(_capabilities, _component), do: nil

  def updates(_conn, provisioner) do
    case provisioner_platform(provisioner) do
      nil -> disabled_updates("unsupported_platform")
      platform -> updates_for_platform(platform)
    end
  end

  defp updates_for_platform(platform) do
    with {:ok, salix_connect} <- ServerReleaseDescriptor.target("salix-connect", platform),
         {:ok, agent_vmm_host} <- ServerReleaseDescriptor.target("agent-vmm-host", platform) do
      %{
        @salix_connect => update_target(@salix_connect, salix_connect),
        @agent_vmm => update_target("agent-vmm-host", agent_vmm_host)
      }
    else
      {:error, _reason} -> disabled_updates("server_release_unavailable")
    end
  end

  defp update_target(component, target) do
    %{
      "component" => component,
      "release_id" => target.release_id,
      "artifact_url" => target.source,
      "sha256" => target.sha256,
      "size" => target.size
    }
  end

  defp disabled_updates(reason) do
    %{
      @salix_connect => %{"component" => @salix_connect, "error" => reason},
      @agent_vmm => %{"component" => "agent-vmm-host", "error" => reason}
    }
  end

  defp targets(platform) do
    Enum.reduce_while(@install_components, {:ok, %{}}, fn component, {:ok, values} ->
      case ServerReleaseDescriptor.target(component, platform) do
        {:ok, target} -> {:cont, {:ok, Map.put(values, component, target)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp provisioner_platform(provisioner) do
    capabilities =
      Map.get(provisioner, :capabilities) || Map.get(provisioner, "capabilities") || %{}

    case capabilities["platform"] || capabilities[:platform] do
      "darwin-arm64" -> "darwin-arm64"
      _ -> platform_from_os_summary(Map.get(provisioner, :os_summary))
    end
  end

  defp platform_from_os_summary(summary) when is_binary(summary) do
    if String.contains?(summary, "arm64"), do: "darwin-arm64", else: nil
  end

  defp platform_from_os_summary(_), do: nil

  defp dashboard_base_url(%Plug.Conn{} = _conn), do: dashboard_base_url(nil)

  defp dashboard_base_url(_conn) do
    case Application.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> dashboard_endpoint_base_url()
    end
  end

  defp dashboard_endpoint_base_url do
    endpoint_config =
      Application.get_env(:bridge_for_teams_web, BridgeForTeamsWeb.DashboardEndpoint, [])

    url_config = Keyword.get(endpoint_config, :url, [])
    http_config = Keyword.get(endpoint_config, :http, [])
    scheme = Keyword.get(url_config, :scheme, "http")
    host = Keyword.get(url_config, :host, "localhost")
    port = Keyword.get(url_config, :port) || Keyword.get(http_config, :port)

    port_suffix =
      case {scheme, port} do
        {"http", port} when port in [nil, 80] -> ""
        {"https", port} when port in [nil, 443] -> ""
        {_scheme, nil} -> ""
        {_scheme, port} -> ":#{port}"
      end

    "#{scheme}://#{host}#{port_suffix}"
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(_value), do: ""
end
