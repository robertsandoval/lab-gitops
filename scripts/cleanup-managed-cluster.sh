#!/usr/bin/env bash
# Remove one KubeVirt hosted cluster so the same name can be created again.
# Leaves the hub ODF provider, the internal StorageConsumer, and local-cluster.
set -euo pipefail

CLUSTER="${1:-managed-cluster1}"
export KUBECONFIG="${KUBECONFIG:-$HOME/openshift/clusters/ocp/lab/state/kubeconfig}"

if [[ "$CLUSTER" == "local-cluster" || "$CLUSTER" == "internal" || "$CLUSTER" == "klusterlet" ]]; then
  echo "refusing to clean ${CLUSTER}" >&2
  exit 1
fi

GUEST_KUBECONFIG="$(mktemp)"
trap 'rm -f "$GUEST_KUBECONFIG"' EXIT

log() { printf '== %s\n' "$*"; }

name_matches() {
  local name="$1"
  [[ "$name" == "$CLUSTER" || "$name" == "$CLUSTER-"* || "$name" == *"-$CLUSTER" || "$name" == *"-$CLUSTER-"* ]]
}

wait_gone() {
  local timeout="$1"
  shift
  local start=$SECONDS
  while oc get "$@" >/dev/null 2>&1; do
    if (( SECONDS - start >= timeout )); then
      echo "timed out waiting for $(printf '%q ' "$@")to be deleted" >&2
      oc get "$@" >&2 || true
      return 1
    fi
    sleep 10
  done
}

guest_api_up() {
  [[ -s "$GUEST_KUBECONFIG" ]] || return 1
  KUBECONFIG="$GUEST_KUBECONFIG" oc --request-timeout=8s get --raw=/readyz >/dev/null 2>&1
}

load_guest_kubeconfig() {
  : >"$GUEST_KUBECONFIG"
  oc -n clusters get secret "${CLUSTER}-admin-kubeconfig" -o jsonpath='{.data.kubeconfig}' 2>/dev/null \
    | base64 -d >"$GUEST_KUBECONFIG" || true
}

preflight() {
  log "checking resources that must survive"
  oc -n openshift-storage get storageconsumer internal >/dev/null
  oc get klusterlet.operator.open-cluster-management.io klusterlet >/dev/null
  oc -n openshift-storage get ds ocs-provider-host-proxy >/dev/null
  oc -n openshift-storage get sa ocs-provider-host-proxy >/dev/null
  oc -n openshift-storage get rolebinding ocs-provider-host-proxy-privileged >/dev/null
  local provider_ip
  provider_ip="$(oc -n openshift-storage get svc ocs-provider-server-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  if [[ "$provider_ip" != "10.1.4.91" ]]; then
    echo "provider LoadBalancer is ${provider_ip}, expected 10.1.4.91" >&2
    exit 1
  fi
  INTERNAL_UID="$(oc -n openshift-storage get storageconsumer internal -o jsonpath='{.metadata.uid}')"
  CONSUMER_UID="$(oc -n openshift-storage get storageconsumer "$CLUSTER" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  TICKET_SECRET="$(oc -n openshift-storage get storageconsumer "$CLUSTER" -o jsonpath='{.status.onboardingTicketSecret.name}' 2>/dev/null || true)"
}

delete_storageclient() {
  load_guest_kubeconfig
  if ! guest_api_up; then
    return 1
  fi
  if KUBECONFIG="$GUEST_KUBECONFIG" oc get storageclient.ocs.openshift.io hub-odf >/dev/null 2>&1; then
    log "deleting StorageClient hub-odf"
    KUBECONFIG="$GUEST_KUBECONFIG" oc delete storageclient.ocs.openshift.io hub-odf --wait=false --ignore-not-found
  fi
}

