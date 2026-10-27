# Ollama on Proxmox LXC, tuned for Ryzen AI Max+ 395 (Strix Halo / gfx1151)

Passes the Radeon 8060S iGPU into an unprivileged LXC container, installs a ROCm
userspace + Ollama, and then **tests** which GPU settings give correct output on this
chip before pinning one. gfx1151 support is still young, so there is no single
"right" setting that stays right across kernel / ROCm / Ollama versions — the tuner
measures it on your hardware instead.

## Why this design

- **LXC, not a VM.** A container shares the host kernel, so it just gets the
  `/dev/kfd` and `/dev/dri/renderDxxx` device nodes. No VFIO / GPU passthrough.
  The Proxmox host only needs the in-kernel `amdgpu` driver — do not install ROCm
  on the host.
- **"VRAM" is system RAM.** Strix Halo has no dedicated VRAM. How much RAM the GPU
  may address is a *host kernel* setting (`ttm.pages_limit`), handled by script `01`.
- **Official Ollama binaries bundle their own ROCm runtime** which doesn't
  recognise gfx1151, so Ollama is run with `HSA_OVERRIDE_GFX_VERSION` (pretend to be
  a supported RDNA3 chip). Which value is fastest *and correct* changes between
  versions — hence `ollama-tune`.

## Files, in the order you use them

| Script | Runs where | What it does |
|---|---|---|
| `01-host-memory-tuning.sh` | Proxmox host (reboot needed) | Raises the GPU-addressable memory pool (`ttm.pages_limit`), enables IOMMU passthrough mode. Optional but recommended. |
| `02-create-gpu-lxc.sh` | Proxmox host | Creates the unprivileged Ubuntu 24.04 LXC, wires up GPU passthrough, copies in 03/04/05 and runs 03. Also has an `update` mode (below). |
| `03-setup-ollama.sh` | inside the container (run by 02) | Installs ROCm userspace + Ollama, matches device group IDs, installs `ollama-tune` and `ollama-update`, runs the tuner. |
| `04-update-ollama.sh` | installed as `ollama-update` | Checks for a newer Ollama release, installs it, then re-runs the tuner. |
| `05-tune-ollama.sh` | installed as `ollama-tune` | Tests GPU settings for **correct output** and pins the fastest one that passes. |

`02` copies 03/04/05 into the container: from the files next to it if present (a `git clone`),
otherwise it downloads them from this repo's `main` branch on raw.githubusercontent.com.

```bash
git clone https://github.com/MarrakchiAyoub/ollama-strixhalo-lxc.git && cd ollama-strixhalo-lxc
./01-host-memory-tuning.sh      # optional; reboot afterwards
./02-create-gpu-lxc.sh          # edit the variables at the top first (CTID, RAM, disk)
```

