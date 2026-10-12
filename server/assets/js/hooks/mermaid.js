// Mermaid diagrams in rendered Markdown (design D11). Mounted on every <.markdown>
// container; does nothing unless the container has a `pre[data-mermaid]` block, so the
// separate mermaid bundle (data-mermaid-src) is only requested by pages with diagrams.
//
// Each diagram is drawn into a `div.hm-mermaid-figure` right after its `pre`, which is
// then hidden. A failed render keeps the source visible with an error line below it.
// Diagrams are drawn again when the theme changes.

let loading = null

const loadMermaid = src => {
  if (window.hmMermaid) return Promise.resolve(window.hmMermaid)
  if (!loading) {
    loading = new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = src
      script.async = true
      script.onload = () => window.hmMermaid ? resolve(window.hmMermaid) : reject(new Error("mermaid missing"))
      script.onerror = () => { loading = null; reject(new Error("failed to load mermaid")) }
      document.head.appendChild(script)
    })
  }
  return loading
}

const isDark = () => document.documentElement.getAttribute("data-theme") === "helmsman-dark"

const Mermaid = {
  mounted() {
    if (!this.blocks().length) return
    this.onTheme = () => this.scheduleRender()
    this.observer = new MutationObserver(this.onTheme)
    this.observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
    this.render()
  },

  destroyed() {
    this.observer?.disconnect()
    this.dead = true
  },

  blocks() { return Array.from(this.el.querySelectorAll("pre[data-mermaid]")) },

  scheduleRender() {
    if (this.dead) return
    cancelAnimationFrame(this.frame)
    this.frame = requestAnimationFrame(() => this.render())
  },

  async render() {
    let mermaid
    try {
      mermaid = await loadMermaid(this.el.dataset.mermaidSrc)
    } catch (e) {
      this.blocks().forEach(pre => this.fail(pre, e))
      return
    }
    if (this.dead) return

    const style = getComputedStyle(this.el)
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: isDark() ? "dark" : "default",
      fontFamily: style.fontFamily,
    })

    const run = (this.run = (this.run || 0) + 1)
    for (const [i, pre] of this.blocks().entries()) {
      const source = pre.querySelector("code")?.textContent ?? pre.textContent
      try {
        const {svg} = await mermaid.render(`${this.el.id}-m${i}-${run}`, source)
        if (this.dead || run !== this.run) return
        this.show(pre, svg)
      } catch (e) {
        if (this.dead || run !== this.run) return
        this.fail(pre, e)
      }
    }
    // Diagrams change the page height: let an anchor jump settle again (app.js).
    window.dispatchEvent(new CustomEvent("hm:layout"))
  },

  show(pre, svg) {
    this.clear(pre)
    const figure = document.createElement("div")
    figure.className = "hm-mermaid-figure"
    figure.setAttribute("role", "img")
    figure.setAttribute("aria-label", this.el.dataset.mermaidLabel || "Mermaid")
    figure.dataset.mermaidFigure = ""
    figure.innerHTML = svg
    pre.after(figure)
    pre.hidden = true
  },

  fail(pre, error) {
    this.clear(pre)
    pre.hidden = false
    const note = document.createElement("p")
    note.className = "hm-mermaid-error"
    note.dataset.mermaidError = ""
    const first = String(error?.message || error || "").split("\n")[0]
    note.textContent = `${this.el.dataset.mermaidFailed || ""}${first}`
    pre.after(note)
  },

  clear(pre) {
    let next = pre.nextElementSibling
    while (next && (next.hasAttribute("data-mermaid-figure") || next.hasAttribute("data-mermaid-error"))) {
      const remove = next
      next = next.nextElementSibling
      remove.remove()
    }
  },
}

export default Mermaid