offboard_odf() {
  if oc get managedcluster.cluster.open-cluster-management.io "$CLUSTER" >/dev/null 2>&1; then
    log "removing operator-group and odf-client labels"
    oc label managedcluster.cluster.open-cluster-management.io "$CLUSTER" operator-group- odf-client- --overwrite >/dev/null
  fi

  # The storage policy recreates StorageClient until the placement drops the
  # cluster. Delete it while that happens so the consumer finalizer is not left
  # waiting on the client.
  log "waiting for Argo CD to prune the hub applications"
  local start=$SECONDS app hub_gone
  while true; do
    delete_storageclient || true
    hub_gone=1
    for app in "${CLUSTER}-odf-consumer" "${CLUSTER}-operator-policy"; do
      if oc -n openshift-gitops get applications.argoproj.io "$app" >/dev/null 2>&1; then
        hub_gone=0
      fi
    done
    if (( hub_gone == 1 )); then
      break
    fi
    if (( SECONDS - start >= 300 )); then
      echo "timed out waiting for the hub Argo CD applications to be pruned" >&2
      return 1
    fi
    sleep 10
  done

  # HyperConverged teardown can sit on operand finalizers. The hosted cluster
  # delete removes those guest objects, so do not block the hub cleanup on it.
  local virt_app="${CLUSTER}-virtualization"
  local virt_start=$SECONDS
  while oc -n openshift-gitops get applications.argoproj.io "$virt_app" >/dev/null 2>&1; do
    if (( SECONDS - virt_start >= 90 )); then
      log "releasing ${virt_app}; guest operands are removed with the hosted cluster"
      oc -n openshift-gitops patch applications.argoproj.io "$virt_app" --type=json \
        -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null || true
      oc -n openshift-gitops delete applications.argoproj.io "$virt_app" --wait=false --ignore-not-found
      break
    fi
    sleep 10
  done
  wait_gone 120 -n openshift-gitops applications.argoproj.io "$virt_app"
  if guest_api_up; then
    delete_storageclient || true
    wait_gone 180 --kubeconfig="$GUEST_KUBECONFIG" storageclient.ocs.openshift.io hub-odf || {
      echo "StorageClient hub-odf did not finish deleting" >&2
      return 1
    }
  else
    log "guest API is not reachable; skipping the final StorageClient wait"
  fi

  if oc -n openshift-storage get storageconsumer.ocs.openshift.io "$CLUSTER" >/dev/null 2>&1; then
    log "deleting StorageConsumer ${CLUSTER}"
    oc -n openshift-storage delete storageconsumer.ocs.openshift.io "$CLUSTER" --wait=false
  fi
  wait_gone 300 -n openshift-storage storageconsumer.ocs.openshift.io "$CLUSTER"

  if [[ -n "${TICKET_SECRET}" ]]; then
    oc -n openshift-storage delete secret "$TICKET_SECRET" --ignore-not-found --wait=false
    wait_gone 120 -n openshift-storage secret "$TICKET_SECRET"
  fi

  if [[ -n "${CONSUMER_UID}" ]]; then
    log "waiting for Ceph clients ${CONSUMER_UID} to be removed"
    local start=$SECONDS
    while oc -n openshift-storage get cephclients.ceph.rook.io -o name | grep -q "$CONSUMER_UID"; do
      if (( SECONDS - start >= 300 )); then
        echo "Ceph clients for ${CONSUMER_UID} are still present" >&2
        oc -n openshift-storage get cephclients.ceph.rook.io -o name | grep "$CONSUMER_UID" >&2 || true
        return 1
      fi
      sleep 10
    done
  fi

  if oc -n openshift-storage get cephfilesystemsubvolumegroup.ceph.rook.io "$CLUSTER" >/dev/null 2>&1; then
    log "deleting CephFilesystemSubVolumeGroup ${CLUSTER}"
    oc -n openshift-storage delete cephfilesystemsubvolumegroup.ceph.rook.io "$CLUSTER" --wait=false
    wait_gone 180 -n openshift-storage cephfilesystemsubvolumegroup.ceph.rook.io "$CLUSTER"
  fi

  log "deleting the copied onboarding secret"
  oc -n openshift-gitops delete secret "odf-onboarding-${CLUSTER}" --ignore-not-found
}

delete_hosted_cluster() {
  if ! oc -n clusters get hostedcluster.hypershift.openshift.io "$CLUSTER" >/dev/null 2>&1; then
    log "HostedCluster ${CLUSTER} is already gone"
    return 0
  fi
  log "deleting HostedCluster ${CLUSTER}"
  oc -n clusters delete hostedcluster.hypershift.openshift.io "$CLUSTER" --wait=false
  local start=$SECONDS api_down=0 klusterlet_cleared=0
  while oc -n clusters get hostedcluster.hypershift.openshift.io "$CLUSTER" >/dev/null 2>&1 \
    || oc get ns "clusters-${CLUSTER}" >/dev/null 2>&1; do
    if (( SECONDS - start >= 1500 )); then
      echo "timed out deleting HostedCluster ${CLUSTER}" >&2
      return 1
    fi
    if guest_api_up; then
      api_down=0
    else
      api_down=$((api_down + 1))
    fi
    if (( api_down >= 3 && klusterlet_cleared == 0 )) \
      && oc get klusterlet.operator.open-cluster-management.io "klusterlet-${CLUSTER}" >/dev/null 2>&1; then
      log "guest API is gone; clearing finalizers on klusterlet-${CLUSTER}"
      oc patch klusterlet.operator.open-cluster-management.io "klusterlet-${CLUSTER}" --type=json \
        -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null || true
      klusterlet_cleared=1
    fi
    sleep 10
  done
}

