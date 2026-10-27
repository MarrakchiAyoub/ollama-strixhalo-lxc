# Ollama on Proxmox LXC, tuned for Ryzen AI Max+ 395 (Strix Halo / gfx1151)

Your community-script LXC was almost certainly running Ollama on **CPU only**,
copying the whole model into container RAM and grinding through it with no
GPU acceleration at all — that's the "uses tons of RAM and is still slow"
symptom. These scripts fix that by passing the Radeon 8060S iGPU straight
into an unprivileged LXC container and running Ollama on its **Vulkan**
backend, because the correct config for this specific chip (`gfx1151`) is
still a moving target across kernel/ROCm/Ollama versions.

## Why this needs a custom approach

Strix Halo has no dedicated VRAM — it carves "VRAM" out of your system RAM
(GTT/unified memory), and `gfx1151` support is very recent and still rough
around the edges in the AMD/Ollama software stack:

- **Ollama's ROCm backend corrupts long prompts on `gfx1151`** (tested with
  Ollama 0.32.5, ROCm 7.2, Proxmox kernel 6.17). Short prompts are fine, but
  anything past a few thousand tokens turns into word salad, on every model
  size tried (8B and 70B), with flash attention on or off. The **Vulkan**
  backend (Mesa RADV) gives correct output, so script `03` configures
  Ollama to use it. Trade-offs: roughly 45% slower prompt processing than
  ROCm, and the GPU can address ~64 GiB through Vulkan instead of ~107 GiB.
  Revisit ROCm after a host kernel upgrade (see "Known trade-offs").
- **Always set a context length.** Left on auto, Ollama picks the model's
  full 131072 context for llama3.1, which needs a ~40 GB KV cache, doesn't
  fit in the GPU, and crashes the driver (`ErrorDeviceLost`). Script `03`
  sets 32768 in `20-user.conf`.
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
| `03-setup-ollama.sh` | Auto-copied into the container and run by script 02 (or run manually inside the CT later) | No | Installs the ROCm userspace libs (not the kernel driver — the host already has that) and the Mesa Vulkan driver, installs Ollama, matches container groups to the host's device GIDs, and configures Ollama for the **Vulkan backend** with a fixed context length (see "Settings files"). Also installs the `ollama-update` command (script 04) into the container. |
| `04-update-ollama.sh` | Auto-copied in by script 02/03, ends up installed inside the container as `/usr/local/bin/ollama-update` | No | Checks whether a newer Ollama release exists; if so, installs it and restarts the service. Your settings files are left alone. |

Run them in order: `01` (optional, reboot when it tells you to), then `02`
(which calls `03` for you at the end, and `03` installs `04` as the
`ollama-update` command). You can re-run `03` by itself later — inside the
container — any time you want to redo the full setup.

## Settings files

Ollama's settings live in systemd drop-ins in `/etc/systemd/system/ollama.service.d/`:

| File | Owner | Contents |
|---|---|---|
| `00-base.conf` | script 03 (rewritten on each run) | listen address, keep-alive |
| `10-gpu.conf` | script 03 (rewritten on each run) | `OLLAMA_LLM_LIBRARY=vulkan`, `OLLAMA_IGPU_ENABLE=1`, `OLLAMA_FLASH_ATTENTION=0` |
| `20-user.conf` | **you** (created once, never overwritten) | `OLLAMA_CONTEXT_LENGTH` and anything else you want |

Edit `20-user.conf`, then `systemctl daemon-reload && systemctl restart ollama`.
A leftover `override.conf` from an older version of these scripts is moved aside
(to `override.conf.bak-<timestamp>`) when you re-run `03`, because it sorts after
the files above and would override them.

**Already have a container built with the old scripts?** Re-run `03` inside it
(copy the latest one in with `pct push`, then `pct exec <CTID> -- bash /root/03-setup-ollama.sh`).
Your models are kept.

## Keeping Ollama up to date

Once the container is built, check for a newer Ollama release any time with
whichever of these is convenient:

```bash
# from the Proxmox host
./02-create-gpu-lxc.sh update <CTID>          # e.g. ./02-create-gpu-lxc.sh update 900

# or directly
pct exec <CTID> -- ollama-update
```

