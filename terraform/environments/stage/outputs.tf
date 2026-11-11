output "environment" {
  value = module.advocate_assist.environment
}

output "project_id" {
  value = module.advocate_assist.project_id
}

output "ingest_api_sa" {
  value = module.advocate_assist.ingest_api_service_account_email
}

output "worker_sa" {
  value = module.advocate_assist.enrichment_worker_service_account_email
}

output "cloud_run_ingress" {
  value = module.advocate_assist.cloud_run_ingress_mode
}

output "pubsub_topic" {
  value = module.advocate_assist.pubsub_topic_name
}

output "pubsub_dlq_topic" {
  value = module.advocate_assist.pubsub_dlq_topic_name
}
