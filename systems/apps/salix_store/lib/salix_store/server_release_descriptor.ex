defmodule SalixStore.ServerReleaseDescriptor do
  @moduledoc false

  @default_root "/opt/comma/install-artifacts"
  @descriptor "release-descriptor.json"
  @max_descriptor_bytes 262_144
  @root_fields ~w(server_build_id artifacts)
  @entry_fields ~w(component platform artifact release_id source sha256 size)
  @build_id ~r/^[0-9a-f]{40}$/
  @sha256 ~r/^[0-9a-f]{64}$/
  @release_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
  @targets [
    {"runner", "darwin-amd64", "mac-mini-provisioner"},
    {"runner", "darwin-arm64", "mac-mini-provisioner"},
    {"salix-connect", "linux-amd64", "salix-connect"},
    {"salix-connect", "linux-arm64", "salix-connect"},
    {"salix-connect", "darwin-amd64", "salix-connect"},
    {"salix-connect", "darwin-arm64", "salix-connect"},
    {"agent-vmm-host", "darwin-arm64", "Agent-VMM-Host.zip"}
  ]
  @target_files MapSet.new(@targets)
  @primary_artifacts %{
    "runner" => "mac-mini-provisioner",
    "salix-connect" => "salix-connect",
    "agent-vmm-host" => "Agent-VMM-Host.zip"
  }

  def target(component, platform), do: target(component, platform, @default_root)

  def target(component, platform, root) when is_binary(root) do
    with {:ok, descriptor} <- read(root),
         {:ok, entry} <-
           exact_entry(descriptor, component, platform, @primary_artifacts[component]) do
      {:ok,
       %{
         release_id: entry["release_id"],
         source: entry["source"],
         sha256: entry["sha256"],
         size: entry["size"]
       }}
    end
  end

  def server_build_id, do: server_build_id(@default_root)

  def server_build_id(root) when is_binary(root) do
    with {:ok, descriptor} <- read(root), do: {:ok, descriptor["server_build_id"]}
  end

  def install_platforms, do: install_platforms(@default_root)

  def install_platforms(root) when is_binary(root) do
    with {:ok, descriptor} <- read(root) do
      platforms =
        descriptor["artifacts"]
        |> Enum.group_by(& &1["component"], & &1["platform"])
        |> Map.new(fn {component, values} ->
          {component, values |> Enum.uniq() |> Enum.sort()}
        end)

      {:ok, platforms}
    end
  end

  defp read(root) do
    path = Path.join(root, @descriptor)

    with {:ok, stat} <- File.lstat(path),
         true <-
           (stat.type == :regular and stat.size <= @max_descriptor_bytes) ||
             {:error, :invalid_descriptor_file},
         {:ok, bytes} <- File.read(path),
         {:ok, descriptor} <- Jason.decode(bytes),
         :ok <- validate_descriptor(descriptor) do
      {:ok, descriptor}
    else
      {:error, reason} -> {:error, {:release_descriptor_unavailable, reason}}
    end
  end

  defp validate_descriptor(descriptor) when is_map(descriptor) do
    with :ok <- exact_fields(descriptor, @root_fields, :descriptor),
         true <-
           (is_binary(descriptor["server_build_id"]) and
              Regex.match?(@build_id, descriptor["server_build_id"])) ||
             {:error, :invalid_server_build_id},
         artifacts when is_list(artifacts) <- descriptor["artifacts"],
         :ok <- validate_entries(artifacts, descriptor["server_build_id"]) do
      :ok
    else
      false -> {:error, :invalid_descriptor}
      {:error, _} = error -> error
      _ -> {:error, :invalid_artifacts}
    end
  end

  defp validate_descriptor(_), do: {:error, :invalid_descriptor}

  defp validate_entries(entries, build_id) do
    Enum.reduce_while(entries, {:ok, MapSet.new()}, fn entry, {:ok, seen} ->
      with :ok <- validate_entry(entry, build_id),
           key = {entry["component"], entry["platform"], entry["artifact"]},
           :ok <- ensure_unique(seen, key) do
        {:cont, {:ok, MapSet.put(seen, key)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, seen} ->
        expected = @target_files

        if seen == expected,
          do: :ok,
          else: {:error, {:target_set_mismatch, MapSet.difference(expected, seen)}}

      error ->
        error
    end
  end

  defp validate_entry(entry, build_id) when is_map(entry) do
    key = {entry["component"], entry["platform"], entry["artifact"]}

    with :ok <- exact_fields(entry, @entry_fields, {:artifact, key}),
         :ok <- known_target(key),
         :ok <- valid_source(entry["source"], build_id, key),
         true <-
           (is_binary(entry["release_id"]) and Regex.match?(@release_id, entry["release_id"])) ||
             {:error, {:invalid_release_id, key}},
         true <-
           (is_binary(entry["sha256"]) and Regex.match?(@sha256, entry["sha256"])) ||
             {:error, {:invalid_sha256, key}},
         true <-
           (is_integer(entry["size"]) and entry["size"] > 0) || {:error, {:invalid_size, key}} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_entry(_, _), do: {:error, :invalid_artifact}

  defp ensure_unique(seen, key) do
    if MapSet.member?(seen, key), do: {:error, {:duplicate_target, key}}, else: :ok
  end

  defp known_target(key) do
    if MapSet.member?(@target_files, key), do: :ok, else: {:error, {:unknown_target, key}}
  end

  defp valid_source(source, build_id, {component, platform, artifact} = key)
       when is_binary(source) do
    suffix = "/releases/#{build_id}/#{component}/#{platform}/#{artifact}"

    case URI.new(source) do
      {:ok, uri} ->
        if not String.contains?(source, "%") and uri.scheme == "https" and
             is_binary(uri.host) and uri.host != "" and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             String.ends_with?(uri.path || "", suffix) and
             not String.contains?(uri.path || "", "/latest/") and
             not String.contains?(uri.path || "", "%") do
          :ok
        else
          {:error, {:invalid_source, key}}
        end

      {:error, _} ->
        {:error, {:invalid_source, key}}
    end
  end

  defp valid_source(_, _, key), do: {:error, {:invalid_source, key}}

  defp exact_fields(map, allowed, label) do
    unknown = Map.keys(map) -- allowed
    if unknown == [], do: :ok, else: {:error, {:unknown_fields, label, Enum.sort(unknown)}}
  end

  defp exact_entry(descriptor, component, platform, artifact) do
    matches =
      Enum.filter(descriptor["artifacts"], fn entry ->
        entry["component"] == component and entry["platform"] == platform and
          entry["artifact"] == artifact
      end)

    case matches do
      [entry] -> {:ok, entry}
      _ -> {:error, {:release_target_unavailable, component, platform}}
    end
  end
end
