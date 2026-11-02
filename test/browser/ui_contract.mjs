// Dependency-free Chrome DevTools regression against a disposable test-only app.
// No user's Chrome profile, real provider, Keychain or private database is used.
import assert from "node:assert/strict"
import {spawn} from "node:child_process"
import {once} from "node:events"
import path from "node:path"

const [browser, root, origin, workspaceId] = process.argv.slice(2)
const chrome = spawn(browser, [
  "--headless", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
  `--user-data-dir=${path.join(root, "chrome")}`, "--no-first-run", "--no-default-browser-check",
  "--disable-background-networking", "--disable-component-update", "--disable-sync",
  "about:blank",
], {stdio: ["ignore", "ignore", "pipe"]})

// Capture closure now: waiting on a new exit listener in finally can hang if
// Chrome was already terminated by a signal (exitCode stays null in that case).
const chromeClosed = new Promise(resolve => chrome.once("close", resolve))
let socket
let nextId = 0
let sessionId
let failStageImages = false
const pending = new Map()
const errors = []
const cspViolations = []
const external = []
const deadline = setTimeout(() => {
  console.error("UI browser suite exceeded its 90-second deadline")
  chrome.kill("SIGKILL")
  process.exit(1)
}, 90_000)

function send(method, params = {}, session = sessionId) {
  const id = ++nextId
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id)
      reject(new Error(`DevTools timeout: ${method}`))
    }, 10_000)
    pending.set(id, {resolve, reject, timer})
    socket.send(JSON.stringify({id, method, params, ...(session ? {sessionId: session} : {})}))
  })
}

async function evaluate(expression) {
  const response = await send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true})
  assert.equal(response.exceptionDetails, undefined, "browser evaluation must not throw")
  return response.result.value
}

async function waitFor(expression, label, timeout = 8_000) {
  const end = Date.now() + timeout
  while (Date.now() < end) {
    if (await evaluate(expression)) return
    await new Promise(resolve => setTimeout(resolve, 25))
  }
  throw new Error(`Timed out: ${label}`)
}

async function click(selector) {
  const point = await evaluate(`(() => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element) throw new Error('Missing click target');
    element.scrollIntoView({block: 'center'});
    const rect = element.getBoundingClientRect();
    return {x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
  })()`)
  await send("Input.dispatchMouseEvent", {type: "mousePressed", button: "left", clickCount: 1, ...point})
  await send("Input.dispatchMouseEvent", {type: "mouseReleased", button: "left", clickCount: 1, ...point})
}

async function key(key, text) {
  await send("Input.dispatchKeyEvent", {type: "keyDown", key, ...(text ? {text} : {})})
  await send("Input.dispatchKeyEvent", {type: "keyUp", key})
}

async function media(features = []) {
  await send("Emulation.setEmulatedMedia", {features})
}

async function focused() {
  await waitFor(`document.querySelector('#main-content')?.dataset.entered === 'true' &&
    Number(getComputedStyle(document.querySelector('#workspace-monogram')).opacity) > 0.8 &&
    getComputedStyle(document.querySelector('#owner-lock-form')).visibility === 'visible'`, "entered focused workspace")
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#workspace-pane')).display`), "none")
  assert.equal(await evaluate(`document.querySelector('#workspace-content').inert`), false)
}

async function landscape() {
  await waitFor(`document.querySelector('#workspace-pane')?.getAttribute('aria-pressed') === 'false' &&
    Number(getComputedStyle(document.querySelector('#workspace-monogram')).opacity) === 0`, "landscape hides corner")
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#owner-lock-form')).visibility`), "hidden")
  assert.equal(await evaluate(`(() => {
    const button = document.querySelector('#owner-lock-form button');
    button.focus({preventScroll: true});
    return document.activeElement === button;
  })()`), false, "hidden Lock must not accept keyboard focus")
}

