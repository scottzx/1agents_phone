# Grok 系列定时任务与例行自动化深度解析（Scheduled Tasks & Routines）

> 本文系统梳理 `../1agents_app/reference_repo/` 中两个 Grok 项目（**`grok-bot-0.18-reconstructed`** 与 **`grok-build`**）在**定时任务（Scheduler）、例行流程（Routine）、多事件源监听（Event Triggers）与安静唤醒（Quiet Wake）**等方面的架构实现，为 `1agents_phone`（一伴）的例行自动化体系升级提供完整参考。

---

## 目录
1. [项目一：Grok Bot (0.18) Routine 自动化体系](#1-grok-bot-018-routine-自动化体系)
   - [1.1 触发器核心模型（Automation Triggers）](#11-触发器核心模型automation-triggers)
   - [1.2 多事件源接入（Cron / Slack / GitHub / Linear / Sentry 等）](#12-多事件源接入cron--slack--github--linear--sentry-等)
   - [1.3 安静唤醒机制（Quiet Wake & Quiet Origin）](#13-安静唤醒机制quiet-wake--quiet-origin)
   - [1.4 Routine 生命周期管理与通知通道](#14-routine-生命周期管理与通知通道)
2. [项目二：Grok Build (Rust) 调度器架构（Scheduler Engine）](#2-grok-build-rust-调度器架构scheduler-engine)
   - [2.1 `Scheduler` 状态机与代际轮转（Generation & Revision）](#21-scheduler-状态机与代际轮转generation--revision)
   - [2.2 任务规格（One-shot Timer vs Recurring Interval）](#22-任务规格one-shot-timer-vs-recurring-interval)
   - [2.3 会话持久化与隔离（Durable vs Ephemeral）](#23-会话持久化与隔离durable-vs-ephemeral)
   - [2.4 事件调度与 `PromptOrigin::SchedulerFired` 唤醒流程](#24-事件调度与-promptoriginschedulerfired-唤醒流程)
3. [两套系统定时与自动化能力对比](#3-两套系统定时与自动化能力对比)
4. [对 `1agents_phone` 的落地改造方案](#4-对-1agents_phone-的落地改造方案)

---

## 1. Grok Bot (0.18) Routine 自动化体系

在 Grok Bot 中，自动化被称为 **Routine（例行任务）** 或 **Automation**，其核心逻辑位于 `source/host/automations/`。

### 1.1 触发器核心模型（Automation Triggers）
* **源码位置**：`source/host/automations/automation-trigger.ts` & `source/shared/automations.ts`

Grok Bot 不仅仅支持时间定时（Cron），还支持将丰富的外部事件作为触发器。触发器分为单触发器和组合组（`group`），支持多达 6 种事件类别：

```typescript
export type AutomationTriggerMember =
  | { type: "cron"; schedule: string }               // 标准 Cron 表达式（如 "0 9 * * 1-5"）
  | SlackTrigger                                     // Slack 消息/提及/表情反应/关键词
  | GithubTrigger                                    // GitHub PR/Issue/CI 状态变更
  | MicrosoftTeamsTrigger                            // Teams 频道消息与关键词
  | LinearTrigger                                    // Linear 工单创建/状态变更/周期结束
  | SentryTrigger                                    // Sentry 错误报警
  | PagerDutyTrigger;                                // PagerDuty 故障升级
```

### 1.2 多事件源接入（Cron / Slack / GitHub / Linear / Sentry 等）
Grok Bot 实现了细粒度的事件过滤器与白名单校验：

* **GitHub 事件监听（`GithubTrigger`）**：
  * 支持事件：`pr-opened`, `pr-pushed`, `pr-merged`, `review-requested`, `review-approved`, `ci-passed`, `ci-failed`, `issue-assigned` 等。
  * 支持按仓库（`repo`）、CI 分支（`ciBranch`）以及用户白名单（`userAllowlist`）过滤。
* **Slack / Teams 监听（`SlackTrigger`）**：
  * 支持指定频道（`channel`），并按动作匹配：`mention`（@提及）、`keyword`（关键词匹配）、`reaction`（特定 Emoji 表情触发）。
* **工单与监控事件（`Linear` / `Sentry` / `PagerDuty`）**：
  * 当生产环境产生 Sentry Issue 或 PagerDuty Incident 时，直接唤醒对应的运维/巡检 Bot 进行现场复现与排查。

### 1.3 安静唤醒机制（Quiet Wake & Quiet Origin）
* **源码位置**：`source/host/extensions/transcript/completion-revivals.ts`

这是无人值守系统最关键的设计之一：**定时任务在后台运行时，用户并没有守在屏幕前等待。如果每次例行检查都向用户发一条无意义的“一切正常”，会产生严重的消息骚扰。**

Grok Bot 引入了 `QuietWakeOrigin` 机制：
1. **静默执行**：当 Routine 触发时，携带 `quietOrigin` 标记；
2. **安静指令注入（QUIET_REVIVAL_INSTRUCTION）**：
   ```text
   Pick the work back up. Everything above came out of your own quiet standing order(s) —
   the user did not ask to hear about it, so the saved instruction's delivery rule governs.
   - If the outcome is a genuine change, a new actionable result, or a real blocker the user must know about,
     tell them once with a single useful SendMessage.
   - If it amounts to no change, nothing new, or still waiting, end the turn with no SendMessage at all —
     no "still waiting" or progress notes.
   ```
3. **零骚扰结果**：巡检无变化时，Bot 默默记录日志并结束轮次；只有发现关键告警/重大变动时，才主动推送一条消息。

### 1.4 Routine 生命周期管理与通知通道
* **源码位置**：`source/host/automations/automation-store.ts` & `routine-notices.ts`
* 包含 Routine 的增删改查、启用/禁用、手动触发测试（Test Run）、运行历史追溯（Execution History）以及异常上报机制。

---

## 2. Grok Build (Rust) 调度器架构（Scheduler Engine）

Grok Build 面向 CLI 终端与无头环境，在 Rust 侧构建了一个极度健壮、支持持久化与事务安全的定时调度器（`Scheduler Actor`）。

### 2.1 `Scheduler` 状态机与代际轮转（Generation & Revision）
* **源码位置**：`crates/codegen/xai-grok-tools/src/implementations/grok_build/scheduler/actor.rs` & `types.rs`

为了防止并发修改冲突与任务状态混乱，Grok Build 引入了基于版本号（`SchedulerVersion`）的状态机：
* **`generation` (UUID)**：调度器代际标识，重启或大重构时轮转；
* **`revision` (u64)**：递增版本号，每次创建、修改、触发任务时原子递增；
* **`SchedulerReservation`**：支持预约式提交（Commit），保证在多任务并发触发时任务不丢、不重。

### 2.2 任务规格（One-shot Timer vs Recurring Interval）
* **源码位置**：`crates/codegen/xai-grok-tools/src/implementations/grok_build/scheduler/create.rs`

```rust
pub struct SchedulerCreateInput {
    pub task_id: Option<String>,       // 更新现有任务或创建新任务
    pub interval: Option<String>,      // 周期，支持人性化格式："5m", "30s", "2h", "1d"
    pub prompt: Option<String>,        // 每次触发时送给 Agent 的指令
    pub recurring: bool,               // 是否周期性循环（还是单次 Timer）
    pub durable: Option<bool>,         // 是否跨会话持久化保存
    pub foreground: Option<bool>,      // true: 主会话 Turn 执行; false: 独立子 Agent 执行
    pub fire_immediately: bool,        // 是否创建后立刻先跑一次
}
```

### 2.3 会话持久化与隔离（Durable vs Ephemeral）
* **Ephemeral（临时任务，`durable: false`）**：生命周期与当前 CLI 进程/Session 绑定，退出时自动清理。
* **Durable（持久任务，`durable: true`）**：写入本地磁盘 SQLite / JSON 存储，即使用户关闭终端或下次重启，调度守护进程仍会恢复并继续按时触发。

### 2.4 事件调度与 `PromptOrigin::SchedulerFired` 唤醒流程
* **源码位置**：`crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn.rs`
1. 调度定时器到期时，通过 Tokio MPSC 通道向主 Session 发送 `ToolNotification::ScheduledTaskFired`；
2. 会话引擎生成 `PromptOrigin::SchedulerFired` 类型的输入，排入 `PromptQueue`；
3. 如果当前处于空闲状态，引擎自动启动一轮推理，执行预设 Prompt；若当前用户正在输入，则排队至用户轮次结束后执行。

---

## 3. 两套系统定时与自动化能力对比

| 维度 | Grok Bot (0.18) | Grok Build (Rust) |
|---|---|---|
| **核心定位** | 企业级/办公级 Routine（面向多 SaaS） | 开发者/终端级 Scheduler（面向任务巡检） |
| **触发器类型** | Cron、Webhook、Slack、GitHub、Linear、Sentry | 相对时间间隔（"5m", "1d"）、绝对时间、单次 Timer |
| **执行载体** | 云端常驻虚拟机 / 独立 Subagent | 独立 Tokio Task / 独立 Subagent |
| **消息抑制** | **Quiet Wake 机制**（无变动则完全静默，杜绝打扰） | 支持 Foreground / Background 分流 |
| **持久化保证** | 云端 DB + 虚拟机本地持久化 | Versioned State + SQLite/Durable Journal |

---

## 4. 对 `1agents_phone` 的落地改造方案

在我们的端侧平替项目 `1agents_phone`（iOS / Android / macOS）中，现有的定时任务仅有简单的本地闹钟/通知（如 `ScheduledTaskManager`）和待完善的 `AgentSchedulesView`。建议参考 Grok 进行如下架构升级：

### 4.1 引入标准化的 Routine 引擎契约
1. **数据模型升级**：
   * 将现有的调度任务升级为包含 `id`, `name`, `trigger` (Cron / Interval / Webhook), `actionPrompt`, `isDurable`, `isQuietMode` 的标准 Routine 实体。
2. **移动端后台触发机制适配**：
   * **iOS 端**：结合 `BGProcessingTask` / `BGAppRefreshTask` 与 `UserNotifications`，在后台唤醒窗口执行轻量巡检；
   * **Android 端**：结合 `WorkManager` / `AlarmManager` 实现精准后台触发。

### 4.2 移植 Quiet Wake 智能静默机制
* 在执行 Routine 时，为 Prompt 注入静默指令：“*若巡检结果正常无变动，不要发送任何消息；仅当发现异常或重要更新时，调用系统通知/发送消息*”，从根本上解决自动化任务造成的“消息轰炸”。

### 4.3 打造可视化的 Routine 管理与测试面板
* 在 UI 上完善 `AgentSchedulesView`，提供 **“立即测试一次（Test Run）”**、**“最近运行日志（Run History）”** 以及 **“一键启用/暂停”** 开关，达到与 Grok Bot 一致的桌面级交互体验。
