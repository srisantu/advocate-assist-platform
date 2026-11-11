output "environment" {
  description = "Deployed environment identifier."
  value       = var.environment
}

output "project_id" {
  description = "Target GCP Service Project ID."
  value       = var.project_id
}

output "ingest_api_service_account_email" {
  description = "Dedicated service account email for Ingest API."
  value       = google_service_account.ingest_api.email
}

output "enrichment_worker_service_account_email" {
  description = "Dedicated service account email for Enrichment Worker."
  value       = google_service_account.enrichment_worker.email
}

output "github_wif_provider_name" {
  description = "Workload Identity Federation provider resource name for GitHub Actions OIDC."
  value       = google_iam_workload_identity_pool_provider.github_provider.name
}

output "pubsub_topic_name" {
  description = "Primary Pub/Sub interaction topic name."
  value       = google_pubsub_topic.crm_interactions.name
}

output "pubsub_dlq_topic_name" {
  description = "Dead-letter Pub/Sub topic name after 5 failed delivery attempts."
  value       = google_pubsub_topic.crm_interactions_dlq.name
}

output "cloud_run_ingress_mode" {
  description = "Verified Cloud Run ingress policy preventing direct edge bypass."
  value       = google_cloud_run_v2_service.ingest_api.ingress
}

output "psc_downstream_dns_fqdn" {
  description = "Private DNS FQDN routed over Private Service Connect to the downstream CRM."
  value       = google_dns_record_set.crm_psc_a_record.name
}

output "redis_cluster_name" {
  description = "Memorystore for Redis Cluster identifier."
  value       = google_redis_cluster.coordination_cache.name
}

output "sql_primary_instance_name" {
  description = "Primary Cloud SQL PostgreSQL durable correctness store instance."
  value       = google_sql_database_instance.correctness_primary.name
}
