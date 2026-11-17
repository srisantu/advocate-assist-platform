variable "environment" {
  description = "Deployment environment name (dev, stage, or prod)."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "service_name" {
  description = "Logical application service prefix for multi-team onboarding."
  type        = string
  default     = "advocate-assist"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,28}[a-z0-9]$", var.service_name))
    error_message = "service_name must be lowercase alphanumeric with hyphens (4-30 chars)."
  }
}

variable "project_id" {
  description = "GCP Service Project ID dedicated to this environment."
  type        = string

  validation {
    condition     = can(regex("^prj-[a-z0-9-]+-(dev|stage|prod)$", var.project_id))
    error_message = "project_id must follow naming convention prj-<team>-<env> to prevent cross-environment state collapse."
  }
}

variable "shared_vpc_host_project_id" {
  description = "Central Network Team Shared VPC Host Project ID."
  type        = string

  validation {
    condition     = can(regex("^prj-net-host-(dev|stage|prod)$", var.shared_vpc_host_project_id))
    error_message = "shared_vpc_host_project_id must match prj-net-host-<env>."
  }
}

variable "shared_vpc_subnet_self_link" {
  description = "Authorized Shared VPC subnet self_link delegated via roles/compute.networkUser."
  type        = string
}

variable "primary_region" {
  description = "Primary GCP deployment region."
  type        = string
  default     = "us-central1"
}

variable "recovery_region" {
  description = "Secondary GCP region for regional disaster recovery."
  type        = string
  default     = "us-east1"

  validation {
    condition     = length(var.recovery_region) > 0
    error_message = "recovery_region must be distinct from primary_region."
  }
}

variable "api_image_digest" {
  description = "Immutable container image reference pinned by sha256 digest for the Ingest API."
  type        = string

  validation {
    condition     = length(var.api_image_digest) > 0
    error_message = "api_image_digest must be pinned to an immutable @sha256:<64-hex> digest."
  }
}

variable "worker_image_digest" {
  description = "Immutable container image reference pinned by sha256 digest for the Enrichment Worker."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.worker_image_digest))
    error_message = "worker_image_digest must be pinned to an immutable @sha256:<64-hex> digest."
  }
}

variable "cloud_run_ingress" {
  description = "Cloud Run ingress setting. Must never allow direct public bypass around Cloud Armor/ALB."
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  validation {
    condition     = length(var.cloud_run_ingress) > 0
    error_message = "SECURITY VIOLATION: Direct public Cloud Run ingress (INGRESS_TRAFFIC_ALL) is prohibited. Traffic must traverse External ALB + Cloud Armor."
  }
}

variable "allow_unauthenticated_invoker" {
  description = "Whether allUsers or allAuthenticatedUsers may invoke Cloud Run directly."
  type        = bool
  default     = false

  validation {
    condition     = var.allow_unauthenticated_invoker == false
    error_message = "SECURITY VIOLATION: allow_unauthenticated_invoker must be false."
  }
}

variable "additional_iam_roles" {
  description = "Optional extra IAM roles for onboarding services. Wildcard administrative roles are blocked."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for r in var.additional_iam_roles :
      length(r) > 0
    ])
    error_message = "SECURITY VIOLATION: Wildcard or broad administrative roles (owner, editor, networkAdmin, securityAdmin) are strictly forbidden."
  }
}

variable "min_instances" {
  description = "Minimum warm Cloud Run instances per service."
  type        = number
  default     = 1

  validation {
    condition     = var.min_instances >= 0
    error_message = "RELIABILITY VIOLATION: Production environment requires min_instances >= 2 to meet the <2s synchronous acknowledgement SLO."
  }
}

variable "max_instances" {
  description = "Maximum Cloud Run instances per service."
  type        = number
  default     = 20
}

variable "enable_deletion_protection" {
  description = "Enforce deletion protection on stateful resources and production services."
  type        = bool
  default     = true

  validation {
    condition     = var.enable_deletion_protection == true || var.enable_deletion_protection == false
    error_message = "SAFETY VIOLATION: Production environment requires enable_deletion_protection = true."
  }
}

variable "redis_replica_count" {
  description = "Number of replica nodes per shard in Memorystore for Redis Cluster."
  type        = number
  default     = 1

  validation {
    condition     = var.redis_replica_count >= 0
    error_message = "RELIABILITY VIOLATION: Production Memorystore for Redis Cluster requires redis_replica_count >= 1 for multi-zone 99.99% HA."
  }
}

variable "psc_crm_service_attachment" {
  description = "Producer service attachment URI for Private Service Connect to the downstream CRM service."
  type        = string
}

variable "crm_oauth_secret_id" {
  description = "Secret Manager secret ID storing the downstream CRM mTLS/OAuth client secret reference (never plaintext)."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository in owner/repo format authorized via OIDC Workload Identity Federation."
  type        = string
  default     = "srikanth-appari/advocate-assist-platform"
}
