# 实施计划:用 pi_agent_rust 替换 1agents 的 Agent Runtime(方案 A,先 iOS)

> 状态:定稿(2026-08-09)。决策记录见 §0。计划模式下的讨论稿因沙箱限制未能写入会话目录,此文件为唯一权威版本。

## 0. 决策记录(用户已确认)

| 问题 | 决策 |
|---|---|
| 替换范围 | **先 iOS**,Android 后置(§6) |
| 集成面 | **方案 A:子进程 RPC 进沙箱**(`pi --mode rpc`,stdio JSON-RPC) |
| 会话真相源 | **镜像存储**:App 的 ChatStore 保持为 UI/同步源,桥接层把 RPC 事件镜像写入,恢复时向 pi 重放 |
| 回滚 | **直接替换**:移除旧 `runAgentLoop` 循环;不做 Settings 开关。以 PR 为单位分阶段落地,git 历史可 revert |

## 1. 架构总览

```
┌────────────────────────── iOS App ──────────────────────────┐
│  UI (现有 Views / MessageList / Markdown / 渲染)              │
│  ChatStore (镜像存储,UI/同步真相源)         PiRuntimeBridge ──┼── 启动/停止 pi 进程
│  AIChatViewModel (瘦身后:仅 UI 状态 + 调 bridge)             │    JSON-RPC 编解码
│  ProviderConfigStore → 凭据 env                               │    prompt/abort/steer/set_model
└──────────────┬───────────────────────────────────────────────┘   事件→ChatStore 镜像
               │ spawn: /usr/local/bin/pi --mode rpc (在 iSH guest 内)
               ▼
┌────────────── iSH guest (Alpine aarch64, 进程内 syscall 模拟) ─┐
│  pi --mode rpc (aarch64-unknown-linux-musl 静态二进制)          │
│    ├─ LLM 编排:SSE 流式 → tool_use → 工具循环(取代 runAgentLoop)│
│    ├─ 内建工具:bash/read/write/edit/grep/find/ls/read(图片)     │
│    ├─ bash → /bin/sh → 沙箱 shell                               │
│    │    ├─ minis-browser-use / minis-model-use / apple-* 等     │
│    │    │    └─ native offload 拦截(设备集成,零改动)            │
│    │    └─ minis-mcp-cli tools/call <server> <tool>(MCP,零改动) │
│    └─ ~/.pi/agent/: settings.json / models.json / agents/*.md   │
│         / skills/ / prompts/(提示词移植目标)                    │
└────────────────────────────────────────────────────────────────┘
```

**工具映射**(当前工具 → pi):

| 当前工具 | pi 侧 | 说明 |
|---|---|---|
| `shell_execute` | `bash` | 同一沙箱 shell,offload CLI 天然可用 |
| `file_read` / `file_write` / `file_edit` | `read` / `write` / `edit` | `read` 支持图片(替代 `read_image`) |
| `browser_use` | `bash` → `minis-browser-use` | 复用现有 offload,不经 WebView 的 Swift 工具 |
| `memory_write` / `memory_get` | `bash` 读写 `/var/minis/memory/*.md` + 提示词注入 | 现状本就以文件为存储 |
| MCP 服务器 | `bash` → `minis-mcp-cli` | 提示词注入 MCP 片段,与现状一致 |

## 2. Phase 0 — 技术验证(Spike,先行,产出"可行/不可行"报告)

目标:在动手写桥接前消除最大不确定性。**本阶段结束后需要一次 go/no-go 评审。**

