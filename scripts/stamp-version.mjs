// Runs on every Netlify build (see netlify.toml).
// Version = number of commits on the branch, e.g. "v14". Falls back to the short commit hash.
import { execSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

let version;
try {
  try { execSync("git fetch --unshallow --quiet", { stdio: "ignore" }); } catch {}
  version = "v" + execSync("git rev-list --count HEAD").toString().trim();
} catch {
  version = (process.env.COMMIT_REF || "dev").slice(0, 7);
}

writeFileSync("public/version.js", `window.APP_VERSION = ${JSON.stringify(version)};\n`);
// New cache name per build, so the service worker refreshes the offline copy.
const sw = readFileSync("public/sw.js", "utf8").replace(/const CACHE = "[^"]*";/, `const CACHE = "cs-shell-${version}";`);
writeFileSync("public/sw.js", sw);
console.log("Stamped version", version);
