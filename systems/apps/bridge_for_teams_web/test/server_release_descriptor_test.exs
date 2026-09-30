defmodule BridgeForTeamsWeb.ServerReleaseDescriptorTest do
  use ExUnit.Case, async: true

  alias SalixStore.ServerReleaseDescriptor
  alias BridgeForTeamsWeb.MacMiniRelease

  @targets [
    {"runner", "darwin-amd64", "mac-mini-provisioner"},
    {"runner", "darwin-arm64", "mac-mini-provisioner"},
    {"salix-connect", "linux-amd64", "salix-connect"},
    {"salix-connect", "linux-arm64", "salix-connect"},
    {"salix-connect", "darwin-amd64", "salix-connect"},
    {"salix-connect", "darwin-arm64", "salix-connect"},
    {"agent-vmm-host", "darwin-arm64", "Agent-VMM-Host.zip"}
  ]
  @build_id String.duplicate("a", 40)

  test "reads the exact Server-bound target contract" do
    {root, descriptor} = fixture!()
    assert {:ok, @build_id} = ServerReleaseDescriptor.server_build_id(root)
    assert {:ok, platforms} = ServerReleaseDescriptor.install_platforms(root)
    assert platforms["agent-vmm-host"] == ["darwin-arm64"]

    assert {:ok, target} = ServerReleaseDescriptor.target("runner", "darwin-arm64", root)
    assert target.source =~ "/releases/#{@build_id}/runner/darwin-arm64/mac-mini-provisioner"
    assert target.release_id == @build_id
    assert target.sha256 == descriptor["artifacts"] |> Enum.at(1) |> Map.fetch!("sha256")

    assert {:error, {:release_target_unavailable, "runner", "linux-arm64"}} =
             ServerReleaseDescriptor.target("runner", "linux-arm64", root)
  end

  test "fails closed on malformed descriptor authority fields" do
    mutations = [
      fn descriptor -> Map.put(descriptor, "channel", "latest") end,
      fn descriptor -> Map.update!(descriptor, "artifacts", &(&1 ++ [hd(&1)])) end,
      fn descriptor -> update_first(descriptor, &Map.put(&1, "component", "unknown")) end,
      fn descriptor ->
        update_first(descriptor, &Map.put(&1, "source", "https://example.test/latest/runner"))
      end,
      fn descriptor -> update_first(descriptor, &Map.put(&1, "size", 0)) end,
      fn descriptor -> update_first(descriptor, &Map.put(&1, "sha256", "bad")) end,
      fn descriptor -> update_first(descriptor, &Map.put(&1, "release_id", "")) end
    ]

    Enum.each(mutations, fn mutate ->
      {root, descriptor} = fixture!()
      File.write!(Path.join(root, "release-descriptor.json"), Jason.encode!(mutate.(descriptor)))
      assert {:error, _} = ServerReleaseDescriptor.server_build_id(root)
    end)
  end

  test "reads the observed component release identity independently of transport digest" do
    capabilities = %{
      "component_releases" => %{
        "agent-vmm-host" => %{"release_id" => "agent-vmm-release-1"}
      },
      "component_digests" => %{"agent-vmm-host" => String.duplicate("a", 64)}
    }

    assert MacMiniRelease.component_release_id(capabilities, "agent-vmm-host") ==
             "agent-vmm-release-1"

    assert MacMiniRelease.component_release_id(%{}, "agent-vmm-host") == nil
    refute MacMiniRelease.update_available?(nil, "agent-vmm-release-2")
    refute MacMiniRelease.update_available?("agent-vmm-release-1", "agent-vmm-release-1")
    assert MacMiniRelease.update_available?("agent-vmm-release-1", "agent-vmm-release-2")

    refute MacMiniRelease.component_update_available?(%{}, "agent-vmm-host", %{
             "release_id" => "agent-vmm-release-2",
             "sha256" => String.duplicate("b", 64)
           })

    assert MacMiniRelease.component_update_available?(
             capabilities,
             "agent-vmm-host",
             %{
               "release_id" => "agent-vmm-release-2",
               "sha256" => capabilities["component_digests"]["agent-vmm-host"]
             }
           )
  end

  defp fixture! do
    root = Path.join(System.tmp_dir!(), "comma-descriptor-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)

    artifacts =
      Enum.map(@targets, fn {component, platform, file} ->
        bytes = "#{component}:#{platform}\n"

        %{
          "component" => component,
          "platform" => platform,
          "artifact" => file,
          "release_id" =>
            if(component == "agent-vmm-host", do: "agent-vmm-release-1", else: @build_id),
          "source" =>
            "https://comma-release.example/server-install-artifacts/releases/#{@build_id}/#{component}/#{platform}/#{file}",
          "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
          "size" => byte_size(bytes)
        }
      end)

    descriptor = %{"server_build_id" => @build_id, "artifacts" => artifacts}
    File.write!(Path.join(root, "release-descriptor.json"), Jason.encode!(descriptor))
    {root, descriptor}
  end

  defp update_first(descriptor, fun) do
    Map.update!(descriptor, "artifacts", fn [first | rest] -> [fun.(first) | rest] end)
  end
end
