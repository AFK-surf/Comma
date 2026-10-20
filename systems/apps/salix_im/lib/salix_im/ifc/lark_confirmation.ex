defmodule SalixIM.IFC.LarkConfirmation do
  @moduledoc """
  The Lark card a person answers when the bot asks to carry something across
  an audience boundary (`docs/verification.md` §6.2).

  It has the three properties of `SalixIM.IFC.SlackConfirmation`: only the
  requester sees the card and only the requester can answer it; the card
  states the flow and never the content; and the answer is a durable receipt
  for one pair of audiences.

  What decides is shared with the other surfaces: the request settles once in
  `SalixAgent.CapabilityRequests.decide_declassification/4`, which writes the
  receipt, and the person who pressed must be the principal the request
  names. This module owns only how Lark shows the question:

    * the card is an `interactive` message to the requester's open_id;
    * a press arrives as a `card.action.trigger` callback
      (`SalixIM.LarkInbound`), and the answer to that callback replaces the
      card with what was decided.

  When the answer to the callback is lost, the card keeps its buttons. A
  second press decides nothing: the request is already settled.
  """

  require Logger

  alias SalixIM.IFC.ConfirmationText, as: Text
  alias SalixIM.Provider.Lark, as: LarkProvider
  alias SalixIM.ProviderConnects

  @event_type "card.action.trigger"
  @approve "approve"
  @deny "deny"

  @doc "True when this callback envelope is a press on a declassification card."
  @spec action?(map()) :: boolean()
  def action?(envelope) when is_map(envelope) do
    event_type(envelope) == @event_type and action_choice(envelope) in [@approve, @deny]
  end

  def action?(_envelope), do: false

  @doc "The Lark callback event type this surface owns."
  @spec event_type() :: String.t()
  def event_type, do: @event_type

  # ---------------------------------------------------------------------------
  # Asking
  # ---------------------------------------------------------------------------

  @doc """
  Sends one pending `ifc_declassify` request as a card to the requester's
  private chat with the bot.

  Returns `:ok` also when there is nobody to send it to: a request of another
  type, a requester who is not a provider user, a connect that is gone. The
  request stays durable and can be answered on every other surface.
  """
  @spec post(map()) :: :ok
  def post(%{"request_type" => "ifc_declassify"} = request) do
    payload = get_in(request, ["request_payload", "ifc_declassify"]) || %{}
    group_id = text(request["group_id"])

    with {:ok, connect_id, open_id} <- provider_user(payload["requester"]),
         {:ok, connect} <- connect(group_id, connect_id),
         {:ok, _response} <-
           LarkProvider.post_direct_card(connect, open_id, card(request, payload)) do
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
  Applies one button press, and returns the callback response that replaces
  the card with what was decided.

  The Lark user who pressed must be the principal the request names. That
  is checked against the stored request, not against anything the callback
  says about the request.
  """
  @spec apply_action(map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_action(connect, envelope) when is_map(connect) and is_map(envelope) do
    group_id = text(connect["group_id"])
    tenant_id = text(connect["tenant_id"])
    request_id = action_value(envelope, "request_id")
    actor = text(get_in(envelope, ["event", "operator", "open_id"]))
    approved? = action_choice(envelope) == @approve

    with {:ok, request} <- fetch(group_id, request_id, tenant_id),
         :ok <- require_requester(request, connect, actor),
         {:ok, decided} <- decide(group_id, request_id, approved?, tenant_id) do
      {:ok, settled_response(decided, approved?)}
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

  def apply_action(_connect, _envelope), do: {:error, {:ignored, :invalid_interaction_payload}}

  defp require_requester(request, connect, actor) do
    payload = get_in(request, ["request_payload", "ifc_declassify"]) || %{}

    case provider_user(payload["requester"]) do
      {:ok, connect_id, open_id} ->
        if actor != "" and actor == open_id and connect_id == text(connect["connect_id"]),
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

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @doc false
  @spec card(map(), map()) :: map()
  def card(request, payload) do
    request_id = to_string(request["request_id"])
    language = Text.language(payload)

    %{
      "config" => %{"wide_screen_mode" => true},
      "header" => %{
        "title" => %{"tag" => "plain_text", "content" => Text.title(language)}
      },
      "elements" => [
        %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => Text.summary(payload)}},
        %{
          "tag" => "note",
          "elements" => [%{"tag" => "plain_text", "content" => Text.flow_line(payload)}]
        },
        %{
          "tag" => "action",
          "actions" => [
            button(Text.approve_label(language), @approve, request_id, "primary"),
            button(Text.deny_label(language), @deny, request_id, "default")
          ]
        }
      ]
    }
  end

  defp button(label, choice, request_id, type) do
    %{
      "tag" => "button",
      "type" => type,
      "text" => %{"tag" => "plain_text", "content" => label},
      "value" => %{"ifc_declassify" => choice, "request_id" => request_id}
    }
  end

  # The card is replaced by what was decided, so the question does not sit
  # there inviting a second answer. Presentation only: the request settled
  # durably before this was built.
  defp settled_response(request, approved?) do
    detail = get_in(request, ["request_payload", "ifc_declassify"]) || %{}

    %{
      "toast" => %{
        "type" => if(approved?, do: "success", else: "info"),
        "content" => Text.toast(detail, approved?)
      },
      "card" => %{
        "type" => "raw",
        "data" => %{
          "config" => %{"wide_screen_mode" => true},
          "elements" => [
            %{
              "tag" => "div",
              "text" => %{"tag" => "lark_md", "content" => Text.settled(detail, approved?)}
            }
          ]
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp event_type(envelope), do: text(get_in(envelope, ["header", "event_type"]))

  defp action_choice(envelope), do: action_value(envelope, "ifc_declassify")

  # Lark delivers the `value` of a button as an object. A card that went
  # through an older schema can deliver the JSON string instead. Both are
  # this app's own card, so both are read.
  defp action_value(envelope, key) do
    case get_in(envelope, ["event", "action", "value"]) do
      %{} = value ->
        text(value[key])

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, %{} = decoded} -> text(decoded[key])
          _other -> ""
        end

      _other ->
        ""
    end
  end

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
    ProviderConnects.get_active_connect_by_id(group_id, connect_id, "lark")
  end

  defp capability_mod, do: SystemsRuntime.get_env(:salix_im, :capability_request_mod)

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
