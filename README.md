# Ollama on Proxmox LXC, tuned for Ryzen AI Max+ 395 (Strix Halo / gfx1151)

Your community-script LXC was almost certainly running Ollama on **CPU only**,
copying the whole model into container RAM and grinding through it with no
GPU acceleration at all — that's the "uses tons of RAM and is still slow"
symptom. These scripts fix that by passing the Radeon 8060S iGPU straight
into an unprivileged LXC container and installing a ROCm build that actually
targets `gfx1151` (Strix Halo's GPU ISA), plus an auto-tuning step, because
the correct config for this specific chip is still a moving target across
kernel/ROCm/Ollama versions.

## Why this needs a custom approach

Strix Halo has no dedicated VRAM — it carves "VRAM" out of your system RAM
(GTT/unified memory), and `gfx1151` support is very recent and still rough
around the edges in the AMD/Ollama software stack:

- Official Ollama release binaries **bundle their own minimal ROCm runtime**
  and, as of this writing, that bundled runtime doesn't recognize `gfx1151`.
  It works anyway once you set `HSA_OVERRIDE_GFX_VERSION` to make Ollama
  treat the GPU as an older, already-supported RDNA3 chip (`gfx1100`).
  Confusingly, several independent benchmarks show the **spoofed gfx1100
  path is currently faster** than the "correct" native gfx1151 kernels
  because AMD's gfx1151 kernels are still under-optimized. There is no
  single "right" override value that stays right for long, so script `03`
  benchmarks a few candidates on your actual hardware and keeps the fastest
  one that's actually confirmed to run on GPU (not silently falling back to
  CPU).
- LXC (not a VM) is the correct container type here: since an LXC shares the
  host kernel, you just hand it the `/dev/kfd` and `/dev/dri/renderDxxx`
  device nodes — no VFIO/IOMMU GPU passthrough, no splitting the GPU away
  from the host, no reserving a PCIe device. This is also why a VM-based
  approach (GPU passthrough to a VM) is not what you want here: an iGPU
  can't easily be split from the host GPU driver, but LXC device sharing
  works because host and container both use the one `amdgpu` kernel driver.
- The amount of RAM the GPU can actually use is controlled by a **host
  kernel parameter** (`ttm.pages_limit` / the old `amdgpu.gttsize` is
  deprecated), not anything inside the container. That's script `01`, and
  it's optional/separate because it edits the bootloader and needs a host
  reboot.

## Files, and the order to run them

| Script | Runs where | Reboots host? | What it does |
|---|---|---|---|
| `01-host-memory-tuning.sh` | Proxmox host, as root | Yes (you choose when) | Checks host kernel version, raises the GTT/TTM memory pool so the GPU can address more of your RAM as "VRAM", enables IOMMU passthrough mode. **Optional but recommended** — skip it and the GPU is capped at whatever your BIOS's small default UMA/VRAM split allows. |
| `02-create-gpu-lxc.sh` | Proxmox host, as root | No | Creates an unprivileged Ubuntu 24.04 LXC, detects your GPU's actual device nodes/GIDs, wires up `/dev/kfd` + `/dev/dri/renderDxxx` passthrough, starts the container, and hands off to script 03 automatically. |
| `03-setup-ollama.sh` | Auto-copied into the container and run by script 02 (or run manually inside the CT later) | No | Installs ROCm userspace libs (not the kernel driver — the host already has that), installs Ollama, matches container groups to the host's device GIDs, then **benchmarks a few `HSA_OVERRIDE_GFX_VERSION` candidates on a tiny model** and keeps whichever one is both fastest and confirmed running on GPU. Also installs the `ollama-update` command (script 04) into the container. |
| `04-update-ollama.sh` | Auto-copied in by script 02/03, ends up installed inside the container as `/usr/local/bin/ollama-update` | No | Checks whether a newer Ollama release exists; if so, installs it, restarts the service, and **re-runs the same benchmark** (a new Ollama build can ship an updated bundled ROCm runtime, which can change which override value wins). |

Run them in order: `01` (optional, reboot when it tells you to), then `02`
(which calls `03` for you at the end, and `03` installs `04` as the
`ollama-update` command). You can re-run `03` by itself later — inside the
container — any time you want to redo the full setup.

## Keeping Ollama up to date

Once the container is built, check for a newer Ollama release any time with
whichever of these is convenient:

```bash
# from the Proxmox host
./02-create-gpu-lxc.sh update <CTID>          # e.g. ./02-create-gpu-lxc.sh update 900

# or directly
pct exec <CTID> -- ollama-update
```

If a new version is out, it installs it, restarts the service, and
re-benchmarks the `HSA_OVERRIDE_GFX_VERSION` candidates (since a new build
can change which one is fastest / actually GPU-backed), then re-pins the
winner. If you're already current, it does nothing. Useful flags:

