# Argo CD Installation and Configuration

## Overview

Argo CD is used as the GitOps continuous delivery tool for the Targil2026 project.

It continuously compares the desired application state defined in Git with the actual state of the Kubernetes cluster.

The environment consists of three K3s control-plane nodes running on KVM virtual machines.

## Environment

| Component | Configuration |
|---|---|
| Kubernetes distribution | K3s |
| Kubernetes version | v1.37.2+k3s1 |
| Nodes | 3 |
| Argo CD version | v3.6.2 |
| Helm chart | argo/argo-cd |
| Helm chart version | 10.18.2 |
| Namespace | argocd |
| Installation type | Non-HA |
| Ingress controller | Traefik |

## Architecture Decision

A non-HA Argo CD installation was selected because this is a development and testing environment.

The Kubernetes control plane itself uses a three-node embedded etcd cluster for high availability.

Argo CD does not require multiple replicas for the scope of this exercise.

A dedicated namespace provides separation from other workloads, including MongoDB and the sample Node.js application.

## Installation

Add the Argo Helm repository:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
```

Install Argo CD using the pinned Helm chart version:

```bash
helm upgrade --install argocd argo/argo-cd \
  --version 10.18.2 \
  --namespace argocd \
  --create-namespace \
  -f infrastructure/argocd/values.yaml \
  --wait \
  --timeout 10m
```

## Configuration

The configuration is maintained in:

`infrastructure/argocd/values.yaml`

The deployment uses a ClusterIP service.

The initial web interface is accessed through Kubernetes port forwarding rather than an externally exposed Ingress.

Optional features such as Dex, Notifications, and ApplicationSet may be disabled when they are not required.

## Validation

Verify the Helm release:

```bash
helm list -n argocd
```

Verify the Argo CD Pods:

```bash
kubectl get pods -n argocd
```

Verify the Services:

```bash
kubectl get svc -n argocd
```

All required components should report a healthy and running state.

## Accessing the Web Interface

Forward the Argo CD server port:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open:

`https://localhost:8080`

The initial administrator username is:

`admin`

Retrieve the initial password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Do not store administrator passwords in Git.

Change the initial administrator password and remove the initial password Secret after completing the initial setup.

## GitOps Deployment Strategy

The sample Node.js application is maintained in:

`https://github.com/ZoharGolano/sample-nodejs`

Argo CD will monitor the `main` branch.

The application Helm chart is located at:

`helm/sample-nodejs`

The target namespace is:

`sample-app`

The Argo CD Application definition will be stored declaratively in Git and configured with automated synchronization.

## Useful Commands

```bash
kubectl get applications -n argocd
kubectl get pods -n sample-app
kubectl get deployments -n sample-app
kubectl get ingress -n sample-app
```

## Troubleshooting

Inspect Argo CD application-controller logs:

```bash
kubectl logs -n argocd statefulset/argocd-application-controller
```

Inspect repository-server logs:

```bash
kubectl logs -n argocd deployment/argocd-repo-server
```

Check namespace events:

```bash
kubectl get events -n argocd --sort-by=.lastTimestamp
```

## Security Considerations

- Argo CD is installed in a dedicated namespace.
- The initial web UI is not publicly exposed.
- GitOps configuration is version-controlled.
- Application container images are scanned with Trivy before publication.
- Administrator credentials must not be committed to Git.
- Kubernetes RBAC and GitHub permissions should follow the principle of least privilege.
