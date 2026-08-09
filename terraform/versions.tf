terraform {
  required_version = "~> 1.15"

  # Own HCP Terraform workspace so this project's state is independent of project 1's
  # (`ai-infra-projects-2026`). Create the workspace in the Shikha_Projects org and set
  # its Execution Mode to "Local" before the first apply, so the local AWS CLI
  # credentials are used.
  cloud {
    organization = "Shikha_Projects"

    workspaces {
      name = "multimodel-llm-routing"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
