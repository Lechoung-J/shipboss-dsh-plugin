/**
 * shipboss-dsh-plugin — 把 SHIPBOSS 技能物化进 DSH 的用户技能目录。
 *
 * 架构（已定死，见 TASK.md）：
 *   - 本插件不调用 `ctx.skills.register()`（它没有目录/资源字段，装不下 references），
 *     也不注册自定义 skill provider。
 *   - `apply()` 把包内 `skills/shipboss/` 复制到 `$DSH_HOME/skills/shipboss/`，
 *     交给 DSH 自带的 `dsh-skill-filesystem` provider 去发现（它会解析 SKILL.md
 *     的 frontmatter，并 watch 目录，新增技能无需重启）。
 *
 * 安全边界：
 *   - host 进程内运行；`apply()` 永不抛，任何失败都只记日志。
 *   - 只写技能根下的 `shipboss/`、临时目录 `shipboss.tmp-<pid>` 与备份
 *     `shipboss.bak-<ts>`；不删除目标之外的任何东西。
 *   - `enabled:false` 时不读不写，只打 loaded。
 *
 * @module shipboss-dsh-plugin
 */

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** cordis 用它对 fiber 命名，日志里也用它。 */
export const name = 'shipboss-dsh-plugin'

/** 本插件不依赖任何 host 服务；不使用 inject。 */
export const inject = []

const TAG = '[shipboss]'
const SKILL_DIR_NAME = 'shipboss'
const VERSION_FILE = '.shipboss-version'

const DEFAULTS = Object.freeze({
  enabled: true,
  skillRoot: null,
  onConflict: 'skip',
})

function errorMessage(error) {
  if (error instanceof Error) return error.message
  return String(error)
}

/** 安全日志适配：ctx.logger 是 cordis 内建属性，不是可注入服务。 */
function makeLogger(ctx) {
  const sink = ctx?.logger
  const send = (level, message) => {
    try {
      const fn = sink?.[level]
      if (typeof fn === 'function') {
        fn.call(sink, message)
        return
      }
    } catch {
      /* 日志本身不许影响宿主 */
    }
    try {
      if (level === 'warn') console.warn(message)
      else if (level === 'error') console.error(message)
    } catch {
      /* ignore */
    }
  }
  return {
    info: (message) => send('info', message),
    warn: (message) => send('warn', message),
    error: (message) => send('error', message),
  }
}

/** 把配置收敛成可执行的三元组；未知键忽略，坏类型回落到默认值。 */
export function normalizeConfig(raw) {
  const source = raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  const enabled = source.enabled === undefined ? DEFAULTS.enabled : source.enabled !== false
  const onConflict = source.onConflict === 'overwrite' ? 'overwrite' : 'skip'
  let skillRoot = null
  if (typeof source.skillRoot === 'string' && source.skillRoot.trim() !== '') {
    skillRoot = source.skillRoot.trim()
  }
  return { enabled, skillRoot, onConflict }
}

/** `$DSH_HOME` 未设或为空时回落到 `~/.dsh`。 */
export function resolveDshHome(env = process.env) {
  const configured = typeof env.DSH_HOME === 'string' ? env.DSH_HOME.trim() : ''
  if (configured !== '') return expandTilde(configured)
  return join(homedir(), '.dsh')
}

/** 展开 `~` / `~/x`；绝对路径原样返回；相对路径按 cwd 解析。 */
function expandTilde(value) {
  if (value === '~') return homedir()
  if (value.startsWith('~/') || value.startsWith('~\\')) return join(homedir(), value.slice(2))
  return resolve(value)
}

/** 技能根：`skillRoot` 覆盖，否则 `$DSH_HOME/skills`。 */
export function resolveSkillRoot(config, env = process.env) {
  if (config.skillRoot !== null) return expandTilde(config.skillRoot)
  return join(resolveDshHome(env), 'skills')
}

/** 包根目录（lib/index.js 的上一级）。 */
function packageRoot() {
  return dirname(dirname(fileURLToPath(import.meta.url)))
}

/** 包版本；读不到时返回 '0.0.0'，绝不让 apply 失败。 */
function packageVersion(root) {
  try {
    const parsed = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
    if (typeof parsed.version === 'string' && parsed.version.trim() !== '') return parsed.version.trim()
  } catch {
    /* fall through */
  }
  return '0.0.0'
}

/** 读目标目录的版本标记；没有、读不到、不是目录都视为 null。 */
function readVersionMarker(target) {
  try {
    const text = readFileSync(join(target, VERSION_FILE), 'utf8').trim()
    return text === '' ? null : text
  } catch {
    return null
  }
}

/** 生成不与现有路径冲突的 `<name>-<prefix><stamp>`。 */
function uniqueSibling(skillsRoot, prefix, stamp) {
  let candidate = join(skillsRoot, `${SKILL_DIR_NAME}.${prefix}-${stamp}`)
  if (!existsSync(candidate)) return candidate
  let n = 1
  for (;;) {
    candidate = join(skillsRoot, `${SKILL_DIR_NAME}.${prefix}-${stamp}-${n}`)
    if (!existsSync(candidate)) return candidate
    n += 1
  }
}

function timestamp() {
  const now = new Date()
  const pad = (value) => String(value).padStart(2, '0')
  return [
    now.getUTCFullYear(),
    pad(now.getUTCMonth() + 1),
    pad(now.getUTCDate()),
    '-',
    pad(now.getUTCHours()),
    pad(now.getUTCMinutes()),
    pad(now.getUTCSeconds()),
  ].join('')
}

