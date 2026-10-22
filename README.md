# gitops

HTPasswd identity provider for hosted clusters. The provider is `htpasswd_provider`, with the users in `management/htpasswd`. `sandoval` is granted `cluster-admin` in the guest.

Hosted control planes take identity providers from `HostedCluster.spec.configuration.oauth`. The htpasswd `Secret` sits in the HostedCluster namespace (`clusters`). The admin binding is guest RBAC.

| Path | Apply target |
| --- | --- |
| `management/` | Management cluster. Creates `Secret/htpass-secret` in `clusters`. |
| `components/htpasswd-idp/` | Kustomize component. Merge it onto each `HostedCluster`. |
| `guest/` | Hosted cluster. Binds `sandoval` to `cluster-admin`. |

Compose the component with the full HostedCluster manifest:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - hostedcluster.yaml
components:
  - ../../components/htpasswd-idp
```

This repo contains password hashes. Keep it private.
