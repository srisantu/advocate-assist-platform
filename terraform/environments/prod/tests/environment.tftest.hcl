# Credential-free Terraform 1.7+ mock_provider test suite for prod
mock_provider "google" {
  mock_resource "google_compute_address" {
    defaults = {
      address = "10.128.0.42"
    }
  }
}

run "verify_prod_mocked_plan" {
  command = plan

  assert {
    condition     = output.environment == "prod"
    error_message = "Environment output must match prod."
  }

  assert {
    condition     = output.project_id == "prj-advocate-prod"
    error_message = "Project ID must be isolated to prj-advocate-prod."
  }

  assert {
    condition     = output.cloud_run_ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
    error_message = "Cloud Run ingress must prevent direct public bypass."
  }
}

run "verify_prod_mocked_apply_and_identity_separation" {
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

run "reject_unsafe_public_cloud_run_ingress_in_prod" {
  command = plan

  variables {
    cloud_run_ingress = "INGRESS_TRAFFIC_ALL"
  }

  expect_failures = [
    var.cloud_run_ingress,
  ]
}

run "reject_disabled_deletion_protection_in_prod" {
  command = plan

  variables {
    enable_deletion_protection = false
  }

  expect_failures = [
    var.enable_deletion_protection,
  ]
}

run "reject_underprovisioned_min_instances_in_prod" {
  command = plan

  variables {
    min_instances = 0
  }

  expect_failures = [
    var.min_instances,
  ]
}

run "reject_wildcard_or_admin_iam_roles_in_prod" {
  command = plan

  variables {
    additional_iam_roles = ["roles/owner"]
  }

  expect_failures = [
    var.additional_iam_roles,
  ]
}

run "reject_mutable_tag_without_sha256_digest" {
  command = plan

  variables {
    api_image_digest = "us-central1-docker.pkg.dev/prj-shared-artifacts/advocate/ingest-api:latest"
  }

  expect_failures = [
    var.api_image_digest,
  ]
}
