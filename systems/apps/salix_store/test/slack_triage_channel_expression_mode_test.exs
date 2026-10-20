defmodule SalixStore.SlackTriageChannelExpressionModeTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{Repo, SlackTriageChannels, ULID}

  setup do
    Repo.query!("TRUNCATE slack_triage_channels")
    :ok
  end

  test "same-workspace reinstall retains a channel exclusion while rotating its fence" do
    attrs = attrs("C_EXCLUDED")
    assert {:ok, before} = SlackTriageChannels.provision_and_set_enabled(attrs, false)

    assert {:ok, after_reconnect} =
             attrs
             |> Map.put("installation_generation", ULID.generate())
             |> Map.delete("channel_generation")
             |> SlackTriageChannels.provision()

    assert after_reconnect["enabled"] == false
    assert after_reconnect["channel_generation"] != before["channel_generation"]
  end

  test "a mode change rotates only its channel fence and an identical write is idempotent" do
    primary = attrs("C_PRIMARY")
    sibling = attrs("C_SIBLING", primary["installation_generation"])

    assert {:ok, before} = SlackTriageChannels.provision(primary)
    assert {:ok, sibling_before} = SlackTriageChannels.provision(sibling)

    assert :ok =
             SlackTriageChannels.set_expression_mode(
               primary["tenant_id"],
               primary["group_id"],
               primary["connect_id"],
               primary["channel_id"],
               primary["installation_generation"],
               "social"
             )

    assert {:ok, social} = get(primary)
    assert {:ok, sibling_after} = get(sibling)
    assert social["expression_mode"] == "social"
    refute social["channel_generation"] == before["channel_generation"]
    assert sibling_after["channel_generation"] == sibling_before["channel_generation"]

    assert :ok =
             SlackTriageChannels.set_expression_mode(
               primary["tenant_id"],
               primary["group_id"],
               primary["connect_id"],
               primary["channel_id"],
               primary["installation_generation"],
               "social"
             )

    assert {:ok, unchanged} = get(primary)
    assert unchanged["channel_generation"] == social["channel_generation"]
    assert unchanged["updated_at"] == social["updated_at"]

    assert {:error, :not_found} =
             SlackTriageChannels.set_expression_mode(
               primary["tenant_id"],
               primary["group_id"],
               primary["connect_id"],
               primary["channel_id"],
               ULID.generate(),
               "project"
             )
  end

  test "a different workspace never inherits the previous workspace policy" do
    attrs = attrs("C_REUSED")

    assert {:ok, social} =
             attrs
             |> Map.put("expression_mode", "social")
             |> SlackTriageChannels.provision()

    assert {:ok, replaced} =
             attrs
             |> Map.put("installation_generation", ULID.generate())
             |> Map.put("channel_generation", ULID.generate())
             |> Map.put("workspace_id", "T_OTHER")
             |> SlackTriageChannels.provision()

    assert replaced["expression_mode"] == "project"
    refute replaced["channel_generation"] == social["channel_generation"]
  end

  defp get(attrs) do
    SlackTriageChannels.get(
      attrs["tenant_id"],
      attrs["group_id"],
      attrs["connect_id"],
      attrs["channel_id"]
    )
  end

  defp attrs(channel_id, installation_generation \\ ULID.generate()) do
    %{
      "tenant_id" => "tenant-expression",
      "group_id" => "group-expression",
      "connect_id" => "connect-expression",
      "channel_id" => channel_id,
      "installation_generation" => installation_generation,
      "workspace_id" => "T_EXPRESSION",
      "channel_name" => "watercooler",
      "channel_generation" => ULID.generate()
    }
  end
end
