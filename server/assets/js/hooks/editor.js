// Keyboard handling of in-place editors (design D6a): the task title <input>
// (data-submit="enter") and description <textarea> (data-submit="mod-enter").
//
// * Keys pressed while an input method is composing belong to the IME.
// * Title: Enter saves; leaving the field saves unless Esc cancelled or Enter already
//   saved.
// * Description: Ctrl/⌘+Enter saves; a plain Enter inserts a newline.
// * Esc cancels and stops the shell's Esc handling.
//
// The server handles "save_field" / "cancel_field" (the same events as the buttons).
const Editor = {
  mounted() {
    this.reset()
    this.onKeydown = e => this.keydown(e)
    this.onBlur = () => this.blur()
    this.el.addEventListener("keydown", this.onKeydown)
    if (this.el.dataset.submit === "enter") this.el.addEventListener("blur", this.onBlur)
  },

  updated() { this.reset() },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("blur", this.onBlur)
  },

  reset() {
    this.cancelled = false
    this.submitted = false
    this.saving = false
  },

  keydown(e) {
    if (e.isComposing || e.keyCode === 229) return

    if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      this.cancelled = true
      this.pushEvent("cancel_field", {field: this.el.dataset.field})
      return
    }

    if (e.key !== "Enter") return
    const enter = this.el.dataset.submit === "enter" && !e.shiftKey
    const modEnter = this.el.dataset.submit === "mod-enter" && (e.ctrlKey || e.metaKey)
    if (!enter && !modEnter) return

    e.preventDefault()
    e.stopPropagation()
    this.submitted = true
    this.save()
  },

  blur() {
    if (this.cancelled || this.submitted) return
    this.save()
  },

  save() {
    if (this.saving) return
    this.saving = true
    this.pushEvent("save_field", {field: this.el.dataset.field, value: this.el.value}, () => {
      this.saving = false
    })
  },
}

export default Editor
