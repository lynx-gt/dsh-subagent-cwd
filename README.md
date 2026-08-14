# dsh-subagent-cwd

Enhanced subagent delegation tools for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh)
**with per-call working-directory control**.

Everything in [dsh-subagent-tools](https://github.com/lynx-gt/dsh-subagent-tools) (per-call model / provider /
persona / toolFilter overrides, `@preset:` references, `provider/model` composite ids) **plus** a per-call
`cwd` parameter — shipped with the two small provider patches that make `cwd` actually work.

| [English](README.md) | [中文](README.zh.md) |

[![awesome · DSH plugin](https://awesome-dsh-plugin.com/badge.svg)](https://awesome-dsh-plugin.com)

## Choose one of the two packages — not both

| Package | Per-call model/provider/persona/toolFilter | `@preset:` | `cwd` | Patches |
|---|---|---|---|---|
| **dsh-subagent-tools** | ✅ | ✅ | ❌ | **none (bundle only)** |
| **dsh-subagent-cwd** (this) | ✅ | ✅ | ✅ | 2 provider patches |

Install **either** one. Both expose the same tool surface (`subagent` / `subagent_fork`) and colliding
installations would fight over the tool names.

## Why cwd needs patches (and the other features don't)

`SubagentStartRequest` has **no cwd field**, and the in-process drive layer builds child session meta purely
from `childSessionMeta(parent, ...)` — a per-call cwd is never forwarded. Two code paths create in-process
children, and **both** must be patched or you hit the classic trap where the foreground path honors `cwd`
while the background path silently ignores it:

| Path | Package to patch | File |
|---|---|---|
| Foreground (one-shot) | `@deepseek-ai/dsh-subagent-in-process-driver` | `lib/index.js` |
| Background (continuable) | `@deepseek-ai/dsh-subagent` | **`lib/index.js` (the BUNDLE — not `lib/types/continuation.js`!)** |

The second one is a bundle trap: `package.json` main/exports point at `lib/index.js`, which contains an
inline copy of the continuation manager. Patching the source-shaped `lib/types/continuation.js` has **no
effect** — always patch and verify the bundle.

## Installation

```sh
# 1. install the plugin (npm / git / local)
dsh plugin --profile web add dsh-subagent-cwd

# 2. apply the two provider patches (required for `cwd`)
powershell -ExecutionPolicy Bypass -File patches\install.ps1    # Windows
# or: ./patches/install.sh                                       # POSIX

# 3. Web sessions: also run the preset adapter (see below)
powershell -ExecutionPolicy Bypass -File install-preset.ps1     # Windows
# or: ./install-preset.sh                                       # POSIX
```

Restart `dsh --profile web` and start a NEW session.

### Web sessions need the preset adapter

In the **web** profile, agent tools are provided by the mounted agent **preset**
(the default `standard` preset composes `subagent` / `subagent_fork` pointing at
`@deepseek-ai/dsh-tool-subagent`), **not** by the host plane — a bundle patch is
invisible to Web sessions. `install-preset.ps1` / `install-preset.sh` copies
`standard` to `$DSH_HOME/.agent-presets/standard-plus`, rewrites its delegation
rows to point at this package, and switches the default preset. Presets are read
at session creation, so you must start a NEW session (live sessions cannot
switch). Revert: pick `standard` in the UI (General > Agent preset) and delete
`standard-plus`.

> `headless` and other non-web profiles do not need the preset adapter.

### Upgrading dsh

A dsh upgrade rewrites `node_modules` and **wipes both patches**. After every upgrade:

```sh
# re-run the installer (it is idempotent; it also detects version-mismatched anchors)
powershell -ExecutionPolicy Bypass -File patches\install.ps1
```

If the installer reports "anchor not found", the target packages changed shape — check for a new
dsh-subagent-cwd release or file an issue.

### Uninstall

```sh
powershell -ExecutionPolicy Bypass -File patches\uninstall.ps1   # Windows
# or: ./patches/uninstall.sh                                     # POSIX
dsh plugin --profile web remove dsh-subagent-cwd
```

## Example

```
Let a subagent work in a directory without the repo's AGENTS.md injected:
  subagent(description="Summarize this file", prompt="...", cwd="D:\\projects\\scratch\\notes")
```

## Design

- **The tool surface is a bundle.** The shipped `tool-subagent` /
  `tool-subagent-fork` rows are disabled and replaced by this package's rows;
  no official package file is modified for the tool surface itself.
- **`cwd` is the one capability that cannot stay a bundle-only feature.**
  `SubagentStartRequest` has no cwd field, so a per-call cwd must be forwarded
  by the in-process subagent providers. That needs the two small patches (one
  hunk each) in `patches/` — idempotent, backed up on first run, and
  `node --check`-verified. This is the entire reason this package exists
  separately from `dsh-subagent-tools`.
- **Version contract:** `peerDependencies` pin the public dsh packages
  (`^0.1.0-rc.6`). The patches target the same version; a dsh upgrade rewrites
  the dsh installation's `node_modules` and **wipes both patches** — re-run
  `patches/install.ps1` / `install.sh` after every upgrade (see *Upgrading dsh*).
  The bundle itself lives in the profile's own `node_modules` and survives an
  upgrade, but a changed public API will make `peerDependencies` refuse to load.

## Verified

Tested against a stock dsh `0.1.0-rc.6` install on Windows (headless + web):

- Everything `dsh-subagent-tools` verifies (per-call model/provider/persona/
  toolFilter, `@preset:`, `presetHints`) ✅
- **`cwd` on the foreground path** ✅ — the child's `pwd` and its sandbox
  workspace both switch to the requested directory
- **`cwd` on the continuable (background) path** ✅ — background children honor
  the same directory (the classic "foreground works, background silently
  ignores cwd" trap does not occur)
- `toolFilter` scoping ✅
- `patches/install.ps1` and `patches/uninstall.ps1` round-trip ✅ (backup,
  apply, `node --check`, restore, re-verify)

## Limitations

- **Patches target rc.6 only.** The two patches match exact anchors in the
  rc.6 bundle; a dsh upgrade invalidates them until re-run (or a new release).
- **`@preset:` depends on the local preset layout** — same caveat as
  `dsh-subagent-tools`.
- **Web sessions need the preset adapter** (`install-preset.ps1`) for the same
  reason as `dsh-subagent-tools`.

## License

MIT
