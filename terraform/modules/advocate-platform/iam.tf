# -----------------------------------------------------------------------------
# Dedicated Runtime Service Accounts (Zero shared identity between API & Worker)
# -----------------------------------------------------------------------------
resource "google_service_account" "ingest_api" {
  project      = var.project_id
  account_id   = "${var.service_name}-api-${var.environment}"
  display_name = "Advocate Assist Ingest API Runtime SA (${var.environment})"
  description  = "Dedicated least-privilege identity for synchronous CRM request ingestion"
}

resource "google_service_account" "enrichment_worker" {
  project      = var.project_id
  account_id   = "${var.service_name}-wrk-${var.environment}"
  display_name = "Advocate Assist Enrichment Worker Runtime SA (${var.environment})"
  description  = "Dedicated least-privilege identity for async Pub/Sub enrichment and Vertex AI"
}

resource "google_service_account" "github_deployer" {
  project      = var.project_id
  account_id   = "${var.service_name}-cd-${var.environment}"
  display_name = "GitHub Actions OIDC WIF Deployer SA (${var.environment})"
  description  = "Environment-scoped deployment identity assumed via GitHub OIDC"
}

# -----------------------------------------------------------------------------
# Least-Privilege IAM Bindings
# -----------------------------------------------------------------------------
# API can ONLY publish to the primary Pub/Sub topic and write initial state
resource "google_pubsub_topic_iam_member" "api_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.crm_interactions.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.ingest_api.email}"
}

resource "google_project_iam_member" "api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.ingest_api.email}"
}

# Worker can subscribe to Pub/Sub, publish to DLQ, invoke Vertex AI, and read secrets
resource "google_pubsub_subscription_iam_member" "worker_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.crm_interactions_sub.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.enrichment_worker.email}"
}

resource "google_project_iam_member" "worker_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.enrichment_worker.email}"
}

resource "google_project_iam_member" "worker_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.enrichment_worker.email}"
}

# Subnet-scoped roles/compute.networkUser in Shared VPC Host Project (No networkAdmin)
resource "google_compute_subnetwork_iam_member" "api_shared_vpc_user" {
  project    = var.shared_vpc_host_project_id
  region     = var.primary_region
  subnetwork = var.shared_vpc_subnet_self_link
  role       = "roles/compute.networkUser"
  member     = "serviceAccount:${google_service_account.ingest_api.email}"
}

resource "google_compute_subnetwork_iam_member" "worker_shared_vpc_user" {
  project    = var.shared_vpc_host_project_id
  region     = var.primary_region
  subnetwork = var.shared_vpc_subnet_self_link
  role       = "roles/compute.networkUser"
  member     = "serviceAccount:${google_service_account.enrichment_worker.email}"
}

# -----------------------------------------------------------------------------
# GitHub OIDC Workload Identity Federation (Zero static JSON keys)
# -----------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github_pool" {
  project                   = var.project_id
  workload_identity_pool_id = "gh-oidc-pool-${var.environment}"
  display_name              = "GitHub Actions OIDC Pool (${var.environment})"
  disabled                  = false
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "gh-oidc-provider-${var.environment}"
  display_name                       = "GitHub Actions OIDC Provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "wif_impersonation" {
  service_account_id = google_service_account.github_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_repository}"
}
