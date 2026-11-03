import assert from "node:assert/strict"
import test from "node:test"
import {execFileSync} from "node:child_process"
import {CalendarDay, CalendarEventTime, calendarDay, calendarEventTime} from "../../assets/js/hooks/calendar_agenda.js"

const moduleURL = new URL("../../assets/js/hooks/calendar_agenda.js", import.meta.url).href

function inTimezone(timezone, code) {
  return JSON.parse(execFileSync(process.execPath, ["--input-type=module", "-e", `import {calendarDay, calendarEventTime} from ${JSON.stringify(moduleURL)}; ${code}`], {
    env: {...process.env, TZ: timezone}, encoding: "utf8",
  }))
}

test("browser day is local, not the UTC calendar date", () => {
  const day = inTimezone("America/Los_Angeles", 'console.log(JSON.stringify(calendarDay(new Date("2026-01-02T03:00:00Z"))))')
  assert.deepEqual(day, {from: "2026-01-01T08:00:00.000Z", to: "2026-01-02T08:00:00.000Z", date: "2026-01-01", timezone: "America/Los_Angeles"})
  const positive = inTimezone("Asia/Tokyo", 'console.log(JSON.stringify(calendarDay(new Date("2026-01-01T20:00:00Z"))))')
  assert.equal(positive.date, "2026-01-02")
  assert.equal(positive.from, "2026-01-01T15:00:00.000Z")
  assert.equal(calendarDay(new Date(2026, 11, 31, 23)).date, "2026-12-31")
})

test("next local midnight respects spring and autumn DST transitions", () => {
  for (const [date, hours, from, to] of [
    ["2026-03-08T12:00:00Z", 23, "2026-03-08T08:00:00.000Z", "2026-03-09T07:00:00.000Z"],
    ["2026-11-01T12:00:00Z", 25, "2026-11-01T07:00:00.000Z", "2026-11-02T08:00:00.000Z"],
  ]) {
    const day = inTimezone("America/Los_Angeles", `console.log(JSON.stringify(calendarDay(new Date(${JSON.stringify(date)}))))`)
    assert.equal(day.from, from)
    assert.equal(day.to, to)
    assert.equal((Date.parse(day.to) - Date.parse(day.from)) / 3600_000, hours)
  }
})

test("timed events use local locale, offsets and half-open ongoing intervals", () => {
  const start = "2026-01-02T09:00:00Z", end = "2026-01-02T10:00:00Z"
  for (const [now, ongoing] of [["2026-01-02T08:59:59Z", false], [start, true], ["2026-01-02T09:59:59Z", true], [end, false]]) {
    const label = calendarEventTime(start, end, false, new Date(now), "en-US")
    assert.equal(label.ongoing, ongoing)
    assert.equal(label.text.includes("Ongoing"), ongoing)
    assert.match(label.title, /2026/)
  }
  const local = inTimezone("America/Los_Angeles", `console.log(JSON.stringify(calendarEventTime("${start}", "${end}", false, new Date("${start}"), "en-US")))`)
  assert.match(local.text, /^1:00\s*AM – 2:00\s*AM · Ongoing$/)
  assert.equal(calendarEventTime("2026-01-02T10:00:00+01:00", end, false, new Date(start)).ongoing, true)
})

test("all-day labels do not parse dates or shift across timezones", () => {
  for (const value of [true, "true"]) {
    assert.deepEqual(calendarEventTime("2026-03-08", "2026-03-09", value), {text: "All day", title: "All day", ongoing: false})
  }
})

test("multi-day timed events include local dates; invalid metadata stays honest", () => {
  const label = inTimezone("UTC", 'console.log(JSON.stringify(calendarEventTime("2026-01-01T23:00:00Z", "2026-01-02T02:00:00Z", false, new Date("2026-01-02T00:00:00Z"), "en-US")))')
  assert.match(label.text, /Jan 1/)
  assert.match(label.text, /Jan 2/)
  for (const [start, end] of [["junk", "also junk"], [null, null], ["2026-01-02", "2026-01-03"], ["2026-01-02T09:00:00", "2026-01-02T10:00:00"], ["2026-01-02T09:00:00Z", "2026-01-02T08:00:00Z"], ["2026-01-02T09:00:00Z", "2026-01-02T09:00:00Z"]]) {
    assert.deepEqual(calendarEventTime(start, end, false), {text: "Time unavailable", title: "Time unavailable", ongoing: false})
  }
})

function target() {
  const listeners = new Map()
  return {
    listeners,
    addEventListener(event, fn) {
      if (!listeners.has(event)) listeners.set(event, new Set())
      listeners.get(event).add(fn)
    },
    removeEventListener(event, fn) {
      listeners.get(event)?.delete(fn)
      if (listeners.get(event)?.size === 0) listeners.delete(event)
    },
    dispatch(event) { for (const fn of listeners.get(event) || []) fn() },
  }
}

