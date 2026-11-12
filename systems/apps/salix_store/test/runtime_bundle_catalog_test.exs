defmodule SalixStore.RuntimeBundleCatalogTest do
  use SystemsClock.Case, async: true

  alias SalixStore.RuntimeBundleCatalog

  @templates [
    "shell.default",
    "station.default"
  ]
  @root Path.expand("fixtures/runtime-bundle", __DIR__)

  test "maps the fixed product templates onto the release-bundled images" do
    assert RuntimeBundleCatalog.keys() == Enum.sort(@templates)

    for key <- @templates do
      assert {:ok, template} = RuntimeBundleCatalog.resolve(key, root: @root)
      assert template.source_revision == "test-runtime-revision"
      assert template.image["platform"] == "linux/arm64"

      assert template.image["archiveUrl"] ==
               "https://comma-release.afk.surf/runtime-bundles/sha256/#{template.image["archiveSha256"]}.oci.tar"
    end
  end

  test "materializes the digest, inline descriptor, and product policy" do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "station.default",
               %{
                 owner_id: "workload-1",
                 generation: 3,
                 image: "https://untrusted.example/image",
                 command: ["curl", "latest"]
               },
               root: @root
             )

    assert materialized.template_key == "station.default"
    digest = "sha256:" <> String.duplicate("d", 64)
    assert materialized.runtime_revision == digest

    assert materialized.spec["runtime_artifact"] == %{
             "class" => "station",
             "platform" => "linux/arm64",
             "manifest_digest" => digest,
             "reference" => "comma.local/runtime/station@" <> digest,
             "archive_sha256" =>
               "47721ddbed08259663f848ff30b14ca2f844ba8fcc7fb03f8f3074e64a76d4c5",
             "archive_size" => 8,
             "archive_url" =>
               "https://comma-release.afk.surf/runtime-bundles/sha256/47721ddbed08259663f848ff30b14ca2f844ba8fcc7fb03f8f3074e64a76d4c5.oci.tar"
           }

    assert materialized.spec["egress_mode"] == "public_internet"
    assert materialized.spec["log_limit_bytes"] == 1_048_576

    assert %{
             "pid_max" => 2048,
             "writable_quota_bytes" => 17_179_869_184
           } = materialized.spec["resources"]

    assert [volume] = materialized.spec["volume_requirements"]

    assert volume == %{
             "role" => "provider_state",
             "volume_id" => "salix-vol-e3693ab172cb92e6ca632dbf18be85a089ecbd8a173da86e4f52",
             "destination" => "/workspace",
             "owner_uid" => 1_000,
             "owner_gid" => 1_000,
             "mode" => 0o700,
             "read_only" => false
           }

    refute Map.has_key?(materialized.spec, "egress")
    refute Map.has_key?(materialized.spec, "image")
    refute Map.has_key?(materialized.spec, "command")
  end

  test "keeps each template's provider volume stable across generations of one workload" do
    for {template, owner} <- [{"station.default", 1_000}, {"shell.default", 10_001}] do
      assert {:ok, first} =
               RuntimeBundleCatalog.materialize(
                 template,
                 %{owner_id: "workload-1", generation: 1},
                 root: @root
               )

      assert [volume] = first.spec["volume_requirements"]
      assert volume["owner_uid"] == owner
      assert volume["owner_gid"] == owner
      assert volume["destination"] == "/workspace"
      assert volume["read_only"] == false

      assert {:ok, replacement} =
               RuntimeBundleCatalog.materialize(
                 template,
                 %{owner_id: "workload-1", generation: 2},
                 root: @root
               )

      assert first.spec["volume_requirements"] == replacement.spec["volume_requirements"]

      assert {:ok, other} =
               RuntimeBundleCatalog.materialize(
                 template,
                 %{owner_id: "workload-2", generation: 1},
                 root: @root
               )

      refute first.spec["volume_requirements"] == other.spec["volume_requirements"]
    end
  end

  test "recovers the image only from the stored descriptor" do
    assert {:ok, workload} =
             RuntimeBundleCatalog.materialize(
               "station.default",
               %{owner_id: "workload-1", generation: 1},
               root: @root
             )

    assert {:ok, image} = RuntimeBundleCatalog.image_for_workload(workload)
    assert image["manifestDigest"] == workload.runtime_revision
    assert image["reference"] == workload.spec["runtime_artifact"]["reference"]

    legacy = %{workload | spec: Map.delete(workload.spec, "runtime_artifact")}

    assert {:error, :runtime_artifact_rebuild_required} =
             RuntimeBundleCatalog.image_for_workload(legacy)

    tampered = %{workload | runtime_revision: "sha256:" <> String.duplicate("9", 64)}

    assert {:error, :invalid_runtime_artifact} =
             RuntimeBundleCatalog.image_for_workload(tampered)
  end
end
