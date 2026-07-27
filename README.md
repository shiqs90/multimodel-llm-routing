# Project 2 — Multi-Model Serving + Request Routing (vLLM production-stack)

Two models behind one router, one URL for the client. Deployed with the official
[vLLM production-stack Helm chart](https://github.com/vllm-project/production-stack) on the
project 1 cluster (`vllm-serving-eks`, us-east-1), scaled out to **2× g6.xlarge** so each model
gets its own GPU.

**Done when:** curling the *router* gets answers from both models through the same endpoint,
requests visibly spread across backends, and I can explain the routing modes without notes.

## Hardware

2× **g6.xlarge** (NVIDIA L4, 24 GB each, ~$0.805/hr per node), one model per GPU. That's project
1's single node scaled to two.

The router needs no GPU. It's a proxy, so it sits on the shared **m7i.large** system node.

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

```bash
# Prereq: the EKS GPU cluster with 2 GPU nodes and the NVIDIA GPU Operator (project 1).
#
# Delete project 1's standalone vLLM Deployment and Service first. Its Service is named `vllm`,
# so Kubernetes injects VLLM_PORT=tcp://... into every new pod, and that crashes the engines.
kubectl delete deployment vllm --ignore-not-found && kubectl delete service vllm --ignore-not-found

# 1. Install the stack with the two-model values (from this repo root)
helm repo add vllm https://vllm-project.github.io/production-stack && helm repo update
helm install vllm vllm/vllm-stack -f values.yaml

# 2. Verify: port-forwards the router, curls both models, prints the routing logs
bash scripts/verify-routing.sh
```

The `VLLM_PORT` collision is worth understanding, not just working around. Kubernetes injects
every existing Service name into new pods as env vars, and vLLM reads `VLLM_PORT` as
configuration. A Service named `vllm` and an app named vLLM is an unlucky pairing.

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
