# apple-container-ebpf-kernel

Build a custom Linux kernel with a **full eBPF feature set** and run it under
[Apple `container`](https://github.com/apple/container) on Apple Silicon macOS.

Apple `container` (and most off-the-shelf macOS Linux VMs) ship a kernel that is
missing the pieces serious eBPF work needs — no BTF, no `sched_ext`, no
`struct_ops` qdisc, sometimes no `kprobes`/`uprobes` at all. This repo is a small
config overlay plus three scripts that build a stock Linux stable kernel
(currently **7.1.1**, arm64) with all of that turned on, and install it into the
`container` runtime.

## What you get

A kernel with, verified present:

- **BTF** (`/sys/kernel/btf/vmlinux`) — required for CO-RE and `struct_ops`.
- **BPF `struct_ops`** targets: `sched_ext` (CPU schedulers in BPF), BPF qdisc
  (`Qdisc_ops`, Linux 7.0+), and TCP congestion ops.
- The **BPF JIT** (always-on) and `BPF_SYSCALL`/`BPF_EVENTS`.
- The full **tracing stack**: kprobes, kretprobes, uprobes, fprobe, ftrace,
  tracepoints, syscall tracepoints.
- **netem** packet impairment (`tc qdisc … netem loss/delay …`) for latency and
  loss testing, plus the common classful qdiscs and BPF/u32 classifiers.
- The **BPF LSM** with `fmod_ret` error injection (so `SEC("lsm/<hook>")` and
  `fmod_ret` programs actually fire — see the cmdline caveat below).
- **AF_XDP** socket maps (`XSKMAP`/`DEVMAP`) so `xsk_redirect` programs load.

The exact set is in [`config/ebpf-overlay.conf`](config/ebpf-overlay.conf), which
is heavily commented with the rationale and the dependency gotchas.

## Requirements

- Apple Silicon Mac running macOS.
- [Apple `container`](https://github.com/apple/container) (`brew install container`).
- ~15 GB free disk and a few minutes (a full build is ~6 minutes on an M-series
  with 8 jobs).
- The kernel itself is built **inside a Linux/arm64 build container**
  (`debian:trixie`); you do not need a cross-toolchain on the host.

## Quick start

```sh
# 0. clone this repo somewhere, e.g. ~/apple-container-ebpf-kernel
cd ~/apple-container-ebpf-kernel

# 1. launch a long-lived build container with this repo mounted at /work
container run -d --name kbuild --cap-add ALL -c 8 -m 8G \
  --mount type=bind,source="$PWD",target=/work \
  -w /work docker.io/library/debian:trixie sleep infinity

# 2. build the kernel (downloads the kernel source + kata config fragments,
#    merges the overlay, builds arch/arm64/boot/Image)
container exec kbuild /work/scripts/build-kernel.sh
#    -> writes /work/output/Image-7.1.1-ebpf

# 3. install it into the runtime (host side) and restart keeping the kernel
./scripts/install-kernel.sh ./output/Image-7.1.1-ebpf
container system start --disable-kernel-install

# 4. verify the feature set on a throwaway container
./scripts/verify-kernel.sh
```

Expected `verify-kernel.sh` output (abridged):

```
uname:     7.1.1-ebpf
BTF:       present (9672773 bytes)
sched_ext: present
lsm:       lockdown,capability,landlock,yama,apparmor,bpf
struct_ops in BTF:
  bpf_struct_ops_Qdisc_ops
  bpf_struct_ops_sched_ext_ops
  bpf_struct_ops_tcp_congestion_ops
```

## How it works

The build is a three-way config merge:

```
arm64 defconfig
  + kata-containers config fragments   (virtio drivers, ext4, the boot console,
  |                                      everything needed to boot under the VM)
  + config/ebpf-overlay.conf           (this repo: BTF + struct_ops + tracing +
                                         netem + BPF LSM + AF_XDP)
  -> merge_config.sh -> olddefconfig -> make Image
```

The kata fragments supply the drivers and boot expectations that make the kernel
bootable inside the lightweight VM; the overlay layers the eBPF capabilities on
top. `build-kernel.sh` fetches both, runs the merge, **asserts the eBPF
essentials survived `olddefconfig`** (it silently drops options with unmet
dependencies), and builds the image.

Installation uses `container system kernel set --binary … --force`. Using
`--binary` (a raw `Image`) avoids known issues with the `--tar` path.

## Repo layout

```
config/ebpf-overlay.conf   the eBPF Kconfig overlay (the core of this repo)
scripts/build-kernel.sh    build the Image inside a debian:trixie container
scripts/install-kernel.sh  install the Image into Apple container (host)
scripts/verify-kernel.sh   probe the running kernel for the feature set (host)
docs/build-workflow.md     the end-to-end build, in detail
docs/troubleshooting.md    the dependency traps and boot pitfalls
```

## Important caveats

- **The new kernel only affects new `container run` instances.** Existing
  containers snapshot their kernel when the runtime starts.
- **The BPF LSM needs a forced kernel command line.** arm64 has no
  `CMDLINE_EXTEND`, so to add `bpf` to the active `lsm=` list the overlay
  `CONFIG_CMDLINE_FORCE`s the *entire* command line. That string must match what
  your runtime actually boots with. **Verify it first**:
  `container exec <some-container> cat /proc/cmdline`, then make
  `CONFIG_CMDLINE` in the overlay match it exactly (only adding `,bpf`). A stale
  forced command line will prevent the guest from booting. If you do not need the
  BPF LSM, delete the two `CMDLINE` lines from the overlay.
- See [`docs/troubleshooting.md`](docs/troubleshooting.md) for the BTF dependency
  chain and other traps.

## Bumping the kernel version

The overlay is version-independent. To build a newer stable release, pass `KVER`:

```sh
container exec kbuild env KVER=7.2.0 /work/scripts/build-kernel.sh
```

Patch-level bumps reuse the same overlay via `olddefconfig` with no changes.

## License

MIT — see [LICENSE](LICENSE). The config overlay references upstream Linux
Kconfig symbols; the Linux kernel itself is GPLv2 and is downloaded at build
time, not redistributed here.
