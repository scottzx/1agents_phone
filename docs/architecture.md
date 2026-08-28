# 架构设计：单 Runtime、多 Flavor 白标

本文描述 **1agents_phone / Minis** 的现行架构：一套完整的端上 Agent Runtime，通过多个 iOS App Target 打成可并存的垂直产品。契约细节见 [specs/flavor-pack-contract.md](specs/flavor-pack-contract.md)；沙箱细节见 [specs/ios-sandbox-ish-summary.md](specs/ios-sandbox-ish-summary.md)。

状态：**iOS Flavor 已落地（v0.3）**。Android 仍是单包 `com.openminis.app`，尚未做 productFlavor。

---

## 1. 原则

1. **不裁剪能力。** 垂直 App 与主产品同源编译，拥有同一套 Linux 沙箱、模型供应商、Skill、Native Offload。差异只在默认 Pack 与入口。
2. **iOS 系统为业务权威源。** 待办写提醒事项，日程写日历，客户写通讯录。Pack 不另建平行业务库。
3. **扩展走 iSH + Skill。** 垂类能力优先用 SOUL、bundled skill、快捷动作，而不是 fork Runtime。
4. **装配与产品分离。** `FlavorKit` 是平台装配层；`Flavors/<id>/` 是垂类资产；`Scenes/<id>/` 是垂类入口 UI。

---

## 2. 总览

```
                    ┌─────────────────────────────────────────┐
                    │              用户可见的 App              │
                    │  Minis │ 销售助手 │ 英语陪练 │ 健身陪练  │
                    └─────────────┬───────────────────────────┘
                                  │ 同一份源码，不同 Bundle
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│ Flavor 装配                                                       │
│  FlavorConfig.json  →  FlavorRegistry / FlavorRootView            │
│  RolePack/          →  RolePackInstaller（SOUL / 快捷动作）        │
│  Scenes/<id>/       →  可选 scene_home（销售首页已接）              │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│ Agent Runtime（四包共享）                                         │
│  SwiftUI Shell  ·  Providers  ·  Session / Memory / Skills        │
│  Tool loop      ·  Browser Use ·  Sync / FileProvider（仅主包）    │
└─────────────────────────────────────────────────────────────────┘
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                       ▼
┌──────────────────────────┐           ┌──────────────────────────┐
│ Linux 沙箱               │           │ Native Offload           │
│ iOS: iSH + Alpine aarch64│           │ apple-calendar / health  │
│ Android: PRoot + Alpine  │           │ ffmpeg / vision / …      │
└──────────────────────────┘           └──────────────────────────┘
```

Agent 把「能在 Linux 里做的事」交给沙箱，把「必须走系统框架的事」交给 offload。Flavor 只决定：**启动时像谁、默认 SOUL 是谁、根页面是聊天还是场景首页**。

---

## 3. 仓库分层

| 路径 | 职责 |
|---|---|
| `src/ios/` | iOS App（Swift / SwiftUI）+ Share / Widget / FileProvider |
| `src/ios/FlavorKit/` | Flavor 装配运行时 |
| `src/ios/Flavors/<id>/` | 各包的 `FlavorConfig.json` + `RolePack/` |
| `src/ios/Scenes/<id>/` | 垂类入口 UI（目前仅 `sales`） |
| `src/android/` | Android 单包（Kotlin / Compose） |
| `src/shared/` | 两端共享资产 |
| `deps/` | iSH / PRoot / FFmpeg / LAME / Alpine rootfs 的源码构建 |
| `docs/specs/` | 接口与装配契约 |

四个 iOS App Target **共用同一套 Sources / Resources / Frameworks**，不复制源码列表。差异只在 Build Settings：

