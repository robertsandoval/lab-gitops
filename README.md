# gitops

Label a managed cluster `operator-group=default` and Advanced Cluster Management installs OpenShift Virtualization and the ODF client. Argo CD syncs the `HyperConverged` operand. The ODF `StorageClient` is an ACM policy because each cluster has its own onboarding token.

The cluster must already be in the `managed-clusters` set (`cluster.open-cluster-management.io/clusterset=managed-clusters`). `local-cluster` is in the `default` set, so these policies do not select the hub.

The htpasswd identity provider is not in this repo. Apply it by hand from `~/openshift/clusters/ocp/identity`.

| Path | What it does |
| --- | --- |
| `hub/` | Hub Application `lab-gitops`. Placement, both operator policies, the StorageClient policy, GitOpsCluster, and the ApplicationSets. |
| `management/odf-provider/` | Hub provider LoadBalancer Service and the host-network proxy on virtualization nodes (`10.1.4.40:50061`). |
| `management/odf-consumer/` | Helm chart. One `StorageConsumer/<cluster>` plus a Job that copies the onboarding token into `Secret/odf-onboarding-<cluster>` in `openshift-gitops` once. |
| `management/operator-policy/` | Helm chart. A Job sets `operator-policy-disabled=false` on `ManagedClusterAddOn/config-policy-controller` so the operator policies are evaluated. |
| `guest/virtualization/` | `HyperConverged/kubevirt-hyperconverged` in `openshift-cnv`. |
| `guest/odf-client/post/` | Manual patches after `StorageClient` is Connected. Not synced. |

## What the label does

`Placement/operator-group-default` in `openshift-gitops` selects managed clusters labeled `operator-group=default`. One `PlacementBinding` attaches three policies:

- `openshift-virtualization-operator` installs `kubevirt-hyperconverged` from `redhat-operators` / `stable` into `openshift-cnv`.
- `odf-client-operator` installs `ocs-client-operator` from `redhat-operators` / `stable-4.21` into `openshift-storage-client`.
- `odf-storage-client` creates cluster-scoped `StorageClient/hub-odf` with endpoint `10.1.4.40:50061`. The ticket comes from `Secret/odf-onboarding-<cluster>` in `openshift-gitops`. `fromSecret` can only read secrets in the policy namespace, and it already returns decoded data.

`GitOpsCluster/operator-group-default` registers those placement decisions with the hub Argo CD. Three ApplicationSets then sync:

- `operator-policy` runs a Job on the hub that waits for `ManagedClusterAddOn/config-policy-controller` and sets `operator-policy-disabled=false`. The config-policy addon leaves OperatorPolicy off until that annotation is present. The Job exits immediately when the annotation is already set. Removing the label prunes the Job and its RBAC; the annotation stays on the addon.

- `guest-virtualization` applies `guest/virtualization/` to the managed cluster. It stays degraded until the virtualization operator policy is Compliant and the `HyperConverged` CRD exists.
- `odf-consumer` applies the Helm chart on the hub. The Job copies the token into `openshift-gitops` and exits without writing a second token when that secret already exists. After the client connects, the consumer clears `status.onboardingTicketSecret`, and later syncs keep the copied secret.

## After StorageClient is Connected

`guest/odf-client/post/` is not part of a kustomize root. Patch with `oc patch --type=merge`:

- Keep `ocs-storagecluster-ceph-rbd` as the only default StorageClass.
- Pin the Ceph CSI `Driver` `controllerPlugin.replicas` to 1. These guests are single-node, and the client operator does not set replicas.

## Removing the label

Prune deletes `HyperConverged` and the consumer Application, including `StorageConsumer/<cluster>`. Delete `StorageClient/hub-odf` on the guest before that, or the consumer finalizer waits on the client. `Secret/odf-onboarding-<cluster>` in `openshift-gitops` is created by the Job, not by Helm, so prune does not delete it. Delete that secret by hand when the consumer is gone.

## UI

Create the KubeVirt HostedCluster in the hub console and put its ManagedCluster in cluster set `managed-clusters`. When the managed cluster is Available, add the label `operator-group=default`.

Expect this order: a placement decision, both operator policies Compliant, Application `<cluster>-virtualization` Healthy, `StorageConsumer/<cluster>` Ready, `Secret/odf-onboarding-<cluster>` in `openshift-gitops`, then `StorageClient/hub-odf` Connected.
