defmodule SalixAgent.Tools.OwnerEmail do
  @moduledoc """
  Owner notification tool — email the humans who own this agent group.

  The recipient list is the group control record's `owner_emails`, a
  platform-managed setting (BridgeForTeams syncs the Agent Swarm owner list
  into it). It is deliberately NEVER disclosed to the agent: the tool takes
  only a subject and a plain-text body, resolves the recipients server-side at
  send time, and reports back only delivery status and recipient count.
  Failure messages likewise never echo addresses (see `SalixStore.Postmark`).

  Visibility: `email.send_to_owners` is only disclosed to sessions whose group
  has a non-empty `owner_emails` list (`SalixAgent.ToolDisclosure`
  `reject_unconfigured_capabilities/2`); if called anyway on an unconfigured
  group it errors politely. Delivery goes through the Postmark API via
  `SalixStore.Postmark`, from the address configured as
  `:salix_agent, :owner_notification_from_email`.

  Entry shape matches the `@registry` in `SalixAgent.Tools`. The tool is
  read-only with respect to durable agent state, so it returns a plain content
  string and emits no journal events; failures raise and the dispatcher
  synthesizes error results.
  """

  alias SalixAgent.{AgentRuntimeConfig, GroupContext}
  alias SalixAgent.Tools.AsyncPolicy
  alias SalixStore.Postmark

  @normal_auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()
  @visible_write_opts [safety: "write"]

  @doc "Tool defs in stable registration order."
  @spec defs() ::
          [{String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}]
  def defs do
    [
      {"email.send_to_owners",
       "Send an email to the owners of this agent group (the humans responsible for it).\n\n" <>
         "Use it for results, reports, or questions that need the owners' attention outside the chat. " <>
         "The recipient list is managed by the platform and is not visible to you; " <>
         "the message is delivered to every configured owner. " <>
         "Provide a short, specific subject and a plain-text body.", &__MODULE__.send_to_owners/2,
       @normal_auto_wait_seconds, @visible_write_opts}
    ]
  end

  @doc false
  def send_to_owners(args, ctx) do
    subject = arg(args, "subject")
    body = arg(args, "body")
    if subject == "", do: raise("email.send_to_owners: missing subject")
    if body == "", do: raise("email.send_to_owners: missing body")

    recipients = owner_recipients!(ctx)

    case Postmark.send_email(from_email(), recipients, subject, body) do
      :ok ->
        Jason.encode!(%{"status" => "sent", "recipients" => length(recipients)})

      {:error, :not_configured} ->
        raise "email.send_to_owners is not configured for this runtime: " <>
                "set the Postmark server token and from address"

      {:error, {:postmark, status, error_code}} ->
        raise "email.send_to_owners: delivery failed: " <>
                "postmark http #{status} error code #{error_code || "unknown"}"

      {:error, {:transport, reason}} ->
        raise "email.send_to_owners: transport error #{inspect(reason)}"
    end
  end

  @doc """
  The normalized owner recipient list on a group control record (may be `[]`).
  Shared with the disclosure gate in `SalixAgent.ToolDisclosure`.
  """
  @spec owner_emails(map()) :: [String.t()]
  def owner_emails(group_record) when is_map(group_record) do
    group_record["owner_emails"]
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp owner_recipients!(ctx) do
    ctx =
      case AgentRuntimeConfig.complete_context(ctx) do
        {:ok, completed} ->
          completed

        {:error, reason} ->
          raise "email.send_to_owners: resolve agent context: #{inspect(reason)}"
      end

    tenant = ctx_value(ctx, :tenant_id)
    group = ctx_value(ctx, :group_id)
    if tenant == "" or group == "", do: raise("email.send_to_owners: agent has no group")

    case GroupContext.get(group, tenant) do
      {:ok, record} ->
        case owner_emails(record) do
          [] -> raise not_configured_message()
          emails -> emails
        end

      {:error, :not_found} ->
        raise not_configured_message()

      {:error, reason} ->
        raise "email.send_to_owners: load group: #{inspect(reason)}"
    end
  end

  defp not_configured_message do
    "email.send_to_owners is not available: no owner email addresses are configured for this agent group"
  end

  # Blank From falls through to Postmark's :not_configured error, which the
  # caller above maps onto the configuration message.
  defp from_email do
    :salix_agent
    |> Application.get_env(:owner_notification_from_email)
    |> to_string()
    |> String.trim()
  end

  defp ctx_value(ctx, key) do
    (Map.get(ctx, key) || Map.get(ctx, to_string(key)))
    |> to_string()
    |> String.trim()
  end

  # Same string-args pattern as SalixAgent.Tools.
  defp arg(args, key), do: to_string(args[key] || args[String.to_atom(key)] || "")
end
