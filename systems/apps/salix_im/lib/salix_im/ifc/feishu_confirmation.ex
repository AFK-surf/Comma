defmodule SalixIM.IFC.FeishuConfirmation do
  @moduledoc """
  The Feishu card a person answers when the bot asks to carry something across
  an audience boundary (`docs/verification.md` §6.2).

  The same three properties as `SalixIM.IFC.SlackConfirmation`, because they
  are properties of the design rather than of Slack: only the requester sees
  the card and only the requester can answer it; the card states the flow and
  never the content; and the answer is a durable receipt scoped to an audience
  pair, not a report a model can claim.

  Everything that decides anything is shared with the Slack surface — the
  settle-once compare-and-set in
  `SalixAgent.CapabilityRequests.decide_declassification/4`, the receipt it
  writes, the check that the presser is the principal the request names. What
  differs is only how a person is shown the question:

    * the card is Feishu's `interactive` message schema rather than Block Kit,
      sent to the requester's open id;
    * a press arrives as a `card.action.trigger` callback rather than a Slack
      interaction POST, and the card is replaced by returning its settled form
      in the callback's own response instead of by a second API call.

  Both differences are presentation. A callback whose response is lost leaves
  live buttons that decide nothing, exactly as a failed `chat.update` does on
  Slack.
  """

  require Logger

  alias SalixIM.IFC.ConfirmationText, as: Text
  alias SalixIM.Provider.Feishu, as: FeishuProvider
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

  @doc "The Feishu callback event type this surface owns."
  @spec event_type() :: String.t()
  def event_type, do: @event_type

  # ---------------------------------------------------------------------------
  # Asking
  # ---------------------------------------------------------------------------

  @doc """
  Renders one pending `ifc_declassify` request into the requester's Feishu
  direct conversation.

  Returns `:ok` for anything that is not a Feishu-addressable declassification
  request: a request of another type, a requester who is not a provider user,
  a connect that no longer exists. The request stays durable and answerable
  through every other capability-request surface either way.
  """
  @spec post(map()) :: :ok
  def post(%{"request_type" => "ifc_declassify"} = request) do
    payload = get_in(request, ["request_payload", "ifc_declassify"]) || %{}
    group_id = text(request["group_id"])

    with {:ok, connect_id, open_id} <- provider_user(payload["requester"]),
         {:ok, connect} <- connect(group_id, connect_id),
         {:ok, _response} <-
           FeishuProvider.post_direct_card(connect, open_id, card(request, payload)) do
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

  The Feishu user who pressed it must be the principal the request names —
  this is the whole point of the card, so it is checked against the stored
  request rather than against anything in the callback.
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

  # Feishu delivers a button's `value` as an object, but a card round-tripped
  # through an older schema can arrive as the JSON string it was authored as.
  # Both are the app's own card coming back, so both are read.
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
    ProviderConnects.get_active_connect_by_id(group_id, connect_id, "feishu")
  end

  defp capability_mod, do: Application.get_env(:salix_im, :capability_request_mod)

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
