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




## Permanent HTTPS Access Through Traefik

### Overview

Argo CD is accessible through a dedicated Traefik Ingress using the hostname:

`https://argocd.test`

This configuration replaces the need for manually running Kubernetes port forwarding.

The endpoint is intended for access from the local lab environment.

### Environment

| Component | Configuration |
|---|---|
| Argo CD | v3.6.2 |
| Helm chart | argo-cd 10.18.2 |
| Helm release revision | 2 |
| Namespace | argocd |
| Ingress controller | Traefik |
| Hostname | argocd.test |
| HTTPS port | 443 |
| TLS termination | Traefik |
| Backend service | argocd-server |
| Backend port | 80 |
| TLS Secret | argocd-server-tls |

### Architecture

```text
Ubuntu Host
    |
    | HTTPS :443
    v
Traefik Ingress
    |
    | TLS termination
    v
argocd-server:80
    |
    v
Argo CD Web UI
```

The browser-to-Traefik connection is encrypted using HTTPS.

Traefik forwards requests to the Argo CD server using HTTP within the Kubernetes cluster.

This configuration is intended for the local lab, not for an internet-facing production environment.

### Helm Configuration

The Argo CD configuration is maintained in:

`infrastructure/argocd/values.yaml`

The relevant settings are:

```yaml
global:
  domain: argocd.test

configs:
  params:
    server.insecure: "true"

server:
  service:
    type: ClusterIP

  ingress:
    enabled: true
    controller: generic
    ingressClassName: traefik
    hostname: argocd.test
    path: /
    pathType: Prefix
    tls: true
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
```

### TLS Certificate

A self-signed certificate was created for `argocd.test`.

The certificate and private key are stored outside the Git repository:

```text
~/targil2026-tls/argocd.crt
~/targil2026-tls/argocd.key
```

The Kubernetes TLS Secret was created using:

```bash
kubectl create secret tls argocd-server-tls \
  --namespace argocd \
  --cert="$HOME/targil2026-tls/argocd.crt" \
  --key="$HOME/targil2026-tls/argocd.key"
```

When recreating an existing Secret, use a controlled update procedure.

**Security:** Never commit TLS private keys or Kubernetes Secret values to Git.

### Helm Upgrade

The existing Argo CD installation was updated using:

```bash
helm upgrade argocd argo/argo-cd \
  --version 10.18.2 \
  --namespace argocd \
  -f infrastructure/argocd/values.yaml \
  --wait \
  --timeout 10m
```

The upgrade completed successfully with Helm release revision 2.

### Local Hostname Resolution

The Ubuntu host uses the following `/etc/hosts` entry:

```text
192.168.122.11 argocd.test
```

Verify hostname resolution:

```bash
getent hosts argocd.test
```

### Validation

Verify the Helm release:

```bash
helm list -n argocd
```

Verify the running Pods:

```bash
kubectl get pods -n argocd
```

Verify the Ingress:

```bash
kubectl get ingress -n argocd
```

Verify HTTPS connectivity:

```bash
curl -k -I https://argocd.test
```

Observed result:

```text
HTTP/2 200
```

The `-k` option skips certificate verification and is used here only for testing the self-signed lab certificate.

### Access

Open the following URL from the Ubuntu host:

`https://argocd.test`

Sign in using the configured Argo CD credentials.

A browser security warning may appear because the certificate is self-signed.

### Troubleshooting

**HTTP 404:** Verify that the hostname matches the Ingress rule.

**HTTP 502:** Verify that `argocd-server` is running and that the Ingress backend uses port 80.

**TLS warning:** Verify that the certificate includes `argocd.test` in its Subject Alternative Names.

**Name resolution failure:** Verify the local `/etc/hosts` entry.

### Lessons Learned

During configuration, Helm validation initially failed because `configs` was incorrectly defined as a YAML list rather than a mapping.

Incorrect:

```yaml
configs:
  - params:
      server.insecure: true
```

Correct:

```yaml
configs:
  params:
    server.insecure: "true"
```

After correcting the YAML structure, Helm lint and template rendering succeeded.
