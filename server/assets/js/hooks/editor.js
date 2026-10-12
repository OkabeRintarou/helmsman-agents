// Keyboard handling of in-place editors (design D6a) and of the Markdown editor
// (add-feedback-ui designs D9, D10, D14).
//
// Title <input> (data-submit="enter"): Enter saves; leaving the field saves unless Esc
// cancelled or Enter already saved; Esc cancels.
//
// Markdown editor <textarea> (data-session set, inside [data-hm-editor]):
// * data-submit="mod-enter" (description): Ctrl/⌘+Enter sends save_field with the
//   textarea's text; Esc cancels.
// * data-submit="mod-enter-form" (feedback, reasons): Ctrl/⌘+Enter submits the form;
//   Esc is left to the panel.
// * Ctrl/⌘+Enter is caught on the editor root, so it also works in preview mode.
// * "hm:editor-mode" (dispatched by the tabs) asks the editor component for that mode
//   with the textarea's current text, so a preview never lags behind the input.
// * @ completion: the text before the caret is matched like a mention; the component
//   lists candidates; ↑/↓, Enter/Tab, Esc and the mouse pick from it.
// * Pasting a single http(s) URL over selected text makes a Markdown link.
// * Keys pressed while an input method is composing belong to the IME.
// * Every event carries the editing session; after destroyed() nothing is sent.
const MENTION = /(^|[^A-Za-z0-9._/@-])@([A-Za-z0-9._/-]{0,64})$/
const LINK = /^https?:\/\/\S+$/

