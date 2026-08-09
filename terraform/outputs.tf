output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "scale_gpus_to_zero" {
  description = "Park the GPU node group between sessions without destroying the cluster"
  value       = "aws eks update-nodegroup-config --cluster-name ${module.eks.cluster_name} --nodegroup-name gpu --scaling-config minSize=0,maxSize=${var.gpu_node_count},desiredSize=0 --region ${var.region}"
}