```bash
pct exec <CTID> -- ollama-update --force            # re-benchmark even if already current
pct exec <CTID> -- ollama-update --skip-benchmark    # just bump the version, skip re-tuning
```

If you want this to happen automatically instead of on-demand, add a weekly
systemd timer inside the container:

```bash
pct exec <CTID> -- bash -c 'cat > /etc/systemd/system/ollama-update.service <<EOF
[Unit]
Description=Check for and apply Ollama updates
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ollama-update
EOF
cat > /etc/systemd/system/ollama-update.timer <<EOF
[Unit]
Description=Weekly Ollama update check
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl enable --now ollama-update.timer'
```

This isn't set up by default because it restarts the Ollama service (and
briefly interrupts any in-progress inference) without asking — fine for a
homelab box, worth knowing about before enabling on something in active use.

## Before you run anything

1. Edit the variables block at the top of `02-create-gpu-lxc.sh` (container
   ID, hostname, disk size, how much RAM to give the container). Defaults
   assume a 128GB unified-memory board and leave ~16GB for Proxmox itself —
   adjust `MEMORY_GB` if your board has a different amount of RAM.
2. In the BIOS, set the **dedicated VRAM/UMA reservation as small as
   possible** (e.g. 512MB–1GB) rather than a big fixed split. We want Linux,
   via `ttm.pages_limit` in script `01`, to control the GPU-addressable pool
   dynamically instead of a static BIOS carve-out — that's the setting that
   was likely capping/starving your original attempt.
3. Copy both scripts onto the Proxmox host (e.g. `scp` them to
   `/root/`), `chmod +x` them, and read through them once — they modify
   system config (bootloader, LXC config) and should not be run blind.

## Verifying it worked

Script `03` prints a summary table at the end, but you can re-check anytime
from inside the container:

```bash
pct exec <CTID> -- rocminfo | grep -A2 gfx        # GPU should be listed
pct exec <CTID> -- ollama ps                       # PROCESSOR column should say "100% GPU"
pct exec <CTID> -- ollama run llama3.2:1b "hello"  # should feel fast (~40-100+ tok/s range for small models, not the crawl you had before)
```

If `ollama ps` ever shows `100% CPU` again after a future Ollama/ROCm
update, re-run `03-setup-ollama.sh` inside the container to re-benchmark and
re-pin the override.

## Known trade-offs / things that may need hand-tuning

- **Kernel version matters a lot.** AMD's own docs want Linux ≥6.18.4 for
  fully stable `gfx1151` KFD behavior; Proxmox VE 9.1+ ships 6.17 by
  default. Script `01` checks and tells you if there's a newer opt-in
  Proxmox kernel (e.g. `pve-kernel-7.0`) worth switching to. This is a
  fast-moving target — if things are flaky, checking for a newer opt-in PVE
  kernel is often the fix.
- **Long context (100K+ tokens)** can be memory-hungry and occasionally
  unstable on this stack per current community reports. If you plan to run
  very long contexts, keep an eye on `journalctl -u ollama -f` for crashes
  and consider capping `num_ctx`.
- **Vulkan is a viable alternative backend** for short-context workloads —
  some benchmarks show Vulkan (via `llama.cpp`'s RADV path) beating ROCm on
  prompt processing, while ROCm+rocWMMA wins on long-context generation.
  This setup uses ROCm because it's what Ollama supports natively; if you
  want to experiment with Vulkan-backed `llama.cpp` as well, that's a
  separate, non-ROCm build — ask and I can put together a script for that
  too.

## Sources used while building this

- [Proxmox forum: Tutorial — Run LLMs using AMD GPU and ROCm in unprivileged LXC container](https://forum.proxmox.com/threads/tutorial-run-llms-using-amd-gpu-and-rocm-in-unprivileged-lxc-container.157920/)
- [AMD ROCm docs: Strix Halo system optimization](https://rocm.docs.amd.com/en/docs-7.2.0/how-to/system-optimization/strixhalo.html)
- [Jeff Geerling: Increasing the VRAM allocation on AMD AI APUs under Linux](https://www.jeffgeerling.com/blog/2025/increasing-vram-allocation-on-amd-ai-apus-under-linux/)
- [llama.cpp discussion #20856: Known-Good Strix Halo ROCm + llama.cpp stack](https://github.com/ggml-org/llama.cpp/discussions/20856)
- [llm-tracker.info: Strix Halo](https://llm-tracker.info/_TOORG/Strix-Halo)
- [ollama/ollama issue #14855: AMD Strix Halo (gfx1151) ROCm Working Guide](https://github.com/ollama/ollama/issues/14855)
- [MaxusAI/ryzen-ai-max-rocm-ollama-testbench](https://github.com/MaxusAI/ryzen-ai-max-rocm-ollama-testbench)
- [Proxmox VE Kernel wiki](https://pve.proxmox.com/wiki/Proxmox_VE_Kernel)
