defmodule SalixStore.Repo.Migrations.MaterializeSlackTaskAliases do
  use Ecto.Migration

  # Preserve the two aliases that the previous runtime already accepted for
  # existing Apps. This writes local configuration only. It does not register
  # commands, change Slack scopes, or grant new provider permissions.
  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)
    page([])
  end

  defp page(opts) do
    {:ok, %{objects: objects, next: next}} =
      SalixStore.S3.list("ctl/im_connects/", Keyword.put(opts, :max_keys, 100))

    for object <- objects do
      {:ok, _} =
        SalixStore.CasRecord.update(
          object.key,
          fn record ->
            if record["provider"] == "slack" and is_nil(record["deleted_at"]) and
                 not Map.has_key?(record, "slack_commands") do
              Map.put(record, "slack_commands", %{
                "app_id" => record["app_id"],
                "revision" => 0,
                "status" => "not_synced",
                "commands" => [
                  %{
                    "command" => "/newgpttask",
                    "description" => "Create a Codex task",
                    "usage_hint" => "<task>",
                    "prompt" => "Create a task using a Codex worker. Task content: ",
                    "enabled" => true
                  },
                  %{
                    "command" => "/newclaudetask",
                    "description" => "Create a Claude task",
                    "usage_hint" => "<task>",
                    "prompt" => "Create a task using a Claude worker. Task content: ",
                    "enabled" => true
                  }
                ]
              })
            else
              {:unchanged, record}
            end
          end,
          create: false
        )
    end

    if next, do: page(continuation_token: next), else: :ok
  end
end
