defmodule SalixAgent.Browser do
  @moduledoc "Browser resources owned by Runtime Sessions. Durable admission serializes all browser mutations across nodes."
  alias SalixStore.{BrowserSettings, BrowserBindings, BrowserStorage, Ids}
  alias SalixAgent.Browser.Driver

  @operations ~w(tabs new_tab close_tab navigate snapshot screenshot click fill press scroll wait request_control take_control return_control input release_keys close clear_storage checkpoint)
  def owner(ctx) do
    agent = ctx.agent_id

    %{
      agent_id: agent,
      session_id: ctx.session_id,
      group_id: Ids.group_id_from_agent!(agent),
      tenant_id: Ids.tenant_id_from_agent!(agent)
    }
  end

  def execute(owner, operation, args, principal \\ :agent) do
    started = System.monotonic_time()
    result = do_execute(owner, operation, args, principal)

    try do
      Salix.Telemetry.emit_operation(
        "salix_agent",
        if(operation == "checkpoint", do: "browser_storage_checkpoint", else: "browser_command"),
        "salix",
        outcome(result),
        System.monotonic_time() - started
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    result
  end

  defp outcome({:ok, %{storage_error: error}}) when not is_nil(error), do: "error"
  defp outcome({:ok, _}), do: "ok"
  defp outcome(_), do: "error"

  defp do_execute(owner, operation, args, principal) do
    with true <- operation in ["open" | @operations],
         true <- operation != "checkpoint" or principal == :checkpoint,
         true <- operation != "clear_storage" or is_binary(principal),
         {:ok, settings} <- allowed_settings(owner, operation) do
      if operation == "open",
        do: open(owner, settings),
        else: run(owner, operation, args, principal)
    else
      false -> {:error, :unsupported_browser_operation}
      error -> error
    end
  rescue
    _ -> {:error, :browser_unavailable}
  catch
    :exit, _ -> {:error, :browser_outcome_unknown}
  end

  defp allowed_settings(_owner, op) when op in ["close", "clear_storage"], do: {:ok, nil}
  defp allowed_settings(owner, _), do: BrowserSettings.resolve(owner.tenant_id)

  defp open(owner, settings) do
    with :ok <- recover_expired(owner) do
      open_current(owner, settings)
    end
  end

  defp recover_expired(owner) do
    case BrowserBindings.active(owner) do
      nil ->
        :ok

      %{provider_id: nil} = holder ->
        case BrowserBindings.expire(holder) do
          {:ok, _} -> :ok
          {:error, :browser_creation_pending} -> :ok
          error -> error
        end

      holder ->
        with {:ok, token} <-
               BrowserSettings.unseal(holder.token_ciphertext, holder.credential_scope),
             {:ok, status} <- provider().status(holder, token) do
          case status do
            :active ->
              :ok

            :expired ->
              with {:ok, _} <- BrowserBindings.expire(holder), do: Driver.stop(holder)
          end
        end
    end
  end

  defp open_current(owner, settings) do
    case BrowserBindings.get(owner) do
      %{status: "ready"} = row ->
        with :ok <- Driver.activate(row), do: {:ok, BrowserBindings.public(row)}

      nil ->
        create(owner, settings)

      %{status: "closed"} ->
        create(owner, settings)

      _ ->
        {:error, :browser_outcome_pending}
    end
  end

  defp create(owner, settings) do
    with {:ok, row} <- BrowserBindings.reserve(owner, settings),
         {:ok, token} <- BrowserSettings.unseal(row.token_ciphertext, row.credential_scope) do
      case provider().create(row, token) do
        {:ok, %{"sessionId" => id}} ->
          with {:ok, restoring} <- BrowserBindings.record_provider(row, id),
               {:ok, snapshot} <- BrowserStorage.load(restoring),
               {:ok, _} <- Driver.call(restoring, "storage_restore", snapshot),
               {:ok, tabs} <- Driver.call(restoring, "tabs"),
               {:ok, ready} <- BrowserBindings.finish(restoring, %{status: "ready"}) do
            {:ok, Map.merge(BrowserBindings.public(ready), tabs)}
          end

        _ ->
          {:error, :browser_create_outcome_unknown}
      end
    end
  end

  defp run(owner, "checkpoint", _, :checkpoint) do
    case BrowserBindings.get(owner) do
      %{status: "ready", pending: nil} = row ->
        result = save(row, false)
        error = storage_error(result)
        BrowserStorage.checkpoint_result(row, error)
        {:ok, %{storage_error: error}}

      _ ->
        {:error, :browser_driver_busy}
    end
  end

  defp run(owner, operation, args, principal) do
    with {:ok, row} <- BrowserBindings.claim(owner, principal, operation) do
      result = dispatch(row, operation, args, principal)

      case result do
        {:ok, value, updates} ->
          with {:ok, final} <- BrowserBindings.finish(row, updates),
               do: {:ok, Map.merge(BrowserBindings.public(final), value)}

        {:error, reason} when reason in [:browser_outcome_unknown, :browser_driver_unavailable] ->
          {:error, reason}

        {:error, reason} ->
          # Provider errors can follow a remote effect. Only explicit local
          # validation errors release admission. All others require close.
          if reason in ([:browser_driver_busy] ++
                          ~w(driver_busy invalid_input invalid_url stale_element tab_not_found unsupported_operation)) do
            BrowserBindings.finish(row, %{})
          end

          {:error, reason}
      end
    end
  end

  defp dispatch(%{provider_id: nil}, op, _, _) when op in ["close", "clear_storage"] do
    {:ok, %{},
     %{
       status: "closed",
       token_ciphertext: "",
       control: "agent",
       controller: nil,
       clear_storage: op == "clear_storage"
     }}
  end

  defp dispatch(row, op, _, _) when op in ["close", "clear_storage"] do
    # An uncertain mutation may still run remotely. Do not bless its state as
    # a new checkpoint. Provider deletion must finish before another task opens.
    saved =
      if op == "clear_storage" or row.options["shared_storage"] != true,
        do: {:ok, :skipped},
        else:
          if(row.interrupted or row.status != "ready",
            do: {:error, :browser_storage_not_saved},
            else: save(row)
          )

    with {:ok, token} <- BrowserSettings.unseal(row.token_ciphertext, row.credential_scope),
         {:ok, _} <- provider().close(row, token) do
      Driver.stop(row)

      {:ok, %{},
       %{
         status: "closed",
         controller: nil,
         controller_expires_at: nil,
         control: "agent",
         token_ciphertext: "",
         clear_storage: op == "clear_storage",
         storage_error: storage_error(saved)
       }}
    end
  end

  defp dispatch(row, "request_control", _, :agent) do
    with :ok <- Driver.activate(row) do
      {:ok,
       %{
         "message" =>
           "Open Browser in Comma and take control. Browser actions remain paused until you return control."
       }, %{control: "handoff_pending"}}
    end
  end

  defp dispatch(row, "take_control", _, principal) when is_binary(principal) do
    with :ok <- Driver.activate(row) do
      {:ok, %{},
       %{
         control: "human",
         controller: principal,
         controller_expires_at: DateTime.add(DateTime.utc_now(), 10, :second)
       }}
    end
  end

  defp dispatch(row, "return_control", args, principal) when is_binary(principal) do
    with {:ok, _} <- Driver.call(row, "release_keys", args),
         {:ok, snapshot} <- Driver.call(row, "snapshot", args) do
      saved = save(row)
      {:ok, snapshot, %{control: "agent", controller: nil, storage_error: storage_error(saved)}}
    end
  end

  defp dispatch(row, operation, args, _) do
    case Driver.call(row, operation, args) do
      {:ok, value} -> {:ok, value, %{}}
      error -> error
    end
  end

  def checkpoint(owner), do: execute(owner, "checkpoint", %{}, :checkpoint)

  defp save(row, all \\ true) do
    save_batches(row, all, nil, System.monotonic_time(:millisecond) + 15_000)
  end

  defp save_batches(row, all, remaining, deadline) do
    saved_at = BrowserStorage.saved_at(row)

    with true <- row.options["shared_storage"] == true,
         true <- System.monotonic_time(:millisecond) < deadline,
         {:ok, snapshot} <-
           Driver.call(row, "storage_export", %{
             "timeout_ms" => max(1, deadline - System.monotonic_time(:millisecond))
           }),
         {:ok, :saved} <- BrowserStorage.save(row, snapshot, saved_at) do
      remaining = if is_nil(remaining), do: snapshot["remaining"], else: max(0, remaining - 4)

      if all and remaining > 0,
        do: save_batches(row, all, remaining, deadline),
        else: {:ok, :saved}
    else
      false -> save_error(:browser_storage_limit, remaining)
      {:error, reason} -> save_error(reason, remaining)
    end
  rescue
    _ -> save_error(:browser_storage_unavailable, remaining)
  catch
    :exit, _ -> save_error(:browser_storage_unavailable, remaining)
  end

  defp save_error(reason, nil), do: {:error, reason}
  defp save_error(_, _), do: {:error, :browser_storage_partially_saved}

  defp storage_error({:error, :browser_storage_partially_saved}),
    do: "browser_storage_partially_saved"

  defp storage_error({:ok, _}), do: nil
  defp storage_error(_), do: "browser_storage_not_saved"

  def test_settings(scope) do
    with {:ok, settings} <- BrowserSettings.selected_scope(scope),
         {:ok, token} <- BrowserSettings.unseal(settings.token_ciphertext, scope) do
      row = %{account_id: settings.account_id, options: %{}}

      case provider().create(row, token) do
        {:ok, %{"sessionId" => id}} ->
          case provider().close(Map.put(row, :provider_id, id), token) do
            {:ok, _} -> {:ok, :connected}
            _ -> {:error, :browser_test_cleanup_failed}
          end

        _ ->
          {:error, :browser_connection_test_failed}
      end
    end
  rescue
    _ -> {:error, :browser_settings_unavailable}
  end

  def provider,
    do: Application.get_env(:salix_agent, :browser_provider, SalixAgent.Browser.Cloudflare)
end
