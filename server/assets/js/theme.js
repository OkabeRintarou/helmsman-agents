// Applies theme, sidebar state and platform before the stylesheet (no flash,
// design D5). Loaded synchronously from the root layout's <head>; a file of
// its own because the Content Security Policy allows no inline script.
(() => {
  const html = document.documentElement;
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const themes = {light: "helmsman-light", dark: "helmsman-dark"};
  const apply = (pref) => {
    if (!["system", "light", "dark"].includes(pref)) pref = "system";
    const resolved = pref === "system" ? (dark.matches ? "dark" : "light") : pref;
    html.setAttribute("data-theme", themes[resolved]);
    html.setAttribute("data-theme-pref", pref);
    document.querySelectorAll("[data-theme-option]").forEach((el) =>
      el.setAttribute("aria-checked", String(el.dataset.themeOption === pref)));
  };
  const setTheme = (pref) => {
    pref === "system" ? localStorage.removeItem("phx:theme") : localStorage.setItem("phx:theme", pref);
    apply(pref);
  };
  apply(localStorage.getItem("phx:theme") || "system");
  if (localStorage.getItem("hm:sidebar") === "collapsed") html.setAttribute("data-sidebar", "collapsed");
  const ua = navigator.userAgentData?.platform || navigator.platform || "";
  html.setAttribute("data-platform", /mac|iphone|ipad/i.test(ua) ? "mac" : "other");

  window.addEventListener("storage", (e) => e.key === "phx:theme" && apply(e.newValue || "system"));
  window.addEventListener("phx:set-theme", (e) => setTheme(e.detail?.theme || e.target?.dataset?.phxTheme));
  dark.addEventListener("change", () => apply(html.getAttribute("data-theme-pref")));
})();
