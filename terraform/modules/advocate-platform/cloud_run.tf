# -----------------------------------------------------------------------------
# Cloud Run Services (Primary Region + Warm Production Standby in Recovery Region)
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "ingest_api" {
  project             = var.project_id
  name                = "${var.service_name}-ingest-api-${var.environment}"
  location            = var.primary_region
  ingress             = var.cloud_run_ingress
  deletion_protection = var.enable_deletion_protection

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
}

resource "google_cloud_run_v2_service" "enrichment_worker" {
  project             = var.project_id
  name                = "${var.service_name}-worker-${var.environment}"
  location            = var.primary_region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  deletion_protection = var.enable_deletion_protection

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
  count               = var.environment == "prod" ? 1 : 0
  project             = var.project_id
  name                = "${var.service_name}-ingest-api-dr-${var.environment}"
  location            = var.recovery_region
  ingress             = var.cloud_run_ingress
  deletion_protection = var.enable_deletion_protection

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