(Don't pipe these through `curl | bash` — the prompts need a real terminal.)

## How the tuner decides

For each candidate (`HSA_OVERRIDE_GFX_VERSION` = none, `11.0.0`, `11.5.1`; flash attention
off by default, `--with-flash-attn` adds it) it restarts Ollama and checks:

1. a short question must be answered correctly,
2. a **~5k-token document** with a code hidden in the middle must be answered correctly,
3. the model must be running on the GPU.

Only candidates that pass all three are eligible; the fastest is pinned. If none pass,
nothing new is pinned and it tells you what to try next. The long test exists because
a previous version only timed a short prompt and pinned a configuration that produced
word salad on long prompts.

The tuner uses a small model by default (`llama3.2:3b`). To prove the model you actually
run works, test with it — slower, since it reloads the model per candidate:

```bash
pct exec <CTID> -- ollama-tune --model llama3.1:70b
```

## Settings files

Ollama's settings live in systemd drop-ins in `/etc/systemd/system/ollama.service.d/`:

| File | Owner | Contents |
|---|---|---|
| `00-base.conf` | script 03 | listen address, keep-alive |
| `10-gpu-tuning.conf` | `ollama-tune` | `HSA_OVERRIDE_GFX_VERSION`, `OLLAMA_FLASH_ATTENTION` — regenerated on every tune |
| `20-user.conf` | **you** | e.g. `OLLAMA_CONTEXT_LENGTH` — never overwritten |

Edit `20-user.conf`, then `systemctl daemon-reload && systemctl restart ollama`.

## Keeping Ollama up to date

```bash
./02-create-gpu-lxc.sh update <CTID>        # from the host
pct exec <CTID> -- ollama-update            # or directly
```

`update` first copies the latest `ollama-update` / `ollama-tune` (from your checkout, or from GitHub if
not present) into the container (so containers built from older versions of these scripts get migrated —
stale flash-attention / HSA lines in the old `override.conf` are moved out, with a
backup), then updates Ollama if a newer release exists and re-tunes.
Flags: `--force` (re-tune even if already current), `--skip-benchmark` (update only).
Env: `BENCH_MODEL=<model>`, `WITH_FLASH_ATTN=1`.

To check automatically each week instead, add a systemd timer in the container
(restarts Ollama without asking, so only on a box that isn't in active use):

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

## Troubleshooting

**Garbled / word-salad output, especially on longer prompts.** Reproduce it without any
UI, so you know it's the inference path and not the front-end:

```bash
pct exec <CTID> -- ollama run <model> "Hello"                       # short prompt
pct exec <CTID> -- bash -c '(for i in $(seq 1 300); do echo "The quick brown fox jumps over the lazy dog near the river, sentence $i."; done; echo; echo "Question: which animal jumps over the dog? Answer in one short sentence.") | ollama run <model>'
```

If the short one is fine and the long one is garbage, run `ollama-tune` (add
`--with-flash-attn` and/or `--model <model>`). If no candidate passes: AMD's docs want
Linux ≥ 6.18.4 for stable gfx1151 and Proxmox VE 9.1 ships 6.17 — try a newer opt-in
Proxmox kernel on the host (see the notes printed by script 01).

**Open WebUI sends thousands of hidden tokens for "Hello".** Recent Open WebUI versions
enable *native tool calling* by default and attach built-in tool definitions (web search,
memory, notes, calendar, …) to every request. On a 70B model at ~130 tokens/s prompt
speed that is ~35 s of prompt processing per message, and it makes long-prompt problems
show up immediately. Edit the model → Capabilities → turn off **Builtin Tools** (or set
Function Calling per chat under Chat Controls → Advanced Params). You can confirm by
checking `prompt_eval_count` in the usage data of a chat export — it should be tens of
tokens for "Hello", not thousands. Also in Admin → Settings → Interface, point background
tasks (title / tags / follow-ups / autocomplete) at a small task model or switch them off.

**Speed expectations.** A dense 70B model is memory-bandwidth-bound on this chip:
~5 tokens/s generation is normal. Mixture-of-experts models in the ~30B class are
reported at roughly 40–100 tokens/s.

## Sources

- [Proxmox forum: Run LLMs using AMD GPU and ROCm in unprivileged LXC](https://forum.proxmox.com/threads/tutorial-run-llms-using-amd-gpu-and-rocm-in-unprivileged-lxc-container.157920/)
- [AMD ROCm docs: Strix Halo system optimization](https://rocm.docs.amd.com/en/docs-7.2.0/how-to/system-optimization/strixhalo.html)
- [Jeff Geerling: Increasing the VRAM allocation on AMD AI APUs under Linux](https://www.jeffgeerling.com/blog/2025/increasing-vram-allocation-on-amd-ai-apus-under-linux/)
- [llama.cpp discussion #20856: Known-good Strix Halo ROCm stack](https://github.com/ggml-org/llama.cpp/discussions/20856)
- [llm-tracker.info: Strix Halo](https://llm-tracker.info/_TOORG/Strix-Halo)
- [ollama/ollama #14855: Strix Halo (gfx1151) ROCm working guide](https://github.com/ollama/ollama/issues/14855)
- [Ollama context length docs](https://docs.ollama.com/context-length)
- [Open WebUI tools docs (native vs legacy function calling)](https://docs.openwebui.com/features/extensibility/plugin/tools.md)
