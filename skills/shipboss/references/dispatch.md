# 派发、待命与恢复（Transport）

目标：工程师在后台工作，PM 结束当前轮次；收到完成事件后再收结果、验收和汇报。
这是跨轮次协作，不是把一个前台等待命令改名为「后台」。

## 1. 先确认宿主条件

首次使用或环境变化时，检查所选工程师的命令、认证与配置。已有可用证据时不要每张工单都重新跑付费自检。版本号存在不等于能执行任务；失败诊断按实际错误处理，不擅自改全局配置。

- 使用 DSH 管理的后台 job 或可持续子 agent，必须取得其返回的标识。
- 普通 DSH `subagent` 与外部 Codex 是不同后端，不能用前者冒充后者。
- 完成事件唤醒依赖会话与宿主仍存活、后台任务归属有效、完成投递启用。重启后不能假设旧 job 仍可恢复。
- 检查是否存在更高优先级的「结束前必须收齐后台结果」规则，或会在待命期间自动续轮的活跃 goal。Skill 无法覆盖它们。若冲突，明确报告当前环境不能保证此模式；不要反复轮询来掩盖冲突，不擅自改宿主配置。
- 不要仅为了「记住尚未完成的后台任务」创建持续续轮 goal。若宿主要求使用 goal，遵循其规则，并报告对待命模式的限制；未完成任务不能标为完成。仅在用户授权时暂停/调整已有 goal。

## 2. 准备任务与隔离目录

并行任务使用不同的 worktree/checkout；仅在同一目录切换分支不能实现并行隔离。
确认任务、基线 revision、允许改动范围和测试命令。保留已有未提交成果，不用 reset/clean/stash 清掉用户工作。

在项目原有工单记录中维护一条运行记录；若没有合适位置，使用 `.delegate/<task>/RUN.md`：

| 字段 | 内容 |
|---|---|
| 身份 | 工单 ID、尝试编号、实现/验收阶段、规格版本 |
| 执行位置 | repo、工程师 worktree、基线 commit、产物位置 |
| 运行标识 | 宿主 job_id 或 agent_id；可用时另记工程师 session/thread ID |
| 结果位置 | 最终回答、事件日志、证据目录、可获得的退出状态 |
| 状态 | launching / running / completed-awaiting-review / reviewing / done / failed / interrupted / unknown |
| 后续动作 | 完成后验收什么、依赖哪些任务、上次核对时间 |

先记 launching，成功启动后补实际 ID 并记 running。没有拿到有效 ID 不宣称已后台派发。

## 3. 派发方式

### CLI：Codex / Claude Code

**以下是交给 DSH `bash` 工具的 command 内容；工具参数必须同时设置 `run_in_background: true` 和实际 workdir。**
`run_in_background` 不是 Codex 的命令行参数，也不能用 shell 的 `&`、nohup 或脱管进程替代。

Codex 示例（将占位路径替换为经过核实的绝对路径）：

```bash
codex exec \
  -C '/absolute/task-worktree' \
  -s workspace-write \
  --json \
  -o '/absolute/task-worktree/.delegate/TASK-ID/evidence/last-message.txt' \
  '阅读 .delegate/TASK-ID/TASK.md 并完成授权交付物，不修改需求文档。' \
  > '/absolute/task-worktree/.delegate/TASK-ID/evidence/codex-events.jsonl' \
  2> '/absolute/task-worktree/.delegate/TASK-ID/evidence/codex-stderr.log'
```

启动前创建证据目录并确保工程师读得到规格。进程退出码必须保留，不能用后续成功的 echo 掩盖失败。

Claude Code 同样通过 DSH `bash(run_in_background: true, workdir=<task-worktree>)` 启动：

```bash
claude -p --permission-mode acceptEdits --output-format json \
  '阅读 .delegate/TASK-ID/TASK.md 并完成授权交付物，不修改需求文档。' \
  > '/absolute/task-worktree/.delegate/TASK-ID/evidence/claude-result.json' \
  2> '/absolute/task-worktree/.delegate/TASK-ID/evidence/claude-stderr.log'
```

以本机 CLI 帮助确认版本支持的参数。`--add-dir` 不是切换 cwd，也不是文件隔离。
采用符合授权的权限策略，不为无人值守默认绕过权限。长链路记忆策略见 `handoff.md`。

### 原生后端

仅当 `subagent_codex` / `subagent_claude_code` 已实际可用时调用，设置 `run_in_background: true`。
按真实返回类型区分 job_id 和可持续 agent_id；job 由 job 工具收取，可持续 agent 由通知和消息工具接续。
不要把两种 ID 混用。原生一次性后端能否续接、模型是否可选，以已安装版本能力为准。

### MCP

先检查工具是否同步阻塞、是否支持后台管理及完成事件。一个 MCP 服务能连接不等于它的长调用是异步的。
不能取得后台标识和完成事件的通道，不符合本协议的待命要求；说明限制，选择已授权的受管后台方式。

### 子 agent 内部的后台 job（硬限制）

- **不要把长任务挂在子 agent 内部的后台 job 上。** 实测（2026-10-18，两次独立复现）：
  子 agent 轮次结束后，它启动的 job 既不可查（`unknown job`），也不再推进；父 agent 同样查不到。
- 长任务（下载、构建、批处理）必须由 **PM 层受管后台 job** 承载；子 agent 只做「同步做完一件事」。
- 依据与实验：`incidents.md` I-001、`runtime-evidence.md`。

## 4. 派发后必须交还控制权

