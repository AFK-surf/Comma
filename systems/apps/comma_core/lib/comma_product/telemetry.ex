defmodule CommaProduct.Telemetry do
  @moduledoc "Comma Product-owned telemetry metrics and bounded emitters."
  import Telemetry.Metrics

  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
  @outcomes ~w(ok error timeout unavailable conflict rejected rate_limited cancelled not_found other)
  @operation_providers %{
    telegram_webhook: "telegram",
    telegram_send_message: "telegram",
    telegram_oidc_restart: "telegram",
    # SSH input latency and unexpected failures identify blocked terminal interactions.
    ssh_command: "other",
    sse_connect: "other",
    sse_first_event: "other",
    redis_challenge: "redis",
    postmark_delivery: "postmark",
    smtp_delivery: "smtp",
    test_email_delivery: "other",
    email_delivery: "other",
    google_desktop_exchange: "google",
    # APNs latency and rejection distinguish provider unavailability from Task execution.
    apns_delivery: "apns",
    # Apple key-fetch latency/failures explain blocked Sign in with Apple requests.
    apple_jwks: "apple",
    deliver: "other",
    salix_boundary: "other",
    synchronicity_provision: "synchronicity",
    synchronicity_enroll: "synchronicity",
    synchronicity_agent_key: "synchronicity",
    profile_avatar_put_start: "gcs",
    profile_avatar_put_finish: "gcs",
    profile_avatar_put_cancel: "gcs",
    profile_avatar_get: "gcs",
    profile_avatar_delete: "gcs",
    admin_command: "other",
    admin_create_user: "other",
    admin_update_user: "other",
    admin_set_admin_access: "other",
    admin_create_support_session: "other",
    admin_bootstrap_workspace: "other",
    admin_create_redeem_code: "other",
    admin_disable_redeem_code: "other",
    admin_apply_redeem_code: "other",
    admin_issue_workspace_credits: "other",
    admin_create_oauth_client: "other",
    admin_rotate_oauth_client_secret: "other",
    admin_disable_oauth_client: "other",
    admin_enable_oauth_client: "other"
  }
  @admin_operations %{
    "create_user" => :admin_create_user,
    "update_user" => :admin_update_user,
    "set_admin_access" => :admin_set_admin_access,
    "create_support_session" => :admin_create_support_session,
    "bootstrap_workspace" => :admin_bootstrap_workspace,
    "create_redeem_code" => :admin_create_redeem_code,
    "disable_redeem_code" => :admin_disable_redeem_code,
    "apply_redeem_code" => :admin_apply_redeem_code,
    "issue_workspace_credits" => :admin_issue_workspace_credits,
    "create_oauth_client" => :admin_create_oauth_client,
    "rotate_oauth_client_secret" => :admin_rotate_oauth_client_secret,
    "disable_oauth_client" => :admin_disable_oauth_client,
    "enable_oauth_client" => :admin_enable_oauth_client
  }
  @operations @operation_providers |> Map.keys() |> Enum.map(&Atom.to_string/1)
  @providers @operation_providers |> Map.values() |> Enum.uniq() |> Kernel.++(["s3", "other"])
  @queues ~w(comma_external comma_recommendations comma_recommendation_control comma_notifications other)
  @recommendation_triggers ~w(manual schedule agent_tool other)
  @recommendation_outcomes ~w(requested published superseded failed rate_limited other)
  @recommendation_variants ~w(generic member other)

  def metrics do
    operation_options = [
      event_name: [:comma_product, :operation, :stop],
      tags: [:operation, :provider, :outcome],
      tag_values: &operation_tags/1
    ]

    [
      counter("comma.product.operations.total", operation_options),
      distribution(
        "comma.product.operations.duration.seconds",
        operation_options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @buckets]
          ]
      ),
      counter("comma.product.backlog.retries.total",
        event_name: [:comma_product, :backlog, :retry],
        tags: [:queue],
        tag_values: &queue_tags/1
      ),
      counter("comma.product.backlog.terminal.failures.total",
        event_name: [:comma_product, :backlog, :terminal_failure],
        tags: [:queue],
        tag_values: &queue_tags/1
      ),
      last_value("comma.product.backlog.depth",
        event_name: [:comma_product, :backlog, :sample],
        measurement: :depth,
        tags: [:queue],
        tag_values: &queue_tags/1
      ),
      last_value("comma.product.backlog.oldest.age.seconds",
        event_name: [:comma_product, :backlog, :sample],
        measurement: :oldest_age_seconds,
        tags: [:queue],
        tag_values: &queue_tags/1
      ),
      counter("comma.product.recommendation.runs.total",
        event_name: [:comma_product, :recommendation, :run],
        tags: [:trigger, :outcome],
        tag_values: &recommendation_tags/1
      ),
      # Do members read the Routines that publication produces, and which
      # collection variant do they read? One member read of a fresh Routine
      # adds one; repeated reads of a generation are not deduplicated.
      counter("comma.product.recommendation.exposures.total",
        event_name: [:comma_product, :recommendation, :exposure],
        tags: [:variant],
        tag_values: &recommendation_exposure_tags/1
      ),
      counter("comma.product.oauth_idp.requests.total",
        event_name: [:comma_product, :oauth_idp, :request],
        tags: [:endpoint, :outcome],
        tag_values: &oauth_idp_request_tags/1
      ),
      counter("comma.product.oauth_idp.rate_limit.decisions.total",
        event_name: [:comma_product, :oauth_idp, :rate_limit],
        tags: [:endpoint, :outcome],
        tag_values: &oauth_idp_rate_limit_tags/1
      ),
      counter("comma.product.oauth_idp.issuance.total",
        event_name: [:comma_product, :oauth_idp, :issuance]
      ),
      counter("comma.product.task_share.rate_limit.decisions.total",
        event_name: [:comma_product, :task_share, :rate_limit],
        tags: [:kind, :outcome],
        tag_values: &task_share_rate_limit_tags/1
      )
    ]
  end

  # Low-cardinality guards for the IdP counters: endpoints and outcomes
  # collapse to closed enums. Issuance is deliberately label-free —
  # per-client detail lives in the structured issuance log line, because
  # an ID-valued label would mint a Prometheus series per registered
  # client (forbidden by the observability GUIDE, and unbounded once
  # self-serve registration opens).
  @oauth_idp_endpoints ~w(discovery jwks authorize token userinfo)
  @oauth_idp_request_outcomes ~w(ok rejected login_redirect rate_limited unavailable not_found error)
  @oauth_idp_rate_limit_outcomes ~w(allow deny unavailable)

  defp task_share_rate_limit_tags(metadata) do
    %{
      kind: bounded(metadata[:kind], ~w(peer share)),
      outcome: bounded(metadata[:outcome], @oauth_idp_rate_limit_outcomes)
    }
  end

  defp oauth_idp_request_tags(metadata) do
    %{
      endpoint: bounded(metadata[:endpoint], @oauth_idp_endpoints),
      outcome: bounded(metadata[:outcome], @oauth_idp_request_outcomes)
    }
  end

  defp oauth_idp_rate_limit_tags(metadata) do
    %{
      endpoint: bounded(metadata[:endpoint], @oauth_idp_endpoints),
      outcome: bounded(metadata[:outcome], @oauth_idp_rate_limit_outcomes)
    }
  end

  defp bounded(value, allowed) do
    string = to_string(value || "other")
    if string in allowed, do: string, else: "other"
  end

  def emit_operation(operation, outcome, duration, metadata \\ %{}) do
    :telemetry.execute(
      [:comma_product, :operation, :stop],
      %{duration: duration},
      Map.merge(metadata, %{
        operation: operation,
        provider: operation_provider(operation),
        outcome: outcome
      })
    )
  end

  @profile_avatar_operations ~w(
    profile_avatar_put_start
    profile_avatar_put_finish
    profile_avatar_put_cancel
    profile_avatar_get
    profile_avatar_delete
  )a

  defp operation_provider(operation) when operation in @profile_avatar_operations do
    case Application.get_env(:comma_core, :profile_avatar, [])[:adapter] do
      Comma.ProfileAvatar.Storage.S3 -> "s3"
      _other -> "gcs"
    end
  end

  defp operation_provider(operation), do: Map.get(@operation_providers, operation, "other")

  def emit_admin_command(action, outcome, duration) do
    emit_operation(
      Map.get(@admin_operations, action, :admin_command),
      outcome,
      duration
    )
  end

  def emit_recommendation_run(trigger, outcome) do
    :telemetry.execute(
      [:comma_product, :recommendation, :run],
      %{},
      %{trigger: trigger, outcome: outcome}
    )
  end

  def emit_recommendation_exposure(variant) do
    :telemetry.execute([:comma_product, :recommendation, :exposure], %{}, %{variant: variant})
  end

  def emit_backlog_retry(queue) do
    :telemetry.execute([:comma_product, :backlog, :retry], %{}, %{queue: queue})
  end

  def emit_backlog_terminal_failure(queue) do
    :telemetry.execute([:comma_product, :backlog, :terminal_failure], %{}, %{queue: queue})
  end

  def emit_backlog_sample(queue, depth, oldest_age_seconds)
      when is_integer(depth) and depth >= 0 and is_number(oldest_age_seconds) and
             oldest_age_seconds >= 0 do
    :telemetry.execute(
      [:comma_product, :backlog, :sample],
      %{depth: depth, oldest_age_seconds: oldest_age_seconds},
      %{queue: queue}
    )
  end

  defp operation_tags(metadata) do
    %{
      operation: finite(metadata[:operation], @operations),
      provider: finite(metadata[:provider], @providers),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp queue_tags(metadata), do: %{queue: finite(metadata[:queue], @queues)}

  defp recommendation_tags(metadata) do
    %{
      trigger: finite(metadata[:trigger], @recommendation_triggers),
      outcome: finite(metadata[:outcome], @recommendation_outcomes)
    }
  end

  defp recommendation_exposure_tags(metadata),
    do: %{variant: finite(metadata[:variant], @recommendation_variants)}

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
