# dsh-subagent-cwd

为 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）提供增强版子代理委派工具，
**支持按次指定工作目录（cwd）**。

包含 [dsh-subagent-tools](https://github.com/lynx-gt/dsh-subagent-tools) 的全部能力（按次 model / provider /
persona / toolFilter 覆盖、`@preset:` 引用、`provider/model` 复合 id）**再加**按次 `cwd` 参数——并附带
让 `cwd` 真正生效所需的两处进程内 provider 补丁。

| [English](README.md) | [中文](README.zh.md) |

[![awesome · DSH plugin](https://awesome-dsh-plugin.com/badge.svg)](https://awesome-dsh-plugin.com)

## 两个包二选一，不要同时装

| 包 | 按次 model/provider/persona/toolFilter | `@preset:` | `cwd` | 补丁 |
|---|---|---|---|---|
| **dsh-subagent-tools** | ✅ | ✅ | ❌ | **无（纯 bundle）** |
| **dsh-subagent-cwd**（本包） | ✅ | ✅ | ✅ | 2 处 provider 补丁 |

二选一安装。两者暴露相同的工具面（`subagent` / `subagent_fork`），同时装会因工具名冲突互相打架。

## 为什么 cwd 需要补丁（而其他功能不需要）

`SubagentStartRequest` **没有 cwd 字段**，进程内驱动层构建子代理会话 meta 时只用
`childSessionMeta(parent, ...)`——按次 cwd 根本不会透传。进程内子代理有**两条**创建路径，**两条都必须**
打补丁，否则就会踩到经典陷阱：前台路径认 cwd、后台路径静默忽略：

| 路径 | 要改的包 | 文件 |
|---|---|---|
| 前台（one-shot） | `@deepseek-ai/dsh-subagent-in-process-driver` | `lib/index.js` |
| 后台（continuable） | `@deepseek-ai/dsh-subagent` | **`lib/index.js`（bundle！不是 `lib/types/continuation.js`）** |

第二处是 bundle 陷阱：该包 `package.json` 的 main/exports 指向 `lib/index.js`（内含 continuation
manager 的内联副本）。改长得像源码的 `lib/types/continuation.js` **不生效**——必须改并验证 bundle。

## 安装

```sh
# 1. 安装插件（npm / git / 本地目录）
dsh plugin --profile web add dsh-subagent-cwd

# 2. 应用两处驱动层补丁（cwd 生效必需）
powershell -ExecutionPolicy Bypass -File patches\install.ps1    # Windows
# 或：./patches/install.sh                                       # POSIX
```

安装后重启 `dsh --profile web`。

### 升级 dsh 之后

dsh 升级会重写 `node_modules`，**两处补丁都会丢失**。每次升级后：

```sh
# 重跑安装脚本（幂等；anchor 不匹配会自动报错）
powershell -ExecutionPolicy Bypass -File patches\install.ps1
```

若安装脚本报 "anchor not found"，说明目标包结构变了——检查是否有新版本，或提 issue。

### 卸载

```sh
powershell -ExecutionPolicy Bypass -File patches\uninstall.ps1   # Windows
# 或：./patches/uninstall.sh                                     # POSIX
dsh plugin --profile web remove dsh-subagent-cwd
```

## 示例

```
让子代理在不注入项目 AGENTS.md 的目录里干活：
  subagent(description="总结这个文件", prompt="...", cwd="D:\\projects\\scratch\\notes")
```

## 设计要点

- **工具面是 bundle**——官方 `tool-subagent` / `tool-subagent-fork` 行被禁用并替换，工具面本身不改任何官方文件。
- **`cwd` 是唯一无法保持 bundle-only 的能力。** `SubagentStartRequest` 没有 cwd 字段，按次 cwd 必须由进程内
  subagent provider 透传——所以需要 `patches/` 里的两处小补丁（各一个 hunk），幂等、首次运行自动备份、
  `node --check` 校验。这就是本包与 `dsh-subagent-tools` 分开存在的原因。
- **版本契约：** `peerDependencies` 锁定公开 dsh 包（`^0.1.0-rc.6`）；补丁针对同一版本。dsh 升级会重写
  dsh 安装的 `node_modules` 并**清掉两处补丁**——每次升级后重跑 `patches/install.ps1` / `install.sh`
  （见"升级 dsh 之后"）。bundle 本身装在 profile 自己的 `node_modules`，升级后仍在，但官方 API 一旦变化，
  `peerDependencies` 会显式拒绝加载。

## 已验证

在干净（无本地补丁）的 dsh `0.1.0-rc.6` Windows 环境实测（headless + web）：

- `dsh-subagent-tools` 的全部验证项（按次 model/provider/persona/toolFilter、`@preset:`、presetHints）✅
- **`cwd` 前台路径** ✅ —— 子代理的 `pwd` 和沙箱工作区都切到指定目录
- **`cwd` 后台（continuable）路径** ✅ —— 后台子代理同样生效（"前台认、后台静默忽略"的经典陷阱未复现）
- `toolFilter` 作用域 ✅
- `patches/install.ps1` 与 `patches/uninstall.ps1` 往返 ✅（备份→打补丁→node --check→还原→复验）

## 限制

- **补丁只针对 rc.6。** 两处补丁匹配 rc.6 bundle 的精确锚点；dsh 升级后失效，需重跑（或等新版本）。
- **`@preset:` 依赖本地预设布局** —— 与 `dsh-subagent-tools` 相同。
- **Web 会话需要 preset 适配脚本**（`install-preset.ps1`）——原因同 `dsh-subagent-tools`。

## License

MIT
