terraform {
  required_version = ">= 1.7.0, < 2.0.0"
  required_providers {
    github = {
      source  = "integrations/github"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

variable "repository_name" {
  description = "GitHub repository governed by platform branch protection standards."
  type        = string
  default     = "advocate-assist-platform"
}

resource "github_branch_protection" "main_branch" {
  repository_id                   = var.repository_name
  pattern                         = "main"
  enforce_admins                  = true
  require_signed_commits          = true
  required_linear_history         = true
  require_conversation_resolution = true

  required_status_checks {
    strict = true
    contexts = [
      "terraform-validate-and-mock-test",
      "semgrep-sast-scan",
      "trivy-iac-and-container-scan",
      "local-e2e-resilience-demo",
    ]
  }

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    require_code_owner_reviews      = true
    required_approving_review_count = 1
  }
}
