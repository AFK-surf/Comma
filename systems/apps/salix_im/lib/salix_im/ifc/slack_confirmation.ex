defmodule SalixIM.IFC.SlackConfirmation do
  @moduledoc """
  The Slack card a person answers when the bot asks to carry something across
  an audience boundary (`docs/verification.md` §6.2).

  Declassification is a human act, and this is the human's half of it. The
  algebra refuses a cross-scope relay; the Router raises one durable
  capability request through `ifc.request_declassification`; this module
  renders that request as an interactive message in the requester's own
  direct conversation with the bot, and turns a button press into a receipt.

  Three properties do the work:

    * **Only the requester sees it, and only the requester can answer it.**
      The card goes to that person's DM, and the interaction handler checks
      that the Slack user who pressed the button is the principal the request
      names. A card forwarded, or a payload replayed by someone else, decides
      nothing.
    * **The card states the flow, not the content.** Origins and destination
      by display name, plus the one-sentence summary the Router wrote. What is
      being carried is already visible to this person; where it would go is
      what they are being asked about.
    * **The answer is a row, not a report.** Approval writes a receipt scoped
      to `(requester, sources, destination)` with a bounded lifetime, spent by
      the one effect that uses it, and the kernel later finds that row.
      Nothing here lets a model claim consent.

  The card is replaced with its settled form as soon as it is answered, but
  that is presentation. What makes a second press decide nothing is the
  durable settlement in `CapabilityRequests.decide_declassification/4`: the
  request leaves `pending` in one compare-and-set before any receipt is
  written, so a replayed interaction, a late press of the other button, and a
  card whose update failed all arrive too late to change the answer.
  """

  require Logger

  alias SalixIM.IFC.ConfirmationText, as: Text
  alias SalixIM.Provider.Slack, as: SlackProvider
  alias SalixIM.ProviderConnects

  @approve "ifc_declassify:approve"
  @deny "ifc_declassify:deny"
  @actions [@approve, @deny]

  @doc "True when this interaction payload belongs to a declassification card."
  @spec action?(map()) :: boolean()
  def action?(%{"actions" => [%{"action_id" => action_id} | _rest]}) when is_binary(action_id),
    do: action_id in @actions

  def action?(_payload), do: false

  # ---------------------------------------------------------------------------
  # Asking
  # ---------------------------------------------------------------------------

  @doc """
  Renders one pending `ifc_declassify` request into the requester's DM.

  Returns `:ok` for anything that is not a Slack-addressable declassification
  request: a request of another type, a requester who is not a provider user,
  a connect that no longer exists. The request stays durable and answerable
  through every other capability-request surface either way.
  """
  @spec post(map()) :: :ok
  def post(%{"request_type" => "ifc_declassify"} = request) do
    payload = get_in(request, ["request_payload", "ifc_declassify"]) || %{}
    group_id = text(request["group_id"])
    tenant_id = text(request["tenant_id"])

    with {:ok, connect_id, user_id} <- provider_user(payload["requester"]),
         {:ok, connect} <- connect(group_id, connect_id),
         {:ok, _response} <-
           SlackProvider.post_direct_surface(
             tenant_id,
             connect,
             user_id,
             fallback(payload),
             blocks(request, payload)
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("ifc declassification card not delivered: #{inspect(reason)}")
        :ok

      _other ->
        :ok
    end
  rescue
    exception ->
      Logger.warning("ifc declassification card failed: #{Exception.message(exception)}")
      :ok
  catch
    _kind, _reason -> :ok
  end

  def post(_request), do: :ok

  # ---------------------------------------------------------------------------
  # Answering
  # ---------------------------------------------------------------------------

  @doc """
  Applies one button press.

  The Slack user who pressed it must be the principal the request names —
  this is the whole point of the card, so it is checked against the stored
  request rather than against anything in the payload.
  """
  @spec apply_action(map(), map()) :: {:ok, :accepted} | {:error, term()}
  def apply_action(connect, %{"actions" => [action | _rest]} = payload) when is_map(connect) do
    group_id = text(connect["group_id"])
    tenant_id = text(connect["tenant_id"])
    request_id = text(action["value"])
    actor = payload |> Map.get("user", %{}) |> Map.get("id") |> text()
    approved? = text(action["action_id"]) == @approve

    with {:ok, request} <- fetch(group_id, request_id, tenant_id),
         :ok <- require_requester(request, connect, actor),
         {:ok, decided} <- decide(group_id, request_id, approved?, tenant_id) do
      settle(tenant_id, connect, payload, decided, approved?)
      {:ok, :accepted}
    else
      {:error, :not_requester} ->
        {:error, {:ignored, :ifc_declassify_wrong_user}}

      # The durable request settles once. A second delivery of the same press,
      # the other button arriving late, or a card answered after its own clock
      # ran out all land here, and none of them is worth retrying.
      {:error, {:conflict, :already_settled}} ->
        {:error, {:ignored, :ifc_declassify_settled}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_action(_connect, _payload), do: {:error, {:ignored, :invalid_interaction_payload}}

  defp require_requester(request, connect, actor) do
    payload = get_in(request, ["request_payload", "ifc_declassify"]) || %{}

    case provider_user(payload["requester"]) do
      {:ok, connect_id, user_id} ->
        if actor != "" and actor == user_id and connect_id == text(connect["connect_id"]),
          do: :ok,
          else: {:error, :not_requester}

      _other ->
        {:error, :not_requester}
    end
  end

  defp decide(group_id, request_id, approved?, tenant_id) do
    case capability_mod() do
      nil ->
        {:error, {:ignored, :capability_requests_unavailable}}

      mod ->
        mod.decide_declassification(group_id, request_id, %{"approved" => approved?}, tenant_id)
    end
  end

  # The card is replaced by what was decided, so the question does not sit
  # there inviting a second answer. This is presentation only: the request
  # itself settled durably before we got here, so a failed update leaves live
  # buttons that decide nothing rather than a second chance to decide.
  defp settle(tenant_id, connect, payload, request, approved?) do
    message = Map.get(payload, "message", %{})
    channel = payload |> Map.get("channel", %{}) |> Map.get("id") |> text()
    ts = message |> Map.get("ts") |> text()
    detail = get_in(request, ["request_payload", "ifc_declassify"]) || %{}

    if channel != "" and ts != "" do
      settled = Text.settled(detail, approved?)

      SlackProvider.update_surface(tenant_id, connect, channel, ts, settled, [
        %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => settled}}
      ])
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp blocks(request, payload) do
    language = Text.language(payload)

    [
      %{
        "type" => "section",
        "text" => %{
          "type" => "mrkdwn",
          "text" => "*#{Text.title(language)}*\n" <> Text.summary(payload)
        }
      },
      %{
        "type" => "context",
        "elements" => [%{"type" => "mrkdwn", "text" => Text.flow_line(payload)}]
      },
      %{
        "type" => "actions",
        "elements" => [
          button(@approve, Text.approve_label(language), request["request_id"], "primary"),
          button(@deny, Text.deny_label(language), request["request_id"], nil)
        ]
      }
    ]
  end

  defp button(action_id, label, request_id, style) do
    %{
      "type" => "button",
      "action_id" => action_id,
      "value" => to_string(request_id),
      "text" => %{"type" => "plain_text", "text" => label}
    }
    |> then(&if(style, do: Map.put(&1, "style", style), else: &1))
  end

  defp fallback(payload), do: Text.fallback(payload)

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp fetch(group_id, request_id, tenant_id) do
    cond do
      group_id == "" or request_id == "" ->
        {:error, {:ignored, :invalid_interaction_payload}}

      is_nil(capability_mod()) ->
        {:error, {:ignored, :capability_requests_unavailable}}

      true ->
        capability_mod().get(group_id, request_id, tenant_id)
    end
  end

  defp provider_user(encoded) when is_binary(encoded) do
    case SalixIFC.Codec.decode_principal(encoded) do
      {:ok, {:provider_user, connect_id, user_id}} -> {:ok, connect_id, user_id}
      _other -> {:error, :not_a_provider_user}
    end
  end

  defp provider_user(_encoded), do: {:error, :not_a_provider_user}

  defp connect(group_id, connect_id) do
    ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack")
  end

  defp capability_mod, do: Application.get_env(:salix_im, :capability_request_mod)

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
