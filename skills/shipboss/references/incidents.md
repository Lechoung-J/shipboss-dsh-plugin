# 事故与问题清单

登记真实事故：**已证事实 / 未知项 / 修复** 三栏分开写，不合并归因。
新事故按同样格式追加，不覆盖旧条目。

---

## I-001 后台任务被当成"完成回调"，`unknown job` 无法恢复

- 时间：2026-10-18
- 现场：某桌面应用 离线模型下载（该项目的一个工单 / 同项目的另一张单）
- 影响：约 252 MB partial 保留、任务既未完成也未判定失败；业务门仍为 false

### 已证事实

1. 工程子 agent 结束本轮 ≠ 它内部启动的后台 job 完成。
2. 连续 3 次 `job_output(wait:true, 60s)` 返回 running 后，宿主发出"重复工具调用"告警。
3. owner 恢复后查询自己的一次后台任务，返回 `Error: unknown job`。
4. 没有宿主退出码、没有 runtime summary/manifest/下载终态收据。
5. 启动记录没有 PID/PGID；监督器只在子进程结束后写 pid 收据。
6. 目标文件停在约 250 MB（约 51.7%），stderr 末行为 `curl: (92) HTTP/2 stream 1 was not closed cleanly: CANCEL (err 8)`。
7. `lsof`（三个精确路径）与 `pgrep`（监督器路径）均无可见匹配。
8. 权限在故障**之后**才改为 danger-full-access/never，不构成下载许可。

### 未知项（不得合并归因）

- HTTP/2 CANCEL 的源头；
- 监督器为何未写终态收据；
- 是否有进程在跑但不可见；
- CANCEL 与"工程结束本轮"是否同因（时序证据不足）。

### 本仓复现（2026-10-18，本会话实验）

- PM 自己的后台 job：跨轮存活、完成通知自动送达、终态可查（exit 0）。
- **子 agent 内部的后台 job：该子 agent 轮次结束后即不可查，且不再推进**（两次独立复现）。
- 父 agent 查询子 agent 的 job：`unknown job`。

结论：`unknown job` 是**归属丢失**，不是失败宿主的记录损坏；长任务不能挂在子 agent 内部。

### 修复

- `dispatch.md` §4：区分"阶段性 final"与"宣称业务完成"；长任务必须由 PM 层受管 job 承载；
  `unknown job` 的处置规则；宿主 rule 冲突的披露方式。
- `runtime-evidence.md`（新增）：启动记录 / 终态记录 / 恢复判断顺序。
- `pm-handoff.md`：交接必须带 running / unknown 任务及其 ID 与状态。

### 仍需宿主维护者处理（技能改不了）

1. **规则冲突**：宿主"final 前收齐后台结果（必要时 wait:true）"与"不要轮询/不要多次阻塞"之间需要明确优先级，
   当前 3 次 wait:true 会被判为重复调用告警。
2. **inactive 子 agent 的 job 注册保留**：子 agent 轮次结束后，其 job 是否应保留可查（当前不可查）。
3. **完成消息路由**：子 agent 内部的 job 完成后，完成事件是否应送达父或原 owner。
4. **owner/parent 查询边界**：父查子 job 返回 unknown 是否为预期语义。
5. **恢复后的 ID 连续性**：跨 Stop/重启后 job_id 是否可继续解析（当前不支持，不得承诺）。
6. **`subagent finished` 的语义**：需明确它只表示轮次结束，不含内部任务状态；通知文本最好直接写明。
7. **终态收据**：宿主是否能为受管 job 提供退出码与终态文件（当前部分场景无）。
