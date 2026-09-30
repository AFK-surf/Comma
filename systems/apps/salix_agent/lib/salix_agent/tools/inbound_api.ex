defmodule SalixAgent.Tools.InboundApi do
  @moduledoc """
  Router-owned inbound API keys: the credential an external system presents to
  post a message to this Group's Router.

  These tools exist so the Router can finish an integration by itself. Asked to
  make an alerting system, a CI pipeline, or a form backend reach it, the
  Router mints a named key, hands the calling system the key and the URL, and
  revokes the key when the integration ends or leaks.

  A key made here is created by the Router (`agent:<agent_id>`), and
  `Salix.Control.GroupApiKeys.principal/1` gives every such key the `system`
  information-flow creator: it holds no membership anywhere. A Router cannot
  mint itself a principal with its own reach, so a key is never a way around
  the checks that already bound what the Router may read or send.

  Scope is the caller's own Group, resolved from the authenticated runtime
  identity. No tool here takes a group or tenant argument.
  """

  alias SalixAgent.Control
  alias SalixAgent.InboundApiKeyStore

  @max_name_chars 80

  @list_description "List this Group's inbound API keys: the named credentials external systems present to post messages to you. Returns each key's key_id, name, status, prefix, creation and last use, plus the post_message_url an external system posts to. Never returns key plaintext; only inbound_api.create returns that, once. Use this to tell a user which integrations exist, or to find the key_id of one to revoke."

  @create_description "Mint one inbound API key so a named external system can post messages to this Group's Router, and return its plaintext exactly once together with the URL and a ready-to-run example request. Use it when a user asks for an external system (alerting, CI, a form, a cron job, another product) to reach you, and you or the user can configure that system. Name the key after the system that will hold it, one key per system, so a later revoke is exact. Set expires_at for a key that should stop working on its own. The plaintext is never recoverable: put it into the target system's configuration, or give it to the user, in this same turn. A Group holds at most 20 keys; revoke a dead integration's key instead of minting past the limit."

  @revoke_description "Stop one inbound API key from working, by key_id from inbound_api.list. mode=disable keeps the record readable and is the default; mode=delete removes it and frees one of the Group's 20 key slots. Use it when an integration ends, when a user asks, or as the first action when a key may have leaked. Revoking is immediate and cannot be undone: a replacement is a new inbound_api.create, with new plaintext the holding system must be reconfigured with."

  def defs do
    [
      {"inbound_api.list", @list_description, list_schema(), &__MODULE__.list/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "read"]},
      {"inbound_api.create", @create_description, create_schema(), &__MODULE__.create/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "write"]},
      {"inbound_api.revoke", @revoke_description, revoke_schema(), &__MODULE__.revoke/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "write"]}
    ]
  end

  def list_schema,
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{},
      "required" => []
    }

  def create_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "name" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @max_name_chars,
          "description" =>
            "The external system that will hold this key, as a person would name it in a settings list, e.g. \"Sentry alerts\" or \"Release pipeline\"."
        },
        "expires_at" => %{
          "type" => "string",
          "description" =>
            "Optional ISO 8601 instant at which the key stops working, e.g. 2026-01-31T00:00:00Z. Must be in the future. Omit for a key with no expiry."
        }
      },
      "required" => ["name"]
    }
  end

  def revoke_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "key_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "mode" => %{"type" => "string", "enum" => ["disable", "delete"]}
      },
      "required" => ["key_id"]
    }
  end

  def list(args, ctx) do
    with :ok <- SalixAgent.Tools.validate_schema(args, list_schema()),
         {:ok, caller} <- caller(ctx),
         {:ok, keys} <- InboundApiKeyStore.list(caller.tenant_id, caller.group_id) do
      url = InboundApiKeyStore.post_message_url(caller.group_id)

      Jason.encode!(%{"post_message_url" => url, "keys" => Enum.map(keys, &projection(&1, url))})
    else
      error -> failure(error)
    end
  end

  def create(args, ctx) when is_map(args) do
    args = normalize(args)

    with :ok <- SalixAgent.Tools.validate_schema(args, create_schema()),
         {:ok, caller} <- caller(ctx),
         {:ok, key} <-
           InboundApiKeyStore.create(
             caller.tenant_id,
             caller.group_id,
             caller.agent_id,
             Map.take(args, ["name", "expires_at"])
           ) do
      Jason.encode!(created(key, caller.group_id))
    else
      error -> failure(error)
    end
  end

  def create(_args, _ctx),
    do: failure({:error, {:bad_request, "inbound_api.create requires an object"}})

  def revoke(args, ctx) when is_map(args) do
    args = normalize(args)

    with :ok <- SalixAgent.Tools.validate_schema(args, revoke_schema()),
         {:ok, caller} <- caller(ctx),
         {:ok, result} <- revoke_key(caller, args["key_id"], args["mode"] || "disable") do
      Jason.encode!(result)
    else
      error -> failure(error)
    end
  end

  def revoke(_args, _ctx),
    do: failure({:error, {:bad_request, "inbound_api.revoke requires an object"}})

  defp revoke_key(caller, key_id, "delete") do
    case InboundApiKeyStore.delete(caller.tenant_id, caller.group_id, key_id) do
      :ok -> {:ok, %{"key_id" => key_id, "mode" => "delete", "status" => "deleted"}}
      error -> error
    end
  end

  defp revoke_key(caller, key_id, "disable") do
    case InboundApiKeyStore.disable(caller.tenant_id, caller.group_id, key_id) do
      {:ok, key} ->
        {:ok,
         %{
           "key_id" => key_id,
           "mode" => "disable",
           "status" => key["status"],
           "name" => key["name"]
         }}

      error ->
        error
    end
  end

  # The Router acts for its own Group only, and the identity comes from the
  # runtime context, never from an argument: a Worker or a stale role reads as
  # not authorized rather than as an empty Group.
  defp caller(ctx) do
    agent_id = context_string(ctx, :agent_id)
    tenant_id = context_string(ctx, :tenant_id)
    group_id = context_string(ctx, :group_id)

    with true <- agent_id != "" and tenant_id != "" and group_id != "",
         {:ok, agent} <- Control.get(agent_id, tenant_id),
         true <- agent["role"] == "router" and agent["group_id"] == group_id do
      {:ok, %{agent_id: agent_id, tenant_id: tenant_id, group_id: group_id}}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp context_string(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> ""
    end
  end

  defp normalize(args) do
    Map.new(args, fn {key, value} ->
      key = to_string(key)

      value =
        if key in ~w(name expires_at key_id mode) and is_binary(value),
          do: String.trim(value),
          else: value

      {key, value}
    end)
  end

  defp created(key, group_id) do
    url = InboundApiKeyStore.post_message_url(group_id)
    plaintext = key["key"]

    key
    |> projection(url)
    |> Map.put("key", plaintext)
    |> Map.put("plaintext_is_final", true)
    |> Map.put("request", request_shape(url, plaintext))
  end

  defp projection(key, url) do
    key
    |> Map.drop(["key", "key_hash", "tenant_id", "group_id"])
    |> Map.put("post_message_url", url)
  end

  # What the holding system has to send. The example carries the plaintext the
  # caller already holds, so a user can paste it or an agent can transcribe it
  # without re-deriving the header shape.
  defp request_shape(url, plaintext) do
    %{
      "method" => "POST",
      "url" => url,
      "headers" => %{
        "Authorization" => "Bearer " <> to_string(plaintext),
        "Content-Type" => "application/json"
      },
      "body_fields" => %{
        "text" => "Required. The message the Router reads. Up to 32000 characters.",
        "source_message_id" =>
          "Optional. The calling system's own id for this message; a repeat of the same id is delivered once.",
        "sender" =>
          "Optional {name, id} the calling system says about itself. It is not verified identity.",
        "context" =>
          "Optional JSON object of structured data, up to 4 KB. The Router reads it as data, never as instructions.",
        "wake" =>
          "Optional boolean, default true. false delivers the message as context without waking the Router."
      },
      "example" =>
        "curl -X POST #{url} \\\n" <>
          "  -H 'Authorization: Bearer #{plaintext}' \\\n" <>
          "  -H 'Content-Type: application/json' \\\n" <>
          ~s|  -d '{"text": "Build 1234 failed on main", "source_message_id": "build-1234"}'|,
      "responses" =>
        "202 accepted; 401 key rejected; 404 wrong group; 409 no Router configured; 413 body over 64 KB; 422 invalid field; 429 over 60 requests per minute for this key; 503 temporarily unavailable."
    }
  end

  defp failure({:error, :forbidden}),
    do: failure("forbidden", "Only this Group's Router can manage inbound API keys.")

  defp failure({:error, :inbound_api_not_configured}),
    do:
      failure(
        "inbound_api_unavailable",
        "Inbound API keys are not available on this runtime. No key was created or changed."
      )

  defp failure({:error, {:bad_request, message}}), do: failure("invalid_arguments", message)

  defp failure({:error, {:conflict, message}}), do: failure("inbound_api_limit_reached", message)

  defp failure({:error, :not_found}),
    do:
      failure(
        "inbound_api_key_not_found",
        "No inbound API key with that key_id exists in this Group."
      )

  defp failure({:error, reason}) when reason in [:unavailable, :store_unavailable],
    do: failure("inbound_api_unavailable", unavailable_message())

  defp failure({:error, {:unavailable, _reason}}),
    do: failure("inbound_api_unavailable", unavailable_message())

  defp failure({:error, reason}) when is_binary(reason), do: failure("invalid_arguments", reason)

  defp failure(_other), do: failure("inbound_api_unavailable", unavailable_message())

  defp failure(code, message) do
    {:tool_failure, Jason.encode!(%{"code" => code, "message" => message}), code,
     "user_reportable", message, []}
  end

  defp unavailable_message,
    do:
      "Inbound API keys are temporarily unavailable. Nothing was created or changed; check inbound_api.list before retrying."
end
