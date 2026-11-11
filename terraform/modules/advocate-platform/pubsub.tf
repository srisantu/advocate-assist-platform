# -----------------------------------------------------------------------------
# Asynchronous Messaging & Bounded Retry Dead-Letter Queue (DLQ)
# -----------------------------------------------------------------------------
resource "google_pubsub_topic" "crm_interactions_dlq" {
  project                    = var.project_id
  name                       = "${var.service_name}-interactions-dlq-${var.environment}"
  message_retention_duration = "604800s" # 7 days retention for DLQ forensics
}

resource "google_pubsub_subscription" "crm_interactions_dlq_sub" {
  project                    = var.project_id
  name                       = "${var.service_name}-interactions-dlq-sub-${var.environment}"
  topic                      = google_pubsub_topic.crm_interactions_dlq.id
  message_retention_duration = "604800s"
  ack_deadline_seconds       = 60
}

resource "google_pubsub_topic" "crm_interactions" {
  project                    = var.project_id
  name                       = "${var.service_name}-interactions-${var.environment}"
  message_retention_duration = "86400s"

  message_storage_policy {
    allowed_persistence_regions = [
      var.primary_region,
      var.recovery_region,
    ]
  }
}

resource "google_pubsub_subscription" "crm_interactions_sub" {
  project                    = var.project_id
  name                       = "${var.service_name}-interactions-sub-${var.environment}"
  topic                      = google_pubsub_topic.crm_interactions.id
  ack_deadline_seconds       = 30
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  enable_message_ordering    = false

  retry_policy {
    minimum_backoff = "2s"
    maximum_backoff = "30s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.crm_interactions_dlq.id
    max_delivery_attempts = 5
  }
}
