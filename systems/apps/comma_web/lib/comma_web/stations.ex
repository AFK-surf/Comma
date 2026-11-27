defmodule CommaWeb.Stations do
  @moduledoc """
  Comma implementation of the `SalixAgent.Stations` port.

  For each call it resolves, from the tool ctx only:

    * the agent's Salix Group, which is the workspace of its stations;
    * the requester: the current turn's sealed principal, or the human
      request behind an ordinary Task's first Worker command. Provider
      senders map to a Comma user. The requester must have a role in that Group
      (`SalixStore.StationMembers`). In a Group whose product gives a role to
      the people its chat app is available to
      (`SalixStore.StationMembers.app_member_role/2`, a CFT Project), a Slack,
      Feishu or Lark sender with no such role still has it by the connect's
      member scope (`SalixIM.ProviderConnects.Members`). On an
      `"organization"` connect the provider answers on this call that they
      are one of the connect's own people (`SalixIM.ProviderAccounts.app_member/2`:
      the Feishu or Lark app is available to them, or they are a full member
      of the Slack workspace) and they have an organization email. On an
      `"external"` connect an admin granted them by name and the grant has
      not expired; the grant's email is theirs. Their `user_id` is
      `<provider>:<connect>:<subject>`. Otherwise the call is refused with
      `{:requester_refused, reason}` (`:not_available`, `:no_email`,
      `{:missing_scope, scope}`, `:not_granted`, `:check_failed`);
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

  # One indexed read of the Group's stations per disclosure, and of its
  # still.fail stations when it has none: `station.list` is how an agent finds
  # those, and they need no station gateway. Any failure, including a Group
  # whose store this node cannot read, hides the tools.
  @impl true
  def offered?(ctx) do
    case group(ctx) do
      {:ok, {tenant_id, group_id}} ->
        roster?(tenant_id, group_id) or stillfail?(group_id)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp roster?(tenant_id, group_id) do
    configured?() and match?({:ok, [_ | _]}, Directory.list_group_stations(tenant_id, group_id))
  end

  defp stillfail?(group_id),
    do: match?({:ok, [_ | _], _more?}, SalixEnv.StillfailDevices.first_page(group_id))

  @impl true
  def member(ctx) do
    with {:ok, scope} <- scope(ctx), do: {:ok, %{email: scope.user["email"], role: scope.role}}
  end

  @impl true
  def list(ctx) do
    with :ok <- ensure_configured(),
         {:ok, scope} <- scope(ctx),
         {:ok, stations} <- Directory.list_group_stations(scope.tenant_id, scope.group_id) do
      {:ok, Enum.map(stations, &public_station/1)}
    end
  end

  # One bounded read of the Group's devices for whoever asked: anyone who can
  # talk to the Group's agents may read and write in its still.fail
  # workspaces, and information flow control decides where what they read may
  # go. still.fail stations need no station gateway.
  @impl true
  def stillfail_stations(ctx) do
    with {:ok, ctx} <- SalixAgent.AgentRuntimeConfig.complete_context(ctx),
         {:ok, {_tenant_id, group_id}} <- group(ctx),
         {:ok, stations, _more?} <- SalixEnv.StillfailDevices.first_page(group_id),
         do: {:ok, stations}
  end

  @impl true
  def call(ctx, station_id, op, args) when is_binary(station_id) and is_binary(op),
    do: call_in_scope(ctx, :turn, station_id, op, args)

  def call(_ctx, _station_id, _op, _args), do: {:error, :station_not_found}

  @doc """
  `call/4` on behalf of a member the caller has already chosen, for server
  work that has no requesting turn (`CommaWeb.StationWorkers`). The member must
  still have a role in the ctx's Group.
  """
  def call_as(ctx, user_id, station_id, op, args)
      when is_binary(user_id) and is_binary(station_id) and is_binary(op),
      do: call_in_scope(ctx, {:member, user_id}, station_id, op, args)

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

  # `requester` is `:turn`, the person who asked for the turn, or
  # `{:member, user_id}`, a member `call_as/5` names. Only the turn's
  # requester may be a chat app's user without a member's account
  # (`app_member_scope/3`).
  defp scope(ctx, requester \\ :turn) do
    with {:ok, ctx} <- SalixAgent.AgentRuntimeConfig.complete_context(ctx),
         {:ok, {tenant_id, group_id}} <- group(ctx) do
      case member_scope(ctx, tenant_id, group_id, requester) do
        {:error, :requester_required} when requester == :turn ->
          app_member_scope(ctx, tenant_id, group_id)

        result ->
          result
      end
    else
      {:error, :missing_agent_runtime_context} -> {:error, :requester_required}
      {:error, :not_found} -> {:error, :requester_required}
      {:error, _reason} = error -> error
    end
  end

  defp member_scope(ctx, tenant_id, group_id, requester) do
    with {:ok, user_id} <- requester_id(ctx, requester),
         {:ok, role} <- member_role(tenant_id, group_id, user_id),
         {:ok, user} <- Comma.Accounts.get_user(user_id) do
      {:ok, %{tenant_id: tenant_id, group_id: group_id, user: user, role: role}}
    else
      {:error, :requester_required} = error -> error
      {:error, :not_found} -> {:error, :requester_required}
      {:error, _reason} = error -> error
    end
  end

  defp requester_id(ctx, :turn), do: requester(ctx)
  defp requester_id(_ctx, {:member, user_id}), do: {:ok, user_id}

  # A Slack, Feishu or Lark sender with no member's account, in a Group whose
  # product gives a role to its chat apps' people (a CFT Project): the
  # connect's member scope decides. An organization connect asks the provider
  # on every call; an external one admits only a live grant. They act under
  # their organization email; any failure refuses (fail closed).
  defp app_member_scope(ctx, tenant_id, group_id) do
    with {:provider_user, connect_id, subject} <-
           SalixAgent.IFC.principal(ctx[:trusted_origin]),
         {:ok, role} <- SalixStore.StationMembers.app_member_role(tenant_id, group_id),
         {:ok, %{"provider" => provider} = connect} when provider in ~w(slack feishu lark) <-
           SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id) do
      case connect_member(connect, subject) do
        {:ok, %{"email" => email} = person} when is_binary(email) and email != "" ->
          {:ok,
           %{
             tenant_id: tenant_id,
             group_id: group_id,
             role: role,
             user: %{
               "id" => "#{provider}:#{connect_id}:#{subject}",
               "email" => email,
               "name" => person["name"]
             }
           }}

        {:error, reason} ->
          {:error, {:requester_refused, refusal(reason)}}

        _other ->
          {:error, {:requester_refused, :check_failed}}
      end
    else
      _not_an_app_member -> {:error, :requester_required}
    end
  end

  defp connect_member(connect, subject) do
    case SalixIM.ProviderConnects.member_scope(connect) do
      "organization" ->
        SalixIM.ProviderAccounts.app_member(connect, subject)

      "external" ->
        case SalixIM.ProviderConnects.member_grant(connect, subject) do
          %{"email" => email} = grant when is_binary(email) and email != "" ->
            {:ok, %{"name" => grant["name"], "email" => email}}

          %{} ->
            {:error, :no_email}

          nil ->
            {:error, :not_granted}
        end
    end
  end

  defp refusal(reason) when reason in [:not_available, :no_email, :not_granted], do: reason
  defp refusal({:missing_scope, scope}) when is_binary(scope), do: {:missing_scope, scope}
  defp refusal(_reason), do: :check_failed

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

      # A bound personal chat is its owner; another chat user (Slack) is the
      # Comma user they linked (`Comma.ProviderUserLinks`).
      {:provider_user, connect_id, subject} ->
        with {:error, _} <-
               CommaWeb.ProactiveDelivery.principal_owner(ctx[:group_id], connect_id, subject),
             :none <- Comma.ProviderUserLinks.resolve(connect_id, subject) do
          {:error, :requester_required}
        end

      _ ->
        SalixIM.TaskExecution.task_requester(ctx)
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