/**
 * 逐文件递归复制。刻意不用 Node 内置的同步递归目录复制：它在遇到不可读目录时
 * 会从 C++ 层 abort（exit 134），`try/catch` 拦不住，会连带杀死宿主进程。
 * `readdirSync` / `readFileSync` 的失败都是普通 JS 异常，可以被 `apply()` 捕获。
 */
function copyTreeSync(source, destination) {
  const stat = lstatSync(source)
  if (stat.isDirectory()) {
    mkdirSync(destination, { recursive: true })
    for (const entry of readdirSync(source, { withFileTypes: true })) {
      copyTreeSync(join(source, entry.name), join(destination, entry.name))
    }
    return
  }
  if (stat.isSymbolicLink()) {
    symlinkSync(readlinkSync(source), destination)
    return
  }
  mkdirSync(dirname(destination), { recursive: true })
  writeFileSync(destination, readFileSync(source))
}

/** 先写同级临时目录，再 rename；同一文件系统内 rename 是原子的。 */
function installAtomically(skillsRoot, target, sourceDir, version, options = {}) {
  mkdirSync(skillsRoot, { recursive: true })
  const temp = join(skillsRoot, `${SKILL_DIR_NAME}.tmp-${process.pid}`)
  try {
    rmSync(temp, { recursive: true, force: true })
    copyTreeSync(sourceDir, temp)
    writeFileSync(join(temp, VERSION_FILE), `${version}\n`)
    // 测试注入口：默认不存在；用于验证「rename 之前失败」不会留下半成品。
    if (typeof options.beforeRename === 'function') {
      options.beforeRename({ temp, target })
    }
    renameSync(temp, target)
  } catch (error) {
    try {
      rmSync(temp, { recursive: true, force: true })
    } catch {
      /* cleanup 失败不能掩盖原错误 */
    }
    throw error
  }
}

/**
 * 物化技能树。返回一个结果标签，便于测试与日志：
 * `installed` | `unchanged` | `upgraded` | `overwritten` | `skipped-conflict`
 */
export function materialize(config, options = {}) {
  const log = options.log ?? makeLogger(options.ctx)
  const root = options.packageRoot ?? packageRoot()
  const sourceDir = join(root, 'skills', SKILL_DIR_NAME)
  const version = options.version ?? packageVersion(root)

  if (!existsSync(join(sourceDir, 'SKILL.md'))) {
    log.warn(`${TAG} bundled skill is missing (${join(sourceDir, 'SKILL.md')}); nothing materialized`)
    return 'missing-source'
  }

  const skillsRoot = options.skillsRoot ?? resolveSkillRoot(config, options.env ?? process.env)
  const target = join(skillsRoot, SKILL_DIR_NAME)

  const marker = existsSync(target) ? readVersionMarker(target) : null
  const targetExists = existsSync(target)

  if (targetExists && marker !== null) {
    if (marker === version) {
      log.info(`${TAG} skill already present at ${target} (version ${version}); leaving it untouched`)
      return 'unchanged'
    }
    const backup = uniqueSibling(skillsRoot, 'bak', timestamp())
    log.info(`${TAG} upgrading ${target} (${marker} -> ${version}); backup: ${backup}`)
    renameSync(target, backup)
    installAtomically(skillsRoot, target, sourceDir, version, options)
    return 'upgraded'
  }

  if (targetExists) {
    if (config.onConflict !== 'overwrite') {
      log.warn(
        `${TAG} ${target} exists but is not managed by this plugin (no ${VERSION_FILE}); ` +
          `onConflict=skip, writing nothing`,
      )
      return 'skipped-conflict'
    }
    const backup = uniqueSibling(skillsRoot, 'bak', timestamp())
    log.warn(`${TAG} ${target} exists without ${VERSION_FILE}; onConflict=overwrite, backup: ${backup}`)
    renameSync(target, backup)
    installAtomically(skillsRoot, target, sourceDir, version, options)
    return 'overwritten'
  }

  installAtomically(skillsRoot, target, sourceDir, version, options)
  log.info(`${TAG} materialized skill at ${target} (version ${version})`)
  return 'installed'
}

/**
 * cordis host 插件入口。
 *
 * @param {object} [ctx] - cordis context（不需要 inject；logger 可选）
 * @param {object} [config] - `cordis.patch.yml` 里的 `config:` 段
 * @returns {() => void} disposer
 */
export function apply(ctx, config = {}) {
  let log
  try {
    log = makeLogger(ctx)
  } catch {
    // 极端情况下 ctx 的属性访问本身会抛；退回到 console，仍然不抛。
    log = makeLogger(undefined)
  }

  // 契约 1：第一行就打 loaded，服务缺失时也看得到。
  log.info(`${TAG} loaded`)

  try {
    const normalized = normalizeConfig(config)
    if (!normalized.enabled) {
      log.info(`${TAG} disabled by config; no filesystem access`)
      return () => {}
    }
    materialize(normalized, { log, ctx })
  } catch (error) {
    // 契约 7：所有失败路径只记日志，不影响宿主启动。
    log.warn(`${TAG} materialization failed: ${errorMessage(error)}; plugin stays inert`)
  }

  return () => {}
}

/** 测试/诊断用；不改变插件契约。 */
export const __internals = {
  DEFAULTS,
  VERSION_FILE,
  normalizeConfig,
  resolveDshHome,
  resolveSkillRoot,
}