const Editor = {
  mounted() {
    this.reset()
    this.alive = true
    this.markdown = this.el.dataset.session !== undefined
    this.listen(this.el, "keydown", e => this.keydown(e))
    if (this.el.dataset.submit === "enter") this.listen(this.el, "blur", () => this.blur())
    if (!this.markdown) return

    this.session = Number(this.el.dataset.session)
    this.root = this.el.closest("[data-hm-editor]")
    this.listen(this.root, "keydown", e => this.rootKeydown(e))
    this.listen(this.root, "mousedown", e => this.optionClick(e))
    this.listen(this.el, "hm:editor-mode", e => this.setMode(e.detail?.mode))
    this.listen(this.el, "input", e => { if (!e.isComposing) this.checkMention() })
    this.listen(this.el, "click", () => this.checkMention())
    this.listen(this.el, "compositionend", () => this.checkMention())
    this.listen(this.el, "paste", e => this.paste(e))
    this.observer = new MutationObserver(() => this.syncList())
    this.observer.observe(this.root, {childList: true, subtree: true})

    // A new editing session starts in edit mode with the caret at the end. Panels show
    // their content after the editor mounts, so focus on the next frame.
    requestAnimationFrame(() => {
      if (!this.alive) return
      this.el.focus()
      const end = this.el.value.length
      this.el.setSelectionRange(end, end)
    })
  },

  updated() { this.reset() },

  destroyed() {
    this.alive = false
    clearTimeout(this.mentionTimer)
    this.observer?.disconnect()
    for (const [el, type, fn] of this.listeners || []) el.removeEventListener(type, fn)
  },

  listen(el, type, fn) {
    el.addEventListener(type, fn)
    ;(this.listeners ||= []).push([el, type, fn])
  },

  reset() {
    this.cancelled = false
    this.submitted = false
    this.saving = false
  },

  push(event, payload, reply) {
    if (!this.alive) return
    this.pushEventTo(this.root, event, {...payload, session: this.session}, reply)
  },

  composing(e) { return e.isComposing || e.keyCode === 229 },

  keydown(e) {
    if (this.composing(e)) return
    if (this.markdown && this.listOpen() && this.listKey(e)) return

    if (e.key === "Escape") {
      if (this.el.dataset.submit === "mod-enter-form") return
      e.preventDefault()
      e.stopPropagation()
      this.cancelled = true
      const payload = {field: this.el.dataset.field}
      if (this.markdown) payload.session = this.session
      this.pushEvent("cancel_field", payload)
      return
    }

    // Markdown editors: Ctrl/⌘+Enter bubbles to the root listener.
    if (this.markdown || e.key !== "Enter") return
    if (this.el.dataset.submit !== "enter" || e.shiftKey) return
    e.preventDefault()
    e.stopPropagation()
    this.submitted = true
    this.save()
  },

  rootKeydown(e) {
    if (this.composing(e) || e.key !== "Enter" || !(e.ctrlKey || e.metaKey)) return
    e.preventDefault()
    e.stopPropagation()
    if (this.el.dataset.submit === "mod-enter-form") this.el.form?.requestSubmit()
    else this.save()
  },

  blur() {
    if (this.cancelled || this.submitted) return
    this.save()
  },

  save() {
    if (this.saving || !this.alive) return
    this.saving = true
    const payload = {field: this.el.dataset.field, value: this.el.value}
    if (this.markdown) payload.session = this.session
    this.pushEvent("save_field", payload, () => { this.saving = false })
  },

  setMode(mode) {
    if (mode !== "edit" && mode !== "preview") return
    this.push("set_mode", {mode, value: this.el.value}, () => {
      if (mode === "edit" && this.alive) this.el.focus()
    })
  },

  paste(e) {
    const {selectionStart: start, selectionEnd: end} = this.el
    const text = (e.clipboardData?.getData("text/plain") || "").trim()
    if (start === end || !LINK.test(text)) return
    e.preventDefault()
    const selected = this.el.value.slice(start, end)
    this.el.setRangeText(`[${selected}](${text})`, start, end, "end")
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
  },

  // @ completion

  mentionQuery() {
    if (this.el.selectionStart !== this.el.selectionEnd) return null
    const match = MENTION.exec(this.el.value.slice(0, this.el.selectionStart))
    return match ? match[2] : null
  },

  checkMention() {
    clearTimeout(this.mentionTimer)
    const q = this.mentionQuery()
    if (q === null) {
      if (this.listOpen() || this.queried) this.push("mention_close", {})
      this.queried = false
      return
    }
    this.mentionTimer = setTimeout(() => {
      this.queried = true
      this.push("mention_query", {q})
    }, 100)
  },

  list() { return document.getElementById(`${this.el.dataset.editor}-mentions`) },
  listOpen() { return !!this.list() },
  options() { return Array.from(this.list()?.querySelectorAll("[role=option]") || []) },

  // Keeps the combobox attributes in line with the list the server renders.
  syncList() {
    const list = this.list()
    this.el.setAttribute("aria-expanded", String(!!list))
    if (!list) {
      this.el.removeAttribute("aria-activedescendant")
      this.activeQ = null
      return
    }
    if (list.dataset.q !== this.activeQ) {
      this.activeQ = list.dataset.q
      this.select(0)
    }
  },

  select(index) {
    const options = this.options()
    if (!options.length) return
    this.active = (index + options.length) % options.length
    options.forEach((o, i) => o.setAttribute("aria-selected", String(i === this.active)))
    this.el.setAttribute("aria-activedescendant", options[this.active].id)
    options[this.active].scrollIntoView({block: "nearest"})
  },

  listKey(e) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      this.select((this.active || 0) + (e.key === "ArrowDown" ? 1 : -1))
    } else if ((e.key === "Enter" && !e.ctrlKey && !e.metaKey) || e.key === "Tab") {
      const option = this.options()[this.active || 0]
      if (!option) return false
      this.insert(option.dataset.name)
    } else if (e.key === "Escape") {
      clearTimeout(this.mentionTimer)
      this.queried = false
      this.push("mention_close", {})
    } else {
      return false
    }
    e.preventDefault()
    e.stopPropagation()
    return true
  },

  optionClick(e) {
    const option = e.target.closest?.("[role=option]")
    if (!option || !this.list()?.contains(option)) return
    e.preventDefault()
    this.insert(option.dataset.name)
  },

  insert(name) {
    const q = this.mentionQuery()
    if (q === null || !name) return
    const caret = this.el.selectionStart
    this.el.setRangeText(`@${name} `, caret - q.length - 1, caret, "end")
    this.el.focus()
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
  },
}

export default Editor
