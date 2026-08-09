variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "multimodel-llm-routing"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "gpu_instance_type" {
  description = "GPU node instance type. g6.xlarge = L4 24GB (cheaper); fallback g5.xlarge = A10G 24GB."
  type        = string
  default     = "g6.xlarge"
}

variable "gpu_node_count" {
  description = <<-EOT
    Number of GPU nodes. Default 2 = one model per GPU, which is what this project
    demonstrates and what the README's cost math assumes (~$1.61/hr for the GPUs alone).

    Set to 1 for a cheaper run: both Qwen2.5-1.5B (~3GB) and Qwen2.5-7B-AWQ (~5.5GB)
    fit inside one L4's 24GB, but they then need GPU time-slicing to share the card,
    and the routing demo no longer shows requests landing on separate nodes.
  EOT
  type        = number
  default     = 2
}

variable "system_instance_type" {
  description = "Non-GPU system node instance type. Runs CoreDNS, the GPU Operator controller, and the vLLM router (a proxy — no GPU needed)."
  type        = string
  default     = "m7i.large"
}