If a new version is out, it installs it and restarts the service. If you're
already current, it does nothing. Useful flag:

```bash
pct exec <CTID> -- ollama-update --force            # reinstall even if already current
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

Script `03` prints the settings it wrote and warns if it can't confirm the
Vulkan backend, but you can re-check anytime from the host:

```bash
pct exec <CTID> -- vulkaninfo --summary                              # should list the Radeon 8060S (RADV)
pct exec <CTID> -- bash -c "journalctl -u ollama --no-pager | grep 'inference compute' | tail -1"   # should say library=Vulkan
pct exec <CTID> -- ollama ps                                         # PROCESSOR column should say "100% GPU"
pct exec <CTID> -- ollama run llama3.2:1b "hello"                    # should feel fast
```

If `ollama ps` shows `100% CPU` or the journal doesn't say `library=Vulkan`,
check that `20-user.conf`/`10-gpu.conf` are intact and that
`OLLAMA_IGPU_ENABLE=1` is set — without it Ollama silently ignores the iGPU.

## Troubleshooting

**Garbled / word-salad output on longer prompts.** Reproduce it without any UI:

```bash
pct exec <CTID> -- ollama run <model> "Hello"                       # short prompt
pct exec <CTID> -- bash -c '(for i in $(seq 1 300); do echo "The quick brown fox jumps over the lazy dog near the river, sentence $i."; done; echo; echo "Question: which animal jumps over the dog? Answer in one short sentence.") | ollama run <model>'
```

If the short one is fine and the long one is garbage, Ollama is on the ROCm
backend: check `10-gpu.conf` and that no other drop-in overrides
`OLLAMA_LLM_LIBRARY`.

**Open WebUI sends thousands of hidden tokens for "Hello".** Recent Open WebUI
versions enable *native tool calling* and attach built-in tool definitions to
every request (~5k tokens in one export), which at Vulkan prompt speeds
(~70 tokens/s on a 70B) costs about a minute per message and makes any
long-prompt problem show up immediately. Edit the model → Capabilities → turn
off **Builtin Tools**. You can confirm with `prompt_eval_count` in the usage
data: it should be tens of tokens for "Hello", not thousands.

**Model crashes at load or the driver dies (`ErrorDeviceLost`).** Usually the
context is too large for the ~64 GiB the GPU can address through Vulkan.
Lower `OLLAMA_CONTEXT_LENGTH` in `20-user.conf`.

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
- **This setup uses Vulkan, not ROCm,** because Ollama's ROCm backend produced
  garbled output on long prompts here (see "Why this needs a custom
  approach"). If you upgrade the host kernel (≥ 6.18.4), ROCm may work again;
  to test it, remove the `OLLAMA_LLM_LIBRARY` line from `10-gpu.conf` and run
  the long-prompt repro under "Troubleshooting" before relying on it.

## Sources used while building this

- [Proxmox forum: Tutorial — Run LLMs using AMD GPU and ROCm in unprivileged LXC container](https://forum.proxmox.com/threads/tutorial-run-llms-using-amd-gpu-and-rocm-in-unprivileged-lxc-container.157920/)
- [AMD ROCm docs: Strix Halo system optimization](https://rocm.docs.amd.com/en/docs-7.2.0/how-to/system-optimization/strixhalo.html)
- [Jeff Geerling: Increasing the VRAM allocation on AMD AI APUs under Linux](https://www.jeffgeerling.com/blog/2025/increasing-vram-allocation-on-amd-ai-apus-under-linux/)
- [llama.cpp discussion #20856: Known-Good Strix Halo ROCm + llama.cpp stack](https://github.com/ggml-org/llama.cpp/discussions/20856)
- [llm-tracker.info: Strix Halo](https://llm-tracker.info/_TOORG/Strix-Halo)
- [ollama/ollama issue #14855: AMD Strix Halo (gfx1151) ROCm Working Guide](https://github.com/ollama/ollama/issues/14855)
- [MaxusAI/ryzen-ai-max-rocm-ollama-testbench](https://github.com/MaxusAI/ryzen-ai-max-rocm-ollama-testbench)
- [Proxmox VE Kernel wiki](https://pve.proxmox.com/wiki/Proxmox_VE_Kernel)
