defmodule CommaWeb.OAuthCommit do
  @moduledoc false

  alias Comma.{PluginInstallAttempts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}

  # OAuth token exchange runs before this call. Claiming the Comma generation is
  # durable before Salix writes the connection or binding. A second row lock
  # covers those writes, so cancel and a later authorization cannot overtake
  # an in-flight callback.
  def run(%{"comma_operation" => operation} = auth, write)
      when is_map(operation) and is_function(write, 0) do
    workspace_id = operation["workspace_id"]
    plugin_id = operation["plugin_id"]
    generation = operation["generation"]
    user_id = operation["user_id"]
    state = auth["state"]

    with true <- valid_operation?(operation, auth),
         {:ok, _} <-
           PluginInstallAttempts.with_lock_rollback(workspace_id, plugin_id, fn attempt ->
             PluginInstallAttempts.claim_reauthorization_callback_locked(
               attempt,
               generation,
               state,
               user_id
             )
           end),
         {:ok, result} <-
           PluginInstallAttempts.with_lock_rollback(workspace_id, plugin_id, fn attempt ->
             if attempt.generation == generation and attempt.provider_state == state and
                  get_in(attempt.operation_data || %{}, ["callback_phase"]) == "committing" do
               result = write.()
               # An error can follow a successful write to a different store, or
               # mean that a write landed but its response was lost. Once the
               # callback has claimed the generation, cancellation cannot claim
               # that the old binding is intact based on the return tuple alone.
               outcome = if match?({:ok, _}, result), do: "committed", else: "uncertain"

               with {:ok, _} <-
                      PluginInstallAttempts.finish_reauthorization_callback_locked(
                        attempt,
                        generation,
                        state,
                        outcome
                      ) do
                 {:ok, result}
               end
             else
               {:error, :stale_plugin_operation}
             end
           end) do
      result
    else
      _ -> {:error, "authorization operation changed or expired"}
    end
  end

  def run(_, _), do: {:error, "authorization operation unavailable"}

  defp valid_operation?(operation, auth) do
    workspace_id = operation["workspace_id"]
    user_id = operation["user_id"]

    is_binary(workspace_id) and is_binary(user_id) and
      is_binary(operation["plugin_id"]) and is_integer(operation["generation"]) and
      is_binary(auth["state"]) and
      case Repo.get(Workspace, workspace_id) do
        %Workspace{} = workspace ->
          workspace.owner_user_id == user_id and
            workspace.salix_tenant_id == auth["tenant"] and
            workspace.salix_group_id == auth["group_id"] and
            not is_nil(
              Repo.get_by(WorkspaceMembership,
                workspace_id: workspace_id,
                user_id: user_id,
                role: "owner",
                status: "active"
              )
            )

        nil ->
          false
      end
  end
end
