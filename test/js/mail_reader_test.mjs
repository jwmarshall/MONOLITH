import assert from "node:assert/strict"
import test from "node:test"
import MailReader from "../../assets/js/hooks/mail_reader.js"
import {MailDate, MailFreshness, mailDate, mailFreshnessText} from "../../assets/js/hooks/mail_time.js"

function reader(t) {
  const frames = new Map()
  let sequence = 0
  const previousRequest = globalThis.requestAnimationFrame
  const previousCancel = globalThis.cancelAnimationFrame
  globalThis.requestAnimationFrame = fn => { frames.set(++sequence, fn); return sequence }
  globalThis.cancelAnimationFrame = id => frames.delete(id)
  t.after(() => {
    globalThis.requestAnimationFrame = previousRequest
    globalThis.cancelAnimationFrame = previousCancel
  })
  const scroller = {scrollTop: 250}
  const elements = new Map()
  const listeners = new Map(), documentListeners = new Map(), viewListeners = new Map()
  const pane = {focused: true, getAttribute: () => pane.focused ? "true" : "false"}
  const focused = [], scrolled = []
  const element = id => ({
    id,
    focus(options) { assert.equal(options.preventScroll, true); focused.push(id) },
    scrollIntoView(options) { assert.equal(options.behavior, "instant"); assert.equal(options.block, id === "latest-summary" ? "nearest" : "start"); scrolled.push(id) },
  })
  const row = element("mail-thread-first")
  const heading = element("mail-heading")
  elements.set("#mail-heading", heading)
  elements.set("#mail-threads", {})
  const dataset = {mailContext: "account-a:list-1", mailThread: "", mailLoaded: "true"}
  const el = {
    dataset,
    closest: () => scroller,
    contains: node => node === row,
    ownerDocument: {
      defaultView: {
        addEventListener: (name, fn) => viewListeners.set(name, fn),
        removeEventListener: (name, fn) => { assert.equal(viewListeners.get(name), fn); viewListeners.delete(name) },
      },
      getElementById: id => id === "workspace-pane" ? pane : id === row.id && elements.has("#mail-threads") ? row : null,
      addEventListener: (name, fn, capture) => { assert.equal(capture, true); documentListeners.set(name, fn) },
      removeEventListener: (name, fn, capture) => { assert.equal(capture, true); assert.equal(documentListeners.get(name), fn); documentListeners.delete(name) },
    },
    querySelector: selector => elements.get(selector),
    addEventListener: (name, fn, capture) => { assert.equal(capture, true); listeners.set(name, fn) },
    removeEventListener: (name, fn, capture) => { assert.equal(capture, true); assert.equal(listeners.get(name), fn); listeners.delete(name) },
  }
  const hook = {...MailReader, el}
  hook.mounted()
  const click = kind => listeners.get("click")({target: {closest: selector =>
    (kind === "row" && selector === "[data-mail-open-thread]") ? row :
      (kind === "back" && selector === "#mail-back") ? {} : null}})
  const update = patch => { Object.assign(dataset, patch); hook.updated() }
  const flush = () => { const callbacks = [...frames.values()]; frames.clear(); callbacks.forEach(fn => fn()) }
  const open = () => {
    click("row")
    elements.delete("#mail-threads")
    update({mailThread: "first", mailLoaded: "false"})
    elements.set("#mail-conversation-heading", element("conversation-heading"))
    const latest = element("latest-message")
    latest.querySelector = selector => selector === ":scope > summary" ? element("latest-summary") : null
    elements.set('[data-mail-latest="true"]', latest)
    update({mailLoaded: "true"})
    flush()
  }
  return {hook, click, update, open, flush, frames, elements, focused, scrolled, scroller, listeners, documentListeners, viewListeners, pane}
}

test("reader waits for content, opens latest once, and restores exact row and scroll after return", t => {
  const r = reader(t)
  r.open()
  assert.deepEqual(r.focused, ["latest-summary"])
  assert.deepEqual(r.scrolled, ["latest-summary"])
  assert.equal(r.scroller.scrollTop, 0)
  r.update({mailLoaded: "true"}) // refresh/PubSub patches must not move focus or scroll
  r.flush()
  assert.equal(r.focused.length, 1)
  r.click("back")
  r.elements.delete("#mail-conversation-heading")
  r.update({mailThread: "", mailLoaded: "false"})
  r.scroller.scrollTop = 0
  r.flush()
  assert.equal(r.focused.length, 1)
  r.elements.set("#mail-threads", {})
  r.update({mailLoaded: "true"})
  r.flush()
  assert.deepEqual(r.focused, ["latest-summary", "mail-thread-first"])
  assert.equal(r.scroller.scrollTop, 250)
  r.hook.destroyed()
  assert.equal(r.listeners.size, 0)
  assert.equal(r.documentListeners.size, 0)
  assert.equal(r.viewListeners.size, 0)
})

