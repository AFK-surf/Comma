mock_provider "grafana" {}

variables {
  gcp_project_id     = "example-staging-project"
  gcm_datasource_uid = "example-gcm-datasource"
}

override_resource {
  target = grafana_message_template.comma_slack
  values = { id = "comma-slack" }
}

override_resource {
  target = grafana_rule_group.comma_business_slo
  values = { id = "fcvt5g:comma-business-slo-1m" }
}

run "active_staging_alerts" {
  command = plan

  assert {
    condition = (
      grafana_message_template.comma_slack.name == "comma-slack" &&
      grafana_message_template.comma_slack.template == file("${path.module}/../alerting/comma-slack.tmpl") &&
      grafana_message_template.comma_slack.disable_provenance == false
    )
    error_message = "Terraform must own the reviewed comma-slack template with provenance enabled."
  }

  assert {
    condition = (
      grafana_rule_group.comma_business_slo.name == "comma-business-slo-1m" &&
      grafana_rule_group.comma_business_slo.folder_uid == "fcvt5g" &&
      grafana_rule_group.comma_business_slo.interval_seconds == 60 &&
      grafana_rule_group.comma_business_slo.disable_provenance == false
    )
    error_message = "Terraform must own the dedicated 60-second staging rule group."
  }

  assert {
    condition = (
      [for rule in grafana_rule_group.comma_business_slo.rule : rule.uid] == [
        "comma-stg-llm-error",
        "bfsralwg6q1hcd",
        "comma-stg-meeting-runtime-lost",
        "comma-stg-meeting-stuck",
        "comma-stg-meeting-delivery-error",
      ] &&
      alltrue([
        for rule in grafana_rule_group.comma_business_slo.rule :
        !rule.is_paused &&
        rule.labels.environment == "staging" &&
        rule.labels.priority == "P2" &&
        rule.labels.source == "grafana" &&
        rule.labels.team == "comma" &&
        length(rule.notification_settings) == 0 &&
        length(rule.record) == 0
      ])
    )
    error_message = "Activation must contain exactly the five reviewed active staging P2 rules."
  }

  assert {
    condition = alltrue(flatten([
      for rule in grafana_rule_group.comma_business_slo.rule : [
        for query in rule.data :
        !strcontains(query.datasource_uid, "production") &&
        !strcontains(query.model, "production")
      ]
    ]))
    error_message = "Production datasource and project references are outside this adoption."
  }
}
