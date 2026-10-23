# gitops

Label a managed cluster `operator-group=default` and Advanced Cluster Management installs OpenShift Virtualization, the ODF client, NMState, and the Migration Toolkit for Virtualization. Argo CD syncs the operand CRs after the ODF client is connected. The ODF `StorageClient` is an ACM policy because each cluster has its own onboarding token.

The cluster must already be in the `managed-clusters` set (`cluster.open-cluster-management.io/clusterset=managed-clusters`). `local-cluster` is in the `default` set, so these policies do not select the hub.

The htpasswd identity provider is not in this repo. Apply it by hand from `~/openshift/clusters/ocp/identity`.

| Path | What it does |
| --- | --- |
| `hub/` | Hub Application `lab-gitops`. Placement, the operator policies, the StorageClient policy, GitOpsCluster, and the ApplicationSets. |
| `management/odf-provider/` | Hub provider LoadBalancer Service and the host-network proxy on virtualization nodes (`10.1.4.40:50061`). |
| `management/odf-consumer/` | Helm chart. One `StorageConsumer/<cluster>`, a Job that copies the onboarding token into `openshift-gitops`, and a Job that enables the consumer after the client connects and then labels the cluster `odf-client=ready`. |
| `management/operator-policy/` | Helm chart. A Job sets `operator-policy-disabled=false` on `ManagedClusterAddOn/config-policy-controller` so the operator policies are evaluated. |
| `guest/virtualization/` | `HyperConverged/kubevirt-hyperconverged` in `openshift-cnv`. |
| `guest/nmstate/` | `NMState/nmstate`. |
| `guest/mtv/` | `ForkliftController/forklift-controller` in `openshift-mtv`. |
| `guest/odf-client/post/` | Manual patches after `StorageClient` is Connected. Not synced. |

## What the label does

`Placement/operator-group-default` in `openshift-gitops` selects managed clusters labeled `operator-group=default`. One `PlacementBinding` attaches five policies:

- `openshift-virtualization-operator` installs `kubevirt-hyperconverged` from `redhat-operators` / `stable` into `openshift-cnv`.
- `odf-client-operator` installs `ocs-client-operator` from `redhat-operators` / `stable-4.21` into `openshift-storage-client`. The hub provider is 4.21.14, and onboarding rejects a client whose minor version differs.
- `nmstate-operator` installs `kubernetes-nmstate-operator` from `redhat-operators` / `stable` into `openshift-nmstate`.
- `mtv-operator` installs `mtv-operator` from `redhat-operators` / `release-v2.12` into `openshift-mtv`.
- `odf-storage-client` creates cluster-scoped `StorageClient/hub-odf` with endpoint `10.1.4.40:50061`. The ticket comes from `Secret/odf-onboarding-<cluster>` in `openshift-gitops`. `fromSecret` can only read secrets in the policy namespace, returns the data still base64-encoded, and ACM encrypts it. Decode on the guest after decryption: `{{ "{{hub fromSecret ... hub}}" | base64dec }}`.

`GitOpsCluster/operator-group-default` registers those placement decisions with the hub Argo CD. Five ApplicationSets then sync:

- `operator-policy` runs a Job on the hub that waits for `ManagedClusterAddOn/config-policy-controller` and sets `operator-policy-disabled=false`. The config-policy addon leaves OperatorPolicy off until that annotation is present. The Job exits immediately when the annotation is already set. Removing the label prunes the Job and its RBAC; the annotation stays on the addon.

- `odf-consumer` applies the Helm chart on the hub. The consumer is created with `spec.enable=false` so it keeps an onboarding ticket. One Job copies that token into `openshift-gitops`. A second Job waits until `StorageClient/hub-odf` is Connected, sets `spec.enable=true`, makes `ocs-storagecluster-ceph-rbd` the default StorageClass, pins the Ceph CSI drivers to one replica, and labels the ManagedCluster `odf-client=ready`. Argo ignores later changes to `spec.enable`.
- `guest-virtualization`, `guest-nmstate`, and `guest-mtv` apply their operand CRs only after that label. `Placement/odf-client-ready` requires both `operator-group=default` and `odf-client=ready`. HyperConverged then imports catalog images onto the ODF class. `NMState/nmstate` and `ForkliftController/forklift-controller` are created in the same wave. The cluster is already registered with Argo CD by `Placement/operator-group-default`.

## After StorageClient is Connected

The `wait-odf-client` Job applies the same merge patches as `guest/odf-client/post/`:

- Keep `ocs-storagecluster-ceph-rbd` as the only default StorageClass.
- Pin the Ceph CSI `Driver` `controllerPlugin.replicas` to 1. These guests are single-node, and the client operator does not set replicas.

Those files are not a kustomize root. Applying them directly drops fields the operator owns.

## Cleaning up a demo cluster

`scripts/cleanup-managed-cluster.sh` removes one hosted cluster so the same name can be created again. It defaults to `managed-cluster1`.

```bash
scripts/cleanup-managed-cluster.sh
scripts/cleanup-managed-cluster.sh other-cluster
```

Run it to completion before creating that name again. It removes the GitOps labels, deletes `StorageClient/hub-odf` before the consumer, prunes the Argo CD applications, deletes the copied onboarding secret, and deletes the HostedCluster. If the guest API is already gone, it clears finalizers only on `klusterlet-<cluster>`.

It does not touch `local-cluster`, the hub Klusterlet, the internal StorageConsumer, the provider LoadBalancer on `10.1.4.91`, or the host-network proxy. The identity provider is separate and is not removed.

## UI

Start `scripts/pin-api-vip.sh` before the first create and leave it running. It pins each new `Service/kube-apiserver` to `metallb.io/address-pool=machine-pool` and `metallb.io/loadBalancerIPs=10.1.4.90`, then waits through the delete and does it again on the next create. Stop it with Ctrl-C. The pin has to land before worker ignition is written. DNS for `api.managed-cluster1.sandoval.lab` is already `10.1.4.90`.

```bash
scripts/pin-api-vip.sh
```

Create the KubeVirt HostedCluster in the hub console and put its ManagedCluster in cluster set `managed-clusters`. When the managed cluster is Available, add the label `operator-group=default`.

Expect this order: a placement decision, the four operator policies Compliant, `StorageConsumer/<cluster>` disabled with a ticket, `Secret/odf-onboarding-<cluster>` in `openshift-gitops`, `StorageClient/hub-odf` Connected, the consumer enabled and Ready, the ODF storage classes, the `odf-client=ready` label, then Applications `<cluster>-virtualization`, `<cluster>-nmstate`, and `<cluster>-mtv` Healthy.
