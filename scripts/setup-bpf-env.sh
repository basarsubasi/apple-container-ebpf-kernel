#!/usr/bin/env sh
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Mount tracefs, securityfs, and bpffs so BPF programs can attach to
# tracepoints and pin maps.  Run this inside the container *before* loading
# any BPF programs that use tracepoints, kprobes, or map pinning.
#
# Requires SYS_ADMIN capability (or --cap-add ALL).
set -euo pipefail

# tracefs — required for tracepoint-based BPF program attachment
if mountpoint -q /sys/kernel/tracing 2>/dev/null; then
  echo "tracefs:    already mounted"
elif [ -d /sys/kernel/tracing ]; then
  mount -t tracefs tracefs /sys/kernel/tracing
  echo "tracefs:    mounted"
else
  echo "tracefs:    FAILED — /sys/kernel/tracing not found" >&2
  exit 1
fi

# bpffs — required for BPF map pinning (pinning to /sys/fs/bpf/...)
if mountpoint -q /sys/fs/bpf 2>/dev/null; then
  echo "bpffs:      already mounted"
elif [ -d /sys/fs/bpf ]; then
  mount -t bpf bpf /sys/fs/bpf
  echo "bpffs:      mounted"
else
  echo "bpffs:      FAILED — /sys/fs/bpf not found" >&2
  exit 1
fi
