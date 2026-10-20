defmodule CommaWeb.Stations do
  @moduledoc """
  Comma implementation of the `SalixAgent.Stations` port.

  For each call it resolves, from the tool ctx only:

    * the agent's Salix Group, which is the workspace of its stations;
    * the requester: the sealed principal of the current turn
      (`SalixAgent.IFC.principal/1`), mapped to a Comma user for provider
      senders, who must have a role in that Group
      (`SalixStore.StationMembers`);
    * the station, which must be listed for that Group by
      `CommaWeb.Stations.Directory`.

  It then forwards the op through `CommaWeb.Stations.Gateway` with the §8
  context `{workspace, user_id, user_email, agent, conversation}`, where
  `workspace` is the workspace id the Group's stations are told
  (`SalixStore.Stations.workspace_id/2`). A `viewer` member may use
  read ops only. `session.start` and `session.say` carry the
  requester's email as `requester_email`, so the station chat is started by
  that member; a model-supplied value is replaced.
  """

  @behaviour SalixAgent.Stations

  alias CommaWeb.Stations.{Directory, Gateway}

  @read_ops ~w(fs.read fs.list fs.stat runtime.probe process.list process.tail session.status)
  @requester_ops ~w(session.start session.say)

  @impl true
  def configured?, do: Gateway.configured?()

  # One indexed read of the Group's stations per disclosure; any failure,
  # including a Group whose store this node cannot read, hides the tools.
  @impl true
  def offered?(ctx) do
    with true <- configured?(),
         {:ok, {tenant_id, group_id}} <- group(ctx),
         {:ok, [_ | _]} <- Directory.list_group_stations(tenant_id, group_id) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def list(ctx) do
    with :ok <- ensure_configured(),
         {:ok, scope} <- scope(ctx),
         {:ok, stations} <- Directory.list_group_stations(scope.tenant_id, scope.group_id) do
      {:ok, Enum.map(stations, &public_station/1)}
    end
  end

  @impl true
  def call(ctx, station_id, op, args) when is_binary(station_id) and is_binary(op),
    do: call_in_scope(ctx, &requester/1, station_id, op, args)

  def call(_ctx, _station_id, _op, _args), do: {:error, :station_not_found}

  @doc """
  `call/4` on behalf of a member the caller has already chosen, for server
  work that has no requesting turn (`CommaWeb.StationWorkers`). The member must
  still have a role in the ctx's Group.
  """
  def call_as(ctx, user_id, station_id, op, args)
      when is_binary(user_id) and is_binary(station_id) and is_binary(op),
      do: call_in_scope(ctx, fn _ctx -> {:ok, user_id} end, station_id, op, args)

  def call_as(_ctx, _user_id, _station_id, _op, _args), do: {:error, :requester_required}

  defp call_in_scope(ctx, requester, station_id, op, args) do
    station_id = String.downcase(String.trim(station_id))

    with :ok <- ensure_configured(),
         {:ok, scope} <- scope(ctx, requester),
         :ok <- authorize_op(scope.role, op),
         :ok <- ensure_station(scope, station_id) do
      Gateway.call(station_id, %{
        "op" => op,
        "id" => request_id(ctx),
        "args" => requester_args(op, args || %{}, scope),
        "context" => %{
          "workspace" => SalixStore.Stations.workspace_id(scope.tenant_id, scope.group_id),
          "user_id" => scope.user["id"],
          "user_email" => scope.user["email"],
          "agent" => to_string(ctx[:agent_id] || ""),
          "conversation" => conversation(ctx)
        }
      })
    end
  end

  defp ensure_configured, do: if(configured?(), do: :ok, else: {:error, :not_configured})

  defp scope(ctx, requester \\ &requester/1) do
    with {:ok, ctx} <- SalixAgent.AgentRuntimeConfig.complete_context(ctx),
         {:ok, {tenant_id, group_id}} <- group(ctx),
         {:ok, user_id} <- requester.(ctx),
         {:ok, role} <- member_role(tenant_id, group_id, user_id),
         {:ok, user} <- Comma.Accounts.get_user(user_id) do
      {:ok, %{tenant_id: tenant_id, group_id: group_id, user: user, role: role}}
    else
      {:error, :missing_agent_runtime_context} -> {:error, :requester_required}
      {:error, :requester_required} = error -> error
      {:error, :not_found} -> {:error, :requester_required}
      {:error, _reason} = error -> error
    end
  end

  defp group(ctx) do
    case {ctx[:tenant_id], ctx[:group_id]} do
      {tenant_id, group_id} when is_binary(tenant_id) and is_binary(group_id) ->
        {:ok, {tenant_id, group_id}}

      _ ->
        {:error, :not_configured}
    end
  end

  @doc false
  # The Comma user who asked for the current turn (also used by CommaWeb.StationWorkers).
  def requester(ctx) do
    case SalixAgent.IFC.principal(ctx[:trusted_origin]) do
      {:comma_user, user_id} ->
        {:ok, user_id}

      {:provider_user, connect_id, subject} ->
        case CommaWeb.ProactiveDelivery.principal_owner(ctx[:group_id], connect_id, subject) do
          {:ok, user_id} -> {:ok, user_id}
          _ -> {:error, :requester_required}
        end

      _ ->
        {:error, :requester_required}
    end
  end

  defp member_role(tenant_id, group_id, user_id) do
    case SalixStore.StationMembers.role(tenant_id, group_id, user_id) do
      {:ok, role} -> {:ok, role}
      :none -> {:error, :requester_required}
    end
  end

  defp authorize_op("viewer", op) when op not in @read_ops, do: {:error, :forbidden}
  defp authorize_op(_role, _op), do: :ok

  defp ensure_station(scope, station_id) do
    with {:ok, stations} <- Directory.list_group_stations(scope.tenant_id, scope.group_id) do
      if Enum.any?(stations, &(String.downcase(to_string(&1["id"])) == station_id)),
        do: :ok,
        else: {:error, :station_not_found}
    end
  end

  defp requester_args(op, args, scope) when op in @requester_ops,
    do: Map.put(args, "requester_email", scope.user["email"])

  defp requester_args(_op, args, _scope), do: args

  defp conversation(ctx) do
    origin = ctx[:trusted_origin]
    conversation = if is_map(origin), do: origin["conversation_id"]
    to_string(conversation || ctx[:session_id] || "")
  end

  # The tool call id makes a request traceable from the Salix tool result to
  # the gateway and station logs.
  defp request_id(ctx) do
    case ctx[:tool_call_id] || ctx["tool_call_id"] do
      id when is_binary(id) and id != "" and byte_size(id) <= 128 -> id
      _ -> Base.encode16(SystemsRuntime.Proc.random_bytes(12), case: :lower)
    end
  end

  defp public_station(station) do
    %{"id" => String.downcase(to_string(station["id"])), "name" => station["name"]}
    |> put_present("online", station["online"])
    |> put_present("version", station["version"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
