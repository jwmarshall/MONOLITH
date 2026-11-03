// Browser-local boundaries: constructing tomorrow (not adding 24 hours) handles DST.
export function calendarDay(now = new Date()) {
  const year = now.getFullYear(), month = now.getMonth(), day = now.getDate()
  return {
    from: new Date(year, month, day).toISOString(),
    to: new Date(year, month, day + 1).toISOString(),
    date: `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  }
}

function observe(hook, update) {
  hook.updateCalendar = update
  hook.calendarDocument = hook.el.ownerDocument
  hook.calendarWindow = hook.calendarDocument.defaultView
  update()
  hook.calendarTimer = setInterval(update, 60_000)
  hook.calendarDocument.addEventListener("visibilitychange", update)
  hook.calendarWindow.addEventListener("pageshow", update)
  hook.calendarWindow.addEventListener("focus", update)
}

function stop(hook) {
  clearInterval(hook.calendarTimer)
  hook.calendarDocument.removeEventListener("visibilitychange", hook.updateCalendar)
  hook.calendarWindow.removeEventListener("pageshow", hook.updateCalendar)
  hook.calendarWindow.removeEventListener("focus", hook.updateCalendar)
}

export const CalendarDay = {
  mounted() {
    this.lastCalendarDay = null
    observe(this, () => {
      const day = calendarDay()
      const key = JSON.stringify(day)
      if (key !== this.lastCalendarDay) {
        this.lastCalendarDay = key
        this.pushEvent("calendar:day", day)
      }
    })
  },
  // A replacement LiveView socket has no browser context, even on the same day.
  reconnected() { this.lastCalendarDay = null; this.updateCalendar() },
  destroyed() { stop(this) },
}

function instant(value) {
  // Timed events must have an explicit offset; do not reinterpret a date as UTC/local time.
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null
  const date = new Date(value)
  return Number.isFinite(date.getTime()) ? date : null
}

export function calendarEventTime(start, end, allDay, now = new Date(), locale) {
  if (allDay === true || allDay === "true") return {text: "All day", title: "All day", ongoing: false}
  const from = instant(start), to = instant(end)
  if (!from || !to || to <= from) return {text: "Time unavailable", title: "Time unavailable", ongoing: false}
  const sameDay = from.getFullYear() === to.getFullYear() && from.getMonth() === to.getMonth() && from.getDate() === to.getDate()
  const options = {hour: "numeric", minute: "2-digit", ...(!sameDay ? {month: "short", day: "numeric"} : {})}
  const formatter = new Intl.DateTimeFormat(locale, options)
  const full = new Intl.DateTimeFormat(locale, {dateStyle: "full", timeStyle: "long"})
  const ongoing = from <= now && now < to
  return {
    text: `${formatter.format(from)} – ${formatter.format(to)}${ongoing ? " · Ongoing" : ""}`,
    title: `${full.format(from)} – ${full.format(to)}`,
    ongoing,
  }
}

export const CalendarEventTime = {
  mounted() {
    observe(this, () => {
      const {start, end, allDay} = this.el.dataset
      const label = calendarEventTime(start, end, allDay)
      // Only this ignored text subtree is client-owned. Dataset patches remain server-owned.
      const text = this.el.querySelector("[data-calendar-time-text]")
      if (text) text.textContent = label.text
      this.el.title = label.title
      this.el.dataset.ongoing = String(label.ongoing)
    })
  },
  updated() { this.updateCalendar() },
  destroyed() { stop(this) },
}
