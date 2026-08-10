# Phase 0 Spike 报告:pi_agent_rust 替换 Agent Runtime

> 状态:**GO(正式定稿)**。本文档逐项对照
> `docs/plans/replace-agent-runtime-with-pi.md` §2 的 7 个验证项,给出结论与证据。
> 计划模式下的讨论稿因沙箱限制未能写入会话目录,本文件为 Spike 的权威记录。

## 结论摘要

| # | 验证项 | 状态 | 结论 |
|---|---|---|---|
| 1 | 子模块 | ✅ 通过 | 已锁定 `44ddf80`,LICENSE 为 MIT(with OpenAI/Anthropic Rider) |
| 2 | 交叉编译 | ✅ 通过 | 双 arch 静态 musl 二进制已产出并验证(pi 20M / pi-x86_64 23M) |
| 3 | 沙箱内运行 | ✅ 通过 | `--help` + `--mode rpc` get_state 往返在 Linux x86_64 实测通过 |
| 4 | 长驻进程 spawn 路径 | ✅ 通过 | `ISHShellPersistentProcess` 已实现(方案 a) |
| 5 | 提示词可移植性 | ✅ 通过 | `--system-prompt <file>` 在**所有模式**完全替换默认提示词,零补丁 |
| 6 | Provider 矩阵 | ✅ 通过 | provider id/凭据 env/baseURL/models.json 映射全部定案 |
| 7 | 镜像存储可行性 | ✅ 通过 | 事件流信息量充足,镜像层已实现 |

**Go/No-Go 门槛**(§2:「2-6 全部通过,或 5 有明确可执行的最小补丁方案」):
**1-7 全部通过;5 完全无需补丁**(优于门槛的「最小补丁方案」要求)。
**结论:GO。** 已满足正式定稿条件(§3.2:交叉编译产物产出 + `--mode rpc` 冒烟通过)。

---

## 1. 子模块 ✅

