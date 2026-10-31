import fs from "node:fs"
import path from "node:path"
import { spawn } from "node:child_process"
import { once } from "node:events"
import { fileURLToPath } from "node:url"

const root = path.resolve(fileURLToPath(new URL("..", import.meta.url)))
const serverDir = path.join(root, "server")
const serverBinary = path.join(serverDir, "zig-out", "bin", "shoufad")
const requestedServerArgs = process.argv.slice(2)
const hasBindOverride = requestedServerArgs.some((arg) => arg === "--bind" || arg.startsWith("--bind="))
const serverArgs = hasBindOverride ? requestedServerArgs : ["--bind", "0.0.0.0", ...requestedServerArgs]

let serverProcess = null
let shuttingDown = false
const watchers = []
let buildTimer = null
let building = false
const pending = { frontend: false, server: false }
const lockPath = path.join(root, ".shoufa-dev.lock")
const lockData = { nodePid: process.pid, serverPid: null }
let ownsDevLock = false

function isAlive(pid) {
  if (!pid) return false
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function writeDevLock() {
  fs.writeFileSync(lockPath, JSON.stringify(lockData))
}

function acquireDevLock() {
  if (fs.existsSync(lockPath)) {
    try {
      const existing = JSON.parse(fs.readFileSync(lockPath, "utf8"))
      if (existing.nodePid && isAlive(existing.nodePid) && existing.nodePid !== process.pid) {
        console.error(`[dev] another dev server is already running (pid ${existing.nodePid})`)
        process.exit(1)
      }
      if (existing.serverPid && isAlive(existing.serverPid)) {
        console.warn(`[dev] stopping stale shoufad process (pid ${existing.serverPid})`)
        try { process.kill(existing.serverPid, "SIGTERM") } catch {}
      }
    } catch {
      // Ignore a corrupt/stale lock.
    }
    fs.rmSync(lockPath, { force: true })
  }
  writeDevLock()
  ownsDevLock = true
}

function releaseDevLock() {
  if (!ownsDevLock) return
  ownsDevLock = false
  try { fs.rmSync(lockPath, { force: true }) } catch {}
}

const ignored = [
  "node_modules",
  ".git",
  ".next",
  "dist",
  "server/src/web",
  "server/src/web_assets.zig",
  "server/zig-out",
  "server/.zig-cache",
  "tsconfig.tsbuildinfo",
  ".shoufa-dev.lock",
  ".DS_Store",
]

function isIgnored(relativePath) {
  const normalized = relativePath.split(path.sep).join("/")
  const base = path.basename(normalized)
  return ignored.some((entry) => normalized === entry || normalized.startsWith(`${entry}/`)) ||
    base.startsWith("_tmp_") ||
    base.startsWith("vite.config.ts.timestamp-") ||
    normalized.endsWith("~") ||
    normalized.endsWith(".swp") ||
    normalized.endsWith(".swx")
}

function classify(relativePath) {
  const normalized = relativePath.split(path.sep).join("/")
  return normalized.startsWith("server/") ? "server" : "frontend"
}

function scheduleBuild() {
  if (buildTimer) clearTimeout(buildTimer)
  buildTimer = setTimeout(() => {
    buildTimer = null
    void runBuilds()
  }, 250)
}

function onFsEvent(base, filename) {
  if (!filename) return
  const relativePath = path.relative(root, path.join(base, filename.toString()))
  if (relativePath.startsWith("..") || isIgnored(relativePath)) return

  console.log(`[dev] change: ${relativePath}`)
  pending[classify(relativePath)] = true
  scheduleBuild()
}

function watch(target, recursive = true) {
  if (!fs.existsSync(target)) return
  try {
    const watcher = fs.watch(target, { recursive }, (_event, filename) => {
      onFsEvent(target, filename)
    })
    watchers.push(watcher)
  } catch (error) {
    console.warn(`[dev] could not watch ${path.relative(root, target) || "."}: ${error.message}`)
  }
}

function runCommand(command, args, cwd) {
  return new Promise((resolve, reject) => {
    console.log(`[dev] $ ${command} ${args.join(" ")}`)
    const child = spawn(command, args, {
      cwd,
      env: process.env,
      stdio: "inherit",
    })
    child.on("error", reject)
    child.on("exit", (code) => {
      if (code === 0) resolve()
      else reject(new Error(`${command} exited with code ${code}`))
    })
  })
}

function prefixOutput(stream, prefix) {
  let buffer = ""
  stream.on("data", (chunk) => {
    buffer += chunk.toString()
    const lines = buffer.split("\n")
    buffer = lines.pop() ?? ""
    for (const line of lines) process.stdout.write(`[${prefix}] ${line}\n`)
  })
  stream.on("end", () => {
    if (buffer) process.stdout.write(`[${prefix}] ${buffer}\n`)
  })
}

function startServer() {
  if (shuttingDown) return

  const child = spawn(serverBinary, serverArgs, {
    cwd: serverDir,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  })

  serverProcess = child
  lockData.serverPid = child.pid ?? null
  writeDevLock()
  prefixOutput(child.stdout, "server")
  prefixOutput(child.stderr, "server")

  child.on("error", (error) => {
    console.error(`[dev] failed to start server: ${error.message}`)
  })
  child.on("exit", (code, signal) => {
    if (serverProcess === child) serverProcess = null
    lockData.serverPid = null
    if (!shuttingDown) writeDevLock()
    if (!shuttingDown) {
      console.error(`[dev] server exited (${signal ?? code})`)
    }
  })
}

async function stopServer() {
  const child = serverProcess
  if (!child) return
  serverProcess = null
  lockData.serverPid = null
  writeDevLock()
  if (child.exitCode !== null) return

  child.kill("SIGTERM")
  await Promise.race([once(child, "exit"), new Promise((resolve) => setTimeout(resolve, 3000))])
  if (child.exitCode === null) child.kill("SIGKILL")
}

async function restartServer() {
  await stopServer()
  startServer()
}

async function runBuilds() {
  if (building) return
  building = true

  try {
    while (pending.frontend || pending.server) {
      const work = { ...pending }
      pending.frontend = false
      pending.server = false

      const label = [work.frontend && "frontend", work.server && "server"].filter(Boolean).join(" + ")
      console.log(`\n[dev] rebuilding ${label}...`)

      try {
        if (work.frontend) {
          await runCommand("pnpm", ["exec", "vite", "build"], root)
        }
        await runCommand("zig", ["build", "-Doptimize=Debug"], serverDir)
        await restartServer()
        console.log("[dev] ready")
      } catch (error) {
        console.error(`[dev] build failed: ${error.message}`)
      }
    }
  } finally {
    building = false
  }

  // A change can arrive between the final loop check and `building = false`.
  if (pending.frontend || pending.server) scheduleBuild()
}

async function main() {
  acquireDevLock()
  console.log("[dev] frontend build -> server/src/web -> embedded into shoufad")
  console.log("[dev] watching src/, public/, scripts/, server/src/, and build files")
  console.log("[dev] Ctrl-C to stop\n")

  watch(root, false)
  watch(path.join(root, "src"), true)
  watch(path.join(root, "public"), true)
  watch(path.join(root, "scripts"), true)
  watch(serverDir, false)
  watch(path.join(serverDir, "src"), true)

  pending.frontend = true
  pending.server = true
  await runBuilds()
}

async function shutdown() {
  if (shuttingDown) return
  shuttingDown = true
  if (buildTimer) clearTimeout(buildTimer)
  for (const watcher of watchers) watcher.close()
  await stopServer()
  releaseDevLock()
  process.exit(0)
}

process.on("SIGINT", () => { void shutdown() })
process.on("SIGTERM", () => { void shutdown() })
process.on("exit", releaseDevLock)

main().catch((error) => {
  console.error("[dev] fatal:", error)
  void shutdown()
})