| Target | Bundle ID | `FLAVOR_ID` | 桌面名 | 扩展 |
|---|---|---|---|---|
| Minis | `com.1agents.phone` | `openminis` | Minis | Share / Widget / FileProvider |
| MinisSales | `com.1agents.phone.sales` | `sales` | 销售助手 | 无 |
| MinisEnglish | `com.1agents.phone.english` | `english` | 英语陪练 | 无 |
| MinisFitness | `com.1agents.phone.fitness` | `fitness` | 健身陪练 | 无 |

垂直 Target 暂不嵌扩展：扩展的 Bundle ID 必须挂在宿主前缀下，需要时再按 flavor 克隆。

构建入口：选对应 Scheme（`Minis` / `MinisSales` / …）。`FLAVOR_ID` 驱动 Run Script `scripts/embed_role_pack.sh`，把 `Flavors/$FLAVOR_ID/` 拷进该包的 Bundle。

---

## 4. 启动与根体验

```
MinisApp.init
  └─ FlavorRegistry.current          # 读 Bundle 内 FlavorConfig.json
       └─ 缺失则回退 openminis

MinisApp.body
  └─ FlavorRootView
       ├─ standard_chat / chat_with_rail → ContentView（会话列表）
       └─ scene_home
            ├─ sales → SalesHomeView
            └─ 其他  → ContentView

首次注册 FileProvider / 准备 App Group 目录时
  └─ RolePackInstaller.installIfNeeded()   # 必须在 SoulStore.ensureExists() 之前
       ├─ 按 apply_policy 写入 SOUL.md（first_launch_only）
       ├─ 加载 RolePack/ui/quick_actions.json → RolePackRuntime
       └─ skills：已声明，安装仍延后
```

`root_experience` 取值：

| 值 | 含义 | 现状 |
|---|---|---|
| `standard_chat` | 主产品会话列表 | openminis |
| `scene_home` | 垂类静态/场景首页 | **sales 已接** `Scenes/sales/SalesHomeView.swift` |
| `chat_with_rail` | 聊天 + 侧栏快捷动作 | english / fitness 已声明，UI 尚未接线，当前回退会话列表 |

销售首页是演示级场景壳：管道数字、Pack 快捷动作预览、系统权威源说明，以及「进入完整 Agent」回到 `ContentView`。快捷动作尚未预填到新会话。

---

## 5. Agent Runtime（各 Flavor 相同）

用户消息进入 `AIChatViewModel` 的 tool loop：

1. **Providers** — Claude / GPT / Gemini / Kimi / OpenRouter / xAI 等；密钥与 OAuth 存在本机。
2. **Session** — 会话、附件、workspace 按 session 隔离。
3. **Tools** — 终端命令、浏览器、文件、Skill、offload CLI。
4. **Memory / Skills** — 跨会话记忆与按需加载的 `SKILL.md`。
5. **Sync** — iCloud / App Group；FileProvider 把 `shared/` 暴露给「文件」App（仅主包嵌扩展）。

沙箱执行由 `ISHExecutionCoordinator` 串行化（全局 FIFO，一次一条命令），按 session 挂载 `/var/minis/`。

Android 对位物是 PRoot + 同一套 Alpine 思路，包名 `com.openminis.app`，无 Flavor 变体。

---

## 6. 沙箱与 Offload

| | iOS | Android |
|---|---|---|
| 内核 | iSH（Asbestos ARM64 JIT） | PRoot |
| Guest | Alpine Linux aarch64 | 同左 |
| rootfs 落盘 | 各 App 沙箱 `Documents/alpine-rootfs/` | 应用私有目录 |

Guest `execve("/usr/local/bin/apple-*")` 被内核拦下，转到原生 handler（EventKit、HealthKit、Vision、FFmpeg 等），JSON 经管道回传。Flavor **不**裁剪 offload 列表。

更细的 syscall / mount / handler 表见 [ios-sandbox-ish-summary.md](specs/ios-sandbox-ish-summary.md)。

---

## 7. 存储模型

Flavor 只增加 **「装了几个独立 App」** 的成本，不把仓库或源码乘以 N。

