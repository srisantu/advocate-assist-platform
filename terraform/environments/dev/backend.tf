# Isolated remote GCS state bucket per environment (prevents state collapse)
# Note: Commented or overridden with -backend=false during offline terraform test runs.
terraform {
  required_version = ">= 1.7.0, < 2.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.20.0, < 6.0.0"
    }
  }
}
