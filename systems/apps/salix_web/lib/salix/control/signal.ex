defmodule Salix.Control.Signal do
  @moduledoc """
  Signal bindings and numbers (docs/messaging-voice.md), for the Salix
  control API, the Comma settings and admin APIs, the Salix dashboard and the
  BFT dashboard (over erpc).

  A Group's Signal peers bind with a claim code: `start_claim/3` creates one
  on the tenant's effective Signal account (`SalixSignal.Settings`), and the
  user sends `comma connect <code>` to that account's number. The connect
  record, its reservations and the claim contract stay owned by
  `SalixIM.SignalConnects`; this module adds the account choice and a
  projection. Code digests never leave `salix_im`, and the plaintext code
  appears only in the `start_claim/3` result.
  """

  alias Salix.Control.Groups
  alias SalixIM.{ProviderConnects, SignalConnects}
  alias SalixSignal.Settings

  @type error ::
          :not_found
          | :not_configured
          | :signal_account_not_found
          | :signal_account_inactive
          | :signal_account_scope
          | :signal_claim_unavailable
          | {:bad_request, String.t()}
          | {:unavailable, term()}

  # ---- Group bindings ----

  @doc """
  The Group's Signal status: `"account"` (the account that new claims use:
  `e164`, `state`, or nil), `"bindings"`, `"pending_claims"` and
  `"connect_id"`.
  """
  @spec status(String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def status(group_id, tenant_id) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, tenant} <- tenant_view(tenant_id) do
      connect =
        case ProviderConnects.get_signal_im_connect(tenant_id, group_id) do
          {:ok, connect} -> connect
          _ -> nil
        end

      {:ok,
       %{
         "group_id" => group_id,
         "account" => tenant["effective"],
         "connect_id" => connect && connect["connect_id"],
         "bindings" => if(connect, do: annotate(connect["bindings"]), else: []),
         "pending_claims" => if(connect, do: connect["pending_claims"], else: [])
       }}
    end
  end

  @doc """
  Starts a claim for the Group. Returns `status/2` plus `"claim"`:
  `claim_id`, `code`, `command` (the text to send), `number` (the account's
  number) and `expires_at`. The code is shown once.
  """
  @spec start_claim(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def start_claim(group_id, tenant_id, created_by) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, account} <- effective_account(tenant_id),
         {:ok, claim} <-
           SignalConnects.start_claim(tenant_id, group_id, account["account_id"], created_by),
         {:ok, status} <- status(group_id, tenant_id) do
      {:ok,
       Map.put(
         status,
         "claim",
         claim
         |> Map.take(~w(claim_id code command expires_at))
         |> Map.put("number", account["e164"])
       )}
    end
  end

  @doc "Cancels a pending claim. Returns `status/2`."
  @spec cancel_claim(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def cancel_claim(group_id, tenant_id, claim_id) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, _connect} <- SignalConnects.cancel_claim(tenant_id, group_id, claim_id) do
      status(group_id, tenant_id)
    end
  end

  @doc """
  Removes a binding and ends a live Signal call from that peer as revoked.
  Returns `status/2`.
  """
  @spec remove_binding(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def remove_binding(group_id, tenant_id, binding_id) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, _connect, binding} <-
           SignalConnects.remove_binding(tenant_id, group_id, binding_id) do
      if binding["kind"] == "user", do: SalixVoice.revoke_caller(group_id, binding["peer"])
      status(group_id, tenant_id)
    end
  end

  # ---- numbers ----

  @doc "The platform Signal account view (`account_id`, `e164`, `state`) or nil."
  @spec platform_settings() :: {:ok, map()} | {:error, error()}
  def platform_settings do
    case Settings.platform() do
      {:ok, platform} -> {:ok, %{"platform" => platform}}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  @doc "Sets or clears (`\"number\" => \"\"`) the platform Signal number."
  @spec put_platform_settings(map()) :: {:ok, map()} | {:error, error()}
  def put_platform_settings(%{"number" => number}) when is_binary(number) or is_nil(number) do
    with {:ok, platform} <- Settings.set_platform_number(number) do
      {:ok, %{"platform" => platform}}
    end
  end

  def put_platform_settings(_attrs), do: {:error, {:bad_request, "number is required"}}

  @doc "The tenant's Signal number view: `override`, `platform`, `effective`."
  @spec tenant_number(String.t()) :: {:ok, map()} | {:error, error()}
  def tenant_number(tenant_id), do: tenant_view(tenant_id)

  @doc "Sets or clears (`\"number\" => \"\"`) the tenant's own Signal number."
  @spec put_tenant_number(String.t(), map()) :: {:ok, map()} | {:error, error()}
  def put_tenant_number(tenant_id, %{"number" => number})
      when is_binary(tenant_id) and (is_binary(number) or is_nil(number)),
      do: Settings.set_tenant_number(tenant_id, number)

  def put_tenant_number(_tenant_id, _attrs), do: {:error, {:bad_request, "number is required"}}

  @doc "Maps a result error to an HTTP status and a stable error code."
  @spec http_error(term()) :: {pos_integer(), String.t()}
  def http_error({:bad_request, message}), do: {400, message}
  def http_error(:not_found), do: {404, "not_found"}
  def http_error(:signal_account_not_found), do: {422, "signal_account_not_found"}
  def http_error(:signal_account_inactive), do: {422, "signal_account_inactive"}
  def http_error(:signal_account_scope), do: {422, "signal_account_scope"}
  def http_error(:signal_claim_unavailable), do: {409, "signal_claim_unavailable"}
  def http_error(:conflict), do: {409, "conflict"}
  def http_error(:not_configured), do: {503, "signal_not_configured"}
  def http_error(_reason), do: {503, "unavailable"}

  # ---- internal ----

  defp effective_account(tenant_id) do
    case Settings.effective_account(tenant_id) do
      {:ok, account} -> {:ok, account}
      {:error, :not_configured} -> {:error, :not_configured}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  defp tenant_view(tenant_id) do
    case Settings.tenant(tenant_id) do
      {:ok, view} -> {:ok, view}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  # Each binding shows the number it was claimed on.
  defp annotate(bindings) do
    numbers =
      bindings
      |> Enum.map(& &1["account_id"])
      |> Enum.uniq()
      |> Map.new(&{&1, (Settings.account_view(&1) || %{})["e164"]})

    Enum.map(bindings, &Map.put(&1, "number", numbers[&1["account_id"]]))
  end

  defp group(group_id, tenant_id) do
    case Groups.get(group_id, tenant_id) do
      {:ok, group} -> {:ok, group}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end
end
