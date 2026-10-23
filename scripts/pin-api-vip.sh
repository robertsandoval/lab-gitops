#!/usr/bin/env bash
# Pin a hosted cluster kube-apiserver Service to the lab API VIP as soon as
# the Service exists, before worker ignition is written.
#
# Leave it running across deletes and the next create. It pins each new
# kube-apiserver, stays quiet once the VIP is assigned, and waits again
# when that cluster is deleted. Stop it with Ctrl-C.
#
#   scripts/pin-api-vip.sh
#   scripts/pin-api-vip.sh managed-cluster1
#
# Uses the current oc login. Set KUBECONFIG to override.
# API_VIP (default 10.1.4.90) and API_POOL (default machine-pool) can be
# overridden in the environment.
set -euo pipefail

CLUSTER="${1:-managed-cluster1}"
API_VIP="${API_VIP:-10.1.4.90}"
API_POOL="${API_POOL:-machine-pool}"

if [[ "$API_VIP" == "10.1.4.91" ]]; then
  echo "refusing to pin the ODF provider address 10.1.4.91" >&2
  exit 1
fi

log() { printf '== %s\n' "$*"; }

oc whoami >/dev/null

log "watching HostedCluster/${CLUSTER}. Create and delete it as often as you want. Ctrl-C stops this."

prev_hc_uid=""
prev_svc_uid=""
warned_svc_uid=""
state=""
last_beat=$SECONDS
hold_note=""

beat() {
  if (( SECONDS - last_beat >= 15 )); then
    log "$*"
    last_beat=$SECONDS
  fi
}

enter() {
  local next="$1"
  shift
  if [[ "$state" != "$next" ]]; then
    log "$*"
    state="$next"
    last_beat=$SECONDS
  fi
}

svc_field() {
  local template="$1"
  oc -n "$CP_NS" get svc kube-apiserver -o "go-template=${template}" 2>/dev/null || true
}

# Prints other Services that already have API_VIP. Exit 0 when one exists.
address_in_use() {
  oc get svc -A -o go-template='{{range .items}}{{.metadata.namespace}} {{.metadata.name}} {{with .metadata.annotations}}{{index . "metallb.io/loadBalancerIPs"}}{{end}} {{range .status.loadBalancer.ingress}}{{.ip}} {{end}}{{"\n"}}{{end}}' 2>/dev/null \
    | awk -v vip="$API_VIP" -v cp="$CP_NS" '
        BEGIN {
          gsub(/\./, "\\.", vip)
          pattern = "(^|[^0-9])" vip "([^0-9]|$)"
        }
        $0 ~ pattern && !($1 == cp && $2 == "kube-apiserver") { print; found = 1 }
        END { exit found ? 0 : 1 }
      '
}

