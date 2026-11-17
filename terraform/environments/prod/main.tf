module "advocate_assist" {
  source = "../../modules/advocate-platform"

  environment                 = "prod"
  service_name                = "advocate-assist"
  project_id                  = var.project_id
  shared_vpc_host_project_id  = var.shared_vpc_host_project_id
  shared_vpc_subnet_self_link = var.shared_vpc_subnet_self_link
  primary_region              = "us-central1"
  recovery_region             = "us-east1"

  api_image_digest           = var.api_image_digest
  worker_image_digest        = var.worker_image_digest
  cloud_run_ingress          = var.cloud_run_ingress
  min_instances              = var.min_instances
  max_instances              = 50
  enable_deletion_protection = var.enable_deletion_protection
  redis_replica_count        = var.redis_replica_count
  additional_iam_roles       = var.additional_iam_roles

  psc_crm_service_attachment = "projects/prj-crm-producer-prod/regions/us-central1/serviceAttachments/sa-crm-prod"
  crm_oauth_secret_id        = "advocate-crm-oauth-secret"
}
