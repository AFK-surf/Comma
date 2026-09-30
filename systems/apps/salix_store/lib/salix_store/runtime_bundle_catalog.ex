defmodule SalixStore.RuntimeBundleCatalog do
  @moduledoc """
  Product templates and immutable runtime descriptions carried by this Server release.

  The manifest supplies immutable import metadata and archive hashes. Salix assembles the
  fixed product CDN URL from that hash. The
  product template supplies behavior and resource policy. Neither callers nor
  deployment environment variables can substitute an image authority.
  """

  @classes ~w(external meeting shell)
  @runtime_bundle_public_base_url "https://comma-release.afk.surf"
  @container_log_limit_bytes 1_048_576
  @external_volume %{
    "role" => "provider_state",
    "destination" => "/workspace",
    "owner_uid" => 1_000,
    "owner_gid" => 1_000,
    "mode" => 0o700,
    "read_only" => false
  }
  @meeting_volume %{
    @external_volume
    | "owner_uid" => 10_001,
      "owner_gid" => 10_001
  }
  @templates %{
    "shell.default" => %{
      class: "shell",
      capabilities: ["runtime_exec", "runtime_process"],
      resources: %{
        "pid_max" => 512,
        "writable_quota_bytes" => 2_147_483_648
      },
      egress_mode: "deny_all"
    },
    "external.codex" => %{
      class: "external",
      capabilities: ["runtime_exec", "runtime_process"],
      volume_requirements: [@external_volume],
      resources: %{
        "pid_max" => 512,
        "writable_quota_bytes" => 2_147_483_648
      },
      egress_mode: "public_internet"
    },
    "external.claude" => %{
      class: "external",
      capabilities: ["runtime_exec", "runtime_process"],
      volume_requirements: [@external_volume],
      resources: %{
        "pid_max" => 512,
        "writable_quota_bytes" => 2_147_483_648
      },
      egress_mode: "public_internet"
    },
    "external.pi" => %{
      class: "external",
      capabilities: ["runtime_exec", "runtime_process"],
      volume_requirements: [@external_volume],
      resources: %{
        "pid_max" => 512,
        "writable_quota_bytes" => 2_147_483_648
      },
      egress_mode: "public_internet"
    },
    "meeting.meetnative" => %{
      class: "meeting",
      capabilities: ["runtime_exec", "runtime_process"],
      volume_requirements: [@meeting_volume],
      resources: %{
        "pid_max" => 512,
        "writable_quota_bytes" => 2_147_483_648
      },
      egress_mode: "public_internet"
    }
  }

  def keys, do: @templates |> Map.keys() |> Enum.sort()

  def resolve(key, opts \\ [])

  def resolve(key, opts) when is_binary(key) do
    with {:ok, template} <- fetch_template(key),
         {:ok, bundle} <- load(opts),
         {:ok, image} <- Map.fetch(bundle.images, template.class) do
      {:ok,
       template
       |> Map.put(:key, key)
       |> Map.put(:source_revision, bundle.source_revision)
       |> Map.put(:image, image)}
    else
      :error -> {:error, :runtime_bundle_incomplete}
      {:error, _} = error -> error
    end
  end

  def resolve(_, _), do: {:error, :unsupported_runtime_template}

  def materialize(key, attrs, opts \\ [])

  def materialize(key, attrs, opts) when is_map(attrs) do
    with {:ok, template} <- resolve(key, opts),
         {:ok, owner_id} <- required_string(attrs, :owner_id),
         {:ok, generation} <- positive_integer(attrs, :generation) do
      {:ok,
       %{
         template_key: template.key,
         runtime_revision: template.image["manifestDigest"],
         owner_id: owner_id,
         generation: generation,
         spec: %{
           "entrypoint" => [],
           "log_limit_bytes" => @container_log_limit_bytes,
           "platform" => "linux/arm64",
           "resources" => template.resources,
           "egress_mode" => template.egress_mode,
           "capabilities" => template.capabilities,
           "volume_requirements" => materialize_volume_requirements(template, owner_id),
           "runtime_artifact" => stored_artifact(template.image)
         }
       }}
    end
  end

  def materialize(_, _, _), do: {:error, :invalid_runtime_template_request}

  def image_for_workload(workload) do
    with {:ok, class} <- class_for_template(field(workload, :template_key)),
         artifact when is_map(artifact) <-
           workload |> field(:spec) |> field(:runtime_artifact),
         {:ok, image} <- validate_stored_artifact(artifact, class),
         true <-
           field(workload, :runtime_revision) == image["manifestDigest"] ||
             {:error, :invalid_runtime_artifact} do
      {:ok, image}
    else
      nil -> {:error, :runtime_artifact_rebuild_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_runtime_artifact}
    end
  end

  defp class_for_template(key) when is_binary(key) do
    with {:ok, template} <- fetch_template(key), do: {:ok, template.class}
  end

  defp class_for_template(_), do: {:error, :unsupported_runtime_template}

  def load(opts \\ []) do
    root = Keyword.get(opts, :root, bundle_root())

    with {:ok, raw} <- File.read(Path.join(root, "manifest.json")),
         {:ok, %{"schemaVersion" => 3, "sourceRevision" => revision, "images" => images}}
         when is_binary(revision) and is_list(images) <- Jason.decode(raw),
         {:ok, indexed} <- validate_images(images) do
      {:ok, %{source_revision: revision, root: root, images: indexed}}
    else
      {:error, :enoent} -> {:error, :runtime_bundle_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :invalid_runtime_bundle_manifest}
    end
  end

  defp validate_images(images) do
    with true <- length(images) == length(@classes),
         {:ok, indexed} <-
           Enum.reduce_while(images, {:ok, %{}}, fn image, {:ok, acc} ->
             case validate_image(image) do
               {:ok, class} when not is_map_key(acc, class) ->
                 image =
                   image
                   |> Map.drop(["inputDigest"])
                   |> Map.put(
                     "archiveUrl",
                     "#{@runtime_bundle_public_base_url}/runtime-bundles/sha256/#{image["archiveSha256"]}.oci.tar"
                   )

                 {:cont, {:ok, Map.put(acc, class, image)}}

               _ ->
                 {:halt, {:error, :invalid_runtime_bundle_manifest}}
             end
           end),
         true <- Map.keys(indexed) |> Enum.sort() == @classes do
      {:ok, indexed}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_runtime_bundle_manifest}
    end
  end

  defp validate_image(%{
         "class" => class,
         "reference" => reference,
         "platform" => "linux/arm64",
         "archiveSize" => archive_size,
         "archiveSha256" => archive_sha,
         "manifestDigest" => "sha256:" <> manifest_sha
       })
       when class in @classes and is_integer(archive_size) and
              archive_size > 0 and is_binary(archive_sha) and byte_size(archive_sha) == 64 and
              byte_size(manifest_sha) == 64 do
    if reference == "comma.local/runtime/#{class}@sha256:#{manifest_sha}" and
         hex?(archive_sha) and hex?(manifest_sha) do
      {:ok, class}
    else
      {:error, :invalid_runtime_bundle_manifest}
    end
  end

  defp validate_image(_), do: {:error, :invalid_runtime_bundle_manifest}

  defp stored_artifact(image) do
    %{
      "class" => image["class"],
      "platform" => image["platform"],
      "manifest_digest" => image["manifestDigest"],
      "reference" => image["reference"],
      "archive_sha256" => image["archiveSha256"],
      "archive_size" => image["archiveSize"],
      "archive_url" => image["archiveUrl"]
    }
  end

  defp validate_stored_artifact(
         %{
           "class" => class,
           "platform" => "linux/arm64",
           "manifest_digest" => "sha256:" <> manifest_sha,
           "reference" => reference,
           "archive_sha256" => archive_sha,
           "archive_size" => archive_size,
           "archive_url" => archive_url
         } = artifact,
         class
       )
       when map_size(artifact) == 7 and is_integer(archive_size) and archive_size > 0 and
              is_binary(archive_sha) and byte_size(archive_sha) == 64 and
              byte_size(manifest_sha) == 64 and is_binary(archive_url) do
    uri = URI.parse(archive_url)

    if reference == "comma.local/runtime/#{class}@sha256:#{manifest_sha}" and
         hex?(archive_sha) and hex?(manifest_sha) and uri.scheme == "https" and
         is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and
         String.ends_with?(uri.path || "", "/runtime-bundles/sha256/#{archive_sha}.oci.tar") do
      {:ok,
       %{
         "class" => class,
         "platform" => "linux/arm64",
         "manifestDigest" => "sha256:#{manifest_sha}",
         "reference" => reference,
         "archiveSha256" => archive_sha,
         "archiveSize" => archive_size,
         "archiveUrl" => archive_url
       }}
    else
      {:error, :invalid_runtime_artifact}
    end
  end

  defp validate_stored_artifact(_, _), do: {:error, :invalid_runtime_artifact}

  defp fetch_template(key) do
    case Map.fetch(@templates, key) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, :unsupported_runtime_template}
    end
  end

  defp materialize_volume_requirements(template, owner_id) do
    Enum.map(Map.get(template, :volume_requirements, []), fn requirement ->
      Map.put(requirement, "volume_id", provider_state_volume_id(owner_id, requirement["role"]))
    end)
  end

  defp provider_state_volume_id(owner_id, role) do
    digest =
      :crypto.hash(:sha256, Enum.join([role, owner_id], ":"))
      |> Base.encode16(case: :lower)

    "salix-vol-" <> binary_part(digest, 0, 52)
  end

  defp bundle_root,
    do: Application.get_env(:salix_store, :runtime_bundle_root, "/opt/comma/runtime-images")

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, Atom.to_string(key))

  defp hex?(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp required_string(attrs, key) do
    case field(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp positive_integer(attrs, key) do
    case field(attrs, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid, key}}
    end
  end
end
