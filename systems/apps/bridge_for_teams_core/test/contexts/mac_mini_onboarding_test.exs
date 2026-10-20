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
      Orgs.create_org(%{
        name: "Acme",
        slug: "acme-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      })

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
    now = SystemsClock.utc_now()
    assert {:ok, %{code: expired}} = create_code(org, now: now, ttl_seconds: 1)

    assert {:error, :code_expired} =
             MacMiniOnboarding.consume_install_code(org.id, expired,
               now: DateTime.add(now, 2, :second)
             )
  end

  test "the install wrapper carries the Computer Use helper only when the release has it", %{
    org: org,
    release: release
  } do
    assert {:ok, %{install_code: install_code}} = create_code(org)

    wrapper = fn release ->
      MacMiniOnboarding.wrapper_script(%{
        org: org,
        install_code: install_code,
        token: "bft_token",
        release: release
      })
    end

    helper = %{
      source: "https://releases.example.test/computer-use-helper",
      sha256: String.duplicate("c", 64),
      size: 43
    }

    with_helper =
      wrapper.(put_in(release, [:targets, "darwin-arm64", "computer-use-helper"], helper))

    assert with_helper =~
             "export BFT_COMPUTER_USE_HELPER_URL='https://releases.example.test/computer-use-helper'"

    assert with_helper =~ "export BFT_COMPUTER_USE_HELPER_SIZE='43'"
    refute wrapper.(release) =~ "BFT_COMPUTER_USE_HELPER_URL="
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
