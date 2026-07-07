#!/usr/bin/env node
/**
 * chaza CLI entry point.
 *
 * Detects the platform and spawns the correct native binary from the
 * matching @chaza/{platform}-{arch} optional dependency package.
 */

import { spawn } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const platform = process.platform;
const arch = process.arch;
const exe = platform === "win32" ? ".exe" : "";

const pkgName = `@chaza/${platform}-${arch}`;

let binaryPath: string | undefined;
try {
  binaryPath = require.resolve(`${pkgName}/bin/chaza${exe}`);
} catch {
  console.error(`chaza: missing optional dependency "${pkgName}"`);
  console.error(`  Try: npm install @chaza/${platform}-${arch}`);
  process.exit(1);
}

const child = spawn(binaryPath, process.argv.slice(2), { stdio: "inherit" });
child.on("exit", (code) => process.exit(code ?? 1));
child.on("error", (err: Error) => {
  console.error(`chaza: ${err.message}`);
  process.exit(1);
});
