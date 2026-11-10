# SHIPBOSS for DSH

把 [SHIPBOSS](https://github.com/Lechoung-J/SHIPBOSS) 协议装成 DeepSeek Harness 的 **/shipboss** 技能。

**你是老板，你只需要一个 PM。** 实施交给外部编码 agent（Codex / Claude Code），
本会话只负责定义需求、排期与验收——并按协议独立验收，不信工程师的自述。

## 装：加一个索引源（推荐）

DSH 里 **Plugins → Discover → Add index source**，加上：

```
https://cdn.jsdelivr.net/gh/Lechoung-J/shipboss-dsh-plugin@main/index.json
```

然后搜 **SHIPBOSS** 一键安装。

## 装：直接给 pnpm 参数

```bash
dsh plugin --profile <你的 profile> add git+https://github.com/Lechoung-J/shipboss-dsh-plugin.git
```

（跟 `main` 最新；要钉版本就用索引里的精确 commit。）

装上后技能物化到 `$DSH_HOME/skills/shipboss/`。**重启 DSH**，之后 `/shipboss` 可用。

## 这个版本缺什么（实话）

- **记录员（scribe）不在公开版**：它依赖未开源的内部工具。
- 协议本身仍在迭代，这一版对应 SHIPBOSS v0.1.0。
- 本包**只装技能**：不注册工具、不改你的项目、不读你的会话历史。

## 卸

删掉 profile 里那条 insert；`$DSH_HOME/skills/shipboss/` 手工删除即可。

## 许可证

MIT，与 SHIPBOSS 一致。
