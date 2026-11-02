// Dependency-free Chrome DevTools regression against a disposable test-only app.
// No user's Chrome profile, real provider, Keychain or private database is used.
import assert from "node:assert/strict"
import {spawn} from "node:child_process"
import {once} from "node:events"
import path from "node:path"

const [browser, root, origin, workspaceId, accountId, unattachedId] = process.argv.slice(2)
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
  const {scrollTop, ...point} = await evaluate(`(() => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element) throw new Error('Missing click target');
    element.scrollIntoView({block: 'center'});
    const rect = element.getBoundingClientRect();
    const x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
    const hit = document.elementFromPoint(x, y);
    if (element.id === 'home-link' && !element.contains(hit)) throw new Error('Home click intercepted by ' + hit?.tagName + '#' + hit?.id);
    return {x, y, scrollTop: document.querySelector('#workspace-content')?.scrollTop};
  })()`)
  await send("Input.dispatchMouseEvent", {type: "mousePressed", button: "left", clickCount: 1, ...point})
  await send("Input.dispatchMouseEvent", {type: "mouseReleased", button: "left", clickCount: 1, ...point})
  // Return the actual pre-click position, after scrollIntoView, just as MailReader captures it.
  return scrollTop
}

async function key(key, text) {
  const enter = key === "Enter" ? {code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, text: "\r", unmodifiedText: "\r"} : {}
  await send("Input.dispatchKeyEvent", {type: "keyDown", key, ...enter, ...(text ? {text} : {})})
  await send("Input.dispatchKeyEvent", {type: "keyUp", key, ...enter})
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
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#home-link')).visibility`), "visible")
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
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#home-link')).visibility`), "hidden")
  assert.equal(await evaluate(`(() => {
    const button = document.querySelector('#home-link');
    button.focus({preventScroll: true});
    return document.activeElement === button;
  })()`), false, "hidden Home must not accept keyboard focus")
}

async function readerLoaded() {
  await waitFor(`document.querySelector('#mail-conversation')?.getAttribute('aria-busy') === 'false' &&
    document.querySelector('#mail-panel')?.dataset.mailLoaded === 'true' &&
    !!document.querySelector('#mail-message-synthetic-message-3 .mail-message-text')`, "loaded conversation")
  // Let the reader's scheduled focus/scroll handoff settle before measuring or
  // calculating click coordinates for another control.
  await evaluate("new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))")
  assert.equal(await evaluate("!!document.querySelector('#mail-threads')"), false, "reader replaces the results, not an inline expansion")
}

async function loadingStatus(forced, reduced) {
  await waitFor("!!document.querySelector('#mail-loading')", "real mail loading status")
  const state = await evaluate(`(() => {
    const status = document.querySelector('#mail-status');
    const loading = document.querySelector('#mail-loading');
    const track = loading.querySelector('.mail-loading-track');
    return {background: getComputedStyle(status).backgroundColor,
      loadingBackground: getComputedStyle(loading).backgroundColor,
      edge: getComputedStyle(status).borderLeftWidth,
      animation: getComputedStyle(track, '::after').animationName,
      hidden: track.getAttribute('aria-hidden'), role: status.getAttribute('role'),
      height: status.getBoundingClientRect().height};
  })()`)
  assert.equal(state.background, "rgba(0, 0, 0, 0)", "loading sits directly on the shared glass")
  assert.equal(state.loadingBackground, "rgba(0, 0, 0, 0)")
  assert.equal(state.edge, "0px", "loading does not borrow the warning edge")
  assert.equal(state.animation, forced || reduced ? "none" : "mail-loading-sweep", "motion respects user preferences and forced colors")
  assert.equal(state.hidden, "true", "the indeterminate sweep is decorative, not fake percentage progress")
  assert.equal(state.role, "status")
  assert.ok(state.height >= 28)
  return state.height
}

