defmodule SalixStore.BrowserBindings do
  @moduledoc "Browser resources of Runtime Sessions. Durable pending commands prevent mutation replay after owner loss."
  import Ecto.Query
  alias SalixStore.{Repo, BrowserStorage}

  defmodule Row do
    use Ecto.Schema
    @primary_key false
    schema "browser_bindings" do
      field(:agent_id, :string, primary_key: true)
      field(:session_id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:provider_id, :string)
      field(:account_id, :string)
      field(:token_ciphertext, :string, redact: true)
      field(:credential_scope, :string)
      field(:options, :map, default: %{})
      field(:status, :string)
      field(:control, :string, default: "agent")
      field(:controller, :string)
      field(:controller_expires_at, :utc_datetime_usec)
      field(:pending, :string)
      field(:storage_error, :string)
      field(:interrupted, :boolean, virtual: true, default: false)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  def get(owner), do: Repo.one(query(owner), log: false)

  def active(owner) do
    Repo.one(
      from(r in Row,
        where:
          r.tenant_id == ^owner.tenant_id and
            r.group_id == ^owner.group_id and r.status != "closed",
        limit: 1
      ),
      log: false
    )
  end

  # Known provider IDs require confirmed expiry. Lost creates use the same
  # remote idle/request bound as explicit close, checked under the row lock.
  def expire(observed) do
    Repo.transaction(fn ->
      row = Repo.one(from(r in query(observed), lock: "FOR UPDATE"), log: false)

      unless row && row.provider_id == observed.provider_id &&
               row.pending == observed.pending && row.updated_at == observed.updated_at &&
               row.status != "closed",
             do: Repo.rollback(:browser_operation_superseded)

      unless is_binary(row.provider_id) or expired_creation?(row),
        do: Repo.rollback(:browser_creation_pending)

      Repo.update_all(
        query(row),
        [
          set: [
            status: "closed",
            pending: nil,
            token_ciphertext: "",
            controller: nil,
            controller_expires_at: nil,
            control: "agent",
            storage_error: "browser_storage_not_saved",
            updated_at: DateTime.utc_now()
          ]
        ],
        log: false
      )

      get(row)
    end)
  end

  def list(tenant, group) do
    Repo.all(
      from(r in Row,
        where: r.tenant_id == ^tenant and r.group_id == ^group and r.status != "closed",
        order_by: [desc: r.updated_at],
        limit: 50
      ),
      log: false
    )
    |> Enum.map(&public/1)
  end

  def public(row),
    do:
      Map.take(row, [:agent_id, :session_id, :status, :control, :updated_at, :storage_error])
      |> Map.put(:busy, not is_nil(row.pending))
      |> Map.put(:shared_storage, row.options["shared_storage"] == true)

  def query(owner),
    do:
      from(r in Row,
        where:
          r.agent_id == ^owner.agent_id and r.session_id == ^owner.session_id and
            r.tenant_id == ^owner.tenant_id and r.group_id == ^owner.group_id
      )

  def reserve(owner, settings) do
    row =
      struct(
        Row,
        Map.merge(owner, %{
          account_id: settings.account_id,
          token_ciphertext: settings.token_ciphertext,
          credential_scope: settings.scope,
          options: %{
            "idle_timeout_ms" => settings.idle_timeout_ms,
            "operation_timeout_ms" => settings.operation_timeout_ms,
            "allowed_domains" => settings.allowed_domains,
            "shared_storage" => true
          },
          status: "creating",
          pending: Ecto.UUID.generate(),
          updated_at: DateTime.utc_now()
        })
      )

    Repo.transaction(fn ->
      BrowserStorage.admit!(owner)

      case get(owner) do
        nil -> :ok
        %{status: "closed"} -> Repo.delete_all(query(owner), log: false)
        _ -> Repo.rollback(:browser_already_exists)
      end

      Repo.insert!(row, log: false)
    end)
  end

  def record_provider(row, provider_id) do
    case Repo.update_all(
           from(r in query(row), where: r.pending == ^row.pending),
           [set: [provider_id: provider_id, status: "restoring"]],
           log: false
         ) do
      {1, _} -> {:ok, %{row | provider_id: provider_id, status: "restoring"}}
      _ -> {:error, :browser_operation_superseded}
    end
  end

  def finish(row, updates) do
    {clear, updates} = Map.pop(updates, :clear_storage, false)
    updates = Map.merge(updates, %{pending: nil, updated_at: DateTime.utc_now()}) |> Map.to_list()

    Repo.transaction(fn ->
      case Repo.update_all(
             from(r in query(row), where: r.pending == ^row.pending),
             [set: updates],
             log: false
           ) do
        {1, _} ->
          if clear, do: BrowserStorage.clear!(row)
          get(row)

        _ ->
          Repo.rollback(:browser_operation_superseded)
      end
    end)
  end

  def heartbeat(owner, principal) do
    Repo.update_all(
      from(r in query(owner), where: r.controller == ^principal),
      [set: [controller_expires_at: DateTime.add(DateTime.utc_now(), 10, :second)]],
      log: false
    )

    :ok
  end

  def release(owner, principal) do
    Repo.update_all(
      from(r in query(owner), where: r.controller == ^principal and is_nil(r.pending)),
      [set: [controller: nil, controller_expires_at: nil, control: "handoff_pending"]],
      log: false
    )

    :ok
  end

  # A create without a returned provider ID cannot be deleted remotely. Wait
  # through the maximum requested idle period plus the bounded HTTP request.
  defp expired_creation?(row) do
    row.status == "creating" and is_nil(row.provider_id) and
      DateTime.diff(DateTime.utc_now(), row.updated_at, :millisecond) >
        (row.options["idle_timeout_ms"] || 60000) + 60000
  end

  def claim(owner, principal, operation) do
    Repo.transaction(fn ->
      row = Repo.one(from(r in query(owner), lock: "FOR UPDATE"), log: false)

      cond do
        is_nil(row) ->
          Repo.rollback(:browser_not_found)

        operation == "clear_storage" and row.options["shared_storage"] != true ->
          Repo.rollback(:browser_shared_profile_not_acquired)

        operation in ["close", "clear_storage"] and row.status != "closed" and
            (is_binary(row.provider_id) or expired_creation?(row)) ->
          :ok

        row.status != "ready" ->
          Repo.rollback(:browser_not_ready)

        not is_nil(row.pending) ->
          Repo.rollback(:browser_outcome_pending)

        principal == :agent and row.control != "agent" ->
          Repo.rollback(:browser_human_control)

        principal != :agent and
          operation not in ["take_control", "tabs", "snapshot"] and
            (row.controller != principal or is_nil(row.controller_expires_at) or
               DateTime.compare(row.controller_expires_at, DateTime.utc_now()) != :gt) ->
          Repo.rollback(:browser_control_required)

        principal != :agent and operation == "take_control" and
          row.controller not in [nil, principal] and not is_nil(row.controller_expires_at) and
            DateTime.compare(row.controller_expires_at, DateTime.utc_now()) == :gt ->
          Repo.rollback(:browser_control_conflict)

        true ->
          :ok
      end

      pending = Ecto.UUID.generate()

      Repo.update_all(query(owner), [set: [pending: pending, updated_at: DateTime.utc_now()]],
        log: false
      )

      %{get(owner) | interrupted: not is_nil(row.pending)}
    end)
  end
end
