# Credential-free Terraform 1.7+ mock_provider test suite for stage
mock_provider "google" {
  mock_resource "google_compute_address" {
    defaults = {
      address = "10.128.0.42"
    }
  }
}

run "verify_stage_mocked_plan" {
  command = plan

  assert {
    condition     = output.environment == "stage"
    error_message = "Environment output must match stage."
  }

  assert {
    condition     = output.project_id == "prj-advocate-stage"
    error_message = "Project ID must be isolated to prj-advocate-stage."
  }

  assert {
    condition     = output.cloud_run_ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCING"
    error_message = "Cloud Run ingress must prevent direct public bypass."
  }
}

run "verify_stage_mocked_apply_and_identity_separation" {
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