1. 记录运行标识、状态和后续动作；同批已批准且互不冲突的任务可以并行派发。
2. 完成老板当前问题以及其他确实可立即推进的工作。不要为了保持运行发明额外检查。
3. **只剩后台依赖未完成时，用简短 final 结束本轮。** 例如：「W-003 已派发，完成后我会接回验收；现在可以继续讨论其他需求。」不宣称整个任务已完成。
   3.1 **阶段性 final ≠ 宣称业务完成。** 结尾必须分开写：哪些是**已交付**、哪些是**已派发、等完成事件**、
   哪些是**状态未知**。业务结算、换班或对外宣称完成时才要求相关终态收齐；阶段性待命不要求。
   3.2 结束本轮前按 `runtime-evidence.md` 写 launch record（owner / job_id / argv / cwd / 时间 / 输出路径）。
   **没有 launch record 就不算已派发。**
4. 不连续调用 `job_output` / `job_list` / `list_agents`，不 `sleep`、循环查 PID、刷日志等待完成。把 wait 改成 false 但不停查也属于轮询。
5. 这里的默认规则是不使用 `job_output(wait: true)` 留在轮次里等工程师。用户明确要求同步等待或宿主强制等待时属于例外，应说明本轮不提供空闲回调体验。

`wait:false` 是非阻塞查询，timeout 参数不意味着睡眠。工具阻塞期间不等于 LLM 持续生成；反复返回模型再发起查询才增加请求与 token。界面显示运行不能单独证明持续计费。

结束本轮不需要杀 job，也不需要按 Stop。PM 空闲不代表工程师不消耗其自身算力。

## 4.6 宿主强制“结束前收齐”时怎么办

若宿主规则要求在 final 前收齐后台结果（例如「give a final answer 前 collect every still-relevant job」），
而本协议要求结束轮次等待完成事件，两者会冲突。处理顺序：

1. 先判断是否**真的阻塞**：只是可等待的 job、且完成事件可用 → 按本协议结束本轮，在 final 里写清状态。
2. 若宿主明确要求收拢，做**一次**有界收拢（`job_output(wait: false)`；必要时单次短 `wait:true`，≤60s），
   结果写入 launch/terminal record，然后结束本轮。**不要把“一次收拢”变成连续多次。**
3. 若宿主因连续阻塞等待发出告警：立即停止等待，把状态标为 `interrupted-before-terminal`，
   在 final 里明确「本轮未收到终态，任务可能仍在运行，状态未知」。
4. **不得把这类冲突掩盖成“已保证回调”。** 在 `RUN.md` / `PM-STATE.md` 写明：
   `capability.completion_callback: supported | unsupported | rules-conflict`，并列出需要宿主维护者裁决的点。

## 5. 完成事件到达

- 根据运行记录将通知匹配到具体工单和尝试；重复、延迟通知先核对状态，不重复派活或重复验收。
- job 通知：调用 `job_output(job_id, wait: false)` 收结算结果，检查真实退出状态，再读最终回答/证据。失败时只读必要诊断。
- subagent 通知：使用通知携带的结果和其指定产物；不要把 agent_id 传给 job_output。
- 若查询显示仍在运行，记录状态后返回待命，不进入查询循环。
- 若 `job_output` 返回 `unknown job`：按**归属丢失**处理——不重派、不删现场、不假设失败或完成；
  状态标 `unknown`，先固定现有证据（文件大小、mtime、日志尾部），再按 `runtime-evidence.md` §4 判断恢复路径。
- 实现结束标记为 completed-awaiting-review，不是 done。固定包含交付内容的 revision 后再派验收；只有基线或旧版本的审查不算本次交付验收。
- 验收员也后台派发；它运行期间 PM 按同样规则结束本轮。验收结果到达后先更新进度记录，再按原有工单安排推进。
- 派下一批或返工之前，检查 PM 是否进入换班收尾状态。若已收尾，不再启动新任务；按 `pm-handoff.md` 收齐本批状态并准备交接。正常状态不要每完成一单就要求老板换窗口。
- 老板当前问题仍在处理时，先完整回答当前问题，再简短说明任务状态；后台通知不应强迫转移话题。

## 6. Stop / 会话恢复后接回任务

**先核对，再续接；按过 Stop 不等于工程师已停止。**

1. 重读当前 skill 和本节，并读取原有工单、运行记录、最近产物；不重新规划业务目标或修改既有 AC。
2. 做一轮有界检查：按真实后端查询 job/agent 状态，必要时读取日志尾部及匹配 cwd/命令/启动时间的进程信息。旧 PID、旧 final 文件都不能单独证明当前状态。
3. 分情况处理：
   - **仍运行且受宿主管理**：保留现有任务，记录并结束本轮，等待原完成事件；不再起第二个工程师。
   - **已完成**：收结果、检查交付 revision，继续原有验收；不重做实现。
   - **已停止/失败**：保留 worktree、日志和未提交产物；确认无存活写入者后，根据实际进度续接明确的工程师 session 或新建补做任务，不盲用 `resume --last`。
   - **状态不明或失去宿主归属**：记录 unknown，不能当作失败然后重派。若已有可验证的受管重接能力，才使用；否则明确说明自动回调尚未恢复，提出最小恢复动作，不假装已经接管、不无限轮询。
4. 若恢复时发现 goal 持续唤醒 PM，按用户授权及宿主规则处理；否则报告该限制。Skill 的运行记录不是调度器，不会自行唤醒会话。

禁止恢复时删除原工单、重置工程师工作树、随意杀进程或清掉未验收成果。

## 上下文卫生

事件日志和完整测试日志落盘，常规只读最终回答与关键证据。诊断失败或核对状态时可限量读必要过程信息。
交接给工程师的是规格及产物路径；交接给验收员的是验收标准和实际交付 revision，不是实现者的整段会话。
