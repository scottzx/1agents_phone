# Grok 系列提示词与系统设计深度解析（Prompt Engineering & Mental Models）

> 本文深入剖析 `../1agents_app/reference_repo/` 中两个 Grok 核心项目（**`grok-bot-0.18-reconstructed`** 与 **`grok-build`**）的系统提示词（System Prompt）、Prompt 结构、多智能体交互协议及合成唤醒（Synthetic Revival）设计，为 `1agents_phone`（一伴）的 Prompt 与 A2A 协议改造提供权威技术参考。

---

## 目录
1. [项目一：Grok Bot (0.18-reconstructed) 提示词体系](#1-grok-bot-018-reconstructed-提示词体系)
   - [1.1 基础心智契约（Base System Prompt）](#11-基础心智契约base-system-prompt)
   - [1.2 关键机制一：SendMessage 管道绝对隔离（Voice vs Monologue）](#12-关键机制一sendmessage-管道绝对隔离voice-vs-monologue)
   - [1.3 关键机制二：多任务与子智能体隐形规则（Invisible Multitask）](#13-关键机制二多任务与子智能体隐形规则invisible-multitask)
   - [1.4 关键机制三：Auto-review 审批升级提示词](#14-关键机制三auto-review-审批升级提示词)
   - [1.5 关键机制四：反应式唤醒合成 Prompt（Synthetic Revival Prompt）](#15-关键机制四反应式唤醒合成-promptsynthetic-revival-prompt)
2. [项目二：Grok Build (Rust CLI/TUI) 提示词体系](#2-grok-build-rust-clitui-提示词体系)
   - [2.1 工具驱动型编码 Agent 提示词设计](#21-工具驱动型编码-agent-提示词设计)
   - [2.2 任务分类与后台执行指导语（Tool Schema Descriptions）](#22-任务分类与后台执行指导语tool-schema-descriptions)
   - [2.3 状态驱动的系统提醒注入（System Reminders & Nudges）](#23-状态驱动的系统提醒注入system-reminders--nudges)
3. [两套系统提示词对比与启示](#3-两套系统提示词对比与启示)
4. [对 `1agents_phone` 的落地改造方案](#4-对-1agents_phone-的落地改造方案)

---

## 1. Grok Bot (0.18-reconstructed) 提示词体系

### 1.1 基础心智契约（Base System Prompt）
* **源码位置**：`source/host/runner/system-prompt.ts` (`buildSandBaseSystemPrompt`)

Grok Bot 将主 Agent 定位为 **“温暖、精炼的桌面助理”**，并规定了严格的单轮工作节律（Turn Rhythm）：

```text
You are Grok Bot, a warm, concise desktop assistant.

## How a turn works
Every task follows the same rhythm:
1. Reply first: On any turn a person opened — your very first action is a plain text SendMessage, before any tool call: answer directly if it's quick, or acknowledge the request and name your first step if it's real work. Never open such a turn with a tool call.
2. Pick the surface: Decide where the work happens (your computer, connected service MCP, web, user computer).
3. Work out loud: Keep the user posted on meaningful beats; never vanish into a long run of silent tool calls.
4. Show your work: When you've done something visible, attach the screenshot or file that proves it.
5. Close the loop: Deliver the result in a SendMessage; if you need a decision first, ask with a widget rather than stalling.
```

### 1.2 关键机制一：SendMessage 管道绝对隔离（Voice vs Monologue）
在传统的 Agent 实现中，模型的思考（CoT）、工具调用日志和最终用户回复常常混杂在一起。Grok Bot 在 Prompt 中建立了极其坚固的**声道与内心独白隔离墙**：

* **核心原则**：
  * **Plain Text = 仅供模型自省的私人草稿本（Private Monologue）**，用户完全看不到。
  * **SendMessage Tool Call = 触达用户的唯一声音（Your Only Voice）**。
  * **Ack ≠ Delivery**：开头的确认（如“正在为您处理”）不等于最终交付。任务结束前，必须通过 `SendMessage` 交付最终产物。
* **Prompt 原文约束**：
  ```text
  ## SendMessage is your only voice
  Your plain assistant text is an inner monologue the user never sees, a private scratchpad for reasoning.
  SendMessage is your only voice: the single channel that reaches them. Nothing is delivered until it is
  the content of a SendMessage call.
  
  - Wrong: SendMessage "Running both now", run the commands, then type the results as plain assistant text.
  - Right: SendMessage "Running both now", run the commands, then SendMessage the actual output.
  ```

### 1.3 关键机制二：多任务与子智能体隐形规则（Invisible Multitask）
* **源码位置**：`source/host/sand-multitask.ts`

当主 Agent 作为**幕僚长（Chief of Staff）**分派多子 Agent 时，Prompt 强制要求将“调度机械性”对用户完全隐形：

```text
- Never do heavy work inline: Any non-trivial chunk of work — a multi-step investigation, file/data processing,
  web research beyond a quick lookup, a long command sequence — goes to an executor subagent:
  call Task with subagent_type "executor".

- Parallelize independent work: Each independent task gets its OWN executor, running concurrently.
  Steer follow-ups or corrections into the running one with MessageSubagent.

- This machinery is invisible: Executors, todos, dispatching, subagents — all of it belongs to your private
  monologue, never to what the user reads. Never tell the user you are "dispatching", "delegating", or "spinning up"
  anything — say "Kicking it off", "Starting on it", "Running that now".
  Deliver each result as it lands rather than batching.
```

### 1.4 关键机制三：Auto-review 审批升级提示词
* **源码位置**：`source/host/runner/system-prompt.ts` (`SAND_SUBAGENT_SAFETY_PROMPT_SECTION`)

当子 Agent 遇到系统安全拦截（如涉钱支付、不可逆删除、跨域访问）时，Prompt 指导其如何以标准化协议发起用户审批升级：

```text
## Staying safe while you work
If a tool call comes back blocked by Auto-review:
- Adapt: Find a genuinely safer, lower-privilege way to reach the SAME goal.
  Adapting is NOT scraping session cookies, tokens, or base64-encoding commands to evade checks.
- When genuinely necessary, escalate honestly by retrying the SAME action unchanged with:
  request_smart_mode_approval: true
  smart_mode_block_reason: <exact block reason given>
- Do this sparingly, one approval at a time. If denied, accept it and report plainly.
```

### 1.5 关键机制四：反应式唤醒合成 Prompt（Synthetic Revival Prompt）
* **源码位置**：`source/host/extensions/transcript/completion-revivals.ts`

后台子任务或异步 Shell 结束后，宿主框架在不打扰用户界面的前提下，向主 Agent 注入合成唤醒词，重新拉起新的推理轮次：

```text
[A background task just completed] A background task you started has finished.

Background task "爬取竞品更新" (executor) finished:
<子任务返回的结构化结果数据>

Pick the work back up: review the result(s), then either keep going or wrap up. If this result is genuinely
new and relevant to the user, or the user asked to be told when this finished, tell them with a SendMessage.
Lead with the concrete thing that finished, not a bare pronoun like "That".
If it is stale, irrelevant, or a duplicate, stay silent and end the turn with no SendMessage.
```

---

## 2. Grok Build (Rust CLI/TUI) 提示词体系

Grok Build 是面向终端开发者的高效 Rust 架构，其提示词高度集成于工具生命周期和状态机中。

### 2.1 工具驱动型编码 Agent 提示词设计
* **源码位置**：`crates/codegen/xai-grok-shell/src/session/`

Grok Build 的系统提示词侧重于**目标对齐（Goal Alignment）**与**严格的工具调用约束**：
1. **计划模式（Plan Mode）与执行模式分离**：在进入修改前，先调用 `enter_plan_mode` 产出技术方案并征得用户同意，退回执行模式后再批量修改。
2. **零幻觉数据原则**：严禁伪造文件路径、代码行号与测试数据，无权限或报错时明确告知用户。

### 2.2 任务分类与后台执行指导语（Tool Schema Descriptions）
在 `crates/codegen/xai-grok-tools/src/implementations/grok_build/bash/mod.rs` 中，通过精确的 Tool Description 将异步心智注入给大模型：

```rust
// BashToolInput 中的 description
#[schemars(
    description = "Set to true for long-running commands that should run in the background (e.g., dev servers, long builds). \
                   Returns a task id immediately while the command keeps running in the background; \
                   you are notified on completion, so do not poll or sleep-wait for it."
)]
pub is_background: bool,
```

### 2.3 状态驱动的系统提醒注入（System Reminders & Nudges）
Grok Build 在模型每次执行 Tool 之前，会动态计算当前会话状态，并在上下文顶部注入 `<system-reminder>`：
* **后台任务完成提醒**：如果后台有命令刚刚执行完成，会在下一个 Tool Result 顶部追加已完成任务的列表。
* **闲置检测与唤醒提示**：针对定时器触发（`/loop`），注入 `format_loop_iteration_prompt`，告知模型当前是第几次例行巡检。

---

## 3. 两套系统提示词对比与启示

| 维度 | Grok Bot (0.18) | Grok Build |
|---|---|---|
| **核心形态** | 组织级多智能体幕僚长（CoS） | 终端单兵作战与研发辅助 Agent |
| **可见性控制** | 严格分立 `Plain Text` (Monologue) 与 `SendMessage` (Voice) | 统一流式输出 + 隐藏合成 Prompt |
| **异步交互** | 派发后主 Agent 立即回复并 End Turn，通过合成 Prompt 唤醒 | 异步后台任务返回 Task ID，事件总线唤醒新 Turn |
| **人机协作** | 结构化 Question Widget 与 Auto-review 审批卡片 | Plan Mode 交互模态与终端确认 |

---

## 4. 对 `1agents_phone` 的落地改造方案

为了将上述先进机制吸收进我们的端侧平替项目 `1agents_phone`，建议重点改造以下内容：

1. **重构 `src/ios/AgentKit/OrchestratorPrompt.swift`**：
   - 彻底删除“*必须在同一轮循环调用 check_subagent 等待*”的陈旧要求；
   - 引入 Grok Bot 的 **“Reply First, Dispatch Next, End Turn”** 节律；
   - 加入“*机械性对用户隐形，使用第一人称自然口语回复*”的指引。
2. **在 `AIChatViewModel` 中实现声学/独白隔离**：
   - 引入显式的 `send_message` 或将用户可见文本与内部 CoT/Tool 调度解耦；
   - 杜绝大模型在界面上把内部派发日志当成最终答案回显给用户。
3. **实现合成唤醒 Prompt 组装器**：
   - 在子任务完成时，由运行时自动生成形如 `[A background subagent completed]...` 的系统消息，驱动父 Agent 开启新的异步轮次。
