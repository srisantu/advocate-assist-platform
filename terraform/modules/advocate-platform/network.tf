# -----------------------------------------------------------------------------
# Edge Protection: Cloud Armor WAF Policy + Global External ALB to Cloud Run NEG
# -----------------------------------------------------------------------------
resource "google_compute_security_policy" "edge_waf" {
  project     = var.project_id
  name        = "${var.service_name}-armor-${var.environment}"
  description = "Enterprise Cloud Armor WAF and rate-limiting policy for CRM ingestion"

  rule {
    action   = "throttle"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 500
        interval_sec = 60
      }
    }
    description = "Per-consumer M2M rate quota enforcement"
  }

  rule {
    action   = "deny(403)"
    priority = 2000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-stable') || evaluatePreconfiguredExpr('sqli-stable')"
      }
    }
    description = "Block OWASP injection payloads at edge"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow authenticated M2M traffic to ALB backend"
  }
}

resource "google_compute_region_network_endpoint_group" "api_primary_neg" {
  project               = var.project_id
  name                  = "${var.service_name}-neg-primary-${var.environment}"
  network_endpoint_type = "SERVERLESS"
  region                = var.primary_region

  cloud_run {
    service = google_cloud_run_v2_service.ingest_api.name
  }
}

resource "google_compute_region_network_endpoint_group" "api_recovery_neg" {
  count                 = var.environment == "prod" ? 1 : 0
  project               = var.project_id
  name                  = "${var.service_name}-neg-recovery-${var.environment}"
  network_endpoint_type = "SERVERLESS"
  region                = var.recovery_region

  cloud_run {
    service = google_cloud_run_v2_service.ingest_api_recovery[0].name
  }
}

resource "google_compute_backend_service" "api_edge_backend" {
  project               = var.project_id
  name                  = "${var.service_name}-backend-${var.environment}"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.edge_waf.id

  backend {
    group = google_compute_region_network_endpoint_group.api_primary_neg.id
  }

  dynamic "backend" {
    for_each = var.environment == "prod" ? [1] : []
    content {
      group = google_compute_region_network_endpoint_group.api_recovery_neg[0].id
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# -----------------------------------------------------------------------------
# Private Service Connect (PSC) Consumer Endpoint & Private DNS for Downstream
# -----------------------------------------------------------------------------
resource "google_compute_address" "psc_crm_ip" {
  project      = var.project_id
  name         = "psc-crm-ip-${var.environment}"
  region       = var.primary_region
  address_type = "INTERNAL"
  subnetwork   = var.shared_vpc_subnet_self_link
}

resource "google_compute_forwarding_rule" "psc_crm_endpoint" {
  project               = var.project_id
  name                  = "psc-crm-fwd-${var.environment}"
  region                = var.primary_region
  load_balancing_scheme = ""
  target                = var.psc_crm_service_attachment
  ip_address            = google_compute_address.psc_crm_ip.id
  subnetwork            = var.shared_vpc_subnet_self_link
}

resource "google_dns_managed_zone" "private_psc_zone" {
  project    = var.project_id
  name       = "advocate-internal-zone-${var.environment}"
  dns_name   = "internal.advocate.local."
  visibility = "private"
}

resource "google_dns_record_set" "crm_psc_a_record" {
  project      = var.project_id
  name         = "crm-callback.${google_dns_managed_zone.private_psc_zone.dns_name}"
  managed_zone = google_dns_managed_zone.private_psc_zone.name
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.psc_crm_ip.address]
}
