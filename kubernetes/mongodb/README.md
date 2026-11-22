# MongoDB Helm Configuration

## Overview

MongoDB is deployed on the Targil2026 K3s cluster using Helm.

The database is configured as a standalone MongoDB instance for development and testing purposes.

## Configuration

The Helm values file is maintained at:

`kubernetes/mongodb/values.yaml`

The configuration includes:

- Standalone MongoDB architecture.
- Kubernetes Secret-based authentication.
- Explicit CPU and memory requests and limits.
- NodePort access for database connections.
- Prometheus exporter metrics.
- Disabled persistent storage.

## Security Considerations

Database credentials are stored in Kubernetes Secrets and must not be committed to Git.

Do not commit passwords, private keys, administrator kubeconfigs, or other sensitive information.

The MongoDB deployment uses legacy Bitnami container images and is intended for this lab environment only.

## Validation

Verify the MongoDB resources:

```bash
kubectl get pods,svc -n mongodb
```

Verify the Helm release:

```bash
helm list -n mongodb
```

Verify the database version:

```bash
kubectl exec -n mongodb deploy/mongodb -c mongodb -- mongod --version
```

## Documentation

For detailed installation instructions, troubleshooting, security considerations, and validation results, see:

[MongoDB Installation and Validation](../../docs/03-mongodb-installation.md).