// Updates VERSION, package.json, and server/build.zig.zon together.
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(fileURLToPath(new URL("..", import.meta.url)))
const version = process.argv[2]

if (!version || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
  console.error("Usage: node scripts/set-version.mjs <semver>")
  console.error("Example: node scripts/set-version.mjs 0.3.0")
  process.exit(1)
}

fs.writeFileSync(path.join(root, "VERSION"), `${version}\n`)

const packagePath = path.join(root, "package.json")
const pkg = JSON.parse(fs.readFileSync(packagePath, "utf8"))
pkg.version = version
fs.writeFileSync(packagePath, `${JSON.stringify(pkg, null, 2)}\n`)

const zonPath = path.join(root, "server", "build.zig.zon")
const zon = fs.readFileSync(zonPath, "utf8")
fs.writeFileSync(
  zonPath,
  zon.replace(/\.version\s*=\s*"[^"]+"/, `.version = "${version}"`),
)

console.log(`version set to ${version}`)
console.log("next:")
console.log("  git add VERSION package.json server/build.zig.zon")
console.log(`  git commit -m "chore: release v${version}"`)
console.log(`  git tag v${version}`)
console.log(`  git push origin main --tags`)