1. **子模块**:`git submodule add https://github.com/Dicklesworthstone/pi_agent_rust deps/pi_agent_rust`(锁 tag 或 commit;仓库含 `legacy_pi_mono_code`,建议 submodule `--depth 1` 并在 `.gitmodules` 记录)。更新 `BUILDING.md` 子模块表、`THIRD_PARTY_LICENSES.md`(MIT + OpenAI/Anthropic Rider)。
2. **交叉编译**:`rustup target add aarch64-unknown-linux-musl`;`cargo build --release --no-default-features --target aarch64-unknown-linux-musl`。确认 ring/rquickjs(自带 C)/sqlmodel-sqlite(自带 sqlite)静态链接通过。如 musl 缺头文件,评估 zig cc 或 musl-cross。同时产出 `x86_64-unknown-linux-musl` 供模拟器(iSH 在模拟器上的 guest 架构需确认)。
3. **沙箱内运行**:在 iSH guest 中跑 `pi --mode rpc`,验证:stdio 协议、事件流(文本增量/tool 更新/agent_end)、`abort`、`set_model`、steer/follow-up 队列;测量冷启动时间与首 token 延迟(对照当前 SSE 路径)。
4. **长驻进程 spawn 路径**(关键):当前 `ISHShellExecutor` 仅一次性执行(`stdinData` 写完关管道)。验证三选一:
   - a. 扩展 `ISHShellExecutor` 增加持久 exec API(保留 stdin 写端、stdout 逐行回调);
   - b. 复用 PTY 通道(`ISHTerminalView` 的 pty bridge);
   - c. **复用 `minis-mcp-cli` daemon 模式**:guest 内 `socat`/小包装把 `pi --mode rpc` 的 stdio 绑到 loopback TCP 端口,Swift 直连 127.0.0.1(代码库已有此先例,fakefs 无 AF_UNIX)。
   - 评估项:iSH 对 pi 多线程(异步 runtime + stdio 线程)的稳定性、进程生命周期管理、`killProcess` 语义。
