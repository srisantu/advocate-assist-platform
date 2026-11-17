# Credential-free Terraform 1.7+ mock_provider test suite for dev
mock_provider "google" {
  mock_resource "google_compute_address" {
    defaults = {
      address = "10.128.0.42"
    }
  }
}

run "verify_dev_mocked_plan" {
  command = plan

  assert {
    condition     = output.environment == "dev"
    error_message = "Environment output must match dev."
  }

  assert {
    condition     = output.project_id == "prj-advocate-dev"
    error_message = "Project ID must be isolated to prj-advocate-dev."
  }

  assert {
    condition     = output.cloud_run_ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
    error_message = "Cloud Run ingress must prevent direct public bypass."
  }
}

run "verify_dev_mocked_apply_and_identity_separation" {
  command = apply

  assert {
    condition     = output.ingest_api_sa != output.worker_sa
    error_message = "API and Worker runtime service accounts must remain strictly separated."
  }

  assert {
    condition     = output.pubsub_topic != output.pubsub_dlq_topic
    error_message = "Primary Pub/Sub topic and Dead-Letter topic must be distinct."
  }
}

