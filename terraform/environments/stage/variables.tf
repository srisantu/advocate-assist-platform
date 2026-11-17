variable "project_id" {
  type    = string
  default = "prj-advocate-stage"
}

variable "shared_vpc_host_project_id" {
  type    = string
  default = "prj-net-host-stage"
}

variable "shared_vpc_subnet_self_link" {
  type    = string
  default = "projects/prj-net-host-stage/regions/us-central1/subnetworks/sb-advocate-stage-usc1"
}

variable "api_image_digest" {
  type    = string
  default = "us-central1-docker.pkg.dev/prj-Shared-artifacts/advocate/ingest-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}

variable "worker_image_digest" {
  type    = string
  default = "us-central1-docker.pkg.dev/prj-Shared-artifacts/advocate/enrichment-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}

variable "cloud_run_ingress" {
  type    = string
  default = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
}

variable "min_instances" {
  type    = number
  default = 1
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
