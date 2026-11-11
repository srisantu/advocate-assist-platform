# -----------------------------------------------------------------------------
# SLO & Alerting Policies (Ack Latency <2s, Completion <30s, Backlog Age, 503s)
# -----------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "edge_503_and_backlog_alert" {
  project      = var.project_id
  display_name = "[${upper(var.environment)}] ${var.service_name} 503 Rate or Pub/Sub Backlog Breach"
  combiner     = "OR"

  conditions {
    display_name = "Pub/Sub Oldest Unacked Message Age > 120s"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 120
    }
  }

  documentation {
    content   = "Runbook: docs/runbooks/INCIDENT-503-AND-GROWING-BACKLOG.md. Immediate action: roll back Cloud Run revision via rollback.yml."
    mime_type = "text/markdown"
  }
}
