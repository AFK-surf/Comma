defmodule Salix.RemoteShell.Registration do
  @moduledoc "One invitation for automatic public-key submission and session-owned registration."
  alias Salix.RemoteShell.Registrations
  @salt "comma-temporary-shell-registration-v1"

  def prepare(handle, scope, controller, seconds) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    expires = System.system_time(:second) + seconds

    with :ok <- Registrations.create(id, expires) do
      ticket =
        Phoenix.Token.sign(
          signing_key(handle),
          @salt,
          {handle.group_id, scope, target_binding(handle), id, controller, expires}
        )

      {:ok, %{request: ticket, request_id: id, expires_at: expires}}
    end
  end

  def verify(handle, scope, ticket) when is_binary(ticket) and byte_size(ticket) <= 4096 do
    expected_binding = target_binding(handle)

    with {:ok, {group, owner, ^expected_binding, id, controller, expires}} <-
           Phoenix.Token.verify(signing_key(handle), @salt, ticket, max_age: 3600),
         true <- group == handle.group_id and (is_nil(scope) or owner == scope),
         true <- is_binary(id) and byte_size(id) == 32,
         true <- is_integer(expires) and expires > System.system_time(:second) do
      {:ok, %{id: id, controller: controller, expires_at: expires}}
    else
      _ -> {:error, :expired_or_foreign_registration}
    end
  end

  def verify(_, _, _), do: {:error, :expired_or_foreign_registration}

  def submit(handle, request_id, ticket, body) do
    with {:ok, %{id: ^request_id, expires_at: expires}} <- verify(handle, nil, ticket),
         {:ok, _} <- submit_body(request_id, expires, body) do
      Registrations.notify(request_id)
      {:ok, %{accepted: true}}
    else
      {:error, _} = error -> error
      _ -> {:error, :expired_or_foreign_registration}
    end
  end

  defp submit_body(id, _expires, %{"cancelled" => true} = body) when map_size(body) == 1,
    do: Registrations.cancel(id)

  defp submit_body(id, expires, %{"device_key" => key, "expires_at" => expires} = body)
       when map_size(body) == 2 do
    if Salix.RemoteShell.valid_key?(key),
      do: Registrations.submit(id, key, expires),
      else: {:error, :invalid_registration}
  end

  defp submit_body(_, _, _), do: {:error, :invalid_registration}

  def wait(handle, scope, ticket, seconds, fresh_handle, register, cleanup)
      when is_integer(seconds) and seconds in 1..120 do
    with {:ok, invitation} <- verify(handle, scope, ticket) do
      Registrations.subscribe(invitation.id)

      deadline =
        System.monotonic_time(:millisecond) +
          min(seconds, invitation.expires_at - System.system_time(:second)) * 1000

      try do
        wait_loop(handle, scope, ticket, invitation, deadline, fresh_handle, register, cleanup)
      after
        Registrations.unsubscribe(invitation.id)
      end
    end
  end

  def wait(_, _, _, _, _, _, _), do: {:error, :invalid_arguments}

  defp wait_loop(handle, scope, ticket, invitation, deadline, fresh_handle, register, cleanup) do
    owner = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with {:ok, current} <- fresh_handle.(),
         {:ok, _} <- verify(current, scope, ticket),
         {:ok, row} <- Registrations.claim(invitation.id, owner) do
      case row do
        %{"status" => "ready", "result" => result} ->
          {:ok, result}

        %{"status" => "cancelled"} ->
          {:error, :registration_cancelled}

        %{"status" => "registering", "claim" => ^owner} ->
          finish_registration(
            current,
            scope,
            ticket,
            invitation,
            row,
            owner,
            fresh_handle,
            register,
            cleanup
          )

        _ ->
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            {:ok, %{status: "waiting", request: ticket, expires_at: invitation.expires_at}}
          else
            receive do
              {:remote_shell_registration, id} when id == invitation.id -> :ok
            after
              remaining -> :ok
            end

            wait_loop(
              handle,
              scope,
              ticket,
              invitation,
              deadline,
              fresh_handle,
              register,
              cleanup
            )
          end
      end
    end
  end

  defp finish_registration(
         handle,
         scope,
         ticket,
         invitation,
         row,
         owner,
         fresh_handle,
         register,
         cleanup
       ) do
    result =
      register.(
        handle,
        row["device_key"],
        invitation.expires_at,
        invitation.id,
        invitation.controller
      )

    still_current = with {:ok, current} <- fresh_handle.(), do: verify(current, scope, ticket)
    if not match?({:ok, _}, still_current), do: Registrations.cancel(invitation.id)

    case Registrations.finish(invitation.id, owner, result) do
      {:ok, _} ->
        Registrations.notify(invitation.id)
        result

      {:error, reason} when reason in [:registration_cancelled, :registration_expired] ->
        # An accepted PUT may have raced cancellation or binding replacement.
        # Use the original handle to compensate, never the replacement binding.
        case cleanup.(handle, row["device_key"]) do
          {:ok, _} -> {:error, reason}
          _ -> {:error, :registration_cleanup_unconfirmed}
        end

      error ->
        error
    end
  end

  def cancel(handle, scope, ticket, cleanup) do
    with {:ok, invitation} <- verify(handle, scope, ticket),
         {:ok, row} <- Registrations.cancel(invitation.id) do
      Registrations.notify(invitation.id)

      cond do
        (row["claim_expires_at"] || 0) > System.system_time(:second) ->
          {:error, :registration_in_progress}

        is_binary(row["device_key"]) ->
          with {:ok, _} <- cleanup.(handle, row["device_key"]), do: {:ok, %{cancelled: true}}

        true ->
          {:ok, %{cancelled: true}}
      end
    end
  end

  defp target_binding(handle), do: {handle.base_url, handle.org_slug, handle.network}
  defp signing_key(handle), do: :crypto.hash(:sha256, handle.token)
end
