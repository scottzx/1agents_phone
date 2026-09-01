# Subagent 与 Direct A2A 异步 Tool Result 通知

## 目标

iOS harness 将 Subagent 和 Direct A2A 作为后台任务运行。发起方当前轮立即收到“任务已启动”的普通 tool result，不等待后台结果。任务终止后，harness 向来源 session 注入隐藏的 synthetic `tool_use` + `tool_result` 消息组，然后恢复 Agent loop。

不使用 `<system-reminder>`，不新增消息 role，不将内部工具 `async_task_notice` 暴露给模型主动调用。

## 首期范围

- Subagent。
- Direct A2A，包括单接收方和多接收方广播。
- 仅 iOS。

不包括 Group A2A、`GroupChatEngine`、群聊 FIFO、群成员并发和群聊 transcript。后者保持现有虚拟群聊语义。

## ID 模型

`notice_id`、`task_id` 和 `agent_id` 不得互相代替。

| 字段 | 含义 | Subagent | Direct A2A |
| --- | --- | --- | --- |
| `notice_id` | 终止通知的幂等键 | `async:subagent:<task_id>:<run_id>` | `async:a2a:<task_id>` |
| `task_id` | 一次后台执行或投递 | Subagent scratch session/task ID | 每个接收方独立生成的投递 ID |
| `agent_id` | 实际执行者或接收者 | Subagent 使用的 Agent ID | 目标 Agent ID |
| `source_session_id` | 通知的回送目标 | 父 session | 发送方 session |

Subagent 允许 `message_subagent` 重启同一 `task_id` 的当前执行，因此使用每代 `run_id` 构造 `notice_id`。同一代的重复完成回调命中同一个 notice，新一代仍可产生新通知。

Direct A2A 不用目标 `agent_id` 充当 `task_id`。广播给 N 个 Agent 时生成 N 个 `task_id`，每个投递独立完成、失败和去重。首期不需要额外的 `batch_id`。

## 持久化与注入

后台结果到达时写入轻量 pending notice：

- `notice_id`
- `source_session_id`
- `task_type`
- `task_id`
- `agent_id`
- `status`
- `result`
- `files_path`
- `created_at`

来源 session 忙时只排队。session 空闲后一次领取当前全部 pending notice，在一个数据库事务中：

1. 追加 assistant synthetic `tool_use(async_task_notice)` 消息。
2. 追加对应的 user `tool_result` 消息。
3. 将 notice 标记为 delivered。

`tool_use_id` 和两条消息 ID 都从 notice ID 确定性派生，崩溃重试不得产生重复消息或孤立 tool result。

注入后调用 `resumeAfterAsyncToolResults(sessionId:)`。整个 synthetic 消息组保留在 session 历史中，但不显示在 UI。notice 驱动轮次返回 `(pass)` 时保持静默，只有实质性文本才展示给用户。

用户消息优先于未开始的异步通知轮次。

## Subagent 流程

1. `spawn_subagent` 创建 scratch session，生成 `task_id` 和 `run_id`。
2. 工具立即返回 `Task started` 和 `task_id`。
3. Subagent 在后台完成、失败、停止或超时。
4. harness 使用 `task_id + agent_id + run_id` 写入终止 notice。
5. `check_subagent` 只做手动状态查询。旧 `wait_seconds` 参数可被解析，但不再阻塞等待。
6. `message_subagent` 和 `stop_subagent` 保持现有能力。

## Direct A2A 流程

1. 为每个接收方生成独立 `task_id`。
2. 将消息投递给目标 Agent 的主 session。
3. 工具立即返回 `task_id + agent_id + running`。
4. 目标本轮完成或失败后，harness 向发送方 session 写入 notice。
5. 保持现有 busy/`interrupt`、回环检测和三跳限制。

`wait_seconds` 和 `is_background` 不再决定 Direct A2A 的执行方式：Direct A2A 固定异步。

## Group 边界

Group 在执行语义上是虚拟房间，不是一个可调用模型的 Group Agent：

- `GroupProfile` 保存 `group_id`、成员和模式。
- 共享 transcript session 保存用户可见群聊，其 `agent_id` 为空。
- 每个成员拥有独立隐藏 member session，真正的模型执行发生在这些 session 中。
- `GroupChatEngine` 负责 transcript 路由、FIFO 和静默终止。

首期不将 Group engine 的 closing line 通过 `async_task_notice` 回推给外部发送 session。Group 的结果留在共享 transcript，群聊调度保持现状。

## 非目标

- 不建立通用后台任务框架。
- 不引入新的消息 role。
- 不将 Group 抽象成一个真实 Agent。
- 不改 Android 和 macOS。