async function readerLayout(width, forced) {
  const dimensions = await evaluate(`(() => {
    const text = document.querySelector('#mail-message-synthetic-message-3 .mail-message-text');
    const conversation = document.querySelector('#mail-conversation');
    const pane = document.querySelector('#workspace-content');
    const back = document.querySelector('#mail-back').getBoundingClientRect();
    const refresh = document.querySelector('#mail-refresh').getBoundingClientRect();
    return {font: getComputedStyle(text).fontSize, width: text.getBoundingClientRect().width,
      textOverflow: text.scrollWidth > text.clientWidth + 1,
      readerOverflow: conversation.scrollWidth > conversation.clientWidth + 1,
      readerBackground: getComputedStyle(conversation).backgroundColor,
      readerShadow: getComputedStyle(conversation).textShadow,
      paneShadow: getComputedStyle(pane).textShadow,
      paneOverflow: pane.scrollWidth > pane.clientWidth + 1,
      pageOverflow: document.documentElement.scrollWidth > innerWidth,
      backHeight: back.height, refreshHeight: refresh.height,
      controlsInPane: back.left >= 0 && refresh.right <= innerWidth,
      forced: matchMedia('(forced-colors: active)').matches};
  })()`)
  assert.equal(dimensions.font, width > 800 ? "18px" : "17px", "reader body type scales for desktop/narrow")
  if (!forced) {
    assert.equal(dimensions.readerBackground, "rgba(0, 0, 0, 0)", "reader uses the normal glass without an opaque fill")
    assert.equal(dimensions.readerShadow, dimensions.paneShadow, "reader inherits the shared glass text treatment")
  }
  // A generous proportional-font range around a 68ch reading measure, not a font-specific pixel snapshot.
  assert.ok(width > 800 ? dimensions.width >= 450 && dimensions.width <= 800 : dimensions.width >= 200 && dimensions.width <= width,
    `bounded reading measure at ${width}px (forced colors: ${forced}): ${JSON.stringify(dimensions)}`)
  assert.equal(dimensions.textOverflow || dimensions.readerOverflow || dimensions.paneOverflow || dimensions.pageOverflow, false,
    `long URL and escaped HTML must wrap at ${width}px (forced colors: ${forced})`)
  assert.ok(dimensions.backHeight >= 44 && dimensions.refreshHeight >= 44 && dimensions.controlsInPane, "reader controls remain usable and within the viewport")
  assert.equal(dimensions.forced, forced)
}

