defmodule SalixAgent.Tools.DeviceSecrets do
  @moduledoc """
  `device.secret_*`: the Group's saved secrets for devices on the user's
  local network (`SalixAgent.DeviceSecrets`). The model writes a value once
  and then names it (`token_ref` on `device.miio_request`, `auth.secret_ref`
  on `device.lan_request`); no result contains a value.
  """

  alias SalixAgent.DeviceSecrets

  @short_wait SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  def defs do
    [
      {"device.secret_save",
       "Save a secret for a device on the user's local network, such as a Xiaomi lamp's miIO token or an ONVIF camera's password, so later conversations use it by name without the user giving it again. Saving an existing name replaces it. The result never contains the value. After saving, never repeat or quote the value or any part of it; refer to the secret by its name.",
       %{
         "type" => "object",
         "additionalProperties" => false,
         "required" => ~w(kind name value),
         "properties" => %{
           "kind" => %{
             "type" => "string",
             "enum" => DeviceSecrets.kinds(),
             "description" =>
               "miio_token: a 32-hex-character Xiaomi miIO device token. onvif_password: an ONVIF camera account's password, 4 to 64 printable ASCII characters without spaces."
           },
           "name" => %{
             "type" => "string",
             "minLength" => 1,
             "maxLength" => 64,
             "description" => "A short name for the device, such as bedside-lamp."
           },
           "value" => %{
             "type" => "string",
             "description" => "The secret, from the user."
           },
           "host" => %{
             "type" => "string",
             "description" => "The device's IP address or hostname on the gateway's network."
           },
           "model" => %{"type" => "string", "description" => "Device model, such as bslamp2."}
         }
       }, &__MODULE__.save/2, @short_wait, [safety: "write"]},
      {"device.secret_list",
       "List the saved device secrets of this Group: name, kind, host, model and when each was created and last used. Never returns values. Check this before asking the user for a device token.",
       %{
         "type" => "object",
         "additionalProperties" => false,
         "required" => [],
         "properties" => %{}
       }, &__MODULE__.list/2, @short_wait, [safety: "read"]},
      {"device.secret_delete",
       "Delete a saved device secret by name. Later requests that name it fail until it is saved again.",
       %{
         "type" => "object",
         "additionalProperties" => false,
         "required" => ["name"],
         "properties" => %{"name" => %{"type" => "string", "minLength" => 1, "maxLength" => 64}}
       }, &__MODULE__.delete/2, @short_wait, [safety: "write"]}
    ]
  end

  @doc false
  def save(args, ctx) do
    case DeviceSecrets.save(group_id!(ctx), args) do
      {:ok, secret, outcome} ->
        Jason.encode!(%{"saved" => true, "replaced" => outcome == :replaced, "secret" => secret})

      {:error, reason} ->
        failure(reason)
    end
  end

  @doc false
  def list(_args, ctx) do
    case DeviceSecrets.list(group_id!(ctx)) do
      {:ok, secrets} -> Jason.encode!(%{"secrets" => secrets})
      {:error, reason} -> failure(reason)
    end
  end

  @doc false
  def delete(args, ctx) do
    case DeviceSecrets.delete(group_id!(ctx), Map.get(args, "name")) do
      {:ok, secret} -> Jason.encode!(%{"deleted" => secret != nil, "secret" => secret})
      {:error, reason} -> failure(reason)
    end
  end

  @doc "The calling Agent's Group."
  def group_id!(ctx) do
    case Map.get(ctx, :group_id) do
      group when is_binary(group) and group != "" -> group
      _ -> SalixStore.Ids.group_id_from_agent!(ctx.agent_id)
    end
  rescue
    _ -> raise "device secrets require the Agent's Group"
  end

  @doc false
  def failure(reason) do
    {code, message} = describe(reason)
    content = Jason.encode!(%{"code" => code, "message" => message})
    {:tool_failure, content, code, "user_reportable", message, []}
  end

  defp describe(:invalid_kind),
    do: {"invalid_kind", "kind must be one of: #{Enum.join(DeviceSecrets.kinds(), ", ")}."}

  defp describe(:invalid_name),
    do: {"invalid_name", "name must be 1 to 64 characters without control characters or /."}

  defp describe(:invalid_value),
    do:
      {"invalid_value",
       "The value does not have the format of this kind. A miio_token is 32 hex characters; an onvif_password is 4 to 64 printable ASCII characters without spaces. Ask the user to check it."}

  defp describe(:invalid_host), do: {"invalid_host", "host must be at most 253 characters."}
  defp describe(:invalid_model), do: {"invalid_model", "model must be at most 128 characters."}

  defp describe(:too_many_secrets),
    do:
      {"too_many_secrets",
       "This Group already has #{DeviceSecrets.max_secrets()} saved device secrets. Delete one first."}

  defp describe(:not_found),
    do:
      {"saved_token_not_found",
       "No saved device secret has this name. Check device.secret_list, or ask the user for the token or password and save it with device.secret_save."}

  defp describe({:wrong_kind, kind}),
    do:
      {"wrong_secret_kind",
       "The saved secret with this name is a #{kind}, not the kind this tool needs."}

  defp describe(_reason),
    do:
      {"device_secrets_unavailable",
       "Saved device secrets are unavailable right now. Try again later."}
end
