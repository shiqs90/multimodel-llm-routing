module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access = true

  # v21 manages access via EKS access entries (no more aws-auth configmap). This grants
  # the identity running `terraform apply` cluster-admin — without it you can't kubectl.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Core EKS addons. The v21 module does NOT install these by default — without the VPC CNI
  # nodes get no pod networking and stay NotReady. vpc-cni uses before_compute so the CNI
  # is registered before the node groups are created.
  addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    # CPU node for system pods (CoreDNS, GPU Operator controller) and the vLLM router.
    # The router is a proxy, so it needs no GPU — keeping it here leaves both GPUs
    # entirely for the engines.
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.system_instance_type]
      min_size       = 1
      max_size       = 2
      desired_size   = 1

      # 50GB, not the 20GB default. The production-stack router image alone is ~5.3GB and
      # a 20GB root disk triggers an ephemeral-storage eviction of the router pod.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 50
            volume_type = "gp3"
          }
        }
      }
    }

    # GPU nodes — one per model. AL2023_x86_64_NVIDIA is the EKS accelerated AMI:
    # driver + container toolkit are baked in, so the GPU Operator runs with
    # driver.enabled=false.
    gpu = {
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = [var.gpu_instance_type]
      min_size       = 0 # allows scale-to-zero between sessions for cost
      max_size       = var.gpu_node_count
      # The module sets ignore_changes on desired_size, so editing this alone does
      # NOTHING to a live node group. max_size is what actually resizes it, because the
      # ASG clamps desired <= max. Both are driven off gpu_node_count for that reason.
      desired_size = var.gpu_node_count

      # Default 20GB root is too small for the NVIDIA AMI + ~11GB vLLM image + HF cache.
      # There are no PVCs in this project, so model weights land here on every pod start.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
          }
        }
      }

      labels = {
        workload = "gpu"
      }

      # Taint reserves the GPU nodes for GPU work only — the router and system pods
      # can't drift onto them.
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "present"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }
}
