# Project 2 — Multi-Model Serving + Request Routing (vLLM production-stack)

Two models behind one router, one URL for the client. Deployed with the official
[vLLM production-stack Helm chart](https://github.com/vllm-project/production-stack) onto a
**self-contained EKS cluster** built by this project's own Terraform (`terraform/`,
us-east-1), with **2× g6.xlarge** so each model gets its own GPU.

**Standalone:** this project owns its VPC, cluster, GPU nodes and GPU Operator, in its own
HCP Terraform workspace (`multimodel-llm-routing`). It shares nothing with project 1 and can
be demoed on its own.

**Done when:** curling the *router* gets answers from both models through the same endpoint,
requests visibly spread across backends, and I can explain the routing modes without notes.

## Hardware

2× **g6.xlarge** (NVIDIA L4, 24 GB each, ~$0.805/hr per node), one model per GPU. Set by
`gpu_node_count` in `terraform/variables.tf`.

The router needs no GPU. It's a proxy, so it sits on the **m7i.large** system node alongside
CoreDNS and the GPU Operator controller. That node gets a 50 GB root disk, not the 20 GB
default — the router image alone is 5.3 GB and 20 GB triggers an ephemeral-storage eviction.

## Architecture

```
client ──► vllm-router-service (roundrobin)
              ├──► qwen-1p5b engine  (GPU node 1)  Qwen2.5-1.5B-Instruct
              └──► qwen-7b-awq engine (GPU node 2) Qwen2.5-7B-Instruct-AWQ
```

The chart supports several routing modes:

- **`roundrobin`** — even spread. Used here because it makes the distribution obvious in the logs.
- **`session`** — sticky by session id, so a conversation keeps hitting the same replica.
- **`prefixaware` / `kvaware`** — send the request to the replica that has probably already
  computed that prefix, so you reuse its KV cache instead of recomputing it.

That last one is the interesting one, and the one-sentence version is worth memorising: *route to
the replica that already holds the prefix, because recomputing KV cache is pure waste.*

## Deploy

Prereqs: `aws` CLI configured, and an HCP Terraform workspace named `multimodel-llm-routing`
in the `Shikha_Projects` org with **Execution Mode = Local** (so it uses your local AWS
credentials). Create that workspace before the first apply.

```bash
# 1. Infrastructure: VPC, EKS cluster, 1x system node, 2x GPU node, NVIDIA GPU Operator.
#    ~15-20 min, mostly the EKS control plane and the node groups.
cd terraform
terraform init
terraform apply

# 2. Point kubectl at the new cluster (terraform prints this exact command)
terraform output -raw configure_kubectl | bash
cd ..

# 3. Both GPU nodes Ready, and the GPU Operator advertising nvidia.com/gpu on each
kubectl get nodes -L workload
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu

# 4. Install the stack with the two-model values (from this repo root).
#    --repo resolves the chart directly, so there's no `helm repo add` and no local
#    cache that can drift you onto a different chart version than the one you tested.
helm install vllm vllm-stack \
  --repo https://vllm-project.github.io/production-stack -f values.yaml

# 5. Verify: port-forwards the router, curls both models, prints the routing logs
bash scripts/verify-routing.sh
```

Step 3 matters because a GPU node can be `Ready` while still advertising `0` GPUs — the
kubelet is up but the GPU Operator's device plugin hasn't registered the card yet. Install the
chart in that window and the engine pods sit `Pending` on `Insufficient nvidia.com/gpu`.

**The `VLLM_PORT` trap.** On a shared cluster this bites hard, and it's worth understanding
rather than just avoiding: Kubernetes injects every *existing* Service name into every *new*
pod as env vars (`<NAME>_PORT=tcp://...`), and vLLM reads `VLLM_PORT` as configuration. So any
Service literally named `vllm` crashes every engine pod created after it. A Service named
`vllm` and an app named vLLM is an unlucky pairing. This standalone cluster has no such
Service — the chart's are named `vllm-router-service`, `vllm-qwen-1p5b-engine-service` and so
on — so there is nothing to delete first. If you ever hit it, `kubectl delete svc vllm` and
restart the engines.

## What `helm install -f values.yaml` actually does

1. Helm downloads the **chart**, which is a bundle of templated Kubernetes manifests.
2. It **renders** those templates with my `values.yaml` layered over the chart defaults. Each
   `modelSpec` entry expands into a full Deployment plus Service, with my image tag, GPU request
   and engine flags substituted in.
3. It applies the result and records it as a **release** named `vllm`, revision 1.

Edit `values.yaml` later and `helm upgrade vllm vllm/vllm-stack -f values.yaml` re-renders and
applies just the diff. That's the model-swap path. `helm rollback vllm 1` undoes a bad one.

## Deliberate choices

- **Both models are ungated**, so there's no HF token anywhere in the repo.
- **No PVCs.** `pvcStorage` is omitted because the cluster has no EBS CSI driver. Weights
  re-download on every pod start. Slower, but it avoids adding a storage failure mode to a demo.
- **Engine image pinned** to `vllm/vllm-openai:v0.22.1`, the known-good tag from project 1.
- **`runtimeClassName: nvidia`** works because the GPU Operator created that runtime class.
  Verified in-cluster rather than assumed.
- **Cost is ~$1.85/hr** with both GPUs up. Scale the node group to zero the moment you're done.

## Teardown

Two levels, depending on whether you're coming back to this.

```bash
# Between sessions — park the GPUs, keep the cluster. Kills ~$1.61/hr of the ~$1.85/hr.
cd terraform && terraform output -raw scale_gpus_to_zero | bash

# Bring them back later
aws eks update-nodegroup-config --cluster-name multimodel-llm-routing --nodegroup-name gpu \
  --scaling-config minSize=0,maxSize=2,desiredSize=2 --region us-east-1

# Done for good — removes the cluster, node groups, VPC and NAT gateway.
helm uninstall vllm
cd terraform && terraform destroy
```

Destroy the Helm release before `terraform destroy`. Skipping it leaves a Service of type
LoadBalancer holding an AWS ELB that Terraform doesn't know about, and the VPC delete then
hangs on the orphaned ENI. (This project's router is `ClusterIP`, so it isn't an issue *here*
— but it's the standard failure mode and worth having the habit.)

An idle cluster is not free: the EKS control plane is ~$0.10/hr and the NAT gateway ~$0.045/hr,
so a parked cluster still runs ~$3.50/day. Against a $50/month ceiling, `terraform destroy` is
usually the right call if the next session is more than a couple of days out.
