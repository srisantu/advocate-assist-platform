# ADR-001: Hub-and-Spoke Shared VPC, Private Service Connect, and Cloud Run Runtime Boundary

- **Status:** Accepted
- **Date:** 2026-11-11
- **Owner:** Platform Engineering (Advocate Assist)

## Context
During live customer interactions, an external enterprise CRM invokes the Advocate Assist CRM Interaction Enrichment API. The platform must:
1. Acknowledge requests synchronously within **2 seconds** after traversing the enterprise External Application Load Balancer (ALB) and Cloud Armor WAF over TLS.
2. Prevent any direct public internet bypass to the underlying compute runtime.
3. Operate inside an enterprise **Hub-and-Spoke Shared VPC** landing zone where a central network team owns the Shared VPC host project (`prj-net-host-{env}`), subnets, Cloud NAT, and hierarchical firewall policies, while workload teams deploy into isolated service projects (`prj-advocate-{env}`).
4. Reach a private downstream CRM callback endpoint and Vertex AI without public internet traversal or granting broad `roles/compute.networkAdmin` permissions to application teams.

In our broader enterprise footprint, we run multi-tenant GKE clusters attached to Shared VPC subnets. However, the assessment explicitly notes that Kubernetes and Helm are not required and mandates **Cloud Run** for application workloads.

## Decision
1. **Cloud Run with Internal + Load Balancer Ingress Only:**
   - Both `ingest-api` and `enrichment-worker` run on Cloud Run v2 (`google_cloud_run_v2_service`) with `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"`.
   - The `ingest-api` is exposed externally **exclusively** via a Global External Application Load Balancer (`EXTERNAL_MANAGED`) backed by a Serverless Network Endpoint Group (NEG) and protected by a Cloud Armor security policy (OWASP Top 10 preconfigured rules + per-consumer rate limiting + mTLS/OAuth JWT validation).
   - Direct `*.run.app` default URLs are disabled (`default_uri_disabled = true`), preventing edge bypass.
2. **Hub-and-Spoke Shared VPC Delegation (`roles/compute.networkUser`):**
   - Each environment (`dev`, `stage`, `prod`) uses a dedicated GCP service project attached to the environment-tier Shared VPC host project.
   - Cloud Run uses **Direct VPC Egress** into the host project's designated subnet (`egress = "ALL_TRAFFIC"` in `prod`) using subnet-scoped `roles/compute.networkUser` granted only to the Cloud Run Service Agent and dedicated workload service accounts. Workload pipelines never receive `roles/compute.networkAdmin` or `roles/compute.securityAdmin`.
3. **Private Service Connect (PSC) & Private Cloud DNS for Downstream Services:**
   - Downstream CRM updates and Vertex AI API calls traverse **Private Service Connect (PSC)** consumer endpoints (`google_compute_forwarding_rule` targeting the producer's `google_compute_service_attachment`) inside the Shared VPC.
   - A private Cloud DNS managed zone (`internal.advocate.local`) resolves `crm-callback.internal.advocate.local` and `us-central1-aiplatform.googleapis.com` (`199.36.153.4/30` restricted VIPs) privately inside the VPC perimeter.
   - **VPC Service Controls (VPC-SC)** perimeters wrap the service project, Cloud Run, Pub/Sub, Secret Manager, Memorystore, Cloud SQL, and Vertex AI to prevent credential or data exfiltration.

## Consequences
- **Positive:** Zero Kubernetes control-plane overhead for bursty webhook/event workloads; strict blast-radius separation between Network Host and Application Service projects; mathematical prevention of direct Cloud Run edge bypass via Terraform input validation (`expect_failures` tested in `.tftest.hcl`).
- **Tradeoffs:** Direct VPC Egress consumes RFC 1918 IP addresses from the Shared VPC subnet proportional to max Cloud Run instances (`max_instances * 2`), requiring subnet CIDR sizing (`/23` in `prod`) and alerting on IP utilization.
