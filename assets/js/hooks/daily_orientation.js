export function dailyOrientation(now = new Date(), locale = undefined) {
  return {
    day: new Intl.DateTimeFormat(locale, {day: "2-digit"}).format(now),
    weekday: new Intl.DateTimeFormat(locale, {weekday: "long"}).format(now),
    monthYear: new Intl.DateTimeFormat(locale, {month: "long", year: "numeric"}).format(now),
    date: new Intl.DateTimeFormat(locale, {weekday: "long", month: "long", day: "numeric"}).format(now),
    iso: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`,
  }
}
export default {
  mounted() {
    this.updateDay = () => {
      const day = dailyOrientation()
      for (const [selector, value] of [["[data-daily-number]", day.day], ["[data-daily-weekday]", day.weekday], ["[data-daily-month]", day.monthYear]]) {
        const target = this.el.querySelector(selector)
        if (target) target.textContent = value
      }
      const date = this.el.querySelector("[data-daily-date]")
      date.setAttribute("datetime", day.iso)
      date.setAttribute("aria-label", day.date)
    }
    this.updateDay()
    this.dayTimer = setInterval(this.updateDay, 30_000)
    this.el.ownerDocument.addEventListener("visibilitychange", this.updateDay)
  },
  destroyed() {
    clearInterval(this.dayTimer)
    this.el.ownerDocument.removeEventListener("visibilitychange", this.updateDay)
  },
}
