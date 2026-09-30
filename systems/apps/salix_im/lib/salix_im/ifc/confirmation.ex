defmodule SalixIM.IFC.Confirmation do
  @moduledoc """
  Where a person is asked to confirm carrying something across an audience
  boundary (`docs/verification.md` §6.2).

  A declassification request is durable and answerable from the dashboard
  whatever happens here. What this decides is whether it *also* reaches the
  person where they are already talking to the bot, which is the difference
  between a question they answer in seconds and a row they never see.

  The request names its requester as a provider principal, so the provider is
  already in the request: `provider_user|<connect>|<id>` says which connect,
  and the connect says which provider. A provider with no surface of its own
  falls through to the dashboard rather than failing — the question is still
  asked, just not in place.
  """

  require Logger

  alias SalixIM.IFC.{FeishuConfirmation, SlackConfirmation}
  alias SalixIM.ProviderConnects

  @doc "Posts one pending `ifc_declassify` request to its requester's provider."
  @spec post(map()) :: :ok
  def post(%{"request_type" => "ifc_declassify"} = request) do
    case provider_of(request) do
      "slack" -> SlackConfirmation.post(request)
      "feishu" -> FeishuConfirmation.post(request)
      _no_surface -> :ok
    end
  rescue
    exception ->
      Logger.warning("ifc confirmation surface failed: #{Exception.message(exception)}")
      :ok
  catch
    _kind, _reason -> :ok
  end

  def post(_request), do: :ok

  defp provider_of(request) do
    with requester when is_binary(requester) <-
           get_in(request, ["request_payload", "ifc_declassify", "requester"]),
         {:ok, {:provider_user, connect_id, _user_id}} <-
           SalixIFC.Codec.decode_principal(requester),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             to_string(request["group_id"]),
             connect_id
           ) do
      to_string(connect["provider"])
    else
      _other -> ""
    end
  end
end
