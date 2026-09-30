defmodule BridgeForTeams.Observability.SalixIMSink do
  @moduledoc """
  Adapter-level bridge from Salix IM diagnostics into BFT Operations events.

  Salix remains decoupled from BFT: it emits a small, already-sanitized
  diagnostic map through `:salix_im, :diagnostic_sink`. This module resolves the
  Salix group to the owning BFT project/org and persists the normalized
  Operations event.
  """
  use BridgeForTeams.Observability.Producer,
    producer: :salix_im_diagnostics,
    records: [:event],
    domains: ["conversation", "integration"],
    sources: ["salix.im"],
    resource_types: ["feishu_connect", "feishu_message", "slack_connect", "slack_message"],
    evidence_allowlist: [
      "app_id",
      "callback_mode",
      "channel_id",
      "chat_id",
      "chat_type",
      "connect_id",
      "delivery_state",
      "group_id",
      "message_id",
      "operation_api",
      "provider",
      "provider_event_id",
      "provider_event_type",
      "receive_id_type",
      "reply_message_id",
      "request_id",
      "source",
      "source_message_id",
      "tenant_id",
      "thread_ts",
      "user_id",
      "workspace_id"
    ],
    permissions: :org_member

  alias BridgeForTeams.Projects
  alias BridgeForTeams.Observability.AdapterDiagnostic

  @im_evidence_keys_by_provider %{
    "feishu" => [
      :provider,
      :source,
      :tenant_id,
      :group_id,
      :connect_id,
      :app_id,
      :provider_event_type,
      :provider_event_id,
      :request_id,
      :message_id,
      :source_message_id,
      :reply_message_id,
      :chat_id,
      :chat_type,
      :callback_mode,
      :delivery_state,
      :operation_api,
      :receive_id_type
    ],
    "slack" => [
      :provider,
      :source,
      :tenant_id,
      :group_id,
      :connect_id,
      :app_id,
      :workspace_id,
      :provider_event_type,
      :provider_event_id,
      :request_id,
      :message_id,
      :source_message_id,
      :reply_message_id,
      :channel_id,
      :thread_ts,
      :message_ts,
      :user_id,
      :callback_mode,
      :delivery_state,
      :operation_api
    ]
  }

  @known_providers Map.keys(@im_evidence_keys_by_provider)
  @default_evidence_keys [
    :provider,
    :source,
    :tenant_id,
    :group_id,
    :connect_id,
    :app_id,
    :provider_event_type,
    :provider_event_id,
    :request_id,
    :message_id,
    :source_message_id,
    :reply_message_id,
    :chat_id,
    :chat_type,
    :callback_mode,
    :delivery_state,
    :operation_api,
    :receive_id_type
  ]

  @doc "Record a Salix IM diagnostic as an Operations event when it belongs to a BFT project."
  @spec record(map()) :: :ok
  def record(diagnostic) when is_map(diagnostic) do
    AdapterDiagnostic.safe_record("BFT IM diagnostic", fn ->
      case AdapterDiagnostic.string_value(AdapterDiagnostic.value(diagnostic, :provider), "") do
        provider when provider in @known_providers -> record_provider(provider, diagnostic)
        _provider -> :ok
      end
    end)
  end

  def record(_diagnostic), do: :ok

  defp record_provider(provider, diagnostic) do
    group_id =
      diagnostic
      |> AdapterDiagnostic.value(:group_id)
      |> AdapterDiagnostic.blank_to_nil()

    if is_binary(group_id) do
      do_record_provider(provider, group_id, diagnostic)
    else
      :ok
    end
  end

  defp do_record_provider(provider, group_id, diagnostic) do
    case Projects.get_project_by_salix_group(group_id) do
      {:ok, project} ->
        diagnostic
        |> im_event_attrs(project, provider)
        |> AdapterDiagnostic.persist_event("BFT IM diagnostic")

      {:error, :not_found} ->
        :ok
    end
  end

  defp im_event_attrs(diagnostic, project, provider) do
    %{
      org_id: project.org_id,
      project_id: project.id,
      domain: im_domain(diagnostic, provider),
      source: "salix.im",
      event_type:
        diagnostic
        |> AdapterDiagnostic.value(:event_type)
        |> AdapterDiagnostic.string_value("#{provider}.callback.diagnostic"),
      severity:
        diagnostic |> AdapterDiagnostic.value(:severity) |> AdapterDiagnostic.string_value("info"),
      status:
        diagnostic
        |> AdapterDiagnostic.value(:status)
        |> AdapterDiagnostic.string_value("unknown"),
      reason_class:
        diagnostic |> AdapterDiagnostic.value(:reason_class) |> AdapterDiagnostic.blank_to_nil(),
      summary:
        diagnostic
        |> AdapterDiagnostic.value(:summary)
        |> AdapterDiagnostic.string_value("#{provider} diagnostic"),
      resource_type: im_resource_type(diagnostic, provider),
      resource_id: im_resource_id(diagnostic, provider),
      correlation_id: im_correlation_id(diagnostic),
      evidence: im_evidence(diagnostic, provider)
    }
  end

  defp im_evidence(diagnostic, provider) do
    keys = Map.get(@im_evidence_keys_by_provider, provider, @default_evidence_keys)
    AdapterDiagnostic.take_evidence(diagnostic, keys)
  end

  defp im_domain(diagnostic, provider) do
    domain = AdapterDiagnostic.value(diagnostic, :domain)
    event_type = AdapterDiagnostic.value(diagnostic, :event_type)

    cond do
      domain in ["integration", "conversation"] -> domain
      message_event_type?(provider, event_type) -> "conversation"
      true -> "integration"
    end
  end

  defp im_resource_type(diagnostic, provider) do
    resource_type =
      diagnostic
      |> AdapterDiagnostic.value(:resource_type)
      |> AdapterDiagnostic.blank_to_nil()

    event_type = AdapterDiagnostic.value(diagnostic, :event_type)

    cond do
      is_binary(resource_type) -> resource_type
      message_event_type?(provider, event_type) -> "#{provider}_message"
      true -> "#{provider}_connect"
    end
  end

  defp im_resource_id(diagnostic, provider) do
    if im_resource_type(diagnostic, provider) == "#{provider}_connect" do
      AdapterDiagnostic.first_value(diagnostic, [:resource_id, :connect_id])
    else
      AdapterDiagnostic.first_value(diagnostic, [
        :resource_id,
        :source_message_id,
        :reply_message_id,
        :message_id,
        :connect_id
      ])
    end
  end

  defp im_correlation_id(diagnostic) do
    AdapterDiagnostic.correlation_id(diagnostic)
  end

  defp message_event_type?(provider, event_type)
       when is_binary(provider) and is_binary(event_type) do
    String.starts_with?(event_type, ["#{provider}.reply.", "#{provider}.message."])
  end

  defp message_event_type?(_provider, _event_type), do: false
end