function environment(t, date = "2026-01-02T09:00:00Z") {
  const NativeDate = globalThis.Date
  let now = new NativeDate(date).getTime()
  globalThis.Date = class extends NativeDate {
    constructor(...args) { super(...(args.length ? args : [now])) }
    static now() { return now }
  }
  const oldSet = globalThis.setInterval, oldClear = globalThis.clearInterval
  const timers = new Map()
  let id = 0
  globalThis.setInterval = (fn, delay) => {
    assert.equal(delay, 60_000)
    timers.set(++id, fn)
    return id
  }
  globalThis.clearInterval = timer => timers.delete(timer)
  t.after(() => { globalThis.Date = NativeDate; globalThis.setInterval = oldSet; globalThis.clearInterval = oldClear })
  const win = target(), doc = {...target(), defaultView: win}
  return {timers, doc, win, advance: ms => { now += ms }}
}

test("day hook sends only changed boundaries, handles midnight/resume and cleans up", t => {
  const {timers, doc, win, advance} = environment(t)
  const calls = []
  const hook = {...CalendarDay, el: {ownerDocument: doc}, pushEvent: (event, payload) => calls.push({event, payload})}
  hook.mounted()
  assert.equal(calls.length, 1)
  assert.equal(calls[0].event, "calendar:day")
  for (const fn of timers.values()) fn()
  doc.dispatch("visibilitychange")
  win.dispatch("pageshow")
  win.dispatch("focus")
  assert.equal(calls.length, 1)
  advance(86400_000)
  win.dispatch("focus")
  assert.equal(calls.length, 2)
  assert.notEqual(calls[0].payload.date, calls[1].payload.date)
  advance(86400_000)
  doc.dispatch("visibilitychange")
  assert.equal(calls.length, 3)
  advance(86400_000)
  win.dispatch("pageshow")
  assert.equal(calls.length, 4)
  hook.reconnected()
  assert.equal(calls.length, 5)
  win.dispatch("focus")
  assert.equal(calls.length, 5)
  assert.equal(timers.size, 1)
  hook.destroyed()
  assert.equal(timers.size, 0)
  assert.equal(doc.listeners.size, 0)
  assert.equal(win.listeners.size, 0)
})

test("day hook notices timezone changes even without crossing midnight", t => {
  const {doc, win} = environment(t)
  const original = Intl.DateTimeFormat
  let timezone = "UTC"
  Intl.DateTimeFormat = function () { return {resolvedOptions: () => ({timeZone: timezone})} }
  t.after(() => { Intl.DateTimeFormat = original })
  const calls = []
  const hook = {...CalendarDay, el: {ownerDocument: doc}, pushEvent: (_event, payload) => calls.push(payload)}
  hook.mounted()
  timezone = "Etc/UTC"
  win.dispatch("focus")
  assert.equal(calls.length, 2)
  assert.equal(calls[0].date, calls[1].date)
  assert.equal(calls[1].timezone, "Etc/UTC")
  win.dispatch("focus")
  assert.equal(calls.length, 2)
  hook.destroyed()
})

test("event hook patches only owned text, updates per minute/resume, and tears down", t => {
  const {timers, doc, win, advance} = environment(t)
  const text = {}, dataset = {start: "2026-01-02T09:00:00Z", end: "2026-01-02T09:01:00Z", allDay: "false"}
  const hook = {...CalendarEventTime, el: {ownerDocument: doc, dataset, querySelector: selector => {
    assert.equal(selector, "[data-calendar-time-text]")
    return text
  }}}
  hook.mounted()
  assert.match(text.textContent, /Ongoing/)
  assert.equal(dataset.ongoing, "true")
  advance(60_000)
  for (const fn of timers.values()) fn()
  assert.equal(dataset.ongoing, "false")
  assert.doesNotMatch(text.textContent, /Ongoing/)
  dataset.allDay = "true"
  hook.updated()
  assert.equal(text.textContent, "All day")
  dataset.allDay = "false"
  dataset.start = "<img src=https://example.invalid>"
  win.dispatch("pageshow")
  assert.equal(text.textContent, "Time unavailable")
  text.textContent = "old"
  win.dispatch("focus")
  assert.equal(text.textContent, "Time unavailable")
  text.textContent = "old"
  doc.dispatch("visibilitychange")
  assert.equal(text.textContent, "Time unavailable")
  assert.equal(timers.size, 1)
  hook.destroyed()
  assert.equal(timers.size, 0)
  assert.equal(doc.listeners.size, 0)
  assert.equal(win.listeners.size, 0)
})