while true; do
  if ! hc_out="$(oc get hostedcluster -A --no-headers 2>/dev/null)"; then
    beat "cannot list HostedClusters; retrying"
    sleep 1
    continue
  fi

  hc_ns="$(printf '%s\n' "$hc_out" | awk -v name="$CLUSTER" '$2 == name { print $1 }')"
  if [[ -z "$hc_ns" ]]; then
    if [[ -n "$prev_hc_uid" ]]; then
      log "HostedCluster/${CLUSTER} is gone. Waiting for the next create."
      prev_hc_uid=""
      prev_svc_uid=""
      warned_svc_uid=""
      hold_note=""
      state=""
      last_beat=$SECONDS
    else
      beat "still waiting for HostedCluster/${CLUSTER}"
    fi
    sleep 1
    continue
  fi

  ns_count="$(printf '%s\n' "$hc_ns" | wc -l | tr -d ' ')"
  if [[ "$ns_count" != "1" ]]; then
    beat "found more than one HostedCluster named ${CLUSTER}; waiting until only one remains"
    sleep 1
    continue
  fi

  CP_NS="${hc_ns}-${CLUSTER}"
  hc_uid="$(oc -n "$hc_ns" get hostedcluster "$CLUSTER" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  if [[ -z "$hc_uid" ]]; then
    sleep 1
    continue
  fi
  if [[ "$hc_uid" != "$prev_hc_uid" ]]; then
    log "HostedCluster/${CLUSTER} is in ${hc_ns}. Waiting for Service/${CP_NS}/kube-apiserver."
    prev_hc_uid="$hc_uid"
    prev_svc_uid=""
    warned_svc_uid=""
    hold_note=""
    state="waiting-svc"
    last_beat=$SECONDS
  fi

  svc_uid="$(oc -n "$CP_NS" get svc kube-apiserver -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  if [[ -z "$svc_uid" ]]; then
    if [[ -n "$prev_svc_uid" ]]; then
      log "Service/${CP_NS}/kube-apiserver is gone. Waiting for it to come back."
      prev_svc_uid=""
      state="waiting-svc"
      last_beat=$SECONDS
    else
      beat "still waiting for Service/${CP_NS}/kube-apiserver"
    fi
    sleep 1
    continue
  fi

  if [[ "$svc_uid" != "$prev_svc_uid" ]]; then
    prev_svc_uid="$svc_uid"
    state="pinning"
  fi

  pool="$(svc_field '{{with .metadata.annotations}}{{index . "metallb.io/address-pool"}}{{end}}')"
  wanted="$(svc_field '{{with .metadata.annotations}}{{index . "metallb.io/loadBalancerIPs"}}{{end}}')"
  assigned="$(svc_field '{{with index .status.loadBalancer.ingress 0}}{{.ip}}{{end}}')"

  if [[ -n "$assigned" && "$assigned" != "$API_VIP" && "$warned_svc_uid" != "$svc_uid" ]]; then
    echo "kube-apiserver already has ${assigned}. Pinning ${API_VIP} now. If worker ignition was already written, those hosts keep dialing ${assigned}." >&2
    warned_svc_uid="$svc_uid"
  fi

  if [[ "$pool" != "$API_POOL" || "$wanted" != "$API_VIP" ]]; then
    if holder="$(address_in_use)"; then
      foreign="$(printf '%s\n' "$holder" | awk '$2 != "kube-apiserver" { print }')"
      if [[ -n "$foreign" ]]; then
        if [[ "$hold_note" != "$foreign" ]]; then
          echo "${API_VIP} is in use by another Service, leaving kube-apiserver alone:" >&2
          printf '%s\n' "$foreign" >&2
          hold_note="$foreign"
        fi
        sleep 1
        continue
      fi
      if [[ "$hold_note" != "$holder" ]]; then
        log "${API_VIP} is still on the previous kube-apiserver. Annotating this one so it takes the address when the previous Service is deleted."
        hold_note="$holder"
      fi
    else
      hold_note=""
    fi

    oc -n "$CP_NS" annotate svc kube-apiserver \
      "metallb.io/address-pool=${API_POOL}" \
      "metallb.io/loadBalancerIPs=${API_VIP}" --overwrite
    oc -n "$CP_NS" patch svc kube-apiserver --type json \
      -p '[{"op":"remove","path":"/spec/loadBalancerIP"}]' >/dev/null 2>&1 || true
    log "annotated ${CP_NS}/kube-apiserver with ${API_POOL} ${API_VIP}"
    state="pinning"
    last_beat=$SECONDS
  fi

  if [[ "$assigned" == "$API_VIP" && "$pool" == "$API_POOL" && "$wanted" == "$API_VIP" ]]; then
    enter ready "kube-apiserver is ${API_VIP}"
  elif [[ "$pool" == "$API_POOL" && "$wanted" == "$API_VIP" ]]; then
    beat "annotation is set; waiting for MetalLB to assign ${API_VIP} (current: ${assigned:-none})"
  fi

  sleep 1
done