sweep_leftovers() {
  log "removing leftover Klusterlet, namespace, secrets, and RBAC"

  if oc get klusterlet.operator.open-cluster-management.io "klusterlet-${CLUSTER}" >/dev/null 2>&1; then
    oc patch klusterlet.operator.open-cluster-management.io "klusterlet-${CLUSTER}" --type=json \
      -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null || true
    oc delete klusterlet.operator.open-cluster-management.io "klusterlet-${CLUSTER}" --wait=false --ignore-not-found
    wait_gone 180 klusterlet.operator.open-cluster-management.io "klusterlet-${CLUSTER}"
  fi

  oc delete ns "klusterlet-${CLUSTER}" --wait=false --ignore-not-found
  wait_gone 300 ns "klusterlet-${CLUSTER}"

  local mw name
  while read -r mw; do
    [[ -n "$mw" ]] || continue
    name="${mw##*/}"
    if name_matches "$name"; then
      oc -n local-cluster delete "$mw" --wait=false --ignore-not-found
    fi
  done < <(oc -n local-cluster get manifestwork.work.open-cluster-management.io -o name 2>/dev/null || true)

  if oc get managedcluster.cluster.open-cluster-management.io "$CLUSTER" >/dev/null 2>&1; then
    oc delete managedcluster.cluster.open-cluster-management.io "$CLUSTER" --wait=false
    local start=$SECONDS
    while oc get managedcluster.cluster.open-cluster-management.io "$CLUSTER" >/dev/null 2>&1; do
      if (( SECONDS - start >= 180 )); then
        log "clearing finalizers on ManagedCluster ${CLUSTER}"
        oc patch managedcluster.cluster.open-cluster-management.io "$CLUSTER" --type=json \
          -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null || true
      fi
      if (( SECONDS - start >= 300 )); then
        echo "timed out deleting ManagedCluster ${CLUSTER}" >&2
        return 1
      fi
      sleep 10
    done
  fi

  oc delete ns "$CLUSTER" --wait=false --ignore-not-found
  wait_gone 300 ns "$CLUSTER"

  local secret
  while read -r secret; do
    [[ -n "$secret" ]] || continue
    name="${secret##*/}"
    if name_matches "$name"; then
      oc -n clusters delete "$secret" --ignore-not-found
    fi
  done < <(oc -n clusters get secret -o name)

  local kind ns obj
  for ns in openshift-storage openshift-gitops clusters kube-system; do
    for kind in job serviceaccount role rolebinding; do
      while read -r obj; do
        [[ -n "$obj" ]] || continue
        name="${obj##*/}"
        if name_matches "$name"; then
          oc -n "$ns" delete "$kind" "$name" --ignore-not-found --wait=false
        fi
      done < <(oc -n "$ns" get "$kind" -o name 2>/dev/null || true)
    done
  done

  for kind in clusterrole clusterrolebinding; do
    while read -r obj; do
      [[ -n "$obj" ]] || continue
      name="${obj##*/}"
      if name_matches "$name"; then
        oc delete "$kind" "$name" --ignore-not-found --wait=false
      fi
    done < <(oc get "$kind" -o name 2>/dev/null || true)
  done
}

verify() {
  log "verifying the hub provider is intact and ${CLUSTER} is gone"
  local failed=0 provider_ip

  oc -n openshift-storage get storageconsumer internal >/dev/null || failed=1
  oc get klusterlet.operator.open-cluster-management.io klusterlet >/dev/null || failed=1
  oc -n openshift-storage get ds ocs-provider-host-proxy >/dev/null || failed=1
  oc -n openshift-storage get sa ocs-provider-host-proxy >/dev/null || failed=1
  oc -n openshift-storage get rolebinding ocs-provider-host-proxy-privileged >/dev/null || failed=1
  if ! oc -n openshift-storage get cephclients.ceph.rook.io -o name | grep -q "$INTERNAL_UID"; then
    echo "internal Ceph clients ${INTERNAL_UID} are missing" >&2
    failed=1
  fi
  if [[ -n "${CONSUMER_UID}" ]] && oc -n openshift-storage get cephclients.ceph.rook.io -o name | grep -q "$CONSUMER_UID"; then
    echo "Ceph clients for ${CONSUMER_UID} are still present" >&2
    failed=1
  fi
  provider_ip="$(oc -n openshift-storage get svc ocs-provider-server-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  if [[ "$provider_ip" != "10.1.4.91" ]]; then
    echo "provider LoadBalancer is ${provider_ip}, expected 10.1.4.91" >&2
    failed=1
  fi
  if oc get svc -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[*].ip}{"\n"}{end}' | grep -qx '10.1.4.90'; then
    echo "10.1.4.90 is still assigned" >&2
    failed=1
  fi
  for obj in \
    "hostedcluster.hypershift.openshift.io -n clusters ${CLUSTER}" \
    "managedcluster.cluster.open-cluster-management.io ${CLUSTER}" \
    "klusterlet.operator.open-cluster-management.io klusterlet-${CLUSTER}" \
    "ns clusters-${CLUSTER}" \
    "ns klusterlet-${CLUSTER}" \
    "ns ${CLUSTER}" \
    "storageconsumer.ocs.openshift.io -n openshift-storage ${CLUSTER}" \
    "secret -n openshift-gitops odf-onboarding-${CLUSTER}"; do
    # shellcheck disable=SC2086
    if oc get $obj >/dev/null 2>&1; then
      echo "still present: ${obj}" >&2
      failed=1
    fi
  done
  if (( failed != 0 )); then
    echo "cleanup of ${CLUSTER} failed verification" >&2
    return 1
  fi
  log "${CLUSTER} is removed. 10.1.4.90 is free and the provider on 10.1.4.91 is unchanged."
}

preflight
offboard_odf
delete_hosted_cluster
sweep_leftovers
verify
