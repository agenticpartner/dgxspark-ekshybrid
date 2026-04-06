# EKS Hybrid Nodes + NVIDIA DGX (Spark) — walkthrough notes

This folder holds manifests and Helm values used while following:

**[Deploy production generative AI at the edge using Amazon EKS Hybrid Nodes with NVIDIA DGX](https://aws.amazon.com/blogs/containers/deploy-production-generative-ai-at-the-edge-using-amazon-eks-hybrid-nodes-with-nvidia-dgx/)**

The sections below mirror that post’s topics and add **hybrid-networking and operator fixes** that often appear when the on‑prem pod network cannot reach the in-cluster Kubernetes API Service VIP or cluster DNS the same way VPC nodes do.

---

## Prerequisites (from the post)

- VPC layout, EKS cluster **with hybrid nodes enabled**, and **private connectivity** (VPN or Direct Connect) between on‑prem and the cluster VPC.
- Distinct, routable **`RemoteNodeNetwork`** and **`RemotePodNetwork`** CIDRs; security groups and firewalls opened per [EKS Hybrid Nodes networking prerequisites](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-networking.html).
- On‑prem GPU system (e.g. DGX Spark) running a supported OS.
- **NGC** account and API key for NIM images.
- **Helm 3.9+**, **kubectl**, **AWS CLI**, **eksctl** (as in the article).

---

## Prepare IAM and cluster access for hybrid nodes

1. Create **temporary credentials** for the node (SSM hybrid activation or IAM Roles Anywhere) and the **hybrid nodes IAM role** as in the EKS user guide.
2. Create an EKS **access entry** for that role with type **`HYBRID_LINUX`** (example `aws eks create-access-entry` in the blog).

Local examples: `hybrid-ssm-cfn.yaml`, `nodeConfig.yaml` (replace placeholders with your cluster name, region, and activation details).

---

## Install `nodeadm` and join the hybrid node

1. Download **nodeadm** for your architecture (the blog uses **ARM64** for DGX Spark), `chmod +x`, then `nodeadm install <k8s-version> --credential-provider ssm` (or your chosen provider).
2. Build **`NodeConfig`** (`apiVersion: node.eks.aws/v1alpha1`) with `spec.cluster` and `spec.hybrid` credentials.
3. Run **`nodeadm init --config-source file://nodeConfig.yaml`**.

**GPU taint (blog recommendation):** for mixed GPU / non‑GPU hybrid nodes, consider registering GPU nodes with a taint such as `nvidia.com/gpu=Exists:NoSchedule` so GPU capacity is not consumed accidentally. Tolerate that taint on GPU workloads (NIM, GPU Operator operands, etc.).

**Troubleshooting joins:** if a node fails to register or `nodeadm init` hangs on Kubernetes API access, use AWS Support Automation **`AWSSupport-TroubleshootEKSWorkerNode`** to narrow down certificate, network, or IAM issues.

---

## Install Cilium (required CNI for hybrid nodes in the article)

The blog installs Cilium with Helm and a values file that, among other things:

- Restricts Cilium (and often the operator) to **hybrid** nodes via `eks.amazonaws.com/compute-type: hybrid`.
- Configures **IPAM** (e.g. `cluster-pool` with your **remote pod CIDR**).
- Enables **BGP control plane** and **NodePort** when advertising pod reachability on‑prem.

Local starting point: `cilium-values.yaml` (merge with your real `RemotePodNetwork` and affinity rules). BGP CR samples: `cilium-bgp-cluster.yaml`, `cilium-bgp-peer.yaml`, `cilium-bgp-cluster-ok.yaml`.

**Extra fix — API reachability from hybrid:** Cilium’s **operator / init** paths sometimes use the in-cluster Service address for the API. If the hybrid pod network cannot reach that VIP reliably, set explicit **`k8sServiceHost`** / **`k8sServicePort`** in Helm values to a reachable endpoint (EKS API **hostname** or a **private API ENI IP** from `nslookup` / VPC DNS — use what works from the hybrid network). Keep this aligned with whatever you use for other cluster components.

**Extra fix — `cilium-envoy`:** if Envoy is scheduled everywhere but Cilium agents only run on hybrid nodes, you may need **affinity** so Envoy runs only where Cilium runs (otherwise DaemonSet pods can stay Pending on non‑hybrid nodes).

---

## Install NVIDIA GPU Operator

Follow the blog’s Helm install (namespace `gpu-operator`, enable driver/toolkit/device plugin/GFD/DCGM exporter as needed, `operator.defaultRuntime=containerd`, `operator.runtimeClass=nvidia`, etc.).

Local overrides: **`gpu-operator-values.yaml`**.

**Extra fixes — Kubernetes API and DNS from hybrid pod network**

Pods on hybrid often fail with timeouts to **`https://172.17.0.1:443`** (Kubernetes Service) or **CoreDNS** (`ClusterIP`). Components that use the in-cluster config then cannot list nodes, patch labels, or write **NodeFeature** CRs.

| Area | What to do |
|------|------------|
| **Node Feature Discovery worker** | In values: **`hostNetwork: true`**, **`dnsPolicy: Default`**, and **`KUBERNETES_SERVICE_HOST` / `KUBERNETES_SERVICE_PORT`** pointed at a reachable API endpoint (hostname or private IP). Optionally relax probe delays if the node is slow to start. |
| **Operator validator** | Set **`validator.*.env`** (cuda, plugin, driver, toolkit sections — not only top-level) with the same API host/port. The chart may not expose **`hostNetwork`**; after each **`helm upgrade`**, re-patch: `kubectl patch ds -n gpu-operator nvidia-operator-validator -p '{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"Default"}}}}'` |
| **GPU Feature Discovery** | Set **`gfd.env`** with API host/port; **`helm upgrade`** may reset DaemonSet spec — re-patch: `kubectl patch ds -n gpu-operator gpu-feature-discovery -p '{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"Default"}}}}'` |
| **Driver DaemonSet** | If the host already has an NVIDIA driver, **`k8s-driver-manager`** patches the node to **`nvidia.com/gpu.deploy.driver=pre-installed`**. Set **`driver.manager.env`** and **`driver.env`** with API host/port; if TCP still times out from pod network, re-patch after upgrades: `kubectl patch ds -n gpu-operator nvidia-driver-daemonset -p '{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"Default"}}}}'` |

Use a **private API IP** only if it is routable from the hybrid path you use for the API; replace placeholders in the values file with your cluster’s real endpoint.

**Scheduling:** if you **cordon** the hybrid node (`SchedulingDisabled`), workloads pinned to that node (e.g. by `nodeSelector`) stay **Pending** until you **`kubectl uncordon <node-name>`**.

After install, confirm **`nvidia-operator-validator`** and **`nvidia-cuda-validator`** logs as in the blog, and **`kubectl get nodes`** shows **`nvidia.com/gpu`** in **allocatable** on the hybrid node.

---

## Deploy NVIDIA NIM on hybrid nodes

As in the blog:

1. Create **`ngc-secret`** (docker-registry to `nvcr.io`) and **`ngc-api`** (generic secret with `NGC_API_KEY`).
2. Fetch the **nim-llm** chart from NGC and install with a values file: **`nodeSelector`** for `eks.amazonaws.com/compute-type: hybrid`, GPU **resources**, **tolerations** for `nvidia.com/gpu`, **`imagePullSecrets`**, **`model.ngcAPISecret`**, etc.

Local example: **`qwen3-32b-spark-nim.values.yaml`**.

**Extra fixes**

- If the NIM pod cannot resolve or reach **NGC** from the CNI pod network, **`hostNetwork: true`** (and compatible **DNS policy**) on the workload is sometimes required so it uses the host’s resolver/path.
- The **`/v1/chat/completions`** API expects a **`messages`** array (OpenAI-style). A body that only sends **`prompt`** may be rejected or behave unexpectedly.

The blog tests inference with **`curl`** against the pod IP once routing (e.g. BGP) advertises pod subnets on‑prem.

---

## EKS Node Monitoring Agent (NMA)

Per the post:

1. Install the add-on: `aws eks create-addon --cluster-name <CLUSTER_NAME> --addon-name eks-node-monitoring-agent`.
2. Inspect hybrid **node conditions** (e.g. networking vs GPU readiness) via **`kubectl describe node`**.
3. Optional: create a **`NodeDiagnostic`** CR (`apiVersion: eks.amazonaws.com/v1alpha1`) to upload logs to S3 using a presigned URL — see the EKS user guide for **`NodeDiagnostic`**.

Create a small manifest for `kind: NodeDiagnostic` (fill in `metadata.name` and `spec.logCapture.destination`).

---

## Cleaning up (from the post)

Remove Helm releases you installed for this demo (e.g. NIM, GPU Operator), delete add-ons and cloud resources you created for the walkthrough, and delete or scale down hybrid nodes according to your process. Skip any steps in the original article that referred only to optional monitoring integrations you did not deploy.
