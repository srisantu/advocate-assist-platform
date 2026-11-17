# -----------------------------------------------------------------------------
# Cloud Run Services (Primary Region + Warm Production Standby in Recovery Region)
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "ingest_api" {
  project  = var.project_id
  name     = "${var.service_name}-ingest-api-${var.environment}"
  location = var.primary_region
  ingress  = var.cloud_run_ingress

  template {
    service_account                  = google_service_account.ingest_api.email
    max_instance_request_concurrency = 80
    timeout                          = "5s"

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        subnetwork = var.shared_vpc_subnet_self_link
      }
    }

    containers {
      image = var.api_image_digest

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "PUBSUB_TOPIC"
        value = google_pubsub_topic.crm_interactions.name
      }
      env {
        name  = "OTEL_SERVICE_NAME"
        value = "${var.service_name}-ingest-api"
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_connection_password.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.cloud_run_ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" || var.cloud_run_ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY"
      error_message = "SECURITY VIOLATION: Direct public Cloud Run ingress (INGRESS_TRAFFIC_ALL) is prohibited."
    }
    precondition {
      condition     = var.environment != "prod" || var.enable_deletion_protection == true
      error_message = "SAFETY VIOLATION: Production environment requires enable_deletion_protection = true."
    }
    precondition {
      condition     = var.environment != "prod" || var.min_instances >= 2
      error_message = "RELIABILITY VIOLATION: Production environment requires min_instances >= 2."
    }
    precondition {
      condition = alltrue([
        for r in var.additional_iam_roles :
        !contains(["roles/owner", "roles/editor", "roles/iam.securityAdmin", "roles/compute.networkAdmin", "*"], r)
      ])
      error_message = "SECURITY VIOLATION: Wildcard or broad administrative roles are strictly forbidden."
    }
    precondition {
      condition     = can(regex("@sha256:[a-f0-9]{64}$", var.api_image_digest))
      error_message = "IMMUTABILITY VIOLATION: api_image_digest must be pinned to an immutable @sha256:<64-hex> digest."
    }
  }
}

resource "google_cloud_run_v2_service" "enrichment_worker" {
  project  = var.project_id
  name     = "${var.service_name}-worker-${var.environment}"
  location = var.primary_region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account                  = google_service_account.enrichment_worker.email
    max_instance_request_concurrency = 10
    timeout                          = "30s"

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        subnetwork = var.shared_vpc_subnet_self_link
      }
    }

    containers {
      image = var.worker_image_digest

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "DOWNSTREAM_CRM_URL"
        value = "https://crm-callback.internal.advocate.local/v1/interactions/callback"
      }
      env {
        name  = "VERTEX_AI_PRIMARY_REGION"
        value = var.primary_region
      }
      env {
        name  = "VERTEX_AI_RECOVERY_REGION"
        value = var.recovery_region
      }
      env {
        name  = "OTEL_SERVICE_NAME"
        value = "${var.service_name}-enrichment-worker"
      }
      env {
        name = "CRM_OAUTH_CLIENT_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.crm_downstream_credentials.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_connection_password.secret_id
            version = "latest"
          }
        }
      }
    }
  }
}

# Warm Active-Passive Recovery Region Cloud Run Services for Production
resource "google_cloud_run_v2_service" "ingest_api_recovery" {
  count    = var.environment == "prod" ? 1 : 0
  project  = var.project_id
  name     = "${var.service_name}-ingest-api-dr-${var.environment}"
  location = var.recovery_region
  ingress  = var.cloud_run_ingress

  template {
    service_account = google_service_account.ingest_api.email
    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }
    containers {
      image = var.api_image_digest
    }
  }
}
