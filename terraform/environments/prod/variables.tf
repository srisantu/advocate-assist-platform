variable "project_id" {
  type    = string
  default = "prj-advocate-prod"
}

variable "shared_vpc_host_project_id" {
  type    = string
  default = "prj-net-host-prod"
}

variable "shared_vpc_subnet_self_link" {
  type    = string
  default = "projects/prj-net-host-prod/regions/us-central1/subnetworks/sb-advocate-prod-usc1"
}

variable "api_image_digest" {
  type    = string
  default = "us-central1-docker.pkg.dev/prj-Shared-artifacts/advocate/ingest-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.api_image_digest))
    error_message = "IMMUTABILITY VIOLATION: api_image_digest must be pinned to an immutable @sha256:<64-hex> digest."
  }
}

variable "worker_image_digest" {
  type    = string
  default = "us-central1-docker.pkg.dev/prj-Shared-artifacts/advocate/enrichment-worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}

variable "cloud_run_ingress" {
  type    = string
  default = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  validation {
    condition     = var.cloud_run_ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" || var.cloud_run_ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY"
    error_message = "SECURITY VIOLATION: Direct public Cloud Run ingress (INGRESS_TRAFFIC_ALL) is prohibited."
  }
}

variable "min_instances" {
  type    = number
  default = 2

  validation {
    condition     = var.min_instances >= 2
    error_message = "RELIABILITY VIOLATION: Production environment requires min_instances >= 2."
  }
}

variable "enable_deletion_protection" {
  type    = bool
  default = true

  validation {
    condition     = var.enable_deletion_protection == true
    error_message = "SAFETY VIOLATION: Production environment requires enable_deletion_protection = true."
  }
}

variable "redis_replica_count" {
  type    = number
  default = 1
}

variable "additional_iam_roles" {
  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for r in var.additional_iam_roles :
      !contains(["roles/owner", "roles/editor", "roles/iam.securityAdmin", "roles/compute.networkAdmin", "*"], r)
    ])
    error_message = "SECURITY VIOLATION: Wildcard or broad administrative roles are strictly forbidden."
  }
}
