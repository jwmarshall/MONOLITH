import assert from "node:assert/strict"
import test from "node:test"
import DailyOrientation, {dailyOrientation} from "../../assets/js/hooks/daily_orientation.js"
import ObservationTime, {observationText} from "../../assets/js/hooks/observation_time.js"

test("daily greeting uses local time and rolls over the local calendar day", () => {
  for (const [hour, greeting] of [[0, "Good morning"], [11, "Good morning"], [12, "Good afternoon"], [17, "Good afternoon"], [18, "Good evening"], [23, "Good evening"]]) {
    const day = dailyOrientation(new Date(2026, 10, 2, hour), "en-US")
    assert.equal(day.greeting, greeting)
    assert.equal(day.iso, "2026-11-02")
    assert.equal(day.date, "Monday, November 2")
  }
  assert.equal(dailyOrientation(new Date(2026, 10, 3, 0), "en-US").iso, "2026-11-03")
})

test("observations age independently of page activity and preserve known failures", () => {
  const at = "2026-11-02T09:00:00Z"
  const now = Date.parse(at)
  assert.equal(observationText(at, false, now), "Checked just now")
  assert.equal(observationText(at, false, now + 179_000), "Checked 2 min ago")
  assert.equal(observationText(at, false, now + 180_000), "Stale · last checked 3 min ago")
  assert.equal(observationText(at, true, now), "Stale · last checked just now")
  assert.equal(observationText(at, false, now + 3600_000), "Stale · last checked 1 hr ago")
  assert.equal(observationText(at, false, now + 86400_000), "Stale · last checked 1 day ago")
  assert.equal(observationText("invalid", false, now), "Unread count update unavailable")
})

test("Home observations omit checked statuses but retain stale warnings", () => {
  const at = "2026-11-02T09:00:00Z"
  const now = Date.parse(at)
  assert.equal(observationText(at, false, now, true), "")
  assert.equal(observationText(at, false, now + 179_000, true), "")
  assert.equal(observationText(at, false, now + 180_000, true), "Stale · 3 min ago")
  assert.equal(observationText(at, true, now, true), "Stale · just now")
})

function timers(t) {
  const oldSet = globalThis.setInterval
  const oldClear = globalThis.clearInterval
  const callbacks = new Map()
  let id = 0
  globalThis.setInterval = (fn, delay) => {
    assert.equal(delay, 30_000)
    callbacks.set(++id, fn)
    return id
  }
  globalThis.clearInterval = handle => callbacks.delete(handle)
  t.after(() => { globalThis.setInterval = oldSet; globalThis.clearInterval = oldClear })
  return callbacks
}

function document() {
  const listeners = new Map()
  return {
    listeners,
    addEventListener: (event, fn) => listeners.set(event, fn),
    removeEventListener: (event, fn) => { if (listeners.get(event) === fn) listeners.delete(event) },
  }
}

test("daily hook refreshes on resume and removes its timer and listener", t => {
  const callbacks = timers(t)
  const doc = document()
  const greeting = {}
  const date = {setAttribute: (name, value) => { date[name] = value }}
  const hook = {...DailyOrientation, el: {ownerDocument: doc, querySelector: selector => selector === "[data-daily-greeting]" ? greeting : date}}
  hook.mounted()
  assert.match(greeting.textContent, /^Good /)
  assert.match(date.datetime, /^\d{4}-\d{2}-\d{2}$/)
  date.textContent = "old"
  doc.listeners.get("visibilitychange")()
  assert.notEqual(date.textContent, "old")
  assert.equal(callbacks.size, 1)
  hook.destroyed()
  assert.equal(callbacks.size, 0)
  assert.equal(doc.listeners.size, 0)
})

test("quiet Home observations age on timers/resume and recover without checked copy", t => {
  const callbacks = timers(t)
  const doc = document()
  const realNow = Date.now
  let now = Date.parse("2026-11-02T09:00:00Z")
  Date.now = () => now
  t.after(() => { Date.now = realNow })
  const hook = {...ObservationTime, el: {ownerDocument: doc, dataset: {observedAt: new Date(now).toISOString(), failed: "false", warningsOnly: "true"}}}
  hook.mounted()
  assert.equal(hook.el.textContent, "")
  now += 180_000
  callbacks.values().next().value()
  assert.equal(hook.el.textContent, "Stale · 3 min ago")
  hook.el.dataset.observedAt = new Date(now).toISOString()
  hook.updated()
  assert.equal(hook.el.textContent, "")
  hook.el.dataset.failed = "true"
  doc.listeners.get("visibilitychange")()
  assert.equal(hook.el.textContent, "Stale · just now")
  hook.el.dataset.warningsOnly = "false"
  hook.updated()
  assert.equal(hook.el.textContent, "Stale · last checked just now")
  hook.destroyed()
  assert.equal(callbacks.size, 0)
  assert.equal(doc.listeners.size, 0)
})

test("observation hook uses patched metadata without duplicating timers", t => {
  const callbacks = timers(t)
  const doc = document()
  const hook = {...ObservationTime, el: {ownerDocument: doc, dataset: {observedAt: new Date().toISOString(), failed: "false"}}}
  hook.mounted()
  assert.equal(hook.el.textContent, "Checked just now")
  hook.el.dataset.failed = "true"
  hook.updated()
  assert.equal(hook.el.textContent, "Stale · last checked just now")
  hook.el.dataset.observedAt = "2000-01-01T00:00:00Z"
  doc.listeners.get("visibilitychange")()
  assert.match(hook.el.textContent, /^Stale · last checked \d+ days ago$/)
  assert.equal(callbacks.size, 1)
  hook.destroyed()
  assert.equal(callbacks.size, 0)
  assert.equal(doc.listeners.size, 0)
})
