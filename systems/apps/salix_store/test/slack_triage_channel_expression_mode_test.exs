defmodule SalixStore.SlackTriageChannelExpressionModeTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Repo, SlackTriageChannels, ULID}

  setup do
    Repo.query!("TRUNCATE slack_triage_channels")
    :ok
  end

  test "the additive database default keeps an old insert project-only" do
    attrs = attrs("C_OLD")
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO slack_triage_channels (
        tenant_id, group_id, connect_id, channel_id, installation_generation,
        workspace_id, channel_name, channel_generation, enabled,
        provisioned_at, updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, TRUE, $9, $9)
      """,
      [
        attrs["tenant_id"],
        attrs["group_id"],
        attrs["connect_id"],
        attrs["channel_id"],
        attrs["installation_generation"],
        attrs["workspace_id"],
        attrs["channel_name"],
        attrs["channel_generation"],
        now
      ]
    )

    assert {:ok, channel} =
             SlackTriageChannels.get(
               attrs["tenant_id"],
               attrs["group_id"],
               attrs["connect_id"],
               attrs["channel_id"]
             )

    assert channel["expression_mode"] == "project"

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "slack_triage_channels_valid_expression_mode"}
            }} =
             Repo.query(
               "UPDATE slack_triage_channels SET expression_mode = 'presentation-name' WHERE channel_id = $1",
               [attrs["channel_id"]]
             )
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

  test "old provision calls preserve an explicit mode across rename and same-workspace revalidation" do
    attrs = attrs("C_SOCIAL")

    assert {:ok, social} =
             attrs
             |> Map.put("expression_mode", "social")
             |> SlackTriageChannels.provision()

    assert social["expression_mode"] == "social"

    assert {:ok, renamed} =
             attrs
             |> Map.put("channel_name", "project-looking-name")
             |> SlackTriageChannels.provision()

    assert renamed["channel_name"] == "project-looking-name"
    assert renamed["expression_mode"] == "social"
    assert renamed["channel_generation"] == social["channel_generation"]

    assert {:error, :invalid_slack_triage_channel} =
             attrs
             |> Map.put("expression_mode", nil)
             |> SlackTriageChannels.provision()
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
