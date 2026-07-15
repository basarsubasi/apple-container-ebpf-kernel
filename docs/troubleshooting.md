# Troubleshooting

The traps that actually cost time when building this kernel, and how to get past
them.

## BTF silently doesn't appear

`CONFIG_DEBUG_INFO_BTF=y` only sticks if a three-link chain is satisfied, and
`make olddefconfig` drops it **without any error or warning** if it isn't:

1. `DEBUG_INFO` is a *choice* (DWARF4 / DWARF5 / NONE), not a bool. You must
   select a DWARF variant — the overlay sets `CONFIG_DEBUG_INFO_DWARF5=y`.
2. arm64 `defconfig` ships `CONFIG_DEBUG_INFO_REDUCED=y`, which is mutually
   exclusive with BTF. The overlay disables it
   (`# CONFIG_DEBUG_INFO_REDUCED is not set`).
3. Only with both of the above does `CONFIG_DEBUG_INFO_BTF=y` survive.

**Always** `grep -x CONFIG_DEBUG_INFO_BTF=y .config` after `olddefconfig`.
`build-kernel.sh` does this and aborts if it fails.

You also need `pahole` (Debian package `dwarves`) installed at build time, or the
DWARF→BTF step is skipped.

## struct_ops targets disappear together

`CONFIG_SCHED_CLASS_EXT` (sched_ext) and `CONFIG_NET_SCH_BPF` (BPF qdisc) both
depend on BTF. If BTF drops (above), both drop with it and the failure looks like
"sched_ext isn't in my kernel" rather than "BTF is missing". Fix BTF first, then
re-check these.

## The BPF LSM loads but never fires; fmod_ret won't attach

Two separate causes:

- **`bpf` isn't in the active `lsm=` list.** The VM runtime passes its own `lsm=`
  on the kernel command line, which overrides `CONFIG_LSM` and does not include
  `bpf` by default. On arm64 there is no `CMDLINE_EXTEND` (only
  `FROM_BOOTLOADER` or `FORCE`), so the only way to add `bpf` is to **force the
  entire command line** with `,bpf` appended to `lsm=`. The overlay does this via
  `CONFIG_CMDLINE_FORCE=y` + `CONFIG_CMDLINE="…"`.
- **No `fmod_ret`-able targets.** `fmod_ret` needs
  `CONFIG_FUNCTION_ERROR_INJECTION=y` (plus `CONFIG_BPF_KPROBE_OVERRIDE=y`) for
  there to be any attachable functions.

Confirm it worked: `/sys/kernel/security/lsm` should list `bpf`. The runtime does
not mount securityfs, so that file does not exist until you mount it yourself —
which needs `CAP_SYS_ADMIN`:

```sh
container run --rm --cap-add SYS_ADMIN docker.io/library/debian:trixie sh -c \
  'mount -t securityfs securityfs /sys/kernel/security && cat /sys/kernel/security/lsm'
# -> capability,landlock,bpf
```

`verify-kernel.sh` does this for you. Note the list only ever contains LSMs that
are actually built in, so it is a subset of the `lsm=` you forced on the command
line — `bpf` being there is the thing to check, not an exact match.

### Forcing the command line can brick the boot

`CONFIG_CMDLINE_FORCE` bakes a fixed command line into the image. If it doesn't
match what the runtime expects (wrong `init=`, `root=`, `console=`, …), the guest
won't boot. Before building:

```sh
container exec <some-running-container> cat /proc/cmdline
```

Copy that string verbatim into `CONFIG_CMDLINE`, changing only `lsm=` to append
`,bpf`. If a runtime upgrade later changes the command line, rebuild with the new
one. If you don't need the BPF LSM at all, delete the two `CMDLINE` lines from the
overlay and avoid the risk entirely.

**Do not read `/proc/cmdline` back from the forced kernel to check this.** Once
`CONFIG_CMDLINE_FORCE` is in effect the kernel ignores what the runtime passed and
reports `CONFIG_CMDLINE` verbatim, so the check becomes circular: it will happily
echo a string that no longer matches the runtime. Read it *before* switching (the
stock kernel does not force anything), or point the runtime at a non-forcing
kernel first:

```sh
container system kernel set --binary <stock-or-kata-kernel> --arch arm64 --force
container system stop && container system start --disable-kernel-install
container run --rm docker.io/library/debian:trixie cat /proc/cmdline   # the real one
```

then put your own kernel back the same way. The versions this was last checked
against are in the README's "Verified with" table.

## `tar` fails extracting the kernel source

Extracting `linux-X.Y.Z.tar.xz` onto a bind-mounted (virtiofs) directory throws
permission errors on the selftest symlinks. Extract inside the container
filesystem (e.g. `/root/build`) and copy only the finished `Image` out to the
mount.

## My new kernel "didn't take"

The kernel set applies to **new** `container run` instances only — existing
containers keep the kernel they snapshotted when the runtime started. Start a
fresh container to test, and restart the runtime with
`container system start --disable-kernel-install` so it keeps your kernel instead
of installing an official one.

Prefer `container system kernel set --binary <Image>` (a raw image) over the
`--tar` form, which has had issues with compressed/relative-path archives.

## netem says "unavailable" in verify

`tc qdisc … netem …` needs `CAP_NET_ADMIN`, which `verify-kernel.sh` does not add
(it only takes `SYS_ADMIN`, to mount securityfs). Test netem explicitly:

```sh
container run --rm --cap-add NET_ADMIN docker.io/library/debian:trixie sh -c \
  'tc qdisc add dev lo root netem loss 5% && tc qdisc del dev lo root && echo netem-ok'
```

(The container image also needs `iproute2` for `tc`.)
