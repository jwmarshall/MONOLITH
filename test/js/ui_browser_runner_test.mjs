import assert from "node:assert/strict"
import {spawnSync} from "node:child_process"
import {mkdtempSync, rmSync, writeFileSync} from "node:fs"
import {tmpdir} from "node:os"
import path from "node:path"
import test from "node:test"
import {fileURLToPath} from "node:url"

const runner = fileURLToPath(new URL("../browser/ui_contract.mjs", import.meta.url))

for (const [name, script] of [["normal exit", "exit 0"], ["signal termination", "kill -TERM $$"]]) {
  test(`browser runner fails promptly and cleans up after Chrome startup ${name}`, {
    skip: process.platform === "win32" ? "Chrome runner targets macOS/Linux" : false,
  }, t => {
    const root = mkdtempSync(path.join(tmpdir(), "monolith-browser-runner-"))
    t.after(() => rmSync(root, {recursive: true, force: true}))
    const browser = path.join(root, "synthetic-browser")
    writeFileSync(browser, `#!/bin/sh\n${script}\n`, {mode: 0o700})

    // No actual Chrome/app/provider is started. A missing startup-timer cleanup
    // or waiting for an already-fired exit event would exceed this deadline.
    const result = spawnSync(process.execPath, [runner, browser, root, "http://localhost:1", "synthetic"], {
      encoding: "utf8",
      timeout: 5_000,
    })
    assert.equal(result.error, undefined, "runner must not hang until the parent timeout")
    assert.equal(result.signal, null)
    assert.equal(result.status, 1, "startup failure must not be reported as a passing suite")
    assert.match(result.stderr, /Chrome exited before DevTools started/)
  })
}
