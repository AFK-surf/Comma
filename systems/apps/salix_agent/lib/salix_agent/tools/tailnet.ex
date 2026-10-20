defmodule SalixAgent.Tools.Tailnet do
  @moduledoc """
  `tailnet.*`: the Group's node in the user's own Tailscale network
  (`SalixAgent.Tailnet`).

  Every Agent of the Group reads the status and the peers, and reaches
  devices with `ssh.open` or `web.http_request` and `via_tailnet`. Only the
  Router connects or disconnects the Group, and only the Router sees the
  login link: a tailnet admin who opens it adds the Group's node to their
  tailnet.

  The Group comes from the runtime identity, never from an argument.
  """

  alias SalixAgent.Control
  alias SalixAgent.Tailnet

  @short_wait SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  # Connect waits up to 15 s for the node's login link.
  @connect_wait 30

  @status_description "Show the Group's tailnet: whether it is enabled, the node state (disabled, idle, starting, needs_login, needs_approval, running, error), the tailnet name, the node's name and addresses, its key expiry, and the settings. idle means the node is offline until the next use; any tailnet call starts it. For the Router, a needs_login state includes login_url."

  @peers_description "List the devices in the Group's tailnet that this node can see: name, MagicDNS name, Tailscale addresses, OS, online, tags and approved subnet routes. Reach one with ssh.open or web.http_request and via_tailnet: true. The tailnet policy decides which devices and ports answer. Pass next as cursor for more."

  @connect_description "Connect this Group to the user's own Tailscale network, or change its settings. Returns the status. When the state is needs_login, send login_url only to the person who manages the tailnet, in a private conversation: when a tailnet admin opens it and approves, the Group's node joins their tailnet. Ask them for the tailnet name and pass it as expected_tailnet, so a link opened in another tailnet is refused. tags (default [\"tag:comma-agent\"]) must be tags the approving admin owns in the tailnet policy; tagged nodes do not expire. Pass tags: [] for a node owned by the approving user instead. accept_routes lets the Agents reach subnets that tailnet routers advertise. Call tailnet.status to see when the node runs."

  @disconnect_description "Disconnect this Group from its tailnet: the node logs out, leaves the tailnet and forgets its keys. Reconnecting needs a new login link. Set user_confirmed only after the user confirmed in this conversation."

  def defs do
    [
      {"tailnet.status", @status_description, schema(%{}, []), &__MODULE__.status/2, @short_wait,
       [safety: "read"]},
      {"tailnet.peers", @peers_description,
       schema(%{"cursor" => %{"type" => "integer", "minimum" => 0}}, []), &__MODULE__.peers/2,
       @short_wait, [safety: "read"]},
      {"tailnet.connect", @connect_description,
       schema(
         %{
           "tags" => %{
             "type" => "array",
             "maxItems" => 8,
             "items" => %{"type" => "string", "pattern" => "^tag:[A-Za-z][A-Za-z0-9-]{0,62}$"}
           },
           "accept_routes" => %{"type" => "boolean"},
           "expected_tailnet" => %{
             "type" => "string",
             "maxLength" => 253,
             "description" =>
               "The tailnet's name, as the Tailscale admin console shows it (such as example.com or user@gmail.com), or its MagicDNS suffix (such as tail1234.ts.net)."
           }
         },
         []
       ), &__MODULE__.connect/2, @connect_wait, [roles: ["router"], safety: "write"]},
      {"tailnet.disconnect", @disconnect_description,
       schema(%{"user_confirmed" => %{"type" => "boolean"}}, ["user_confirmed"]),
       &__MODULE__.disconnect/2, @connect_wait, [roles: ["router"], safety: "write"]}
    ]
  end

  @doc false
  def status(_args, ctx) do
    with {:ok, group_id} <- group(ctx),
         {:ok, status} <- Tailnet.status(group_id) do
      Jason.encode!(present(status, router?(ctx)))
    else
      error -> failure(error)
    end
  end

  @doc false
  def peers(args, ctx) do
    cursor = Map.get(args, "cursor") || 0

    with {:ok, group_id} <- group(ctx),
         {:ok, page} <- Tailnet.peers(group_id, cursor) do
      Jason.encode!(page)
    else
      error -> failure(error)
    end
  end

  @doc false
  def connect(args, ctx) do
    attrs = Map.take(args, ["tags", "accept_routes", "expected_tailnet"])

    with {:ok, router} <- router(ctx),
         {:ok, status} <- Tailnet.connect(router.group_id, attrs, "agent:" <> router.agent_id) do
      Jason.encode!(present(status, true))
    else
      error -> failure(error)
    end
  end

  @doc false
  def disconnect(args, ctx) do
    with true <- Map.get(args, "user_confirmed") == true || {:error, :not_confirmed},
         {:ok, router} <- router(ctx),
         {:ok, status} <- Tailnet.disconnect(router.group_id, "agent:" <> router.agent_id) do
      Jason.encode!(present(status, true))
    else
      error -> failure(error)
    end
  end

  defp present(status, router?) do
    status = Map.drop(status, ["owner"])
    if router?, do: status, else: Map.delete(status, "login_url")
  end

  defp group(ctx) do
    case context_string(ctx, :group_id) do
      "" ->
        try do
          {:ok, SalixStore.Ids.group_id_from_agent!(ctx.agent_id)}
        rescue
          _ -> {:error, :forbidden}
        end

      group_id ->
        {:ok, group_id}
    end
  end

  # The Router acts for its own Group only; a Worker or a stale role reads
  # as not authorized.
  defp router(ctx) do
    agent_id = context_string(ctx, :agent_id)
    tenant_id = context_string(ctx, :tenant_id)
    group_id = context_string(ctx, :group_id)

    with true <- agent_id != "" and tenant_id != "" and group_id != "",
         {:ok, agent} <- Control.get(agent_id, tenant_id),
         true <- agent["role"] == "router" and agent["group_id"] == group_id do
      {:ok, %{agent_id: agent_id, group_id: group_id}}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp router?(ctx), do: match?({:ok, _}, router(ctx))

  defp context_string(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> ""
    end
  end

  defp schema(properties, required),
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required
    }

  @doc false
  def failure({:error, %{"code" => code, "message" => message}}), do: failure(code, message)

  def failure({:error, :forbidden}),
    do: failure("forbidden", "Only the Group's Router manages its tailnet.")

  def failure({:error, :not_confirmed}),
    do: failure("confirmation_required", "Ask the user to confirm, then set user_confirmed.")

  def failure({:error, reason})
      when reason in [:invalid_tags, :invalid_accept_routes, :invalid_expected_tailnet] do
    failure(
      Atom.to_string(reason),
      "tags is a list of at most 8 tags like tag:name; accept_routes is a boolean; expected_tailnet is a name of at most 253 characters."
    )
  end

  def failure({:error, reason}),
    do: failure("tailnet_unavailable", "The tailnet settings are unavailable: #{inspect(reason)}")

  defp failure(code, message) do
    content = Jason.encode!(%{"ok" => false, "error" => %{"code" => code, "message" => message}})
    {:tool_failure, content, code, "user_reportable", message, []}
  end
end
