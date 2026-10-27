defmodule SalixIM.Provider.Apps do
  @moduledoc "Router tools for Mini App management through the product owner."

  @app_id %{"type" => "string", "minLength" => 1, "maxLength" => 64}
  @version %{"type" => "integer", "minimum" => 1}
  @visibility %{"type" => "string", "enum" => ~w(private workspace link)}
  @token %{"type" => "string", "minLength" => 43, "maxLength" => 43}
  @secret_name %{"type" => "string", "minLength" => 1, "maxLength" => 64}

  # One catalog supplies tool discovery and dispatch parameter validation.
  def manual do
    [
      operation(
        "publish",
        "Publish a ready Version. Comma accepts its build Task review, opens the pull request if needed, merges the deployed commit and makes it live. Use get to choose version. A failed merge leaves the live Version unchanged. Retry after resolving the reported error.",
        ~w(app_id version),
        %{"version" => @version, "visibility" => @visibility}
      ),
      operation(
        "update",
        "Change an app's name, description or visibility. Leaving link visibility revokes its link and removes other Workspaces' installs.",
        ~w(app_id),
        %{
          "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 60},
          "description" => %{"type" => "string", "maxLength" => 500},
          "visibility" => @visibility
        }
      ),
      operation(
        "rollback",
        "Make a previous ready Version live. This does not change the GitHub repository.",
        ~w(app_id version),
        %{"version" => @version}
      ),
      operation(
        "disable",
        "Stop an app for every viewer. Keep its data and Versions.",
        ~w(app_id)
      ),
      operation(
        "enable",
        "Start an owner-disabled app again. A platform takedown cannot be undone here.",
        ~w(app_id)
      ),
      operation(
        "delete",
        "Delete an app, revoke sharing and remove installs. Cleanup deletes its bundles, backend and stored app data. The GitHub repository remains.",
        ~w(app_id),
        %{},
        "destructive"
      ),
      operation(
        "link.get",
        "Read the app's active share link, or null when it has none.",
        ~w(app_id),
        %{},
        "read"
      ),
      operation(
        "link.create",
        "Create or return the app's share link and set link visibility. Give the returned URL to people outside the Workspace.",
        ~w(app_id)
      ),
      operation(
        "link.reset",
        "Replace the share link. The old link stops working and other Workspaces' installs are removed.",
        ~w(app_id)
      ),
      operation(
        "link.revoke",
        "Revoke the share link and remove other Workspaces' installs.",
        ~w(app_id)
      ),
      operation(
        "grants.set",
        "Replace this Workspace's capability grants for an owned or installed app. An empty list revokes all grants. Read get for the app's capabilities and current grants.",
        ~w(app_id grants),
        %{"grants" => %{"type" => "array", "maxItems" => 32, "items" => %{"type" => "string"}}}
      ),
      operation(
        "secrets.set",
        "Set a backend secret. Comma seals its value and updates the live backend. Results contain names only. Never put values in source code or replies.",
        ~w(app_id name value),
        %{
          "name" => @secret_name,
          "value" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096}
        }
      ),
      operation(
        "secrets.delete",
        "Remove a backend secret and update the live backend.",
        ~w(app_id name),
        %{"name" => @secret_name}
      ),
      operation(
        "install",
        "Install a shared app in this Workspace using its link token. Set pinned_version to pin a ready Version. Omit it to follow the live Version, including when updating an install.",
        ~w(token),
        %{"token" => @token, "pinned_version" => @version}
      ),
      operation(
        "uninstall",
        "Remove a shared app from this Workspace. The source app and its data remain.",
        ~w(app_id)
      ),
      operation(
        "remix",
        "Copy a shared app's live source into this Workspace's GitHub repository and start its build Task. Uses a share link token. Returns the new app and Task.",
        ~w(token),
        %{"token" => @token}
      ),
      operation(
        "report",
        "Report an owned, installed or link-visible app to the platform.",
        ~w(app_id reason),
        %{"reason" => %{"type" => "string", "minLength" => 1, "maxLength" => 2000}}
      )
    ]
  end

  defp operation(action, description, required, properties \\ %{}, safety \\ "write") do
    properties =
      if "app_id" in required, do: Map.put(properties, "app_id", @app_id), else: properties

    %{
      "name" => "internal.apps." <> action,
      "safety" => safety,
      "roles" => ["router"],
      "description" => description,
      "required_params" => required,
      "input_schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => required,
        "properties" => properties
      }
    }
  end

  def call(%{agent: %{"role" => "router"}} = scope, api, params) when is_map(params) do
    with %{} = operation <- Enum.find(manual(), &(&1["name"] == api)),
         schema = operation["input_schema"],
         :ok <- validate_params(params, schema),
         {:ok, result} <-
           SalixIM.MiniApps.manage(
             Map.take(scope, [:tenant_id, :group_id, :agent_id]),
             String.replace_prefix(api, "internal.apps.", ""),
             params
           ) do
      {:ok, result}
    else
      nil -> {:error, "unknown Mini App operation"}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}}, _api, _params),
    do: {:error, "params must be a JSON object"}

  def call(_scope, _api, _params),
    do: {:error, "operation is not authorized for this agent role"}

  defp validate_params(params, schema) do
    schema
    |> ExJsonSchema.Schema.resolve()
    |> ExJsonSchema.Validator.validate(params)
    |> case do
      :ok ->
        :ok

      {:error, errors} ->
        {:error,
         {:bad_request,
          Enum.map_join(errors, "; ", fn {message, path} -> "#{path}: #{message}" end)}}
    end
  end

  defp error({:bad_request, message}), do: message
  defp error({:conflict, message}), do: message
  defp error({:github, _status, message}), do: "GitHub refused the operation: #{message}"

  defp error(:deploy_latest_first),
    do: "Deploy the latest changes first. Then publish that Version."

  defp error(:not_found),
    do:
      "App or Version not found in this Workspace. Read internal.apps.list or internal.apps.get."

  defp error(:forbidden), do: "This operation is not authorized for this app."
  defp error(:mini_apps_unavailable), do: "Mini Apps are unavailable in this Workspace."
  defp error(reason) when is_binary(reason), do: reason
  defp error(reason), do: "Mini App operation failed: #{inspect(reason)}"
end
