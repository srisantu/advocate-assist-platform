# -----------------------------------------------------------------------------
# Approved Secrets Management Pattern (Secret Manager Metadata + IAM Binding)
# Note: Secret payloads are never passed through Terraform variables or state.
# -----------------------------------------------------------------------------
resource "google_secret_manager_secret" "crm_downstream_credentials" {
  project   = var.project_id
  secret_id = "${var.crm_oauth_secret_id}-${var.environment}"

  replication {
    user_managed {
      replicas {
        location = var.primary_region
      }
      replicas {
        location = var.recovery_region
      }
    }
  }

  labels = {
    environment = var.environment
    service     = var.service_name
    managed_by  = "terraform"
  }
}

resource "google_secret_manager_secret" "db_connection_password" {
  project   = var.project_id
  secret_id = "${var.service_name}-db-password-${var.environment}"

  replication {
    user_managed {
      replicas {
        location = var.primary_region
      }
      replicas {
        location = var.recovery_region
      }
    }
  }
}

# Only the Enrichment Worker is permitted to access downstream CRM credentials
resource "google_secret_manager_secret_iam_member" "worker_crm_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.crm_downstream_credentials.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.enrichment_worker.email}"
}

resource "google_secret_manager_secret_iam_member" "worker_db_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.db_connection_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.enrichment_worker.email}"
}

resource "google_secret_manager_secret_iam_member" "api_db_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.db_connection_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ingest_api.email}"
}
