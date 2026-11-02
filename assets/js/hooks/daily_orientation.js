export function dailyOrientation(now = new Date(), locale = undefined) {
  const hour = now.getHours()
  return {
    greeting: hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening",
    date: new Intl.DateTimeFormat(locale, {weekday: "long", month: "long", day: "numeric"}).format(now),
    // Local calendar date, not UTC's possibly different day.
    iso: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`,
  }
}

export default {
  mounted() {
    this.updateDay = () => {
      const day = dailyOrientation()
      this.el.querySelector("[data-daily-greeting]").textContent = day.greeting
      const date = this.el.querySelector("[data-daily-date]")
      date.textContent = day.date
      date.setAttribute("datetime", day.iso)
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
