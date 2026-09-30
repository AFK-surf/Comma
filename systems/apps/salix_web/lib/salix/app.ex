defmodule Salix.App do
  @moduledoc """
  Salix composition root.

  This module wires domain ports to implementations hosted by `salix_web`.
  Domain modules keep their own public APIs and declare outbound behaviours;
  this module only binds those behaviours at application start.
  """

  @doc "Register cross-app port implementations for the running Salix node."
  def configure do
    Application.put_env(:salix_im, :conversation_notifier, &SalixWeb.PubSubNotifier.notify/2)
    register_notifier(SalixWeb.PubSubNotifier)

    Application.put_env(:salix_agent, :llm_resolver, Salix.Bindings.AgentLlmResolver)
    Application.put_env(:salix_agent, :media_resolver, Salix.Bindings.AgentMediaResolver)

    Application.put_env(
      :salix_agent,
      :audio_transcriber_mod,
      Salix.Bindings.AgentAudioTranscriber
    )

    Application.put_env(:salix_agent, :group_context_mod, Salix.Bindings.AgentGroupContext)
    Application.put_env(:salix_agent, :agent_management_ports, Salix.Bindings.AgentManagement)
    Application.put_env(:salix_agent, :cloud_vm_mod, Salix.Bindings.AgentCloudVM)

    Application.put_env(
      :salix_agent,
      :storage_authorization_mod,
      SalixAgent.StorageAuthorization.BillingCore
    )

    Application.put_env(
      :salix_web,
      :vm_authorization_mod,
      SalixWeb.ComputeProviders.Cloudflare.VMAuthorization.BillingCore
    )

    Application.put_env(
      :salix_agent,
      :runtime_environment_mod,
      Salix.Bindings.AgentRuntimeEnvironment
    )

    Application.put_env(
      :salix_agent,
      :capability_request_store_mod,
      SalixAgent.CapabilityRequests
    )

    Application.put_env(
      :salix_agent,
      :capability_request_notifier_mod,
      Salix.Bindings.AgentCapabilityRequests
    )

    Application.put_env(:salix_agent, :loop_webhook_url_builder, fn secret ->
      SalixWeb.Application.public_base_url() <> "/v1/loop-webhooks/" <> secret
    end)

    Application.put_env(:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore)

    Application.put_env(
      :salix_agent,
      :inbound_api_key_store_mod,
      Salix.Bindings.AgentInboundApiKeys
    )

    Application.put_env(:salix_agent, :composio_store_mod, Salix.Bindings.AgentComposioStore)
    Application.put_env(:salix_agent, :drive_mod, Salix.Bindings.AgentDrive)
    Application.put_env(:salix_agent, :remote_shell_mod, Salix.RemoteShell)

    Application.put_env(:salix_agent, :plugin_store_mod, Salix.Bindings.AgentPluginStore)

    Application.put_env(
      :salix_agent,
      :memory_consultation_source_mod,
      Salix.Bindings.AgentConversations
    )

    Application.put_env(:salix_agent, :calendar_mod, Salix.Bindings.AgentCalendar)
    Application.put_env(:salix_agent, :meeting_mod, Salix.Bindings.AgentMeeting)

    Application.put_env(
      :salix_agent,
      :meeting_activation_provenance_mod,
      Salix.Bindings.MeetingActivationProvenance
    )

    Application.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    Application.put_env(:salix_agent, :ifc_facts_mod, SalixIM.IFC.Facts)

    # A declassification card is answered in Slack, so the IM domain needs a
    # way back to the durable request that raised it. Reading and deciding
    # only; the receipt is written by the agent side that owns it.
    Application.put_env(:salix_im, :capability_request_mod, SalixAgent.CapabilityRequests)
    Application.put_env(:salix_agent, :visible_reply_mod, Salix.Bindings.AgentVisibleReply)
    Application.put_env(:salix_agent, :mcp_provider_mod, SalixMCP.Provider)
    Application.put_env(:salix_mcp, :credential_resolver_mod, Salix.Bindings.MCPCredentials)
    Application.put_env(:salix_agent, :env_dispatch, Salix.Bindings.AgentEnvDispatch)

    Application.put_env(
      :salix_agent,
      :external_runtime_driver,
      SalixWeb.ExternalRuntime.ExternalWorkerDriver
    )

    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)
    Application.put_env(:salix_im, :agent_control_mod, Salix.Bindings.IMAgentControl)
    Application.put_env(:salix_im, :session_activity_mod, Salix.Bindings.IMSessionActivity)
    Application.put_env(:salix_im, :agent_workspace_mod, Salix.Bindings.IMAgentWorkspace)
    Application.put_env(:salix_im, :local_file_refs_mod, Salix.Bindings.IMLocalFileRefs)
    Application.put_env(:salix_im, :local_file_import_mod, Salix.Bindings.LocalFileImport)
    Application.put_env(:salix_im, :provider_app_store_mod, Salix.Bindings.IMProviderAppStore)
    Application.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    Application.put_env(:salix_im, :task_schedule_mod, Salix.Bindings.AgentConversations)

    Application.put_env(
      :salix_im,
      :triage_delegation_mod,
      :"Elixir.BridgeForTeams.TriageDelegation"
    )

    Application.put_env(
      :salix_im,
      :triage_follow_up_thread_reader_mod,
      Salix.Bindings.TriageFollowUpThreadReader
    )

    Application.put_env(:salix_env, :group_directory_mod, Salix.Bindings.EnvGroupDirectory)
    Application.put_env(:salix_env, :public_url_mod, Salix.Bindings.EnvPublicURL)
    Application.put_env(:salix_env, :runtime_proxy_handler, Salix.Bindings.EnvRuntimeProxy)
    Application.put_env(:salix_meet, :agent_runtime_mod, Salix.Bindings.MeetingAgentRuntime)
    Application.put_env(:salix_meet, :public_url_mod, Salix.Bindings.MeetingPublicURL)
    Application.put_env(:salix_meet, :meeting_dispatch_mod, Salix.Bindings.MeetingConnectDispatch)
    Application.put_env(:salix_meet, :summary_mod, Salix.Bindings.MeetingSummary)
    Application.put_env(:salix_meet, :router_summary_mod, Salix.Bindings.RouterMeetingSummary)
    Application.put_env(:salix_meet, :copilot_mod, Salix.Bindings.MeetingCopilot)
    Application.put_env(:salix_meet, :memory_mod, Salix.Bindings.MeetingMemory)
    Application.put_env(:salix_meet, :activation_mod, Salix.Bindings.MeetingActivation)

    Application.put_env(
      :salix_meet,
      :meeting_status_notifier_mod,
      SalixMeet.ProviderDispatcher
    )

    Application.put_env(
      :salix_meet,
      :owner_attribution_mod,
      Salix.Bindings.MeetingOwnerAttribution
    )

    Application.put_env(
      :salix_meet,
      :calendar_occurrences_mod,
      Salix.Bindings.MeetingCalendar
    )

    Application.put_env(:salix_calendar, :source_adapters, %{
      "google_calendar" => Salix.Bindings.GoogleCalendarSource,
      "salix_task_schedule" => SalixCalendar.SourceAdapter.SalixTaskSchedule
    })

    Application.put_env(
      :salix_calendar,
      :retirement_sink,
      Salix.Bindings.MeetingCalendar
    )

    Application.put_env(
      :salix_meet,
      :calendar_notifier_mod,
      Salix.Bindings.MeetingCalendarNotifier
    )

    Application.put_env(
      :salix_meet,
      :calendar_preparation_mod,
      Salix.Bindings.MeetingCalendarPreparation
    )

    Application.put_env(:salix_meet, :meeting_channel_mod, Salix.Bindings.MeetingChannel)
    Application.put_env(:salix_meet, :calendar_enrollment_mod, Salix.Bindings.MeetingEnrollment)

    # Plugin projection resolves a missing group override from the definition's
    # default_enabled value, so startup needs no group scan or catch-up.

    :ok
  end

  defp register_notifier(module) do
    notifiers =
      :salix_agent
      |> Application.get_env(:notifiers, [])
      |> List.wrap()
      |> Kernel.++([module])
      |> Enum.uniq()

    Application.put_env(:salix_agent, :notifiers, notifiers)
  end
end
