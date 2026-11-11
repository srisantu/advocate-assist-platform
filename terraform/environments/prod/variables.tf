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
}

variable "worker_image_digest" {
  type    = string
  default = "us-central1-docker.pkg.dev/prj-Shared-artifacts/advocate/enrichment-worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}

variable "cloud_run_ingress" {
  type    = string
  default = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCING"
}

variable "min_instances" {
  type    = number
  default = 2
}

variable "enable_deletion_protection" {
  type    = bool
  default = true
}

variable "redis_replica_count" {
  type    = number
  default = 1
}

variable "additional_iam_roles" {
  type    = list(string)
  default = []
}