### 7.1 按包复制（每个已安装、已启动过的 Flavor 一份）

| 数据 | 位置 | 量级 |
|---|---|---|
| App 本体 | 各自 Bundle | Debug 约 160–185 MB（垂直包无扩展，略小） |
| Alpine rootfs（解压后） | 各自 `Documents/alpine-rootfs/` | 基础数十 MB，用户 `apk add` 后继续涨 |

iOS 不在不同 Bundle ID 之间共享可执行文件。rootfs 也不进 App Group，因此 Minis 与销售助手各有一份 Linux。

### 7.2 当前共享（不按 Flavor 翻倍，也未隔离）

垂直 Target **复用** `Minis.entitlements`：

- App Group：`group.com.1agents.phone`
- iCloud：`iCloud.com.1agents.phone`

会话、skills、memory、共享文件走该容器。同机多装时各包看到同一套用户数据。省空间，产品上尚未隔离。

契约约定：若以后要按垂直包拆数据，再拆 App Group / iCloud 容器。在此之前不要假设「卸掉销售助手会清掉 Minis 的会话」。

### 7.3 工程磁盘

`Flavors/<id>/` 只有 JSON / SOUL / 快捷动作，几十 KB。四个 Target 共享 compile sources，Mac 上几乎不加倍。

日常开发只装正在改的那个 Scheme 即可。并排对比原始包 + 销售助手大约再多约 200 MB（未计各自 rootfs）。

---

## 8. 并行开发边界

| 改哪里 | 谁改 | 影响 |
|---|---|---|
| `src/ios/` 平台源码（Agent、Providers、Views…） | 平台 | 四个包下次构建都会带上 |
| `FlavorKit/` | 平台 | 装配契约；改根体验路由、Installer |
| `Flavors/<id>/` | 对应垂类 | 只影响该 `FLAVOR_ID` 的 Bundle 资源 |
| `Scenes/<id>/` | 对应垂类 | 源码仍编进所有 Target；**展示**由 `FlavorRootView` 按 `flavor_id` 开关 |

`Scenes/` 现阶段没有按 Target 裁剪编译（四包共享 Sources phase）。体积可忽略；行为必须用 `FlavorRegistry` 门控，避免销售首页出现在 Minis 里。

新增 Flavor：

1. 在 `Flavors/<id>/` 放 `FlavorConfig.json` + `RolePack/`
2. 跑 `python3 src/ios/scripts/add_flavor_targets.py`（已存在的 Target 不会重克隆源码列表）
3. 若需要独立首页：加 `Scenes/<id>/`，并在 `FlavorRootView` 增加分支

---

## 9. 现状与后续

**已落地**

- 四 Target / 四 Scheme / 四 Bundle ID，可同机并存
- 构建期 Embed Role Pack
- 启动期 FlavorRegistry + RolePackInstaller（SOUL first_launch_only、快捷动作加载）
- `FlavorRootView` 按 `root_experience` 选根页
- 销售助手 `scene_home` 静态页已装机验证

**未做（仍按契约排队）**

- `chat_with_rail` 真正接到会话预填
- Pack `skills[]` → SkillStore.bundled 安装
- 英语 / 健身的 Scene 页
- 垂直扩展（Share / Widget / FileProvider）与独立 App Group
- Android productFlavor

---

## 10. 相关文档

| 文档 | 内容 |
|---|---|
| [specs/flavor-pack-contract.md](specs/flavor-pack-contract.md) | FlavorConfig / RolePack JSON 字段与装配步骤 |
| [specs/ios-sandbox-ish-summary.md](specs/ios-sandbox-ish-summary.md) | iSH、mount、offload |
| [specs/minis-url-scheme.md](specs/minis-url-scheme.md) | `minis://` 深链 |
| [specs/debug-server-api.md](specs/debug-server-api.md) | Debug RPC |
| [BUILDING.md](../BUILDING.md) | 原生依赖与首次构建 |