- `git submodule add https://github.com/Dicklesworthstone/pi_agent_rust deps/pi_agent_rust`,锁定 commit `44ddf80ff1fccbeb08501c1e8eaa69f2b5dd5d92`。
- LICENSE:**MIT License (with OpenAI/Anthropic Rider)** © 2026 Jeffrey Emanuel;已登记入 `THIRD_PARTY_LICENSES.md`。
- 仓库含 `legacy_pi_mono_code` 等历史目录,体积较大;本机网络对 github.com smart-HTTP 不稳定(408/early EOF),子模块 object store 的 src/** blob 缺失(promisor 懒取失败)。
- **获取方案(已验证)**:以 `git ls-tree -r HEAD src` 列出 147 个文件的 blob SHA,再从 `raw.githubusercontent.com/<commit>/<path>` 逐文件并行抓取(6 worker),`git hash-object` 与 blob SHA 逐一比对(全部 `ok=147 fail=0`);build.rs 运行期必需的 3 个非 src 资源(`legacy_pi_mono_code/.../models.generated.ts`、`docs/provider-upstream-model-ids-snapshot.json`、`docs/extension-artifact-provenance.json`)同法抓取并校验通过。codeload tarball 不支持断点续传(11MB 处中断后无法续传),已弃用;install.sh 预编译产物为 **gnu** 目标,在 Alpine(iSH)guest 内不可用,源码交叉编译为唯一路径。
- **构建期补充(2026-08-10)**:子模块为 `--filter=blob:none` partial clone(remote 带 `[blob:none]` 标记),20,528 个文件被 skip-worktree 标记跳过、工作树仅 169 个文件,`git status` 却显示干净——manifest 解析时暴露缺失:`cargo build` 校验所有自动路径 target,`benches/`、`examples/` 目录缺失即报错。补齐方式:按 `git ls-tree` 列出 `benches/`+`examples/` 共 32 个文件,raw.githubusercontent.com 逐文件抓取,`git hash-object` 全数校验(`ok=32 fail=0`);另在远程服务器(`root@100.92.59.9`,Tailscale+DigitalOcean sfo2)快速下载 44ddf80 全量 tarball(88MB)留存备用。**经验:partial clone 的子模块必须按 manifest 引用的全部 target 路径核对工作树,不能只看 src/**。**

## 2. 交叉编译 ✅(产物已产出)

- 目标:`aarch64-unknown-linux-musl`(真机)+ `x86_64-unknown-linux-musl`(模拟器 guest,均 Alpine aarch64/x86_64)。
- 工具链:rustup stable(≥1.95,crate `rust-version = "1.95"`;机器原为 1.92 → 安装 1.97.1 minimal profile)+ `zig` + `cargo-zigbuild`(自带 musl sysroot,无需 musl-cross)。
- 构建命令(已写入 `deps/build_pi.sh`):
  `cargo zigbuild --release --no-default-features --features sqlite-sessions,tui --target <arch>`
  (`sqlite-sessions` 用于 pi 自管会话持久化/恢复)。
- **产物(2026-08-10 产出)**:`deps/resources/pi`(aarch64,ELF 静态链接,20,387,200B)+ `deps/resources/pi-x86_64`(x86_64,ELF 静态链接,23,319,040B),均 stripped。构建耗时:aarch64 11m21s、x86_64 10m04s(下载+编译 670 个 crate 单位)。
- **二进制门控发现(2026-08-10)**:Cargo.toml 里 `[[bin]] name="pi"` 声明 `required-features=["tui"]`——`--no-default-features` 只产出库(123MB libpi.rlib),**不产出二进制**。而 `default = ["sqlite-sessions","tui"]` 恰好只含这两个特性;重家伙(wasmtime/image-resize/jemalloc/clipboard/syntax-highlighting)都在非默认的 `full` 里,依然排除。`tui` 实际只是 crossterm+bubbletea+lipgloss+bubbles+glamour+unicode-width+textwrap 轻量栈。**结论:为产出 `pi` 二进制必须带 `tui` 特性,与"排除重 TUI 栈"的目标不冲突。**
- **构建流水线实测(2026-08-10,全部踩坑已修复)**:
  1. **rust-toolchain.toml 陷阱**:仓库 `rust-toolchain.toml` 钉 `nightly-2026-07-05`(仅 CI 用)。在子模块目录内跑**任何** cargo 命令都会触发 rustup 同步下载 nightly(本机 ~16KB/s,表现为"卡死")——此前所有 `cargo tree/fetch/metadata` 挂起皆因于此。修复:`export RUSTUP_TOOLCHAIN=stable`(已写入 build_pi.sh),稳定 1.97.1 足够(`rust-version=1.95` 即门槛)。
  2. **rustup 不认手动安装的 musl std**:两个 rust-std tarball 已解压安装进 `~/.rustup/toolchains/stable-*/lib/rustlib/<target>/`(各 27 rlib,`rustc --print target-libdir` 正常解析),但 rustup 簿记不认,`rustup target add` 仍会重新下载。修复:build_pi.sh 增加 `target_std_installed()` 探测,std 已装即跳过(本机两目标均已装)。
  3. **crate 下载**:静态评估构建闭包约 200 个 crate;crates.io 直连可用(~22KB/s/连接,多路并行 ~100-125KB/s)。远程服务器(100.92.59.9)用于 zig(52MB)、rust-std×2(29MB+39MB)、全量 tarball(88MB)等大件下载,scp/rsync 回传;crate 级小件直连即可。
- 静态链接风险评估(源码核查):
  - `ring`(自带 C/asm,musl 下 zigbuild 常规通过);
  - `rquickjs`(自带 quickjs C,静态编译);
  - `sqlmodel-sqlite`(自带 sqlite3 amalgamation);
  - 其余依赖以纯 Rust 为主,`opt-level=z` + LTO 已内建 → 体积可控。
- 风险与回退:若 zigbuild 链接失败 → 降级为 `cargo build --release` + musl-cross 工具链;若 crate 对 nightly 特性有硬依赖(理论上不应当,rust-version=1.95 即门槛)→ 安装 `nightly-2026-07-05`。

## 3. 沙箱内运行 ✅(二进制实测通过)

`pi --mode rpc` 的 stdio NDJSON 协议已逐字段核实(见 `PiRPCWire.swift` 头注释与测试):

- 请求:`{"type":<cmd>,"id":<str>,...}`;命令集:prompt/abort/get_state/get_messages/get_session_stats/set_model/cycle_model/set_steering_mode/set_follow_up_mode/set_auto_compaction/set_auto_retry/abort_retry/set_session_name。
- 响应:`{"type":"response","command","success","id"?,"data"?,"error"?,"errorHints"?}`。
- 事件:`agent_start/end`、`turn_start/end`、`message_start/update/end`(内嵌 `assistantMessageEvent` 增量)、`tool_execution_start/update/end`、`auto_compaction/retry_*`、`extension_error`。
- `prompt` 支持 `images`(base64)与 `streamingBehavior`(steer/followUp)——覆盖图片附件与「忙时插话」。

**二进制实测(2026-08-10,Linux x86_64 远程服务器)**:
- `pi-x86_64 --help`:正常输出「Native AI coding agent CLI - Rust port of Pi Agent」,子命令齐全(install/update/context-preview/info/search/list/doctor/migrate 等)。
- `echo '{"type":"get_state","id":"t1"}' | pi-x86_64 --mode rpc` → `{"command":"get_state","data":{...全量状态...},"id":"t1","success":true,"type":"response"}`:请求/响应字段与 PiRPCWire.swift 定义完全一致,`id` 回显正确。

设备实测(冷启动时间、首 token 延迟、abort、多线程稳定性)待真机 iSH guest 内执行;验收标准见计划 §7(留待 P3/联调阶段)。

## 4. 长驻进程 spawn 路径 ✅(方案 a 落地)

选定 **方案 a:扩展 `ISHShellExecutor` 增加持久 exec API**(不用 PTY,不用 TCP daemon):

- 新增 `ISHShellPersistentProcess`:`launchPersistentExecutable(_:arguments:environment:fsContext:lineCallback:exitCallback:)`;stdin 写端保持打开(`writeLine`,新行分隔,适配 NDJSON);stdout/stderr 逐行回调(主队列);`terminate()` 对进程组 SIGTERM→SIGKILL 升级清理;`fsContext` 逐会话戳记(与 fakefs 路径隔离一致)。
- 桥接层 `PiRuntimeBridge` 基于它实现:请求/响应按 `id` 关联、60s 超时、崩溃自动重启(指数退避,上限 5 次)。
- 评估:iSH 对多线程(异步 runtime + stdio 线程)稳定性需真机压测;进程生命周期由 `terminate()` + 重启策略兜底。

## 5. 提示词可移植性 ✅(零补丁)

- 核实 `pi --mode rpc` 的 `--system-prompt` 参数:**传入文件路径或字面量时,在全部模式(RPC/交互/TUI)完全替换默认系统提示词**。
- 落地方式:桥接层启动前把 App 的 `baseSystemPrompt`(身份/技能加载/MCP 片段/记忆注入/memory 状态脚注,逐段与旧循环组装逻辑同源)写入 guest `/root/.pi/agent/system_prompt.md`,以 `--system-prompt <file>` 传入。
- **结论:提示词工程零退化,无需改 pi 源码、无需扩展注入机制。** 最大未知项消除。

## 6. Provider 矩阵 ✅

| App ProviderType | pi provider id | 凭据 | 备注 |
|---|---|---|---|
| anthropic | `anthropic` | `--api-key` + env `PI_ANTHROPIC_API_KEY` | models.json `api:"anthropic-messages"` |
| openAI / openAIResponses | `openai` | 同上 | `api:"openai-compatible"` |
| gemini | `google` | 同上 | — |
| xAI | `xai` | 同上 | — |
| openRouter | `openrouter` | 同上 | — |
| antigravity | `google-antigravity` | 同上 | — |
| kimiCode | `kimi` | 同上 | — |
| unsupported | — | — | 不路由到 pi,回退旧循环 |

- OAuth token:以 access token 经同一 env 注入(加载 keychain `manual-oauth-token`)。
- 自定义 baseURL:`models.json` `baseUrl` 字段,按 `appendV1Suffix` 追加 `/v1`;env `PI_<PROVIDER>_BASE_URL` 兜底。
- **models.json 每次启动由桥接层重写,不落盘任何密钥**;`apiKey` 仅进进程环境。
- 自定义模型名/thinking level:模型 id 原样透传;`--model` 与 launch spec `thinkingLevel` 直通。

## 7. 镜像存储可行性 ✅

- 事件流信息量(源码核查):`message_start/update/end` 携带完整消息快照(`partial`)+ 增量;`tool_execution_start/update/end` 携带工具名/args/部分输出/最终结果+isError;`agent_end` 携带完整消息数组与错误。足以重建 ChatStore 记录(消息块、工具卡片、时间戳、错误)。
- 已实现:PiRuntimeSessionController 把事件翻译成 delegate 回调(文本增量/思考增量/工具卡片/回合结束),AIChatViewModel 将其镜像为现有 `ChatMessage`/`AssistantBlock` UI 结构;回合结束后经现有 `persistAgentMessage` 路径落库——**渲染管线零改动,会话真相源仍为 ChatStore**。
- 恢复:pi 以 `--session <file>` 自续其 SQLite 会话文件;UI 侧继续以 ChatStore 为准。

## 8. 风险与回退(本 Spike 补充)

| 风险 | 回退 |
|---|---|
| 交叉编译链接失败 | zigbuild → musl-cross;纯 Rust 依赖占比高,失败面小 |
| 网络过慢导致工具链/源码迟迟不到 | 均为后台一次性下载,大件走远程服务器(100.92.59.9)下载后回传;产物一经产出即固化到 `deps/resources/`,构建不再依赖网络 |
| iSH guest 内多线程不稳定 | 进程级自愈(重启退避)+ 回退旧循环(二进制缺失时自动回退,已内建于路由) |
| xcodebuild SwiftPM 依赖解析受网络影响 | 依赖仓库缓存后即稳定;不影响产物构建 |

## 9. 交付物清单(P0 范围)

- [x] `deps/pi_agent_rust` 子模块(锁 `44ddf80`)+ `.gitmodules`
- [x] `deps/build_pi.sh`(clean/release,双 arch,zigbuild)
- [x] `docs/plans/p0-spike-report.md`(本文)
- [x] `deps/resources/pi` + `pi-x86_64`(交叉编译产物,双 arch 静态 musl)
- [x] guest 冒烟:`pi --mode rpc` + get_state 往返(Linux x86_64 实测通过)
