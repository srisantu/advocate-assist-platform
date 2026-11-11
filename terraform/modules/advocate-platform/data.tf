# -----------------------------------------------------------------------------
# Tier 1 Fast In-Flight Lock & Cache: Memorystore for Redis Cluster (99.99% SLA)
# -----------------------------------------------------------------------------
resource "google_redis_cluster" "coordination_cache" {
  project                    = var.project_id
  name                       = "${var.service_name}-redis-${var.environment}"
  shard_count                = 3
  region                     = var.primary_region
  replica_count              = var.redis_replica_count
  transit_encryption_mode    = "TRANSIT_ENCRYPTION_MODE_SERVER_AUTHENTICATION"
  authorization_mode         = "AUTH_MODE_IAM_AUTH"
  deletion_protection_enabled = var.enable_deletion_protection

  zone_distribution_config {
    mode = "MULTI_ZONE"
  }
}

# -----------------------------------------------------------------------------
# Tier 2 Durable Correctness & Idempotency Ledger: Cloud SQL PostgreSQL
# -----------------------------------------------------------------------------
resource "google_sql_database_instance" "correctness_primary" {
  project             = var.project_id
  name                = "${var.service_name}-pg-primary-${var.environment}"
  database_version    = "POSTGRES_16"
  region              = var.primary_region
  deletion_protection = var.enable_deletion_protection

  settings {
    tier              = var.environment == "prod" ? "db-custom-4-16384" : "db-custom-2-8192"
    availability_type = var.environment == "prod" ? "REGIONAL" : "ZONAL"

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }

    ip_configuration {
      ipv4_enabled                                  = false
      enable_private_path_for_google_cloud_services = true
    }
  }
}

# Cross-region read/promotion replica for Production Regional Recovery (RPO=0, RTO<15m)
resource "google_sql_database_instance" "correctness_recovery_replica" {
  count                = var.environment == "prod" ? 1 : 0
  project              = var.project_id
  name                 = "${var.service_name}-pg-recovery-${var.environment}"
  master_instance_name = google_sql_database_instance.correctness_primary.name
  region               = var.recovery_region
  database_version     = "POSTGRES_16"
  deletion_protection  = var.enable_deletion_protection

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = "db-custom-4-16384"
    availability_type = "REGIONAL"
  }
}