test("new account/list intent fences a queued reader handoff and discards return memory", t => {
  const r = reader(t)
  r.click("row")
  r.update({mailThread: "first", mailLoaded: "false"})
  r.elements.set("#mail-conversation-heading", {focus: () => assert.fail("stale reader focus")})
  r.update({mailLoaded: "true"})
  assert.equal(r.frames.size, 1)
  r.update({mailContext: "account-b:list-2", mailThread: "", mailLoaded: "false"})
  r.flush()
  assert.equal(r.frames.size, 0)
  assert.equal(r.hook.returnPosition, null)
  r.elements.set("#mail-threads", {})
  r.update({mailLoaded: "true"})
  r.flush()
  assert.deepEqual(r.focused, [])
  r.hook.destroyed()
})

test("intentional control actions cancel pending focus and destruction cancels frames", t => {
  const r = reader(t)
  r.click("row")
  r.update({mailThread: "first", mailLoaded: "false"})
  r.click("search")
  r.elements.set("#mail-conversation-heading", {})
  r.update({mailLoaded: "true"})
  assert.equal(r.frames.size, 0)
  r.hook.schedule(() => assert.fail("destroyed hook callback"))
  assert.equal(r.frames.size, 1)
  r.hook.destroyed()
  assert.equal(r.frames.size, 0)
})

test("keyboard or pointer intent cancels delayed focus rather than stealing the user's next action", t => {
  const r = reader(t)
  for (const event of ["keydown", "pointerdown", "input"]) {
    r.click("row")
    r.update({mailThread: "first", mailLoaded: "false"})
    r.documentListeners.get(event)()
    r.elements.set("#mail-conversation-heading", {})
    r.update({mailLoaded: "true"})
    r.flush()
    assert.deepEqual(r.focused, [])
    r.update({mailThread: "", mailLoaded: "false"})
  }
  r.hook.destroyed()
})

test("newer pointer intent survives the first delayed thread patch while the pane stays active", t => {
  const r = reader(t)
  r.click("row")
  r.documentListeners.get("pointerdown")()
  r.update({mailThread: "first", mailLoaded: "false"})
  r.elements.set("#mail-conversation-heading", {})
  r.update({mailLoaded: "true"})
  r.flush()
  assert.deepEqual(r.focused, [])
  assert.deepEqual(r.scrolled, [])
  r.hook.destroyed()
})

test("browser Back starts a fresh return handoff after reader interactions, while newer input can still cancel it", t => {
  const r = reader(t)
  for (const cancelReturn of [false, true]) {
    r.focused.length = 0
    r.open()
    r.documentListeners.get("keydown")()
    r.click("metadata")
    r.viewListeners.get("popstate")({type: "popstate"})
    r.elements.delete("#mail-conversation-heading")
    r.update({mailThread: "", mailLoaded: "false"})
    r.scroller.scrollTop = 0
    if (cancelReturn) r.documentListeners.get("input")()
    r.elements.set("#mail-threads", {})
    r.update({mailLoaded: "true"})
    r.flush()
    assert.deepEqual(r.focused, cancelReturn ? ["latest-summary"] : ["latest-summary", "mail-thread-first"])
    assert.equal(r.scroller.scrollTop, cancelReturn ? 0 : 250)
  }
  r.hook.destroyed()
  assert.equal(r.viewListeners.size, 0)
})

test("focus-only control navigation supersedes a pending reader handoff", t => {
  const r = reader(t)
  r.click("row")
  r.update({mailThread: "first", mailLoaded: "false"})
  r.documentListeners.get("focusin")({target: {matches: () => true}})
  r.elements.set("#mail-conversation-heading", {})
  r.update({mailLoaded: "true"})
  r.flush()
  assert.deepEqual(r.focused, [])
  assert.deepEqual(r.scrolled, [])
  r.hook.destroyed()
})

test("Back Forward Back preserves the same bounded result position", t => {
  const r = reader(t)
  r.open()
  const traverse = thread => {
    r.viewListeners.get("popstate")({type: "popstate"})
    if (thread) r.elements.delete("#mail-threads")
    else r.elements.set("#mail-threads", {})
    r.update({mailThread: thread, mailLoaded: "true"})
    r.flush()
  }
  traverse("")
  traverse("first")
  traverse("")
  assert.deepEqual(r.focused, ["latest-summary", "mail-thread-first", "latest-summary", "mail-thread-first"])
  assert.equal(r.scroller.scrollTop, 250)
  r.hook.destroyed()
})

test("latest-summary handoff clears sticky context overlap without canceling its own focus", t => {
  const r = reader(t)
  r.elements.set(".mail-reader-context", {getBoundingClientRect: () => ({bottom: 80})})
  r.click("row")
  r.update({mailThread: "first", mailLoaded: "false"})
  r.elements.set("#mail-conversation-heading", {})
  const summary = {
    scrollIntoView() { r.scroller.scrollTop = 300 },
    getBoundingClientRect: () => ({top: 50}),
    focus() {
      r.documentListeners.get("focusin")({target: {matches: () => true}})
      r.focused.push("latest-summary")
    },
  }
  r.elements.set('[data-mail-latest="true"]', {querySelector: () => summary})
  r.update({mailLoaded: "true"})
  r.flush()
  assert.equal(r.scroller.scrollTop, 254)
  assert.deepEqual(r.focused, ["latest-summary"])
  assert.equal(r.hook.handoffCanceled, false)
  r.hook.destroyed()
})

