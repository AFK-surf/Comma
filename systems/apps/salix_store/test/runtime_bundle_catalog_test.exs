defmodule SalixStore.RuntimeBundleCatalogTest do
  use ExUnit.Case, async: true

  alias SalixStore.RuntimeBundleCatalog

  @templates [
    "shell.default",
    "external.claude",
    "external.codex",
    "external.pi",
    "meeting.meetnative"
  ]
  @root Path.expand("fixtures/runtime-bundle", __DIR__)

  test "maps the five fixed product templates onto the three release-bundled images" do
    assert RuntimeBundleCatalog.keys() == Enum.sort(@templates)

    assert {:ok, codex} = RuntimeBundleCatalog.resolve("external.codex", root: @root)
    assert {:ok, claude} = RuntimeBundleCatalog.resolve("external.claude", root: @root)
    assert {:ok, pi} = RuntimeBundleCatalog.resolve("external.pi", root: @root)
    assert codex.image == claude.image
    assert codex.image == pi.image
    assert codex.class == "external"
    assert codex.source_revision == "test-runtime-revision"

    for key <- ["shell.default", "meeting.meetnative"] do
      assert {:ok, template} = RuntimeBundleCatalog.resolve(key, root: @root)
      assert template.image["platform"] == "linux/arm64"

      assert template.image["archiveUrl"] ==
               "https://comma-release.afk.surf/runtime-bundles/sha256/#{template.image["archiveSha256"]}.oci.tar"
    end
  end

  test "Claude materializes the shared non-root external Workload policy" do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.claude",
               %{owner_id: "claude-workload", generation: 1},
               root: @root
             )

    assert materialized.template_key == "external.claude"
    assert materialized.spec["egress_mode"] == "public_internet"

    assert [
             %{
               "destination" => "/workspace",
               "owner_uid" => 1_000,
               "owner_gid" => 1_000,
               "mode" => 0o700,
               "read_only" => false
             }
           ] = materialized.spec["volume_requirements"]
  end

  test "materializes the digest, inline descriptor, and product policy" do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{
                 owner_id: "workload-1",
                 generation: 3,
                 image: "https://untrusted.example/image",
                 command: ["curl", "latest"]
               },
               root: @root
             )

    assert materialized.template_key == "external.codex"
    digest = "sha256:" <> String.duplicate("a", 64)
    assert materialized.runtime_revision == digest

    assert materialized.spec["runtime_artifact"] == %{
             "class" => "external",
             "platform" => "linux/arm64",
             "manifest_digest" => digest,
             "reference" => "comma.local/runtime/external@" <> digest,
             "archive_sha256" =>
               "1b665050c87b37aa6ac165e4d12580794f99fa769fc6a87d482923a5be8465bb",
             "archive_size" => 9,
             "archive_url" =>
               "https://comma-release.afk.surf/runtime-bundles/sha256/1b665050c87b37aa6ac165e4d12580794f99fa769fc6a87d482923a5be8465bb.oci.tar"
           }

    assert materialized.spec["egress_mode"] == "public_internet"
    assert materialized.spec["log_limit_bytes"] == 1_048_576

    assert %{
             "pid_max" => 512,
             "writable_quota_bytes" => 2_147_483_648
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

  test "keeps the provider volume stable across generations of one workload" do
    assert {:ok, first} =
             RuntimeBundleCatalog.materialize(
               "external.pi",
               %{owner_id: "workload-1", generation: 1},
               root: @root
             )

    assert {:ok, replacement} =
             RuntimeBundleCatalog.materialize(
               "external.pi",
               %{owner_id: "workload-1", generation: 2},
               root: @root
             )

    assert first.spec["volume_requirements"] == replacement.spec["volume_requirements"]

    assert {:ok, other} =
             RuntimeBundleCatalog.materialize(
               "external.pi",
               %{owner_id: "workload-2", generation: 1},
               root: @root
             )

    refute first.spec["volume_requirements"] == other.spec["volume_requirements"]
  end

  test "materializes a Meeting-owned writable workspace" do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "meeting.meetnative",
               %{owner_id: "meeting-workload", generation: 1},
               root: @root
             )

    assert [volume] = materialized.spec["volume_requirements"]
    assert volume["destination"] == "/workspace"
    assert volume["owner_uid"] == 10_001
    assert volume["owner_gid"] == 10_001
    assert volume["mode"] == 0o700
    refute volume["read_only"]
  end

  test "fails closed for unknown templates or a missing bundle" do
    assert {:error, :unsupported_runtime_template} =
             RuntimeBundleCatalog.resolve("arbitrary.image", root: @root)

    assert {:error, :runtime_bundle_unavailable} =
             RuntimeBundleCatalog.resolve("shell.default", root: Path.join(@root, "missing"))
  end

  test "recovers the image only from the stored descriptor" do
    assert {:ok, workload} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
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
