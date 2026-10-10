// Global keyboard handling (design D5a). The hook element is the shell root; the
// listener lives on `document` (bubble phase) because modal layers are portalled into
// #hm-overlays, outside the shell. Local hooks that handle a key call preventDefault()
// and are skipped here.

const EDITABLE =
  "input:not([type=checkbox]):not([type=radio]):not([type=button]):not([type=submit]), textarea, select"

const isEditable = el => !!el && (el.isContentEditable || el.matches?.(EDITABLE))

const topOverlay = () => {
  const open = Array.from(document.querySelectorAll("[data-hm-overlay][data-open]"))
  return open.filter(el => !el.closest("[inert]")).pop() || null
}

const openMenu = scope =>
  Array.from((scope || document).querySelectorAll("[data-hm-menu][data-open]"))
    .filter(el => !el.closest("[inert]")).pop() || null

const Hotkeys = {
  mounted() {
    if (window.__hmHotkeys) window.__hmHotkeys.detach()
    window.__hmHotkeys = this
    this.onKeydown = e => this.handle(e)
    document.addEventListener("keydown", this.onKeydown)
  },

  destroyed() { this.detach() },

  detach() {
    document.removeEventListener("keydown", this.onKeydown)
    if (window.__hmHotkeys === this) window.__hmHotkeys = null
  },

  exec(el, attr) {
    const js = el?.getAttribute(attr)
    if (js) this.liveSocket.execJS(el, js)
  },

  handle(e) {
    if (e.isComposing || e.keyCode === 229) return
    if (e.defaultPrevented) return

    const mod = e.metaKey || e.ctrlKey
    const top = topOverlay()

    if (mod && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "k") {
      if (!top) {
        e.preventDefault()
        this.exec(document.getElementById("command-palette"), "data-open-palette")
      } else if (top.hasAttribute("data-hm-palette")) {
        e.preventDefault()
        this.exec(top, "data-cancel")
      }
      return
    }

    const menu = openMenu(top)
    const drawer = document.querySelector("#hm-sidebar.hm-drawer-open")
    if (menu) return this.menuKey(e, menu)
    if (top) return this.overlayKey(e, top, mod)
    if (drawer) {
      if (e.key === "Escape") { e.preventDefault(); this.exec(drawer, "data-cancel") }
      return
    }

    if (mod || e.altKey || isEditable(e.target)) return
    if (e.key === "c" || e.key === "C") {
      e.preventDefault()
      document.querySelector("[data-hm-new-task]")?.click()
    } else if (e.key === "[") {
      e.preventDefault()
      window.dispatchEvent(new Event("hm:toggle-sidebar"))
    } else if (e.key === "/") {
      const filter = document.querySelector("[data-hm-filter-input]")
      if (filter) { e.preventDefault(); filter.focus() }
    }
  },

  menuKey(e, menu) {
    const items = Array.from(menu.querySelectorAll("[role^=menuitem]:not([aria-disabled=true])"))
    const index = items.indexOf(document.activeElement)
    if (e.key === "Escape") {
      e.preventDefault()
      this.exec(menu, "data-cancel")
    } else if (e.key === "Enter" && e.target.matches?.("[data-hm-menu-filter]")) {
      // The rendered items may belong to an older query (debounce): let the server pick
      // from the full list. Its reply arrives after the matching items are patched in.
      e.preventDefault()
      if (menu.dataset.hmSelecting) return
      menu.dataset.hmSelecting = "1"
      const done = () => delete menu.dataset.hmSelecting
      const timer = setTimeout(done, 5000)
      this.pushEventTo(e.target, "select_first", {query: e.target.value}, ({id} = {}) => {
        clearTimeout(timer); done()
        const item = id && menu.hasAttribute("data-open") && document.getElementById(id)
        if (item && item.getAttribute("aria-disabled") !== "true") item.click()
      })
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (items.length === 0) return
      const step = e.key === "ArrowDown" ? 1 : -1
      const next = index === -1 ? (step === 1 ? 0 : items.length - 1)
        : (index + step + items.length) % items.length
      items[next].focus()
    }
  },

  overlayKey(e, top, mod) {
    if (e.key === "Escape") {
      e.preventDefault()
      if (!top.querySelector(".phx-submit-loading")) this.exec(top, "data-cancel")
      return
    }
    if (mod && e.key === "Enter" && top.getAttribute("role") === "alertdialog") {
      e.preventDefault()
      top.querySelector("[data-confirm-primary]")?.click()
      return
    }
    if (top.hasAttribute("data-hm-palette") && e.target.matches?.("[data-hm-palette-input]")) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        this.pushEventTo("#command-palette", "move", {delta: e.key === "ArrowDown" ? 1 : -1})
      } else if (e.key === "Enter") {
        e.preventDefault()
        this.pushEventTo("#command-palette", "execute", {})
      }
    }
  },
}

export default Hotkeys