let homeVisits = 0
async function home() {
  await waitFor(`!!document.querySelector('#home-overview') &&
    document.querySelector('#home-link')?.getAttribute('aria-current') === 'page' &&
    document.title === 'Home · LOVELACE'`, `Home overview and title (visit ${++homeVisits})`)
  assert.equal(await evaluate("document.title"), "Home · LOVELACE")
  assert.equal(await evaluate("document.querySelector('#home-link').closest('nav')?.id"), "center-nav", "Home belongs to the center navigation")
  assert.equal(await evaluate("document.querySelector('#home-link').textContent.trim()"), "Home")
  assert.equal(await evaluate("document.querySelector('#workspace-monogram').closest('a, button') === null && document.querySelector('#workspace-monogram').getAttribute('aria-hidden') === 'true' && document.querySelector('#workspace-monogram').getAttribute('focusable') === 'false' && getComputedStyle(document.querySelector('#workspace-monogram')).pointerEvents === 'none'"), true, "corner monogram is decoration only")
  assert.equal(await evaluate("location.pathname + location.search + location.hash"), "/", "navigation stays in-page")
  assert.equal(await evaluate("!!document.querySelector('#workspace-list, #home-inbox, #connections-panel')"), false)
  const orientation = await evaluate(`(() => {
    const now = new Date();
    const hour = now.getHours();
    const date = document.querySelector('#daily-heading [data-daily-date]');
    return {
      greeting: document.querySelector('#daily-heading [data-daily-greeting]').textContent.trim(),
      expectedGreeting: hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening',
      date: date.textContent,
      expectedDate: new Intl.DateTimeFormat(undefined, {weekday: 'long', month: 'long', day: 'numeric'}).format(now),
      iso: date.getAttribute('datetime'),
      expectedIso: now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' + String(now.getDate()).padStart(2, '0'),
    };
  })()`)
  assert.equal(orientation.greeting, orientation.expectedGreeting, "greeting uses browser-local time")
  assert.equal(orientation.date, orientation.expectedDate, "date uses browser-local calendar")
  assert.equal(orientation.iso, orientation.expectedIso)
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
  await waitFor(`!!document.querySelector('#home-accounts') && window.liveSocket?.getSocket().isConnected()`, "connected Home after unlock")
  await home()
  await landscape()
  await click("#workspace-pane")
  assert.equal(await evaluate("document.querySelector('#main-content').dataset.entered ?? 'false'"), "false")
  assert.equal(await evaluate("Number(getComputedStyle(document.querySelector('#workspace-monogram')).opacity)"), 0)
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true)
  await waitFor("document.querySelector('#lovelace-letter-7').style.opacity === '1' && document.querySelector('#main-content').dataset.entered !== 'true'", "completed wordmark before exit")
  await waitFor("Number(document.querySelector('#lovelace-letter-0').style.opacity) < Number(document.querySelector('#lovelace-letter-7').style.opacity)", "left-to-right letter exit")
  await waitFor("parseFloat(document.querySelector('#lovelace-monogram-stroke').style.strokeDashoffset) < 0 && Number(document.querySelector('#lovelace-letter-0').style.opacity) < 1", "opposite-end erase before handoff")
  assert.equal(await evaluate("Number(getComputedStyle(document.querySelector('#workspace-monogram')).opacity)"), 0)
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#owner-lock-form')).visibility"), "hidden")
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#home-link')).visibility"), "hidden")
  await focused()
  await waitFor("document.querySelector('#workspace-background img')?.dataset.loaded === 'true'", "live image hook load")
  assert.equal(await evaluate("document.activeElement.id"), "directory-heading")
  console.log("PASS ordinary entrance, static stage, corner/Home/Lock visibility and gate/focus handoff")

  await home()
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('#center-nav > button'), button => button.id)"), ["home-link", "show-workspaces", "show-connections"])
  assert.equal(await evaluate("document.querySelectorAll('#home-accounts > li').length"), 2, "one Home row per connection, not per membership")
  for (const [id, count] of [[accountId, "7"], [unattachedId, "0"]]) {
    assert.equal(await evaluate(`document.querySelectorAll('#home-account-${id}').length`), 1)
    assert.equal(await evaluate(`document.querySelector('#home-count-${id} .home-unread-number').textContent.trim()`), count)
    assert.equal(await evaluate(`document.querySelector('#home-count-${id} .home-unread-label').textContent.trim()`), "unread")
    await waitFor(`document.querySelector('#home-freshness-${id}')?.textContent.includes('Checked')`, "local count observation time")
  }
  const memberships = await evaluate(`document.querySelector('#home-account-${accountId} .home-account-workspaces').textContent`)
  assert.match(memberships, /Browser studio/)
  assert.match(memberships, /Synthetic space 1/)
  assert.match(await evaluate(`document.querySelector('#home-account-${unattachedId}').textContent`), /Not in a workspace/)

  await click(`#open-home-account-${accountId}`)
  await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", "Home row opens separate account inbox")
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.equal(await evaluate("document.querySelector('#home-link').hasAttribute('aria-current')"), false)
  await evaluate("document.querySelector('#workspace-content').scrollTop = 100")
  const inboxScroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(inboxScroll > 0, "synthetic inbox must really scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('#home-inbox #mail-account-view')"), true)
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '0.02'")
  await key("Shift")
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('#home-inbox #mail-account-view')"), true)
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '3'")
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)

  const conversationTitle = await evaluate("document.querySelector('#mail-thread-synthetic-thread-12 .mail-thread-subject').textContent.trim()")
  const resultsContext = await evaluate("document.querySelector('#mail-panel').dataset.mailContext")
  assert.ok(resultsContext, "inbox has an opaque results context")
  const returnScroll = await click("#mail-thread-synthetic-thread-12")
  assert.ok(returnScroll > 100, "open a genuinely scrolled result, capturing after the click helper scrolls it into view")
  const loadingHeight = await loadingStatus(false, false)
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.mail-loading-track'), '::after').animationName"), "none", "mid-load reduced-motion change stops the sweep")
  await media([])
  await readerLoaded()
  assert.equal(await evaluate("document.querySelector('#mail-status').getBoundingClientRect().height"), loadingHeight, "status space stays stable when loading completes")
  assert.equal(await evaluate("document.querySelector('#mail-panel').getAttribute('phx-hook')"), "MailReader")
  assert.equal(await evaluate("document.querySelector('#mail-panel').dataset.mailThread"), "synthetic-thread-12")
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('details.mail-message'), message => ({id: message.id, open: message.open}))"), [
    {id: "mail-message-synthetic-message-1", open: false},
    {id: "mail-message-synthetic-message-2", open: false},
    {id: "mail-message-synthetic-message-3", open: true},
  ], "chronological conversation expands only the latest message")
  assert.equal(await evaluate("document.querySelectorAll('#mail-conversation-heading').length"), 1)
  assert.equal(await evaluate("document.querySelector('#mail-conversation-heading').textContent.trim()"), conversationTitle)
  assert.equal(await evaluate(`Array.from(document.querySelectorAll('#mail-panel :is(h1, h2, h3, h4, h5, h6)')).filter(heading => heading.textContent.trim() === ${JSON.stringify(conversationTitle)}).length`), 1, "conversation subject is not repeated as message titles")
  assert.equal(await evaluate("document.querySelectorAll('.mail-message-subject').length"), 1, "only the changed middle subject gets a per-message title")
  assert.equal(await evaluate("!!document.querySelector('#mail-message-synthetic-message-2 .mail-message-subject')"), true)
  await readerLayout(1440, false)

  await evaluate("document.querySelector('#mail-message-synthetic-message-1 > summary.mail-message-summary').focus()")
  await key("Enter")
  await waitFor("document.querySelector('#mail-message-synthetic-message-1').open", "native summary Enter opens earlier message")
  await key("Enter")
  await waitFor("!document.querySelector('#mail-message-synthetic-message-1').open", "native summary Enter collapses earlier message")
  await key("Enter")
  await waitFor("document.querySelector('#mail-message-synthetic-message-1').open", "reopen earlier message before refresh")
  await click("#mail-message-synthetic-message-2 > summary.mail-message-summary")
  await waitFor("document.querySelector('#mail-message-synthetic-message-2').open", "mouse opens middle message")
  await click("#mail-message-synthetic-message-3 > summary.mail-message-summary")
  await waitFor("!document.querySelector('#mail-message-synthetic-message-3').open", "collapse latest before refresh")

  // Observe the real loading round trip, so a fast pre-response assertion cannot pass accidentally.
  await evaluate(`(() => {
    window.uiMailRefreshDone = false;
    const observer = new MutationObserver(records => {
      if (records.some(record => record.target.id === 'mail-conversation' &&
          record.attributeName === 'aria-busy' && record.oldValue === 'true') &&
          document.querySelector('#mail-conversation')?.getAttribute('aria-busy') === 'false') {
        window.uiMailRefreshDone = true;
        observer.disconnect();
      }
    });
    observer.observe(document.querySelector('#mail-panel'), {subtree: true, attributes: true, attributeOldValue: true, attributeFilter: ['aria-busy']});
  })()`)
  await click("#mail-refresh")
  await waitFor("window.uiMailRefreshDone", "Refresh completes an asynchronous mail load")
  await readerLoaded()
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('details.mail-message'), message => message.open)"), [true, true, false], "user expansion choices survive Refresh, including collapsed latest")
  await click("#mail-message-synthetic-message-3 > summary.mail-message-summary")
  await waitFor("document.querySelector('#mail-message-synthetic-message-3').open", "reopen latest body")
  const metadata = "#mail-message-synthetic-message-3 .mail-message-details"
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(metadata)}).open`), false)
  await click(`${metadata} > summary`)
  await waitFor(`document.querySelector(${JSON.stringify(metadata)}).open`, "recipient metadata disclosure opens")
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(metadata)}).textContent.includes('<img src="https://mail-fixture.invalid/recipient.png">')`), true, "recipient markup is literal escaped metadata")
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(metadata)}).textContent.includes('Sat, 15 Mar 2025 11:30:00 +0000')`), true, "raw RFC2822 date remains available in details")
  assert.equal(await evaluate("document.querySelector('#mail-message-synthetic-message-3 .mail-message-text').textContent.includes('<img src=\"https://mail-fixture.invalid/body.png\"')"), true, "hostile body markup is literal text")
  assert.equal(await evaluate("document.querySelector('#mail-conversation img, #mail-conversation iframe, #mail-conversation script') === null"), true, "untrusted content creates no remote-content elements")
  assert.deepEqual(external, [], "body and metadata must not request remote content")
  await click(`${metadata} > summary`)
  await waitFor(`!document.querySelector(${JSON.stringify(metadata)}).open`, "recipient metadata disclosure closes")

  await evaluate("document.querySelector('#workspace-content').scrollTop = 700")
  const readerScroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(readerScroll > 100, "long latest message makes the reader scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), readerScroll)
  assert.equal(await evaluate("!!document.querySelector('#mail-message-synthetic-message-3[open] .mail-message-text') && !document.querySelector('#mail-threads')"), true)
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), readerScroll)
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('details.mail-message'), message => message.open)"), [true, true, true], "Escape/wake retains reader content and disclosures")
  await click("#mail-back")
  await waitFor(`document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false' &&
    document.activeElement.id === 'mail-thread-synthetic-thread-12' &&
    Math.abs(document.querySelector('#workspace-content').scrollTop - ${returnScroll}) <= 1`, "Back restores original row keyboard focus and actual click scroll after async results")
  assert.equal(await evaluate("!!document.querySelector('#mail-conversation')"), false)
  assert.equal(await evaluate("document.querySelector('#mail-panel').dataset.mailContext"), resultsContext, "Back returns to the same results context")
  console.log("PASS dedicated conversation, native message/recipient disclosures, Refresh preservation, escaped mail, reader Escape/wake and async Back focus/scroll")
  await click("#home-link")
  await home()

  await click(`#open-home-account-${unattachedId}`)
  await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", "Home opens an account without workspace membership")
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "unattached@example.test")
  assert.equal(await evaluate("Array.from(document.querySelectorAll('#mail-panel button')).some(button => button.textContent.trim() === 'Home')"), false, "inbox has no redundant Home button")
  await click("#home-link")
  await home()
  await click(`#open-home-account-${accountId}`)
  await waitFor("!!document.querySelector('#home-inbox #mail-account-view') && document.activeElement.id === 'directory-heading'", "reopen inbox and heading focus for keyboard Home")
  await evaluate("document.querySelector('#home-link').focus()")
  assert.equal(await evaluate("document.activeElement.id"), "home-link")
  await key("Enter")
  await home()
  await waitFor("document.activeElement.id === 'directory-heading'", "keyboard Home transfers heading focus")
  await click("#show-connections")
  await waitFor("!!document.querySelector('#connections-panel')", "Home opens Connections")
  assert.equal(await evaluate("!!document.querySelector('#back-from-connections')"), false, "Connections has no redundant Home button")
  await click("#home-link")
  await home()
  await click("#show-connections")
  await waitFor("!!document.querySelector('#connections-panel')", "Connections before center-nav Home")
  await click("#workspace-monogram")
  assert.equal(await evaluate("!!document.querySelector('#connections-panel') && document.querySelector('#home-overview') === null"), true, "clicking the decorative monogram does not navigate")
  await click("#home-link")
  await home()
  await click("#show-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}') && document.activeElement.id === 'directory-heading'`, "explicit workspace directory navigation")
  console.log("PASS local daily orientation, per-account counts/memberships, Home inbox, Escape/idle preservation and mouse/keyboard Home")

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
  await waitFor("document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false'", "synthetic inbox")
  assert.equal(await evaluate("!!document.querySelector('#workspace-content #mail-account-view #mail-threads')"), true)
  await click("#show-connections")
  await waitFor("!!document.querySelector('#connections-panel') && document.activeElement.id === 'directory-heading'", "Connections navigation focus")
  await click("#back-from-connections")
  await waitFor("!!document.querySelector('#workspace-landing') && document.activeElement.id === 'directory-heading'", "return to workspace")
  await click("#back-to-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "return to directory")
  await click(`#open-${workspaceId}`)
  await waitFor("!!document.querySelector('#workspace-landing')", "workspace before center-nav Home")
  await click("#home-link")
  await home()
  await click("#show-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "directory before reload")
  console.log("PASS workspace/integration/Connections navigation, center-nav Home, decorative monogram and real LiveView focus events")

  // Reload really restarts the entrance. Changing preference mid-reveal must
  // finish once and open the actual inert gate, not just a fake hook target.
  failStageImages = true
  await send("Page.reload")
  await waitFor(`!!document.querySelector('#home-overview') && document.querySelector('#workspace-background img')?.dataset.loaded === 'false'`, "reload returns Home with fresh entrance and failed live image")
  await home()
  await landscape()
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true)
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-background img')).opacity"), "0")
  assert.match(await evaluate("getComputedStyle(document.querySelector('#workspace-background')).backgroundImage"), /distant-shore\.svg/)
  failStageImages = false
  await click("#workspace-pane")
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  await focused()
  await home()
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
      await click("#home-link")
      await home()
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "Home has no horizontal overflow")
      const homeDimensions = await evaluate(`(() => {
        const row = document.querySelector('#open-home-account-${accountId}').getBoundingClientRect();
        const button = document.querySelector('#home-link').getBoundingClientRect();
        const content = document.querySelector('#home-overview').getBoundingClientRect();
        return {rowWidth: row.width, rowHeight: row.height, homeWidth: button.width, homeHeight: button.height, contentWidth: content.width, contentLeft: content.left};
      })()`)
      assert.ok(homeDimensions.rowWidth > 200 && homeDimensions.rowHeight >= 44 && homeDimensions.homeWidth >= 44 && homeDimensions.homeHeight >= 44,
        `usable Home targets at ${width}px (forced colors: ${forced}): ${JSON.stringify(homeDimensions)}`)
      await click(`#open-home-account-${accountId}`)
      await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", "inbox for search layout checks")
      const searchDimensions = await evaluate(`(() => {
        const input = document.querySelector('#mail-search input');
        const button = document.querySelector('#mail-search button');
        const identity = document.querySelector('.mail-inbox-heading .mail-account-identity').getBoundingClientRect();
        const form = document.querySelector('#mail-search').getBoundingClientRect();
        const field = input.getBoundingClientRect();
        const submit = button.getBoundingClientRect();
        const pane = document.querySelector('#workspace-content');
        return {gap: submit.left - field.right, inputHeight: field.height, buttonHeight: submit.height,
          inputFont: getComputedStyle(input).fontSize, buttonFont: getComputedStyle(button).fontSize,
          identityRight: identity.right, identityBottom: identity.bottom, searchLeft: form.left, searchTop: form.top,
          overflow: pane.scrollWidth > pane.clientWidth};
      })()`)
      assert.ok(Math.abs(searchDimensions.gap) < 1 && Math.abs(searchDimensions.inputHeight - searchDimensions.buttonHeight) < 1,
        `search input/button touch and match heights: ${JSON.stringify(searchDimensions)}`)
      assert.equal(searchDimensions.inputFont, searchDimensions.buttonFont, "search input/button font sizes match")
      assert.ok(searchDimensions.buttonHeight >= 44, "search remains a usable target")
      assert.equal(searchDimensions.overflow, false, "inbox has no horizontal overflow")
      assert.ok(width > 800 ? searchDimensions.searchLeft >= searchDimensions.identityRight : searchDimensions.searchTop >= searchDimensions.identityBottom,
        `identity/search split on desktop and stack on narrow screens: ${JSON.stringify(searchDimensions)}`)
      assert.equal(await evaluate("document.querySelector('#mail-search input').getAttribute('aria-label')"), "Search Gmail")
      // Distinct uncached threads exercise actual loading at every preference/width.
      const threadNumber = (forced ? 16 : 14) + (width === 390 ? 1 : 0)
      await click(`#mail-thread-synthetic-thread-${threadNumber}`)
      await loadingStatus(forced, true)
      await readerLoaded()
      await readerLayout(width, forced)
      if (forced) {
        await evaluate("document.querySelector('#mail-message-synthetic-message-1 > summary.mail-message-summary').focus()")
        await key("Enter")
        await waitFor("document.querySelector('#mail-message-synthetic-message-1').open", "forced-color keyboard disclosure")
        assert.notEqual(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), "none", "forced-color reader retains a visible keyboard focus outline")
      }
      await click("#show-connections")
      await waitFor("!!document.querySelector('#connections-panel')", "Connections for shared width check")
      const connectionBounds = await evaluate(`(() => {
        const content = document.querySelector('#connections-panel').getBoundingClientRect();
        return {width: content.width, left: content.left};
      })()`)
      assert.ok(Math.abs(connectionBounds.width - homeDimensions.contentWidth) < 1 && Math.abs(connectionBounds.left - homeDimensions.contentLeft) < 1,
        `Home and Connections share the content width and alignment: ${JSON.stringify({home: homeDimensions, connections: connectionBounds})}`)
      await click("#show-workspaces")
      await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "directory for card layout checks")
      const workspaceBounds = await evaluate(`(() => {
        const content = document.querySelector('#workspace-list').getBoundingClientRect();
        return {width: content.width, left: content.left};
      })()`)
      assert.ok(Math.abs(workspaceBounds.width - homeDimensions.contentWidth) < 1 && Math.abs(workspaceBounds.left - homeDimensions.contentLeft) < 1,
        `Home and Workspaces share the content width and alignment: ${JSON.stringify({home: homeDimensions, workspaces: workspaceBounds})}`)
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "directory has no horizontal overflow")
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
  console.log("PASS Home reload, reduced motion, forced colors, desktop/narrow Home/card/inbox search/reader layout and no off-origin requests/page errors")
} catch (error) {
  console.error(error.message)
  if (socket?.readyState === WebSocket.OPEN) {
    console.error(await evaluate(`JSON.stringify({title: document.title, home: !!document.querySelector('#home-overview'), current: document.querySelector('#home-link')?.getAttribute('aria-current'), inbox: !!document.querySelector('#home-inbox'), active: document.activeElement?.id, heading: document.querySelector('#directory-heading')?.textContent.trim()})`).catch(() => "Browser state unavailable"))
  }
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
