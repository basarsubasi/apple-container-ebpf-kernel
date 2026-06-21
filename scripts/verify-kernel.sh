#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Verify the currently installed kernel has the eBPF feature set. Run on the
# macOS host; it spawns a throwaway container on the active kernel.
#
# Tunables:
#   IMAGE   container image to probe with (default debian:trixie)
set -euo pipefail

IMAGE="${IMAGE:-docker.io/library/debian:trixie}"

container run --rm "$IMAGE" sh -c '
  set -e
  echo "uname:     $(uname -r)"

  if [ -s /sys/kernel/btf/vmlinux ]; then
    echo "BTF:       present ($(wc -c </sys/kernel/btf/vmlinux) bytes)"
  else
    echo "BTF:       MISSING"
  fi

  if [ -d /sys/kernel/sched_ext ]; then
    echo "sched_ext: present"
  else
    echo "sched_ext: MISSING"
  fi

  # The active LSM list; shows "bpf" only if the forced cmdline took effect.
  echo "lsm:       $(cat /sys/kernel/security/lsm 2>/dev/null || echo "(securityfs not mounted)")"

  if ! command -v bpftool >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq bpftool >/dev/null 2>&1 || true
  fi
  if command -v bpftool >/dev/null 2>&1; then
    echo "struct_ops in BTF:"
    bpftool btf dump file /sys/kernel/btf/vmlinux format c 2>/dev/null \
      | grep -oE "bpf_struct_ops_(sched_ext_ops|Qdisc_ops|tcp_congestion_ops)" \
      | sort -u | sed "s/^/  /" || echo "  (none found)"
  fi
'
echo ">>> netem needs CAP_NET_ADMIN; check it manually with:"
echo "    container run --rm --cap-add NET_ADMIN $IMAGE sh -c 'tc qdisc add dev lo root netem loss 5% && tc qdisc del dev lo root && echo netem-ok'"