test("a late loading patch cannot wake scenery even if Escape happened before that patch", t => {
  const r = reader(t)
  r.click("row")
  r.documentListeners.get("keydown")()
  r.pane.focused = false
  r.update({mailThread: "first", mailLoaded: "false"})
  r.elements.set("#mail-conversation-heading", {})
  r.update({mailLoaded: "true"})
  r.flush()
  assert.deepEqual(r.focused, [])
  assert.deepEqual(r.scrolled, [])
  r.hook.destroyed()
})

test("fresh inbox navigation preserves its top context and focuses the heading without waiting for provider data", t => {
  const r = reader(t)
  r.update({mailAccount: "account-a", mailContext: "account-a:list-1", mailLoaded: "false"})
  r.flush()
  assert.deepEqual(r.focused, ["mail-heading"])
  assert.deepEqual(r.scrolled, [])
  assert.equal(r.scroller.scrollTop, 0)
  r.update({mailLoaded: "true"})
  r.flush()
  assert.deepEqual(r.focused, ["mail-heading"])
  r.hook.destroyed()
})

test("new keyboard intent cancels a queued inbox heading handoff", t => {
  const r = reader(t)
  r.update({mailAccount: "account-a", mailLoaded: "false"})
  r.documentListeners.get("keydown")()
  r.flush()
  r.update({mailLoaded: "true"})
  r.flush()
  assert.deepEqual(r.focused, [])
  r.hook.destroyed()
})

test("message dates are browser-local, year-aware, and preserve invalid provider text safely", () => {
  const now = new Date(2026, 10, 2, 14)
  const today = new Date(2026, 10, 2, 9, 15)
  assert.equal(mailDate(today.toISOString(), now, "en-US").text, "9:15 AM")
  assert.equal(mailDate(new Date(2026, 10, 1, 23).toISOString(), now, "en-US").text, "Yesterday")
  assert.equal(mailDate(new Date(2026, 9, 28).toISOString(), now, "en-US").text, "Oct 28")
  assert.equal(mailDate(new Date(2025, 9, 28).toISOString(), now, "en-US").text, "Oct 28, 2025")
  assert.equal(mailDate(today.toISOString(), now, "en-US").iso, today.toISOString())
  assert.match(mailDate(today.toISOString(), now, "en-US").title, /Monday, November 2, 2026/)
  assert.deepEqual(mailDate("<img src=remote>"), {text: "<img src=remote>", title: "<img src=remote>", iso: null})
  assert.equal(mailDate(null).text, "Date unavailable")
})

test("mail freshness ages independently and never presents failed cached reads as fresh", () => {
  const at = "2026-11-02T09:00:00Z", now = Date.parse(at)
  assert.equal(mailFreshnessText(at, false, false, now), "Fetched just now")
  assert.equal(mailFreshnessText(at, true, false, now), "Local copy · fetched just now")
  assert.equal(mailFreshnessText(at, false, false, now + 179_000), "Fetched 2 min ago")
  assert.equal(mailFreshnessText(at, false, false, now + 180_000), "Stale · fetched 3 min ago")
  assert.equal(mailFreshnessText(at, true, true, now), "Stale · fetched just now")
  assert.equal(mailFreshnessText("invalid", false, false, now), "Fetch time unavailable")
})

test("date and freshness hooks use patched attributes and clean up timers and resume listeners", t => {
  const oldSet = globalThis.setInterval, oldClear = globalThis.clearInterval
  const timers = new Map()
  let next = 0
  globalThis.setInterval = (fn, delay) => { assert.equal(delay, 30_000); timers.set(++next, fn); return next }
  globalThis.clearInterval = id => timers.delete(id)
  t.after(() => { globalThis.setInterval = oldSet; globalThis.clearInterval = oldClear })
  for (const definition of [MailDate, MailFreshness]) {
    const listeners = new Map(), attrs = new Map()
    const el = {
      dataset: {mailDate: new Date().toISOString(), fetchedAt: new Date().toISOString(), cached: "false", stale: "false"},
      ownerDocument: {
        addEventListener: (name, fn) => listeners.set(name, fn),
        removeEventListener: (name, fn) => { assert.equal(listeners.get(name), fn); listeners.delete(name) },
      },
      setAttribute: (name, value) => attrs.set(name, value),
      removeAttribute: name => attrs.delete(name),
    }
    const hook = {...definition, el}
    hook.mounted()
    assert.ok(el.textContent)
    el.dataset.stale = "true"
    el.dataset.mailDate = "<unsafe date>"
    hook.updated()
    assert.equal(el.textContent, definition === MailDate ? "<unsafe date>" : "Stale · fetched just now")
    assert.equal(attrs.has("datetime"), false)
    el.textContent = "old"
    listeners.get("visibilitychange")()
    assert.notEqual(el.textContent, "old")
    assert.equal(timers.size, 1)
    hook.destroyed()
    assert.equal(timers.size, 0)
    assert.equal(listeners.size, 0)
  }
})
