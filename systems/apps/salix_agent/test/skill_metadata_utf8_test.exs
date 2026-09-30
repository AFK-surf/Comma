defmodule SalixAgent.SkillMetadataUtf8Test do
  use ExUnit.Case, async: false

  alias SalixAgent.SkillStore

  # Byte-truncated CJK — the shape that corrupted a production skill's
  # name/description and, through the prompt's skill index section, every
  # system-prompt snapshot built from the catalog.
  @truncated_cjk binary_part("接入", 0, 4)

  setup do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    :ok
  end

  test "prepare_group_create scrubs invalid UTF-8 from name and description" do
    ctx = %{
      agent_id: "agt1_" <> Integer.to_string(System.unique_integer([:positive])),
      group_id: "grp1_0000000000000000001",
      tenant_id: "ten1_0000000000000000001"
    }

    assert {:ok, event} =
             SkillStore.prepare_group_create(ctx, %{
               "skill_id" => "slack-local-machine-onboarding",
               "name" => "通过 Slack " <> @truncated_cjk,
               "description" => "当有人说“把我的电脑/Mac " <> @truncated_cjk,
               "content" => "---\nname: x\n---\nbody"
             })

    skill = event["skill"]
    assert String.valid?(skill["name"])
    assert String.valid?(skill["description"])
    assert String.valid?(skill["normalized_name"])
    assert skill["name"] == "通过 Slack 接�"
    assert skill["description"] == "当有人说“把我的电脑/Mac 接�"

    # The prompt section renders these verbatim; they must be encodable.
    assert {:ok, _} = Jason.encode(skill)
  end
end
