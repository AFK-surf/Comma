defmodule BridgeForTeams.MacMiniOnboardingTest do
  use BridgeForTeams.DataCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{Auth, MacMiniOnboarding, Observability, Orgs}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.MacMiniInstallCode

  @server_build_id String.duplicate("a", 40)

  setup do
    {:ok, org} =
      Orgs.create_org(%{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"})

    %{org: org, release: release_fixture()}
  end

  test "create_install_code stores only the hash and Server build identity", %{org: org} do
    assert {:ok, %{code: raw_code, command: command, install_code: install_code}} =
             create_code(org)

    assert String.starts_with?(raw_code, "bfti_")
    assert String.starts_with?(command, "curl -fsSL ")

    reloaded = Repo.get!(MacMiniInstallCode, install_code.id)
    assert reloaded.code_hash == Sessions.hash_token(raw_code)
    assert reloaded.server_build_id == @server_build_id
    refute inspect(reloaded) =~ raw_code
    assert is_nil(reloaded.consumed_at)
  end

  test "create_install_code preserves an explicitly selected runner identity", %{org: org} do
    assert {:ok, %{code: raw_code, install_code: install_code}} =
             create_code(org, runner_stable_id: "runner-existing")

    assert install_code.runner_stable_id == "runner-existing"

    assert {:ok, %{token: token}} = MacMiniOnboarding.consume_install_code(org.id, raw_code)
    assert {:ok, %{runner_stable_id: "runner-existing"}} = Auth.authenticate_api_key(token)
  end

  test "create_install_code audit does not expose the bearer", %{org: org} do
    assert {:ok, %{code: raw_code, install_code: install_code}} =
             create_code(org,
               actor_label: "owner@example.com",
               audit_metadata: %{"reason" => "initial setup"}
             )

    assert [audit] = Observability.list_audit_logs(org.id, action: "runner_install_code.created")
    assert audit.resource_id == install_code.id
    assert audit.metadata["reason"] == "initial setup"
    assert audit.metadata["server_build_id"] == @server_build_id
    refute inspect(audit) =~ raw_code
  end

  test "missing Server release fails closed and records a redacted write attempt", %{org: org} do
    assert {:error, :server_release_unavailable} =
             MacMiniOnboarding.create_install_code(org.id,
               wrapper_url: wrapper_url(org),
               actor_label: "owner@example.com",
               request_id: "req_install_code_failed"
             )

    assert [audit] = Observability.list_audit_logs(org.id, action: "runner_install_code.created")
    assert audit.result == "failed"
    assert audit.reason_class == "server_release_unavailable"
    assert audit.request_id == "req_install_code_failed"
    refute inspect(audit) =~ "bfti_"
  end

  test "consume_install_code is single-use and lazy-mints the bound runner key", %{org: org} do
    assert {:ok, %{code: raw_code}} = create_code(org)

    assert {:ok, %{token: token, api_key: api_key, install_code: consumed}} =
             MacMiniOnboarding.consume_install_code(org.id, raw_code,
               request_id: "req_install_code_consumed"
             )

    assert String.starts_with?(token, "bft_")
    assert api_key.scopes == ["runners:write"]
    assert consumed.api_key_id == api_key.id
    assert %DateTime{} = consumed.consumed_at

    assert [event] =
             Observability.list_events(org.id, event_type: "runner.install_code.consumed")

    assert event.evidence["server_build_id"] == @server_build_id
    assert event.evidence["request_id"] == "req_install_code_consumed"
    refute inspect(event) =~ raw_code
    refute inspect(event) =~ token

    assert {:ok, %{org_id: org_id, runner_stable_id: stable_id}} =
             Auth.authenticate_api_key(token)

    assert org_id == org.id
    assert stable_id == consumed.runner_stable_id

    assert {:error, :code_already_consumed} =
             MacMiniOnboarding.consume_install_code(org.id, raw_code,
               request_id: "req_install_code_reused"
             )

    assert Repo.aggregate(
             from(k in BridgeForTeams.Schema.ApiKey, where: k.org_id == ^org.id),
             :count
           ) == 1
  end

  test "consume_install_code rejects expired codes", %{org: org} do
    now = DateTime.utc_now()
    assert {:ok, %{code: expired}} = create_code(org, now: now, ttl_seconds: 1)

    assert {:error, :code_expired} =
             MacMiniOnboarding.consume_install_code(org.id, expired,
               now: DateTime.add(now, 2, :second)
             )
  end

  test "wrapper fails closed when an artifact download fails", %{org: org, release: release} do
    root = Path.join(System.tmp_dir!(), "bft-wrapper-test-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    script_path = Path.join(root, "wrapper.sh")
    uname_path = Path.join(bin_dir, "uname")
    File.mkdir_p!(bin_dir)

    try do
      release =
        put_in(release, [:targets, "darwin-arm64", "salix-connect", :source], "file:///missing")

      File.write!(uname_path, "#!/usr/bin/env sh\n[ \"$1\" = -s ] && echo Darwin || echo arm64\n")
      File.chmod!(uname_path, 0o755)
      File.write!(script_path, script_for(org, release))
      File.chmod!(script_path, 0o755)

      {output, status} =
        System.cmd("sh", [script_path],
          env: [{"PATH", bin_dir <> ":" <> System.get_env("PATH", "")}],
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "preflight.salix_connect_download_failed"
    after
      File.rm_rf!(root)
    end
  end

  test "wrapper enforces the descriptor size before hashing an artifact", %{
    org: org,
    release: release
  } do
    root = Path.join(System.tmp_dir!(), "bft-wrapper-size-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    artifact_path = Path.join(root, "salix-connect")
    script_path = Path.join(root, "wrapper.sh")
    uname_path = Path.join(bin_dir, "uname")
    File.mkdir_p!(bin_dir)

    try do
      bytes = String.duplicate("x", 43)
      File.write!(artifact_path, bytes)
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      release =
        put_in(release, [:targets, "darwin-arm64", "salix-connect"], %{
          source: "file://#{artifact_path}",
          sha256: sha,
          size: 42
        })

      File.write!(uname_path, "#!/usr/bin/env sh\n[ \"$1\" = -s ] && echo Darwin || echo arm64\n")
      File.chmod!(uname_path, 0o755)
      File.write!(script_path, script_for(org, release))
      File.chmod!(script_path, 0o755)

      {output, status} =
        System.cmd("sh", [script_path],
          env: [{"PATH", bin_dir <> ":" <> System.get_env("PATH", "")}],
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "preflight.salix_connect_size_mismatch"
      assert output =~ "exceeds expected size 42"
    after
      File.rm_rf!(root)
    end
  end

  test "error response is executable and exits non-zero" do
    root = Path.join(System.tmp_dir!(), "bft-error-script-#{System.unique_integer([:positive])}")
    path = Path.join(root, "error.sh")
    File.mkdir_p!(root)

    try do
      File.write!(path, MacMiniOnboarding.error_script(:code_expired))
      File.chmod!(path, 0o755)
      {output, status} = System.cmd("sh", [path], stderr_to_stdout: true)
      assert status != 0
      assert output =~ "code_expired"
      refute output =~ "bft_"
    after
      File.rm_rf!(root)
    end
  end

  defp create_code(org, opts \\ []) do
    MacMiniOnboarding.create_install_code(
      org.id,
      Keyword.merge(
        [wrapper_url: wrapper_url(org), server_build_id: @server_build_id],
        opts
      )
    )
  end

  defp wrapper_url(org),
    do: "https://bridge.example.test/v1/orgs/#{org.id}/runners/install.sh"

  defp script_for(org, release) do
    {:ok, %{code: code}} = create_code(org)
    {:ok, consumed} = MacMiniOnboarding.consume_install_code(org.id, code)
    MacMiniOnboarding.wrapper_script(Map.put(consumed, :release, release))
  end

  defp release_fixture do
    components =
      for component <- ~w(runner salix-connect agent-vmm-host), into: %{} do
        {component,
         %{
           source: "https://releases.example.test/#{component}",
           sha256: String.duplicate("b", 64),
           size: 42
         }}
      end

    %{
      server_build_id: @server_build_id,
      api_base_url: "https://bridge.example.test",
      install_prefix: "$HOME/.bridge-for-teams",
      state_dir: "$HOME/.bridge-for-teams/state",
      launchd_label: "com.bridgeforteams.runner",
      targets: %{"darwin-arm64" => components}
    }
  end
end