5. **提示词可移植性**(最大未知):核实 pi 的系统提示词承载机制——`~/.pi/agent/agents/*.md` 定义、settings.json、prompt templates 能否注入完整 `baseSystemPrompt` 内容(身份/技能加载说明/记忆/`/var/minis` 目录文档/minis:// URL/MCP 片段/执行纪律/`delay` 语义)。若不足以承载,列出最小补丁面(改 pi?还是经扩展注入?)。
6. **Provider 矩阵**:App 各 provider(Anthropic/GPT/Gemini/xAI/OpenRouter/本地)→ pi `models.json` + env 映射;确认 OAuth token(access token)可直接以 env 注入;确认自定义模型名、thinking level 透传。
7. **镜像存储可行性**:确认 RPC 事件流信息量足以重建 ChatStore 记录(消息块、tool 标题、图片、时间戳、token 统计)。

**Go/No-Go 门槛**:2-6 全部通过,或 5 有明确可执行的最小补丁方案。

## 3. Phase 1 — 构建与交付二进制

1. `deps/build_pi.sh`(对齐 `build_ish.sh`:SCRIPT_DIR 定位、`clean|debug|release` 参数、前置检查):
   - `rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl`
   - `cargo build --release --no-default-features --target <arch>`
   - 产物 → `deps/resources/pi`(aarch64,真机)/ `deps/resources/pi-x86_64`(模拟器)
2. iOS 注入:`default_mount/usr/local/bin/pi` 由 `RootfsManager.applyDefaultMountOverlay()` 随每次 boot 注入(0o755,与 `minis-mcp-cli` 同法;二进制体积大,确认 overlay 只读策略与包体积影响)。
3. 预置 `default_mount/root/.pi/agent/`:初始 `settings.json`、`models.json` 骨架。
4. 更新 `BUILDING.md`(构建顺序、产物说明)、`THIRD_PARTY_LICENSES.md`。

## 4. Phase 2 — Swift 桥接(`PiRuntimeBridge`)

新增 `src/ios/Agent/Runtime/PiRuntimeBridge.swift`(Swift actor,对齐现有并发风格):

1. **进程管理**:启动/停止 `pi --mode rpc`(经 Phase 0 定案的 spawn 路径);生命周期与 iSH kernel boot 绑定(`ensureKernelBooted()` 之后);崩溃/退出自动重启策略;进程组 kill。
2. **JSON-RPC 层**:stdin 写命令(`prompt` 含 images/streamingBehavior、`abort`、`set_model`、`set_steering_mode`、`set_follow_up_mode`、`set_auto_compaction`、`set_auto_retry`、`get_state`),stdout 按行解析事件。
3. **事件 → ChatStore 镜像**:文本增量 → assistant 消息块;tool 执行更新 → tool 块(标题/状态/输出);`agent_end` → 回合收尾;token/usage 统计。保持现有渲染管线零改动。
4. **凭据注入**:`ProviderConfigStore` → pi 进程 env + `models.json` 刷新;provider/model 切换 → `set_model` 或重启进程。
5. **会话恢复(镜像重放)**:新建会话时向 pi 重放 ChatStore 中的历史消息(或 pi 以 `--session` 续自己的 JSONL;按 Phase 0 验证结果定)。
6. **提示词注入**:把 `baseSystemPrompt` 迁移进 pi 的提示词承载机制(Phase 0 定案),在进程启动时落盘到 `~/.pi/agent/`。
7. **入口替换**:`AIChatViewModel.sendMessage` 改走 bridge;UI 状态(流式渲染、停止按钮、工具卡片)保持。

**验收**:真机上跑通「发消息 → pi 流式回答 → 工具调用(含 `minis-browser-use`/`minis-mcp-cli`)→ 结果入 ChatStore → 历史可恢复」;`pi` 崩溃可自愈。

## 5. Phase 3 — 移除旧循环(直接替换)

1. 删除/禁用 `AIChatViewModel.runAgentLoop` 及其 LLM 编排依赖:`AIChatViewModel+SSEStream.swift`(SSE 解析)、`AIChatViewModel+ProviderFactory.swift`(若仅服务旧循环)、`AIChatViewModel+ConcurrentTools.swift`(工具并行)、`AIChatViewModel+ToolDefinitions.swift`(工具 schema)、`AIChatViewModel+RequestBudget.swift`(视情况并入 bridge)。
2. 保留:`ChatStore`/消息模型、工具执行底层(`ISHExecutionCoordinator`)、提示词内容(迁至 pi 侧)、MCPStore、SkillStore、MemoryStore 的**数据层**(桥接仍要读)。
3. 保留 `maxAgentTurns`/`ToolLoopDetector` 语义映射到 pi(pi 自带 turn/retry/compaction 控制,对照验收)。
4. 清理失效的单元测试引用;MinisTests 增补 bridge 的 JSON-RPC 编解码测试。

## 6. Phase 5 — Android 后置(预留,不在本次范围)

- 同构 Kotlin `PiRuntimeBridge.kt`,复用 `ExecutionCoordinator` spawn 路径(PRoot 无 JIT 开销,验证成本更低);同一份 `aarch64-unknown-linux-musl` 产物(Alpine guest)直接可用。
- 待 iOS 稳定后另行立项。

## 7. 验收标准(全量)

- [ ] 冷启动:pi 进程就绪 < 1s(对照 minis-mcp-cli daemon),首 token 延迟不劣于旧 SSE 路径(允许 ±30%)
- [ ] 工具回归:shell/文件/浏览器/记忆/MCP/设备 offload(日历、健康、HomeKit 等)逐项对照旧循环
- [ ] 会话:新建/继续/回放一致;iCloud 同步、小组件、Shortcuts、分享到会话不受影响
- [ ] 长驻稳定性:连续多轮无泄漏/无崩溃;killProcess 后自愈
- [ ] 提示词行为:执行纪律(不空许承诺)、minis:// URL、`delay` 语义在新 runtime 中不退化
- [ ] 许可证声明已更新;`BUILDING.md` 从零构建可通过(含子模块)

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| pi 系统提示词承载不足(最大) | 提示词工程退化 | Phase 0 专门验证;最小补丁面(扩展注入/上游 PR)在 Go/No-Go 评审定案 |
| iSH 长驻进程/多线程不稳定 | 崩溃、卡死 | Phase 0 压测;daemon+TCP 模式有先例;进程级自愈 |
| 镜像存储双写一致性 | 记录错位 | 事件流幂等设计;Phase 0 验证事件信息量;恢复用重放对账 |
| Provider 兼容(非 Anthropic/OpenAI 端点) | 模型不可用 | 全走 OpenAI-compat `models.json`;OAuth token 以 env 注入,Phase 0 验证 |
| 子模块体积/上游迭代快(3692 commits) | 构建慢、锁定漂移 | `--depth 1` + 锁 commit;升级走独立 PR |
| 静态链接 musl 交叉编译坑 | 构建失败 | 依赖多为纯 Rust/自带 C;zig cc 备选;Phase 0 先行 |
| 二进制包体积 | App 变大 | musl 静态 + `strip`(release 已配);`opt-level=z` + LTO 已内建 |

## 9. 里程碑

| 里程碑 | 内容 | 出口 |
|---|---|---|
| M0 | Phase 0 完成 | Go/No-Go 报告 |
| M1 | Phase 1 完成 | pi 在真机沙箱内可交互(手动 RPC) |
| M2 | Phase 2 完成 | 全功能对话走 pi,bridge 可用 |
| M3 | Phase 3 完成 | 旧循环移除,验收全绿 |
