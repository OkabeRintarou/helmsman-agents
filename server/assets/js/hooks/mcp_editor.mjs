// Stored secrets arrive only as $keep markers. Newly entered secrets stay in this DOM.
const DOTS = "••••••"
export const isKeep = value => value && typeof value === "object" && Object.keys(value).length === 1 && typeof value.$keep === "string"
export function toJson(config) {
  return JSON.stringify(config, (_key, value) => isKeep(value) ? DOTS : value, 2)
}
export function fromJson(text, originals) {
  const parsed = JSON.parse(text)
  if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") throw new Error("JSON must be an object")
  const names = Object.keys(originals)
  const newNames = Object.keys(parsed)
  const removed = names.filter(name => !newNames.includes(name))
  const added = newNames.filter(name => !names.includes(name))
  const convert = (value, source, old) => {
    if (value === DOTS) {
      if (!isKeep(old)) throw new Error("No stored value to keep")
      return {$keep: old.$keep || source}
    }
    if (Array.isArray(value)) return value.map((v, i) => convert(v, source, old?.[i]))
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, convert(v, source, old?.[k])]))
    return value
  }
  return Object.fromEntries(newNames.map((name, i) => {
    // Stable card order survives renaming in advanced mode.
    const source = names.includes(name) ? name : added.length === removed.length ? removed[added.indexOf(name)] : undefined
    return [name, convert(parsed[name], source, originals[source])]
  }))
}
export const lines = value => value.split(/\r?\n/).filter(v => v !== "")
const element = (tag, text, attrs = {}) => {
  const el = document.createElement(tag)
  if (text != null) el.textContent = text
  for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value)
  return el
}
export default {
  mounted() {
    this.config = JSON.parse(this.el.dataset.config)
    this.labels = JSON.parse(this.el.dataset.labels)
    this.templates = JSON.parse(this.el.dataset.templates)
    this.single = this.el.dataset.single === "true"
    this.output = this.el.querySelector("[data-mcp-output]")
    this.body = this.el.querySelector("[data-mcp-body]")
    this.dirty = false
    this.invalidFields = new Set()
    this.renderCards()
    this.onSubmit = event => {
      if (this.invalidFields.size > 0) { event.preventDefault(); event.stopImmediatePropagation(); return }
      if (this.jsonText) {
        try { this.config = fromJson(this.jsonText.value, this.originals); this.dirty = true }
        catch (e) { event.preventDefault(); event.stopImmediatePropagation(); this.jsonError.textContent = e.message; return }
      }
      if (this.dirty) this.output.value = JSON.stringify(this.config)
    }
    this.el.closest("form").addEventListener("submit", this.onSubmit, true)
  },
  destroyed() { clearTimeout(this.validationTimer); this.el.closest("form")?.removeEventListener("submit", this.onSubmit, true) },
  changed() {
    this.dirty = true; this.output.value = JSON.stringify(this.config)
    clearTimeout(this.validationTimer)
    this.validationTimer = setTimeout(() => this.validate(), 250)
  },
  validate(done) {
    this.pushEvent("mcp_validate", {mcp: this.config}, reply => {
      this.body.querySelectorAll("[data-mcp-error]").forEach(el => el.remove())
      for (const [path, message] of reply.errors || []) {
        const name = path.split(".")[0]
        const card = [...this.body.querySelectorAll("[data-mcp-card]")].find(el => el.dataset.mcpCard === name)
        const field = card && [...card.querySelectorAll("[data-mcp-field]")].find(el => el.dataset.mcpField === path || path.startsWith(el.dataset.mcpField + "."))
        ;(field || card || this.body).append(element("p", `${path}: ${message}`, {"data-mcp-error": "", role: "alert", class: "text-caption text-danger-fg"}))
      }
      done?.((reply.errors || []).length === 0)
    })
  },
  button(label, action) {
    const button = element("button", label, {type: "button", class: "rounded-field border border-border px-2 py-1 text-label hover:bg-surface-hover"})
    button.addEventListener("click", action)
    return button
  },
  input(parent, label, value, change, type = "text", field = null) {
    const wrap = element("label", null, {class: "flex min-w-0 flex-col gap-1 text-caption text-fg-muted"})
    if (field) wrap.dataset.mcpField = field
    wrap.append(element("span", label))
    const input = element(type === "textarea" ? "textarea" : "input", null, {class: "min-w-0 w-full rounded-field border border-border-strong bg-surface p-2 text-label text-fg", autocomplete: "off"})
    if (type !== "textarea") input.type = type
    input.value = value ?? ""
    input.addEventListener("input", () => { change(input.value); this.changed() })
    wrap.append(input); parent.append(wrap)
    return input
  },
  renderCards() {
    this.jsonText = null
    this.body.replaceChildren()
    const controls = element("div", null, {class: "flex flex-wrap gap-2"})
    controls.append(this.button(this.labels.add, () => {
      if (this.single && Object.keys(this.config).length > 0) return
      let name = "server"; let n = 1
      while (this.config[name]) name = `server${n++}`
      this.config[name] = {type: "stdio", command: "", args: []}
      this.changed(); this.renderCards()
    }))
    const select = element("select", null, {class: "min-w-0 max-w-full rounded-field border border-border bg-surface p-1 text-label"})
    select.append(element("option", this.labels.template, {value: ""}))
    this.templates.forEach(t => select.append(element("option", t.description, {value: t.name})))
    select.addEventListener("change", () => {
      const template = this.templates.find(t => t.name === select.value)
      if (template && (!this.config[template.name] || window.confirm(this.labels.overwrite))) {
        if (this.single) this.config = {}
        this.config[template.name] = structuredClone(template.config); this.changed(); this.renderCards(); if (template.env_refs?.length) this.body.append(element("p", this.labels.setLocal + " " + template.env_refs.join(", "), {class: "text-caption text-fg-muted"}))
      }
    })
    controls.append(select, this.button(this.labels.json, () => this.renderJson()), this.button(this.labels.import, () => this.renderImport()))
    this.body.append(controls)
    Object.entries(this.config).forEach(([original, entry]) => {
      let name = original
      const card = element("div", null, {class: "flex min-w-0 flex-col gap-3 rounded-card border border-border bg-surface p-3", "data-mcp-card": original})
      this.input(card, this.labels.name, name, value => {
        if (value !== name && Object.keys(this.config).some(k => k !== name && k.toLowerCase() === value.toLowerCase())) {
          this.invalidFields.add(name + ".name")
          if (!card.querySelector("[data-name-error]")) card.append(element("p", this.labels.duplicateName, {"data-name-error": "", role: "alert", class: "text-caption text-danger"}))
          return
        }
        this.invalidFields.delete(name + ".name"); card.querySelector("[data-name-error]")?.remove()
        if (value !== name) {
          const previous = name
          this.config = Object.fromEntries(Object.entries(this.config).map(([k, v]) => [k === previous ? value : k, v]))
          this.invalidFields = new Set([...this.invalidFields].map(path => path.startsWith(previous + ".") ? value + path.slice(previous.length) : path))
          name = value; card.dataset.mcpCard = name
          card.querySelectorAll("[data-mcp-field]").forEach(el => el.dataset.mcpField = name + el.dataset.mcpField.slice(previous.length))
        }
      }, "text", name + ".name")
      const types = element("select", null, {"aria-label": this.labels.type, class: "rounded-field border border-border bg-surface p-2"})
      const type = entry.type || (entry.command ? "stdio" : "http")
      for (const t of ["stdio", "http", "sse"]) types.append(element("option", t, {value: t}))
      types.value = type
      types.addEventListener("change", () => { entry.type = types.value; this.changed(); this.renderCards() })
      card.append(types)
      if (type === "stdio") {
        this.input(card, this.labels.command, entry.command, v => entry.command = v, "text", name + ".command")
        this.input(card, this.labels.args, (Array.isArray(entry.args) ? entry.args : []).join("\n"), v => entry.args = lines(v), "textarea", name + ".args")
        this.input(card, this.labels.cwd, entry.cwd, v => { if (v) entry.cwd = v; else delete entry.cwd }, "text", name + ".cwd")
        this.renderPairs(card, entry, "env", this.labels.env)
      } else {
        this.input(card, this.labels.url, entry.url, v => entry.url = v, "text", name + ".url")
        this.renderPairs(card, entry, "headers", this.labels.headers)
        if (type === "sse" && this.el.dataset.provider === "codex") card.append(element("p", this.labels.sse, {class: "text-caption text-warning"}))
      }
      const other = element("details")
      other.append(element("summary", this.labels.other))
      for (const [key, value] of Object.entries(entry).filter(([k]) => !["type", "command", "args", "cwd", "url", "env", "headers"].includes(k))) {
        const row = element("div", null, {class: "my-2 flex flex-col gap-1"})
        this.input(row, key + (isKeep(value) ? ` · ${this.labels.set}` : ""), isKeep(value) ? "" : JSON.stringify(value), v => {
          try { entry[key] = JSON.parse(v); this.invalidFields.delete(name + "." + key); row.querySelector("[data-local-error]")?.remove() }
          catch (_e) { this.invalidFields.add(name + "." + key); if (!row.querySelector("[data-local-error]")) row.append(element("p", this.labels.invalidJson, {"data-local-error": "", role: "alert", class: "text-caption text-danger"})) }
        }, isKeep(value) || !this.publicField(key, value) ? "password" : "text", name + "." + key)
        row.append(this.button(this.labels.delete, () => { delete entry[key]; this.invalidFields.delete(name + "." + key); this.changed(); this.renderCards() }))
        other.append(row)
      }
      other.append(this.button(this.labels.add, () => {
        const key = window.prompt(this.labels.key)
        if (key && !Object.hasOwn(entry, key)) { entry[key] = null; this.changed(); this.renderCards() }
      }))
      card.append(other, this.button(this.labels.delete, () => {
        delete this.config[name]
        this.invalidFields = new Set([...this.invalidFields].filter(path => !path.startsWith(name + ".")))
        this.changed(); this.renderCards()
      }))
      this.body.append(card)
    })
  },
  publicField(key, value) {
    return (["tools", "enabled_tools", "disabled_tools", "alwaysAllow", "autoApprove"].includes(key) && Array.isArray(value) && value.every(v => typeof v === "string")) ||
      (["timeout", "startup_timeout_sec", "startup_timeout_ms", "tool_timeout_sec", "disabled", "enabled", "trust", "disableToolCache"].includes(key) && ["number", "boolean"].includes(typeof value))
  },
  renderPairs(card, entry, field, label) {
    const group = element("div", null, {class: "flex flex-col gap-2"})
    group.append(element("p", label))
    for (const [original, value] of Object.entries(entry[field] && typeof entry[field] === "object" && !Array.isArray(entry[field]) ? entry[field] : {})) {
      let key = original
      const row = element("div", null, {class: "grid grid-cols-2 gap-2"})
      this.input(row, this.labels.key, key, v => { const old = entry[field][key]; delete entry[field][key]; key = v; entry[field][key] = old }, "text", card.dataset.mcpCard + "." + field + "." + key)
      const mode = element("select", null, {class: "col-span-2 rounded-field border border-border bg-surface p-1"})
      mode.append(element("option", this.labels.local, {value: "local"}), element("option", this.labels.fixed, {value: "fixed"}))
      const local = typeof value === "string" && value.includes("${env:")
      mode.value = local ? "local" : "fixed"
      row.append(mode)
      const input = this.input(row, isKeep(value) ? this.labels.set : this.labels.value, isKeep(value) ? "" : value, v => entry[field][key] = mode.value === "local" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(v) ? "${env:" + v + "}" : v, local ? "text" : "password", card.dataset.mcpCard + "." + field + "." + key)
      mode.addEventListener("change", () => { input.type = mode.value === "local" ? "text" : "password" })
      row.append(this.button(this.labels.delete, () => { delete entry[field][key]; this.changed(); this.renderCards() }))
      group.append(row)
    }
    group.append(this.button(this.labels.add, () => {
      entry[field] ||= {}; let key = "KEY"; let i = 1
      while (Object.hasOwn(entry[field], key)) key = `KEY${i++}`
      entry[field][key] = ""; this.changed(); this.renderCards()
    }))
    card.append(group)
  },
  renderJson() {
    if (this.invalidFields.size > 0) return
    this.body.replaceChildren()
    this.originals = structuredClone(this.config)
    const textarea = element("textarea", null, {rows: "16", "aria-label": "MCP JSON", class: "min-w-0 w-full rounded-field border border-border bg-surface p-2 font-mono text-label"})
    textarea.value = toJson(this.config)
    this.jsonText = textarea
    const error = element("p", "", {class: "text-caption text-danger"})
    this.jsonError = error
    textarea.addEventListener("input", () => {
      try { this.config = fromJson(textarea.value, this.originals); this.changed(); error.textContent = "" }
      catch (e) { this.output.value = textarea.value; error.textContent = e.message }
    })
    this.body.append(textarea, error, this.button(this.labels.form, () => {
      try { this.config = fromJson(textarea.value, this.originals); this.changed(); this.validate(valid => { if (valid) this.renderCards() }) }
      catch (e) { error.textContent = e.message }
    }))
  },
  renderImport() {
    if (this.invalidFields.size > 0) return
    this.jsonText = null
    this.body.replaceChildren()
    const text = element("textarea", null, {rows: "10", "aria-label": this.labels.import, class: "min-w-0 w-full rounded-field border border-border bg-surface p-2 font-mono text-label"})
    const name = element("input", null, {placeholder: this.labels.name, class: "rounded-field border border-border bg-surface p-2"})
    const preview = element("div", null, {class: "text-label"})
    this.body.append(name, text, preview, this.button(this.labels.preview, () => {
      this.pushEvent("mcp_import", {text: text.value, name: name.value || "imported"}, reply => {
        preview.replaceChildren()
        if (reply.error) { preview.textContent = reply.error; return }
        reply.entries.forEach(item => {
          const row = element("div", null, {class: "flex flex-col gap-2"})
          let importedName = item.name
          this.input(row, this.labels.name, item.name, v => importedName = v)
          row.append(element("p", `${item.type} · ${item.config.command || item.config.url || ""} · ${(item.config.args || []).join(" ")} · ${item.warnings.join(" · ")}`))
          row.append(this.button(this.labels.add, () => {
            if (!this.config[importedName] || window.confirm(this.labels.overwrite)) {
              if (this.single) this.config = {}
              this.config[importedName] = item.config; this.changed(); this.renderCards()
            }
          }))
          preview.append(row)
        })
      })
    }), this.button(this.labels.form, () => this.renderCards()))
  }
}
