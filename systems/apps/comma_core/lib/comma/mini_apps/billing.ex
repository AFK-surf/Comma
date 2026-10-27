defmodule Comma.MiniApps.Billing do
  @moduledoc """
  Paid-work admission for Mini Apps (design §9), through the same
  `BillingCore.FeeControl` availability check that admits paid Comma work:

    * `owner_available/2`: the owner Workspace's billing account. An app opens,
      calls its backend, writes storage or calls AI or web search only while it is
      available; otherwise the call answers `app_paused`. A pause stores
      nothing and deletes nothing.
    * `deploy_admitted/1`: the owner Workspace before a deploy (hosting).
    * `viewer_admitted/2`: the viewer's Workspace before `ai.chat` or `ai.decide`, whose model
      call `SalixAgent.LLM` meters to that Workspace.

  Hosting is admitted but not metered here: no billing catalog key exists for
  bundle storage, backend requests or app documents yet.
  """

  require Logger

  @refusals ["insufficient_credits", "account_inactive", "missing_account"]

  @doc "`:ok`, or `{:error, :app_paused}` when the owner Workspace cannot pay."
  def owner_available(billing_account_id, kind) do
    case authorize(billing_account_id, kind) do
      :ok -> :ok
      {:error, {:billing_unavailable, _reason}} -> {:error, :app_paused}
      {:error, _} = error -> error
    end
  end

  def deploy_admitted(billing_account_id), do: authorize(billing_account_id, "deploy")

  def viewer_admitted(billing_account_id, kind \\ "ai_chat"),
    do: authorize(billing_account_id, kind)

  defp authorize(account_id, kind) when is_binary(account_id) and account_id != "" do
    request = %{
      billing_account_id: account_id,
      resource_kind: :llm,
      action: :start,
      mode: :enforce,
      estimated_credits: 1,
      provider: "runtime",
      sku: "llm",
      surface: "comma",
      source: "mini_app_admission",
      source_key: "mini_app:" <> kind,
      row_context: %{
        "billing_account_id" => account_id,
        "surface" => "comma",
        "entrypoint" => "mini_app_" <> kind,
        "actor_type" => "user"
      }
    }

    case BillingCore.FeeControl.authorize(request) do
      {:ok, %{allowed?: true}} ->
        :ok

      {:ok, %{reason: reason}} when reason in @refusals ->
        {:error, {:billing_unavailable, reason}}

      {:ok, %{reason: reason}} ->
        {:error, {:billing_unavailable, to_string(reason)}}

      {:error, reason} ->
        Logger.warning("mini app admission failed: #{inspect(reason)}")
        {:error, :temporarily_unavailable}
    end
  rescue
    exception ->
      Logger.warning("mini app admission failed: #{Exception.message(exception)}")
      {:error, :temporarily_unavailable}
  end

  defp authorize(_account_id, _kind), do: {:error, {:billing_unavailable, "missing_account"}}
end