try {
  const endpoint = await new Promise((resolve, reject) => {
    let buffered = ""
    const timer = setTimeout(() => reject(new Error("Chrome did not start DevTools")), 10_000)
    chrome.once("error", error => { clearTimeout(timer); reject(error) })
    chrome.once("exit", () => { clearTimeout(timer); reject(new Error("Chrome exited before DevTools started")) })
    chrome.stderr.on("data", bytes => {
      buffered = (buffered + bytes.toString()).slice(-16_384)
      const match = buffered.match(/DevTools listening on (ws:\/\/127\.0\.0\.1:\d+\/[^\s]+)/)
      if (match) { clearTimeout(timer); resolve(match[1]) }
    })
  })
  socket = new WebSocket(endpoint)
  await once(socket, "open")
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data)
    const call = pending.get(message.id)
    if (call) {
      clearTimeout(call.timer)
      pending.delete(message.id)
      if (message.error) call.reject(new Error(message.error.message))
      else call.resolve(message.result)
    } else if (message.method === "Runtime.exceptionThrown") {
      errors.push("Uncaught page exception")
    } else if (message.method === "Runtime.bindingCalled" && message.params.name === "uiCspViolation") {
      cspViolations.push("CSP violation")
    } else if (message.method === "Fetch.requestPaused") {
      const {requestId, request} = message.params
      if (failStageImages && request.url.startsWith(`${origin}/stage/background/`)) {
        send("Fetch.failRequest", {requestId, errorReason: "Failed"}).catch(() => {})
      } else if (request.url.startsWith(`${origin}/`) || request.url.startsWith("data:")) {
        send("Fetch.continueRequest", {requestId}).catch(() => {})
      } else {
        external.push("Off-origin page request blocked")
        send("Fetch.failRequest", {requestId, errorReason: "BlockedByClient"}).catch(() => {})
      }
    }
  })
  const {targetId} = await send("Target.createTarget", {url: "about:blank"}, null)
  ;({sessionId} = await send("Target.attachToTarget", {targetId, flatten: true}, null))
  await send("Page.enable")
  await send("Runtime.enable")
  await send("Network.enable")
  await send("Network.setCacheDisabled", {cacheDisabled: true})
  await send("Fetch.enable", {patterns: [{urlPattern: "*"}]})
  await send("Runtime.addBinding", {name: "uiCspViolation"})
  await send("Page.addScriptToEvaluateOnNewDocument", {source:
    "document.addEventListener('securitypolicyviolation', () => window.uiCspViolation('CSP violation'));"})
  await send("Emulation.setDeviceMetricsOverride", {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await send("Page.navigate", {url: `${origin}/unlock`})
  await waitFor("!!document.querySelector('#owner-unlock-form') && getComputedStyle(document.documentElement).getPropertyValue('--workspace-scenery-blur').trim() !== ''", "styled static unlock")
  assert.equal(await evaluate("document.querySelector('#owner-stage [phx-hook], #owner-stage [inert]') === null"), true)
  await waitFor("Number(getComputedStyle(document.querySelector('#owner-stage-monogram')).opacity) > 0.8", "static owner corner")
  assert.notEqual(await evaluate("getComputedStyle(document.querySelector('#owner-stage-background')).filter"), "none")
  await waitFor("document.querySelector('[data-static-stage-image]')?.dataset.loaded === 'true'", "static app image-observer registration")
  failStageImages = true
  await send("Page.reload")
  await waitFor("document.querySelector('[data-static-stage-image]')?.dataset.loaded === 'false'", "failed static image keeps fallback")
  assert.equal(await evaluate("getComputedStyle(document.querySelector('[data-static-stage-image]')).opacity"), "0")
  failStageImages = false
  await send("Emulation.setScriptExecutionDisabled", {value: true})
  await send("Page.reload")
  await waitFor("!!document.querySelector('#owner-unlock-form') && getComputedStyle(document.querySelector('#owner-stage-monogram')).opacity === '0.9'", "static owner usable without JavaScript")
  assert.equal(await evaluate("document.querySelector('#owner-unlock-form input[type=password]').disabled"), false)
  await send("Emulation.setScriptExecutionDisabled", {value: false})
  await send("Page.reload")
  await waitFor("document.querySelector('[data-static-stage-image]')?.dataset.loaded === 'true'", "restored static observer")
  await evaluate(`document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()`)
  await waitFor(`!!document.querySelector('#open-${workspaceId}') && window.liveSocket?.getSocket().isConnected()`, "connected workspace directory")
  await landscape()
  await click("#workspace-pane")
  assert.equal(await evaluate("document.querySelector('#main-content').dataset.entered ?? 'false'"), "false")
  assert.equal(await evaluate("Number(getComputedStyle(document.querySelector('#workspace-monogram')).opacity)"), 0)
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true)
  await waitFor("document.querySelector('#lovelace-letter-7').style.opacity === '1' && document.querySelector('#main-content').dataset.entered !== 'true'", "completed wordmark before reverse exit")
  await waitFor("parseFloat(document.querySelector('#lovelace-monogram-stroke').style.strokeDashoffset) > 0 && Number(document.querySelector('#lovelace-letter-0').style.opacity) < 1", "reverse untrace before handoff")
  assert.equal(await evaluate("Number(getComputedStyle(document.querySelector('#workspace-monogram')).opacity)"), 0)
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#owner-lock-form')).visibility"), "hidden")
  await focused()
  await waitFor("document.querySelector('#workspace-background img')?.dataset.loaded === 'true'", "live image hook load")
  assert.equal(await evaluate("document.activeElement.id"), "directory-heading")
  console.log("PASS ordinary entrance, static stage, corner/Lock visibility and gate/focus handoff")

  await click(`#workspace-menu-${workspaceId} summary`)
  assert.equal(await evaluate(`document.querySelector('#workspace-menu-${workspaceId}').open`), true)
  await click(`#rename-${workspaceId}`)
  await waitFor("document.activeElement.id === 'workspace-name'", "rename field focus")
  await evaluate("(() => { const input = document.querySelector('#workspace-name'); input.setSelectionRange(input.value.length, input.value.length); })()")
  await send("Input.insertText", {text: " unsaved"})
  await waitFor("document.querySelector('#workspace-name').value.endsWith(' unsaved')", "unsaved input")
  const before = await evaluate("document.querySelector('#workspace-name').value")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("document.activeElement.id"), "workspace-name")
  await key("x", "x")
  await focused()
  assert.equal(await evaluate("document.querySelector('#workspace-name').value"), `${before}x`)
  assert.equal(await evaluate("document.activeElement.id"), "workspace-name")
  await click("#workspace-form button[type=button]")
  await waitFor("!document.querySelector('#workspace-form') && document.activeElement.id === 'directory-heading'", "cancel returns heading focus")
  await evaluate("document.querySelector('#workspace-content').scrollTop = 100")
  const scroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(scroll > 0, "fixture must actually scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), scroll)
  await key("a", "a")
  await focused()
  // Only shorten this disposable DOM timer, not persisted/user configuration.
  // Begin focused so removing expiration cannot make an already-idle assertion pass.
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "true")
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '0.02'")
  await key("Shift") // A fresh activity timestamp schedules the real browser timer.
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "true")
  await landscape()
  await send("Input.dispatchMouseEvent", {type: "mouseMoved", x: 10, y: 10})
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "false")
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '3'")
  await click("#new-workspace")
  await waitFor("!!document.querySelector('#workspace-form') && document.activeElement.id === 'workspace-name'", "first idle click activates intended control")
  await focused()
  console.log("PASS native disclosures, Escape/idle/wake, first key/click, unsaved input and scroll preservation")
  await click("#workspace-form button[type=button]")

  await click(`#open-${workspaceId}`)
  await waitFor("!!document.querySelector('#mail-accounts') && document.activeElement.id === 'directory-heading'", "workspace navigation focus")
  await click("#add-integration")
  await waitFor("!!document.querySelector('#integration-add-panel')", "Add integration panel")
  await click("#close-add-integration")
  await click("#mail-accounts .mail-account-open")
  await waitFor("document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false'", "synthetic empty inbox")
  assert.equal(await evaluate("!!document.querySelector('#workspace-content #mail-account-view #mail-threads')"), true)
  await click("#show-connections")
  await waitFor("!!document.querySelector('#connections-panel') && document.activeElement.id === 'directory-heading'", "Connections navigation focus")
  await click("#back-from-connections")
  await waitFor("!!document.querySelector('#workspace-landing') && document.activeElement.id === 'directory-heading'", "return to workspace")
  await click("#back-to-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "return to directory")
  console.log("PASS workspace/integration/Connections navigation and real LiveView focus events")

  // Reload really restarts the entrance. Changing preference mid-reveal must
  // finish once and open the actual inert gate, not just a fake hook target.
  failStageImages = true
  await send("Page.reload")
  await waitFor(`!!document.querySelector('#open-${workspaceId}') && document.querySelector('#workspace-background img')?.dataset.loaded === 'false'`, "fresh entrance with failed live image")
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-background img')).opacity"), "0")
  assert.match(await evaluate("getComputedStyle(document.querySelector('#workspace-background')).backgroundImage"), /distant-shore\.svg/)
  failStageImages = false
  await click("#workspace-pane")
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  await focused()
  await media([])
  await key("Escape")
  await landscape()
  await key("a", "a")
  await focused()

  for (const forced of [false, true]) {
    await media([
      {name: "prefers-reduced-motion", value: "reduce"},
      {name: "forced-colors", value: forced ? "active" : "none"},
    ])
    for (const width of [1440, 390]) {
      await send("Emulation.setDeviceMetricsOverride", {width, height: 1000, deviceScaleFactor: 1, mobile: false})
      await focused()
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "no horizontal overflow")
      const dimensions = await evaluate(`(() => {
        const card = document.querySelector('#open-${workspaceId}').getBoundingClientRect();
        const menu = document.querySelector('#workspace-menu-${workspaceId} summary').getBoundingClientRect();
        const lock = document.querySelector('#owner-lock-form button').getBoundingClientRect();
        return {card: card.width, menu: menu.width, menuHeight: menu.height, lock: lock.height};
      })()`)
      assert.ok(dimensions.card > 200 && dimensions.menu >= 44 && dimensions.menuHeight >= 44 && dimensions.lock >= 44,
        `usable card/menu/Lock targets at ${width}px (forced colors: ${forced}): ${JSON.stringify(dimensions)}`)
      if (width === 390) {
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-list')).gridTemplateColumns.split(' ').length"), 1)
        await click(`#open-${workspaceId}`)
        await waitFor("!!document.querySelector('#mail-accounts .integration-tile')", "narrow integration tiles")
        assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true)
        await click("#mail-accounts .workspace-menu summary")
        assert.equal(await evaluate("document.querySelector('#mail-accounts details').open"), true)
        await click("#show-connections")
        await waitFor("!!document.querySelector('#connections-panel')", "narrow Connections")
        assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true)
        await click("#back-from-connections")
        await waitFor("!!document.querySelector('#workspace-landing')", "narrow return workspace")
        await click("#back-to-workspaces")
        await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "narrow return directory")
      }
      await key("Escape")
      await landscape()
      if (forced) {
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-content')).filter"), "none")
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-content')).opacity"), "1")
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-background')).display"), "none")
      }
      await key("a", "a")
      await focused()
    }
  }
  assert.deepEqual(cspViolations, [], "CSP evidence accumulates across all navigations/reloads")
  assert.deepEqual(errors, [])
  assert.deepEqual(external, [])
  console.log("PASS reduced motion, forced colors, desktop/narrow card layout and no off-origin requests/page errors")
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
} finally {
  socket?.close()
  for (const {reject, timer} of pending.values()) {
    clearTimeout(timer)
    reject(new Error("Browser closed"))
  }
  if (chrome.exitCode === null && chrome.signalCode === null) chrome.kill("SIGTERM")
  let kill
  await Promise.race([
    chromeClosed,
    new Promise(resolve => { kill = setTimeout(() => { chrome.kill("SIGKILL"); resolve() }, 2_000) }),
  ])
  clearTimeout(kill)
  clearTimeout(deadline)
}
