defmodule SalixAgent.Tools.ComposioTriggers do
  @moduledoc "Group-scoped provider triggers and Agent-owned Loop bindings."
  alias SalixAgent.{ComposioStore, OAuthStore}
  alias SalixStore.Loops

  @wait 30
  def defs do
    [
      tool(
        "list_trigger_types",
        "List Composio trigger types for a toolkit, one bounded page. Use get_trigger_type for configuration and event schemas.",
        %{toolkit: string(), cursor: string()},
        ["toolkit"],
        :list_types,
        "read"
      ),
      tool(
        "get_trigger_type",
        "Get a Composio trigger's configuration and event schemas, for example GMAIL_NEW_GMAIL_MESSAGE.",
        %{trigger_slug: string()},
        ["trigger_slug"],
        :get_type,
        "read"
      ),
      tool(
        "list_triggers",
        "List this group's Composio triggers, including disabled triggers, one page. Provider triggers can serve several Loops.",
        %{cursor: string()},
        [],
        :list,
        "read"
      ),
      tool(
        "create_trigger",
        "Create or reuse a trigger for an ACTIVE connected account and bind it to your Loop. Configure the project's secret webhook through the Composio settings API first. Replaces this Loop's previous binding. Repeated identical provider configuration reuses and enables the shared trigger. Existing triggers remain until explicitly disabled or deleted.",
        %{
          loop_id: string(),
          connected_account_id: string(),
          trigger_slug: string(),
          trigger_config: %{"type" => "object"}
        },
        ["loop_id", "connected_account_id", "trigger_slug"],
        :create,
        "write"
      ),
      tool(
        "bind_trigger",
        "Bind an existing group trigger to your Loop. Omit trigger_id to remove the binding. Each Loop has one trigger. Several Loops can share it. Pause retains the binding but drops incoming events. Delete removes the binding, not the shared provider trigger.",
        %{loop_id: string(), trigger_id: string()},
        ["loop_id"],
        :bind,
        "write"
      ),
      tool(
        "manage_trigger",
        "Enable, disable or delete a group-owned Composio trigger. This affects every Loop subscribed to this shared provider trigger. Deleted triggers require an explicit new binding.",
        %{
          trigger_id: string(),
          action: %{"type" => "string", "enum" => ["enable", "disable", "delete"]}
        },
        ["trigger_id", "action"],
        :manage,
        "write"
      )
    ]
  end

  defp string, do: %{"type" => "string", "minLength" => 1, "maxLength" => 256}

  defp tool(name, description, properties, required, function, safety) do
    schema = %{
      "type" => "object",
      "properties" => Map.new(properties, fn {k, v} -> {to_string(k), v} end),
      "required" => required,
      "additionalProperties" => false
    }

    {"composio." <> name, description, schema, Function.capture(__MODULE__, function, 2), @wait,
     [safety: safety]}
  end

  def list_types(args, ctx) do
    {settings, _group} = context!(ctx)
    result(client().list_trigger_types(settings, required!(args, "toolkit"), args["cursor"]), ctx)
  end

  def get_type(args, ctx) do
    {settings, _group} = context!(ctx)
    result(client().get_trigger_type(settings, required!(args, "trigger_slug")), ctx)
  end

  def list(args, ctx) do
    {settings, group} = context!(ctx)

    case client().list_triggers(settings, group, cursor: args["cursor"]) do
      {:ok, %{"items" => items} = page} when is_list(items) ->
        result(
          {:ok,
           %{
             "items" =>
               items
               |> Enum.filter(&(&1["user_id"] == group))
               |> Enum.map(
                 &Map.take(
                   &1,
                   ~w(id connected_account_id trigger_name trigger_config disabled_at updated_at)
                 )
               ),
             "next_cursor" => page["next_cursor"]
           }},
          ctx
        )

      error ->
        result(error, ctx)
    end
  end

  def create(args, ctx) do
    {settings, group} = context!(ctx)
    loop_id = required!(args, "loop_id")
    account = required!(args, "connected_account_id")
    slug = required!(args, "trigger_slug") |> String.upcase()
    config = args["trigger_config"] || %{}

    if not is_map(config) or byte_size(Jason.encode!(config)) > 16_384,
      do: raise("Invalid trigger_config")

    with :ok <- webhook_ready(settings),
         {:ok, _} <- Loops.get_agent_owned(loop_id, ctx.agent_id),
         {:ok, _} <- owned_account(settings, group, account, true),
         {:ok, %{"trigger_id" => id}} when is_binary(id) and byte_size(id) in 1..256 <-
           client().upsert_trigger(settings, group, account, slug, config),
         {:ok, row} <-
           Loops.bind_composio_trigger(
             loop_id,
             ctx.agent_id,
             binding(settings, id, account, slug)
           ) do
      result({:ok, SalixAgent.Loops.public(row)}, ctx)
    else
      {:error, _} = error -> result(error, ctx)
      _ -> result({:error, :invalid_composio_response}, ctx)
    end
  end

  def bind(args, ctx) do
    {settings, group} = context!(ctx)
    loop_id = required!(args, "loop_id")

    with {:ok, _} <- Loops.get_agent_owned(loop_id, ctx.agent_id),
         {:ok, value} <- binding_for(settings, group, args["trigger_id"]),
         {:ok, row} <- Loops.bind_composio_trigger(loop_id, ctx.agent_id, value) do
      result({:ok, SalixAgent.Loops.public(row)}, ctx)
    else
      error -> result(error, ctx)
    end
  end

  def manage(args, ctx) do
    {settings, group} = context!(ctx)
    id = required!(args, "trigger_id")
    action = required!(args, "action")
    if action not in ["enable", "disable", "delete"], do: raise("Invalid trigger action")

    with {:ok, _} <- owned_trigger(settings, group, id, action in ["disable", "delete"]),
         {:ok, _} <- client().manage_trigger(settings, group, id, action) do
      result({:ok, %{"trigger_id" => id, "status" => action}}, ctx)
    else
      error -> result(error, ctx)
    end
  end

  defp binding_for(_settings, _group, nil), do: {:ok, nil}

  defp binding_for(settings, group, id) when is_binary(id) and byte_size(id) in 1..256 do
    with :ok <- webhook_ready(settings),
         {:ok, trigger} <- owned_trigger(settings, group, id),
         {:ok, _} <- owned_account(settings, group, trigger["connected_account_id"], true) do
      {:ok, binding(settings, id, trigger["connected_account_id"], trigger["trigger_name"])}
    end
  end

  defp binding_for(_, _, _), do: {:error, :invalid_trigger_id}

  defp binding(settings, id, account, slug),
    do: %{
      "scope" => settings["scope"],
      "trigger_id" => id,
      "connected_account_id" => account,
      "trigger_slug" => slug
    }

  defp owned_trigger(settings, group, id, allow_missing_account \\ false) do
    case client().list_triggers(settings, group, trigger_id: id) do
      {:ok, %{"items" => items}} when is_list(items) ->
        case Enum.find(items, &(&1["id"] == id and &1["user_id"] == group)) do
          nil ->
            {:error, :not_found}

          trigger ->
            # A group-owned trigger can outlive its disconnected account.
            # Its provider user_id still authorizes disable/delete cleanup.
            case client().get_connected_account(settings, trigger["connected_account_id"],
                   error_mode: :structured
                 ) do
              {:ok, %{"user_id" => ^group}} -> {:ok, trigger}
              {:ok, _} -> {:error, :not_found}
              {:error, :not_found} when allow_missing_account -> {:ok, trigger}
              error -> error
            end
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_composio_response}
    end
  end

  defp owned_account(settings, group, id, active?) do
    with {:ok, account} <- client().get_connected_account(settings, id, error_mode: :structured) do
      cond do
        account["user_id"] != group -> {:error, :not_found}
        active? and account["status"] != "ACTIVE" -> {:error, :account_not_active}
        true -> {:ok, account}
      end
    end
  end

  defp context!(ctx) do
    with {:ok, %{tenant: tenant, group_id: group}} <- OAuthStore.agent_oauth_context(ctx.agent_id),
         {:ok, settings} <- ComposioStore.settings(tenant) do
      {settings, group}
    else
      _ -> raise "Composio is not configured for this Agent"
    end
  end

  defp webhook_ready(%{"webhook_configured" => true}), do: :ok
  defp webhook_ready(_), do: {:error, :configure_composio_webhook_in_settings}

  defp required!(args, key) do
    case args[key] do
      s when is_binary(s) and byte_size(s) in 1..256 -> s
      _ -> raise "#{key} must be a nonempty string of at most 256 bytes"
    end
  end

  defp result({:ok, data}, ctx),
    do: SalixAgent.IFC.ConnectorLabels.group_audience(Jason.encode!(data), ctx)

  defp result({:error, reason}, _ctx),
    do: raise("Composio trigger operation failed: #{inspect(reason)}")

  defp result(_, _ctx), do: raise("Invalid Composio trigger response")
  defp client, do: Application.get_env(:salix_agent, :composio_client_mod, SalixStore.Composio)
end
