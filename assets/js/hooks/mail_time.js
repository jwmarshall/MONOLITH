// Provider dates are untrusted text: format parseable dates locally, retain the
// original otherwise, and never turn provider strings into markup or requests.
export function mailDate(value, now = new Date(), locale) {
  const date = new Date(value || "invalid")
  if (!Number.isFinite(date.getTime())) return {text: value || "Date unavailable", title: value || "Date unavailable", iso: null}
  const sameDay = other => date.getFullYear() === other.getFullYear() && date.getMonth() === other.getMonth() && date.getDate() === other.getDate()
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
  const text = sameDay(now) ? new Intl.DateTimeFormat(locale, {hour: "numeric", minute: "2-digit"}).format(date)
    : sameDay(yesterday) ? "Yesterday"
    : new Intl.DateTimeFormat(locale, {month: "short", day: "numeric", ...(date.getFullYear() !== now.getFullYear() ? {year: "numeric"} : {})}).format(date)
  return {
    text,
    title: new Intl.DateTimeFormat(locale, {dateStyle: "full", timeStyle: "long"}).format(date),
    iso: date.toISOString(),
  }
}

export function mailFreshnessText(timestamp, cached, stale, now = Date.now()) {
  const at = Date.parse(timestamp)
  if (!Number.isFinite(at)) return "Fetch time unavailable"
  const seconds = Math.max(0, Math.floor((now - at) / 1000))
  const age = seconds < 60 ? "just now"
    : seconds < 3600 ? `${Math.floor(seconds / 60)} min ago`
    : seconds < 86400 ? `${Math.floor(seconds / 3600)} hr ago`
    : `${Math.floor(seconds / 86400)} ${seconds < 172800 ? "day" : "days"} ago`
  const prefix = stale || seconds >= 180 ? "Stale · fetched" : cached ? "Local copy · fetched" : "Fetched"
  return `${prefix} ${age}`
}

function observe(hook, update) {
  hook.updateTime = update
  update()
  hook.timeTimer = setInterval(update, 30_000)
  hook.el.ownerDocument.addEventListener("visibilitychange", update)
}

function stop(hook) {
  clearInterval(hook.timeTimer)
  hook.el.ownerDocument.removeEventListener("visibilitychange", hook.updateTime)
}

export const MailDate = {
  mounted() {
    observe(this, () => {
      const {text, title, iso} = mailDate(this.el.dataset.mailDate)
      this.el.textContent = text
      this.el.title = title
      if (iso) this.el.setAttribute("datetime", iso)
      else this.el.removeAttribute("datetime")
    })
  },
  updated() { this.updateTime() },
  destroyed() { stop(this) },
}

export const MailFreshness = {
  mounted() {
    observe(this, () => {
      const {fetchedAt, cached, stale} = this.el.dataset
      this.el.textContent = mailFreshnessText(fetchedAt, cached === "true", stale === "true")
      this.el.title = mailDate(fetchedAt).title
    })
  },
  updated() { this.updateTime() },
  destroyed() { stop(this) },
}
