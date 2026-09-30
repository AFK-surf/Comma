# Live provider names are supplied at release time, never stored in the JSON projection.
variable "gcp_project_id" {
  type        = string
  description = "GCP project that owns the staging Managed Prometheus data."
}

variable "gcm_datasource_uid" {
  type        = string
  description = "UID of the installed Grafana Cloud Monitoring datasource."
}

locals {
  alerting = jsondecode(templatefile("${path.module}/alerting-rules.json", {
    GCP_PROJECT_ID     = var.gcp_project_id
    GCM_DATASOURCE_UID = var.gcm_datasource_uid
  }))
}

resource "grafana_message_template" "comma_slack" {
  name               = "comma-slack"
  template           = file("${path.module}/../alerting/comma-slack.tmpl")
  disable_provenance = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "grafana_rule_group" "comma_business_slo" {
  name               = local.alerting.rule_group_name
  folder_uid         = local.alerting.folder_uid
  interval_seconds   = local.alerting.interval_seconds
  disable_provenance = false

  dynamic "rule" {
    for_each = local.alerting.rules
    iterator = managed_rule

    content {
      uid            = managed_rule.value.uid
      name           = managed_rule.value.name
      condition      = managed_rule.value.condition
      for            = managed_rule.value.for
      no_data_state  = managed_rule.value.no_data_state
      exec_err_state = managed_rule.value.exec_err_state
      is_paused      = managed_rule.value.is_paused
      labels         = managed_rule.value.labels
      annotations    = managed_rule.value.annotations

      dynamic "data" {
        for_each = managed_rule.value.data
        iterator = query

        content {
          ref_id         = query.value.ref_id
          query_type     = query.value.query_type
          datasource_uid = query.value.datasource_uid
          model          = jsonencode(query.value.model)

          relative_time_range {
            from = query.value.relative_time_range.from
            to   = query.value.relative_time_range.to
          }
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = local.alerting.schema_version == 1
      error_message = "Unsupported generated alerting schema version."
    }

    precondition {
      condition     = local.alerting.interval_seconds == 60
      error_message = "The managed Grafana rule group must evaluate every 60 seconds."
    }

    precondition {
      condition     = length(local.alerting.rules) == 5 && alltrue([for rule in local.alerting.rules : !rule.is_paused])
      error_message = "The activated Terraform rollout must contain exactly five active staging rules."
    }
  }
}

# Adopt the two live resources into the new GCS state on the first plan/apply.
# Import blocks are idempotent once the resources are present in state.
import {
  to = grafana_message_template.comma_slack
  id = "comma-slack"
}

import {
  to = grafana_rule_group.comma_business_slo
  id = "fcvt5g:comma-business-slo-1m"
}
