defmodule Salix.RemoteShell do
  @moduledoc """
  Temporary-shell policy over an enabled group Drive binding. No CP credential
  reaches tool output. Targets are signed for one agent/session and deadline;
  rotating/disabling the underlying binding invalidates future operations.
  The device owns consent, its private key, and the hard access deadline.
  """
  alias Salix.Control.DriveBindings
  alias Salix.RemoteShell.{Transport, Registration, Registrations}

  @key ~r/\A[ybndrfg8ejkmcpqxot1uwisza345h769]{52}\z/
  @salt "comma-temporary-shell-v1"

  def call(group, scope, args) do
    started = System.monotonic_time()

    result =
      with {:ok, handle} <- DriveBindings.handle(group) do
        perform(handle, scope, args, fn -> DriveBindings.handle(group) end)
      end

    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    Salix.Telemetry.emit_operation(
      "salix_web",
      "remote_shell",
      :salix,
      outcome,
      System.monotonic_time() - started
    )

    result
  end

  @doc false
  def perform(handle, scope, args, fresh_handle \\ nil)

  def perform(handle, scope, args, fresh_handle) when is_map(args) do
    fresh_handle = fresh_handle || fn -> {:ok, handle} end

    case args do
      %{"action" => "prepare"} ->
        prepare(handle, scope, args)

      %{"action" => "register", "request" => ticket} ->
        Registration.wait(
          handle,
          scope,
          ticket,
          Map.get(args, "timeout_seconds", 120),
          fresh_handle,
          fn current, key, expires, request_id, controller ->
            register(
              current,
              scope,
              %{"device_key" => key, "expires_at" => expires},
              request_id,
              controller
            )
          end,
          &revoke_delegation/2
        )

      %{"action" => "revoke", "request" => ticket} ->
        Registration.cancel(handle, scope, ticket, &revoke_delegation/2)

      %{"action" => "register"} ->
        register(handle, scope, args, nil, nil)

      %{"action" => action, "target" => target} when action in ~w(exec revoke) ->
        with {:ok, device} <- target(handle, scope, target) do
          operate(handle, device, action, args)
        end

      _ ->
        {:error, :invalid_arguments}
    end
  end

  def perform(_, _, _, _), do: {:error, :invalid_arguments}

  defp prepare(handle, scope, args) do
    seconds = Map.get(args, "seconds", 600)

    with true <- is_integer(seconds) and seconds in 30..3600,
         {:ok, %{"controller" => key}} <- request(handle, :get, "sockets"),
         true <- valid_key?(key),
         {:ok, invitation} <- Registration.prepare(handle, scope, key, seconds) do
      {:ok,
       Map.merge(invitation, %{
         script: script(handle.group_id, key, invitation),
         seconds: seconds,
         controller_key: key,
         next:
           "Give the script to the user to run and confirm yes locally. Then call register with request to wait for automatic registration. Do not ask the user to copy output or report that it is running. If status is waiting, repeat register with the same request until expiry, without repeated user messages."
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_gateway_or_lifetime}
    end
  end

  defp register(
         handle,
         scope,
         %{"device_key" => key, "expires_at" => expires},
         request_id,
         expected_controller
       ) do
    with true <- valid_key?(key) and valid_deadline?(expires),
         {:ok, %{"controller" => controller}} <- request(handle, :get, "sockets"),
         true <-
           valid_key?(controller) and
             (is_nil(expected_controller) or controller == expected_controller),
         {:ok, _} <-
           request(handle, :put, "delegations/" <> key,
             json: %{
               spaces: ["temporary-shell-" <> String.slice(key, 0, 16)],
               expires_at: expires
             }
           ),
         device = %{key: key, expires: expires, controller: controller},
         {:ok, host_key} <-
           Transport.pin(handle, device, min(20, expires - System.system_time(:second)) * 1000) do
      device = device |> Map.put(:host_key, host_key) |> Map.put(:request_id, request_id)

      token =
        Phoenix.Token.sign(
          :crypto.hash(:sha256, handle.token),
          @salt,
          {handle.group_id, scope, target_binding(handle), device}
        )

      {:ok, %{target: token, expires_at: expires, device_key: key}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_registration}
    end
  end

  defp register(_, _, _, _, _), do: {:error, :invalid_registration}

  defp target(handle, scope, token) when is_binary(token) and byte_size(token) <= 4096 do
    expected_binding = target_binding(handle)

    with {:ok, {group, ^scope, ^expected_binding, device}} <-
           Phoenix.Token.verify(:crypto.hash(:sha256, handle.token), @salt, token, max_age: 3600),
         true <- group == handle.group_id and valid_deadline?(device.expires) do
      {:ok, device}
    else
      _ -> {:error, :expired_or_foreign_target}
    end
  end

  defp target(_, _, _), do: {:error, :expired_or_foreign_target}

  defp target_binding(handle), do: {handle.base_url, handle.org_slug, handle.network}

  defp operate(handle, device, "revoke", _) do
    with :ok <- cancel_registration(device),
         {:ok, _} <- revoke_delegation(handle, device.key) do
      {:ok,
       %{
         revoked: true,
         note:
           "Delegation removed; this is not a guarantee that an existing invocation or detached process stopped. Ask the user to press Ctrl-C; the device deadline still applies."
       }}
    end
  end

  defp operate(handle, device, "exec", args) do
    command = args["command"]
    timeout = Map.get(args, "timeout_seconds", 30)

    if is_binary(command) and byte_size(command) in 1..16384 and
         not String.contains?(command, <<0>>) and is_integer(timeout) and timeout in 1..120 do
      with :ok <- active_registration(device) do
        Transport.run(
          handle,
          device,
          command,
          min(timeout, device.expires - System.system_time(:second)) * 1000
        )
      end
    else
      {:error, :invalid_command}
    end
  end

  @doc false
  def url(handle, route) do
    handle.base_url <>
      "/api/orgs/" <>
      URI.encode_www_form(handle.org_slug) <>
      "/networks/" <> URI.encode_www_form(handle.network) <> "/" <> route
  end

  defp request(handle, method, route, options \\ []) do
    result =
      Req.request(
        [
          method: method,
          url: url(handle, route),
          headers: [{"authorization", "Bearer " <> handle.token}],
          receive_timeout: 25_000,
          retry: false,
          redirect: false
        ] ++ options ++ handle.req_options
      )

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, :not_authorized}
      {:ok, %{status: 429}} -> {:error, :busy}
      _ -> {:error, :gateway_unavailable}
    end
  rescue
    _ -> {:error, :gateway_unavailable}
  end

  def valid_key?(key), do: is_binary(key) and Regex.match?(@key, key)

  defp valid_deadline?(expires) do
    is_integer(expires) and expires > System.system_time(:second) and
      expires <= System.system_time(:second) + 3600
  end

  defp revoke_delegation(handle, key), do: request(handle, :delete, "delegations/" <> key)

  defp active_registration(%{request_id: id, key: key}) when is_binary(id),
    do: Registrations.active?(id, key)

  defp active_registration(_), do: :ok

  defp cancel_registration(%{request_id: id}) when is_binary(id) do
    case Registrations.cancel(id) do
      {:ok, _} ->
        Registrations.notify(id)
        :ok

      {:error, :registration_expired} ->
        :ok

      error ->
        error
    end
  end

  defp cancel_registration(_), do: :ok

  @doc false
  def script(group_id, controller, invitation) do
    base = SalixWeb.Application.public_base_url() |> String.trim_trailing("/")

    callback =
      base <>
        "/v1/remote-shell/" <>
        URI.encode_www_form(group_id) <>
        "/registrations/" <> invitation.request_id

    launcher = base <> "/v1/remote-shell/client.py"

    command =
      ~S|set -eu; helper=$(mktemp); trap 'rm -f "$helper"' EXIT HUP INT TERM; curl -fsSL --connect-timeout 10 --max-time 60 "$1" -o "$helper"; python3 "$helper" --controller "$2" --expires-at "$3" --callback "$4" --ticket "$5"|

    "sh -c " <>
      shell_quote(command) <>
      " sh " <>
      Enum.map_join(
        [launcher, controller, to_string(invitation.expires_at), callback, invitation.request],
        " ",
        &shell_quote/1
      )
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
