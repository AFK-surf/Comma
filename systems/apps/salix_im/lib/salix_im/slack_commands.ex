defmodule SalixIM.SlackCommands do
  @moduledoc """
  App-scoped prompt aliases owned by the existing IM Connect.
  Mutation is exposed only through the authenticated admin dashboard.
  Reads share the callback's canonical connect snapshot. No global fallback.
  """

  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixStore.{CasRecord, Keys, SlackCommandControl}

  @max_commands 50
  @fields ~w(command description usage_hint prompt enabled)

  def list(connect) do
    state = state(connect)
    state["commands"] || []
  end

  def state(%{"app_id" => app_id} = connect) when is_binary(app_id) and app_id != "" do
    case connect["slack_commands"] do
      %{"app_id" => ^app_id} = state ->
        state

      _ ->
        %{
          "app_id" => connect["app_id"],
          "revision" => 0,
          "commands" => [],
          "status" => "not_configured"
        }
    end
  end

  # Legacy connections can be used for delivery without an App registration.
  # They have no command authority, including when stored state has a nil App ID.
  def state(connect) when is_map(connect) do
    %{"app_id" => nil, "revision" => 0, "commands" => [], "status" => "not_configured"}
  end

  def resolve(connect, command) do
    case Enum.find(list(connect), &(&1["command"] == command and &1["enabled"] == true)) do
      nil -> {:error, :command_unavailable}
      entry -> {:ok, entry["prompt"]}
    end
  end

  def get(tenant_id, group_id, connect_id) do
    with {:ok, _} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, connect} <- ProviderConnects.fetch_im_connect(group_id, connect_id),
         true <-
           connect["provider"] == "slack" and connect["tenant_id"] == tenant_id and
             is_nil(connect["deleted_at"]) do
      {:ok,
       Map.take(connect, ~w(app_id app_name group_id connect_id))
       |> Map.put("configuration", state(connect))
       |> Map.put("oauth_url", ProviderConnects.slack_oauth_url(connect))}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def validate(entries) when is_list(entries) and length(entries) <= @max_commands do
    names = Enum.map(entries, &if(is_map(&1), do: &1["command"]))

    if length(Enum.uniq(names)) == length(names) and Enum.all?(entries, &valid_entry?/1) do
      {:ok, Enum.map(entries, &Map.take(&1, @fields))}
    else
      {:error, :invalid_commands}
    end
  end

  def validate(_), do: {:error, :invalid_commands}

  defp valid_entry?(entry) when is_map(entry) do
    name = entry["command"]

    is_binary(name) and Regex.match?(~r|^/[a-z0-9_-]{1,31}$|, name) and
      text?(entry["description"], 2000, false) and text?(entry["usage_hint"], 1000, true) and
      text?(entry["prompt"], 16_000, false) and is_boolean(entry["enabled"])
  end

  defp valid_entry?(_), do: false

  defp text?(text, max, empty?) do
    is_binary(text) and byte_size(text) <= max and (empty? or String.trim(text) != "")
  end

  def save(tenant_id, group_id, connect_id, app_id, revision, entries, profile \\ "default") do
    with true <- SlackCommandControl.valid_profile?(profile),
         {:ok, entries} <- validate(entries) do
      SlackCommandControl.exclusive(fn ->
        with {:ok, _} <- get(tenant_id, group_id, connect_id),
             {:ok, saved} <-
               update(group_id, connect_id, app_id, fn state ->
                 if state["revision"] == revision do
                   state
                   |> Map.put("commands", entries)
                   |> Map.put("credential_profile", profile)
                   |> Map.put("revision", revision + 1)
                   |> Map.put("status", "pending")
                   |> Map.delete("error")
                 else
                   {:error, :command_configuration_changed}
                 end
               end) do
          SalixIM.SlackCommandSync.sync(saved)
        end
      end)
    else
      false -> {:error, :invalid_credential_profile}
      error -> error
    end
  end

  def retry_sync(tenant_id, group_id, connect_id, app_id) do
    SlackCommandControl.exclusive(fn ->
      with {:ok, _} <- get(tenant_id, group_id, connect_id),
           {:ok, connect} <-
             update(group_id, connect_id, app_id, &Map.put(&1, "status", "pending")) do
        SalixIM.SlackCommandSync.sync(connect)
      end
    end)
  end

  @doc false
  def update(group_id, connect_id, app_id, fun) do
    CasRecord.update(
      Keys.ctl_im_connect(group_id, connect_id),
      fn connect ->
        if connect["app_id"] == app_id and connect["provider"] == "slack" and
             is_nil(connect["deleted_at"]) do
          case fun.(state(connect)) do
            {:error, _} = error -> error
            next -> Map.put(connect, "slack_commands", next)
          end
        else
          {:error, :command_app_changed}
        end
      end,
      create: false
    )
  end

  def task_aliases do
    [
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
  end
end
