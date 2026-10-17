pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Particles
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Panorama — every workspace in one wide view.
//
// Pull back from the screen you are on to a strip of live workspace feeds (real window captures
// over the wallpaper, borders drawn in), the selected one in the centre, its windows listed beneath it
// as rows of app icon and title. Left/Right and the wheel move along the strip — always; Up/Down walk the
// rows (Up past the first steps back out, and the list scrolls with the cursor), Home/End jump to the ends
// of the strip, digits jump to a workspace, "/" opens a search and typing then sorts (workspaces holding no
// match fall back, rows that miss fade) — a letter on its own does nothing, so a stray key cannot startle
// you; Tab and Shift+Tab step through the matches, Backspace edits the query and leaves search once it is
// empty, Enter cuts into the chosen window or workspace, Escape leaves search and then flies back to the
// workspace that is actually on screen. Pointing at a window inside the selected feed (or at its row)
// picks it too — a peek: the ring and the row follow the pointer, the keys never change meaning, and only
// a keyboard or query pick makes the rest of the workspace step back. Nothing animates while idle.
//
// Open zooms OUT: the overlay appears as a 1:1 copy of the screen (the live feed of the current
// workspace, full size, pixel-exact) and shrinks into the focus slot while the chrome fades in.
// Enter zooms IN: the chosen feed grows back to the full screen, the compositor is told to switch
// underneath, and the overlay vanishes on a frame identical to the real desktop. The zoom always
// maps the selected feed AS DRAWN (mid-pan, mid-scale) onto the screen rect, so every frame is a
// perfect scaled copy and the landing is exact even when Enter interrupts a pan. `zoom` ms (340;
// 0 = cut), `zoomEase` [x1,y1,x2,y2].
//
// The layer surface is never unmapped and never resized: Hyprland fades layer surfaces in/out on
// map/unmap and tweens a mapped surface's geometry change — either would blend or squeeze the copy.
// So the surface is always the full desktop area (the bar keeps its strip): idle, it is fully
// transparent, input-masked and on the Bottom layer (which never blocks direct scanout); open, it
// switches to the Overlay layer — a layer change alone warps.
//
// The bar goes with the desktop. Hiding the real bar would drop its exclusive zone and re-tile every
// window under the copy, so a second surface (the veil) lies over the bar's strip instead: the whole
// monitor, transparent and input-masked over the desktop area, Bottom while idle and Overlay while open
// like the overlay itself. It maps the very same blurred wallpaper and scrim onto the monitor rect
// (drift included), so the two surfaces join without a seam, and fades it in over the bar as the copy
// shrinks and out again as it grows. `bar = "shown"` in the plugin's settings keeps the bar.
//
// Motion clock: all motion is driven from the compositor's frame callbacks (QQuickWindow.frameSwapped)
// snapped to the monitor's frame period — a 240 Hz panel gets 240 distinct steps a second and every
// duration is exact. The clock advances one frame period per presented frame and resyncs to the wall
// clock only after a real stall. The reveal waits for the surface to have its final geometry, and
// everything that fades in later is pre-rendered at 0.4 % opacity so first-render work never lands
// mid-zoom. Keyboard focus is released the moment Enter is pressed and the dispatch follows a beat later
// (24 ms): Hyprland refuses to focus a window while a layer surface holds exclusive keyboard focus.
// Nothing the compositor reports is acted on while a commit is in flight — a refresh landing mid-zoom
// would rebuild the very feed being blown up and restart the captures inside it.
//
// Look. Panorama has no look of its own. Out of the box it wears the shell's own picker surface —
// the [image-picker] tokens (scrim, selected-border, unselected-border, text) over the wallpaper,
// blurred the way the lock screen blurs it and laid a shade deeper, the [menu] selected fill for the cursor
// row, corners from the theme's radius, type and spacing from the shell, app icons from the icon theme by
// way of the launcher's lookup — so it sits in any Omarchy theme like a first-party overlay. The chrome is
// the clock and the strip: the clock is a hero on the strip's axis, centred in the band above the feeds,
// and what is typed takes its place at the same size — no hints, no counts, no placeholder. A theme may dress it further with an optional [panorama] section in its shell.toml — every key
// optional, colours take a role name or a hex:
//   backdrop = "background"   backdrop-alpha = 0.65   scrim over the field (default: the image-picker scrim, a shade deeper)
//   field = "wallpaper"       field-blur = 0.8        wallpaper: the current wallpaper under the scrim, blurred 0–1 (0 = sharp)
//                             field-density = 1       stills: the theme's atlases (below), density 0–3 · off: the scrim alone
//   frame = "foreground"      frame-alpha = 0.30      feed frames and hairlines (default: image-picker unselected-border)
//   frame-style = "line"                              line: the selected feed's own border carries the focus
//                                                     brackets: corner brackets grip the selected slot
//                                                     none: no focus frame at all
//   list = "dock"                                     dock: the selected workspace's windows as rows of app icon + title under
//                                                     the strip, lifting in out of the feed · record: a typed list on hairlines
//   glass = false                                     a thick band of smoked glass around every feed (blurs the field behind it)
//   wires = false                                     hairlines: strip links, stems to the list, capture outlines, rules
//   focus = "accent"                                  focus border, chosen window, match highlights (default: image-picker selected-border)
//   text = "foreground"       muted = "muted"         primary and secondary text (default: image-picker text)
//   readout = "muted"         readouts = false        colour of system values; readouts: counts top-right, seconds and the
//                                                     screen on the clock, the frame / refresh / zoom / capture line below
//   case = "normal"           numbers = "plain"       upper | normal labels; padded | plain workspace numbers (03 / 3)
//   stills-path = "<current theme>/panorama"          where the stills atlases live
// Stills: field-4/12/24/48.png — one atlas per depth, sixteen square frames in a row (6, 16, 28 and 54 px:
// the tile plus a transparent margin), frames 0–14 the looks a tile cuts through, frame 15 a glitch.
// Hundreds of them float in depth behind the strip (QtQuick.Particles, no per-frame JS), born where
// the plugin's emission masks (mask-*.png) put them, flowing outward from the focus frame and riding
// the zoom at four parallax rates. Without atlases the field simply stays off.
//
// Settings (this plugin's entry in shell.json): zoom (ms, 340; 0 = cut), zoomEase ([x1,y1,x2,y2]),
// feed (% of the screen width, 30), pan (ms, 200), card (ms, 0: how long a receipt of what was chosen is
// held after the zoom, 0 = none), thumbnails (live | static | off),
// minimum (5), maximum (10 — the strip ends with one empty slot to walk into, inside this cap),
// icons (dock rows, 8), rows (record, 4), doubleTap (ms, 300), field (density 0–3, 1; 0 = off),
// bar (hidden | shown, hidden), bind ("SUPER + SUPER_L"; false = claim no key at all).
//
// IPC:  omarchy-shell panorama toggle | open | close | openWith "<query>" | enter | tap | state
// `tap` is for a release bind on the Super key itself: two taps within `doubleTap` ms open, a
// single tap does nothing, any tap while open closes. Panorama registers that bind itself, at
// runtime, through `hyprctl eval` (see "bind" below) — nothing in ~/.config/hypr is ever written
// or read by this plugin, and a bind already sitting on the key is left alone.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: "io.github.ilkaydnc.panorama"

  // Harness knob: when true the window is a small surface in the bottom-right
  // corner on the Bottom layer instead of a full-screen overlay. Never set by
  // the shell; only a test harness flips it.
  property bool compact: false

  // ---------------------------------------------------------------- settings
  // Third-party services keep their settings on their plugins[] entry in
  // shell.json, exactly like the lock-explorer plugin does.
  function entry() {
    var cfg = shell ? shell.shellConfig : null
    var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (Util.isPlainObject(e) && String(e.id || "") === pluginId) return e
    }
    return null
  }
  function setting(key, fallback) {
    var e = entry()
    if (!e || e[key] === undefined || e[key] === null) return fallback
    return e[key]
  }
  function clampInt(v, lo, hi, fallback) {
    var n = Number(v)
    if (!isFinite(n)) return fallback
    return Math.max(lo, Math.min(hi, Math.round(n)))
  }
  readonly property int cardMs: clampInt(setting("card", 0), 0, 400, 0)
  readonly property int panMs: clampInt(setting("pan", 200), 0, 600, 200)
  readonly property string thumbnails: String(setting("thumbnails", "live"))   // live | static | off
  readonly property int minimum: clampInt(setting("minimum", 5), 1, 10, 5)
  readonly property int maximum: clampInt(setting("maximum", 10), 1, 20, 10)
  readonly property int maxRows: clampInt(setting("rows", 4), 1, 8, 4)          // record: rows listed
  readonly property int maxIcons: clampInt(setting("icons", 8), 1, 12, 8)       // dock: rows shown
  property real fieldDensity: { var v = Number(setting("field", 1)); return isFinite(v) ? Math.max(0, Math.min(3, v)) : 1 }   // user scale for the stills field, 0 = off
  readonly property int doubleTapMs: clampInt(setting("doubleTap", 300), 100, 1000, 300)
  readonly property int zoomMs: clampInt(setting("zoom", 340), 0, 800, 340)
  readonly property real feedFrac: clampInt(setting("feed", 30), 18, 45, 30) / 100   // selected feed width, % of the screen
  readonly property var zoomEase: easeSetting(setting("zoomEase", null), [0.45, 0, 0.15, 1])
  readonly property bool barHidden: String(setting("bar", "hidden")).toLowerCase() !== "shown"   // the veil over the bar (see header)
  // Harness knob: maps the veil in compact mode too (still Bottom and input-masked) so its bands can be grabbed.
  property bool veilProbe: false
  // Harness knob: the compact surface's size, so a run can model the real monitor's geometry exactly.
  property int compactW: 960
  property int compactH: 540
  // The veil's bands: the bar dissolves as the copy shrinks and comes back as it grows, and stays up for
  // the card — which covers the desktop area only. The same states the veil's input mask covers.
  readonly property real veilAlpha: barHidden && (!compact || veilProbe) ? (open ? zoomProgress : (cardShowing ? 1 : 0)) : 0
  readonly property var panEase: [0.65, 0, 0.35, 1, 1, 1]
  readonly property int dispatchDelayMs: 24
  readonly property int revealCapMs: 160
  function easeSetting(v, fallback) {
    var ok = Array.isArray(v) && v.length === 4
    for (var i = 0; ok && i < 4; i++) ok = isFinite(Number(v[i]))
    var e = ok ? v.map(Number) : fallback
    return [e[0], e[1], e[2], e[3], 1, 1]
  }

  // -------------------------------------------------------------------- dress
  // The theme's [panorama] section in shell.toml (see header), read through the Color singleton so it
  // follows theme switches. Every key falls back to a theme role: with no section at all, Panorama is
  // the theme's colours on the theme's background and nothing else.
  QtObject {
    id: dress
    function str(k, fb) { var v = Color.pick("panorama." + k, ""); return v === "" ? fb : String(v) }
    function col(k, fb) { return Color.flatColor(Color.pick("panorama." + k, ""), fb) }
    function number(k, fb) { var v = Color.pick("panorama." + k, ""); var n = Number(v); return v !== "" && isFinite(n) ? n : fb }
    function flag(k, fb) { var v = str(k, ""); return v === "" ? fb : /^(true|yes|on|1)$/i.test(v) }
    function oneOf(k, list, fb) { var v = str(k, fb).toLowerCase(); return list.indexOf(v) >= 0 ? v : fb }
    function has(k) { return Color.pick("panorama." + k, "") !== "" }
    // Defaults borrow the shell's picker surface; any [panorama] key takes over its slot.
    readonly property color scrim: Color.imagePicker.scrim
    readonly property color backdrop: has("backdrop") ? col("backdrop", Color.background) : Qt.rgba(scrim.r, scrim.g, scrim.b, 1)
    readonly property real backdropAlpha: has("backdrop-alpha") ? Color.pickAlpha("panorama.backdrop-alpha", 1.0) : Math.min(1, scrim.a + 0.15)
    readonly property color line: has("frame") || has("frame-alpha") ? Util.alpha(col("frame", Color.foreground), Color.pickAlpha("panorama.frame-alpha", 0.30)) : Color.imagePicker.unselectedBorder
    readonly property string frameStyle: oneOf("frame-style", ["line", "brackets", "none"], "line")
    readonly property string list: oneOf("list", ["dock", "record"], "dock")
    readonly property bool dock: list === "dock"                // the window list is rows of app icon + title
    readonly property bool glass: flag("glass", false)
    readonly property bool wires: flag("wires", false)
    readonly property color focus: has("focus") ? col("focus", Color.accent) : Color.imagePicker.selectedBorder
    readonly property color text: has("text") ? col("text", Color.foreground) : Color.imagePicker.text
    readonly property color muted: col("muted", Color.muted)
    readonly property color readout: col("readout", Color.muted)
    readonly property bool readouts: flag("readouts", false)
    readonly property bool upper: oneOf("case", ["normal", "upper"], "normal") === "upper"
    readonly property bool padded: oneOf("numbers", ["plain", "padded"], "plain") === "padded"
    readonly property string field: oneOf("field", ["off", "wallpaper", "stills"], "wallpaper")
    readonly property real fieldBlur: Math.max(0, Math.min(1, number("field-blur", 0.8)))
    readonly property real fieldDensity: Math.max(0, Math.min(3, number("field-density", 1)))
    readonly property string stillsPath: str("stills-path", Color.currentThemePath + "/panorama")
  }
  readonly property var dressObj: dress          // harness hook
  function lbl(s) { return dress.upper ? String(s).toUpperCase() : String(s) }
  function num(n) { return dress.padded ? pad(n) : String(n) }
  function workspaceLabel(id) { var ws = wsMap[id]; return ws && ws.name !== String(id) ? ws.name : num(id) }
  function windowsLabel(n) { return n ? n + " " + lbl(n === 1 ? "window" : "windows") : lbl("empty") }
  // Stills atlases come from the theme (dress.stillsPath); the field runs only once the first one has loaded.
  function atlasUrl(px) { return Util.fileUrl(dress.stillsPath + "/field-" + px + ".png") }
  // Each depth samples its own atlas, so the field waits for all four: a partial export would otherwise
  // start the system and silently drop the depths whose texture never loads.
  Image { id: probe4; visible: false; asynchronous: true; cache: false; source: dress.field === "stills" ? root.atlasUrl(4) : "" }
  Image { id: probe12; visible: false; asynchronous: true; cache: false; source: dress.field === "stills" ? root.atlasUrl(12) : "" }
  Image { id: probe24; visible: false; asynchronous: true; cache: false; source: dress.field === "stills" ? root.atlasUrl(24) : "" }
  Image { id: probe48; visible: false; asynchronous: true; cache: false; source: dress.field === "stills" ? root.atlasUrl(48) : "" }
  readonly property bool atlasesReady: probe4.status === Image.Ready && probe12.status === Image.Ready
                                    && probe24.status === Image.Ready && probe48.status === Image.Ready
  readonly property bool stillsOn: fieldDensity > 0 && dress.fieldDensity > 0 && dress.field === "stills" && atlasesReady

  // ------------------------------------------------------------------- icons
  // App icons the way the launcher finds them: the desktop entry for the window class (Quickshell's
  // heuristic lookup: id, case-insensitive id, StartupWMClass), else the class itself as an icon name —
  // resolved through shell.appLibrary when the shell offers it (its index also covers icons installed
  // after the shell started). Omarchy web apps have a class the browser makes up
  // (chrome-<host>__<path>-<profile>) and a desktop entry that only knows the URL; the index joins them.
  property var webappIcons: ({})
  function webappKey(host, path) { return String(host).toLowerCase() + "__" + String(path).replace(/^\//, "").replace(/\/+$/, "").replace(/\//g, "_").toLowerCase() }
  function indexWebapps() {
    var m = ({})
    var list = DesktopEntries.applications.values || []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      var hit = /omarchy-launch-webapp\s+"?(https?:\/\/[^\s"]+)/.exec(String(e.execString || e.command || ""))
      if (!hit) continue
      var u = /^https?:\/\/([^\/?#]+)([^?#]*)/.exec(hit[1])
      if (u && e.icon) m[webappKey(u[1], u[2])] = String(e.icon)
    }
    webappIcons = m
  }
  Connections { target: DesktopEntries.applications; function onValuesChanged() { root.indexWebapps() } }
  function iconNameFor(client) {
    var cls = String(client["class"] || client.initialClass || "")
    if (!cls) return ""
    if (cls.indexOf("__") > 0) {                       // a browser-made web-app class
      var body = cls.slice(cls.indexOf("-") + 1)
      var icon = webappIcons[body.toLowerCase()] || webappIcons[body.replace(/-[^-_]*$/, "").toLowerCase()]
      if (icon) return icon
    }
    var entry = null
    try {
      entry = DesktopEntries.heuristicLookup(cls)
      if (!entry && client.initialClass && String(client.initialClass) !== cls) entry = DesktopEntries.heuristicLookup(String(client.initialClass))
    } catch (e) { entry = null }
    if (entry && entry.icon) return String(entry.icon)
    return cls
  }
  // "" when nothing fits: the dock then draws a letter tile rather than the generic executable icon.
  function iconSourceFor(client) {
    var name = iconNameFor(client)
    if (!name) return ""
    var lib = shell && shell.appLibrary ? shell.appLibrary : null
    if (lib && typeof lib.iconSource === "function") {
      var s = String(lib.iconSource(name) || "")
      return s.indexOf("application-x-executable") === -1 ? s : ""
    }
    return Quickshell.iconPath(name, true) || Quickshell.iconPath(name.toLowerCase(), true) || ""
  }

  // ------------------------------------------------------------------- state
  property bool open: false
  property bool cardShowing: false
  property bool locked: false
  property string query: ""
  // Search is somewhere you GO, not something a stray key does to you: "/" opens it, and until it is
  // open a letter is not text — it was startling to have the clock, the largest thing on screen, swapped
  // for a query by a hand brushing the keyboard. Once open, the query has the date's line under the
  // clock, and Backspace past the first character (or Escape) leaves again.
  property bool searching: false
  // Leave first, then clear: the query line latches its last text the moment `searching` goes false,
  // so clearing the other way round would blank the line a frame before its fade-out began.
  function endSearch() { searching = false; setQuery("") }
  property int sel: 1
  property int rowIdx: -1
  property bool pickByKey: false      // rowIdx came from the keys or a query (spotlight), not from the pointer (peek)
  property string pendingQuery: ""
  property bool opening: false
  property bool committing: false
  property bool cancelling: false
  property string pendingLua: ""
  property string pendingAddr: ""     // the window a commit is flying to: the copy gives it the focus ring at once
  // 1 = the overview; 0 = the reticle slot blown up to the exact screen rect.
  property real zoomProgress: 1
  // Content morphs first, UI follows: chrome rides the last 30% of the zoom, feed decorations the last 20%.
  // Both keep a 0.004 floor while open: items at opacity 0 are culled, and their first render
  // (glyph atlases, canvas textures) used to cost ~12 ms right where they fade in (zoomProgress 0.7-0.8).
  // At 0.004 they blend to no change on 8-bit output, so the 1:1 frames stay exact.
  readonly property real chromeAlpha: open ? Math.max(0.004, Math.min(1, (zoomProgress - 0.7) / 0.3)) : 0
  readonly property real decorAlpha: open ? Math.max(0.004, Math.min(1, (zoomProgress - 0.8) / 0.2)) : 0
  // ---- motion clock (see header). frameNow is the wall-clock time of the last
  // tick while anything moves; every tween is a pure function of it.
  property double frameNow: 0
  property int frameSeq: 0
  property bool ticking: false
  property double holdUntil: 0
  readonly property real frameMs: monitor && monitor.refreshRate > 1 ? 1000 / monitor.refreshRate : 1000 / 60
  property bool zoomActive: false
  property real zoomFrom: 1
  property real zoomTo: 1
  property double zoomT0: 0
  property bool landed: false          // the exact-copy frame is on its way to the screen; hide on the next tick
  // The strip's position in slots: selIndex, tweened (panMs) while the overview is showing.
  property real selPos: 0
  property bool panActive: false
  property real panFrom: 0
  property double panT0: 0
  readonly property var fadeEase: [0.23, 1, 0.32, 1, 1, 1]
  // False between "window mapped" and "the selected feed's captures have pixels":
  // the overlay stays fully transparent, so the first frame anyone sees is the 1:1 copy.
  property bool revealed: true
  property var readyMap: ({})
  property string wallpaper: ""
  property int borderSize: 2
  property color activeBorder: Color.accent      // replaced by Hyprland's general:col.* on every open
  property color inactiveBorder: Color.muted

  property var screen: null          // Quickshell screen the overlay is on
  property var monitor: null         // hyprctl monitor object for that screen
  property var monitors: []          // hyprctl monitors
  property var ids: []               // workspace ids shown, in strip order
  property var wsMap: ({})           // id -> { id, name, selector, addrs: [], exists, fullscreen, monitorName, elsewhere, windows }
  property var clientMap: ({})       // address -> hyprctl client
  property var urgentMap: ({})       // address -> bool (from the Hyprland event model)
  property var matches: []           // [{ ws, addr }] in strip order
  property string clock: ""
  property string today: ""
  property string clockShort: ""     // HH:mm
  property string dateLong: ""       // Thursday, 27 August
  property string cardTime: ""
  property string cardSub: ""
  property string status: ""

  readonly property int selIndex: Math.max(0, ids.indexOf(sel))

  // ------------------------------------------------------------------- utils
  function pad(n) { return (n < 10 ? "0" : "") + n }
  function appName(cls) {
    var c = String(cls || "").trim()
    if (!c) return "window"
    if (c.indexOf("chrome-") === 0) {
      var host = c.slice(7).split("__")[0].split(".")
      if (host.length >= 2) c = host[host.length - 2]
      else c = host[0]
    } else if (c.indexOf(".") !== -1) {
      var parts = c.split(".")
      c = parts[parts.length - 1]
    }
    if (c.indexOf("google-") === 0) c = c.slice(7)
    return c.charAt(0).toUpperCase() + c.slice(1)
  }
  function rowText(client) { return appName(client["class"]) + " — " + String(client.title || "") }
  // Contiguous hit wins; otherwise subsequence. Returns matched indices or null.
  function matchIndices(text, pat) {
    var t = String(text).toLowerCase()
    var at = t.indexOf(pat)
    if (at >= 0) { var out = []; for (var k = 0; k < pat.length; k++) out.push(at + k); return out }
    var idx = [], j = 0
    for (var i = 0; i < t.length && j < pat.length; i++) if (t[i] === pat[j]) { idx.push(i); j++ }
    return j === pat.length ? idx : null
  }
  function escapeHtml(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
  function markup(text, pat, hitColor) {
    var idx = pat ? matchIndices(text, pat) : null
    if (!idx) return escapeHtml(text)
    var out = "", k = 0
    for (var i = 0; i < text.length; i++) {
      var ch = escapeHtml(text[i])
      if (idx[k] === i) { out += "<font color=\"" + hitColor + "\">" + ch + "</font>"; k++ }
      else out += ch
    }
    return out
  }
  function css(c) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + c.a + ")" }
  function normAddr(a) { return String(a || "").toLowerCase().replace(/^0x/, "") }
  function isSpecialWorkspace(ws) { var id = Number(ws && ws.id); return id >= -99 && id <= -2 }
  function luaString(value) {
    return "\"" + String(value).replace(/[\\"\x00-\x1f\x7f]/g, function(ch) {
      if (ch === "\\" || ch === "\"") return "\\" + ch
      return "\\" + ("00" + ch.charCodeAt(0)).slice(-3)
    }) + "\""
  }
  function screenFor(name) {
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i]
    return list.length ? list[0] : null
  }
  // hyprctl reports a monitor's mode in physical pixels, while every coordinate the overlay works in —
  // the surface, the reserved bands, a client's at/size, a monitor's x/y — is logical. Divide by the scale.
  function logicalW(m) { var sc = m && m.scale > 0 ? m.scale : 1; return m && m.width > 0 ? m.width / sc : 0 }
  function logicalH(m) { var sc = m && m.scale > 0 ? m.scale : 1; return m && m.height > 0 ? m.height / sc : 0 }
  function monitorByName(name) {
    for (var i = 0; i < monitors.length; i++) if (monitors[i].name === name) return monitors[i]
    return null
  }
  function tickClock() {
    var d = new Date()
    clock = pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
    today = d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    clockShort = pad(d.getHours()) + ":" + pad(d.getMinutes())
    dateLong = Qt.formatDate(d, "dddd, d MMMM")
  }
  Timer { interval: 1000; repeat: true; running: root.open || root.cardShowing; triggeredOnStart: true; onTriggered: root.tickClock() }

  // Capture handle for a client: the Hyprland model by address first, the
  // plain Wayland toplevel list (appId + title) as a fallback.
  function handleFor(client) {
    var want = normAddr(client.address)
    var tls = Hyprland.toplevels.values
    for (var i = 0; i < tls.length; i++) {
      var t = tls[i]
      if (normAddr(t.address) === want && t.wayland) return t.wayland
    }
    var wl = ToplevelManager.toplevels.values
    for (var j = 0; j < wl.length; j++) {
      var w = wl[j]
      if (String(w.appId) === String(client["class"]) && String(w.title) === String(client.title)) return w
    }
    return null
  }

  // ---------------------------------------------------------------- snapshot
  // hyprctl is the source of truth for geometry (Quickshell's cached IPC
  // objects can lag behind a resize); the Hyprland event model supplies
  // urgency and the capture handles.
  Process {
    id: snap
    command: ["bash", "-c", "printf '%s\\n---\\n%s\\n---\\n%s\\n' \"$(hyprctl -j clients)\" \"$(hyprctl -j workspaces)\" \"$(hyprctl -j monitors)\""]
    stdout: StdioCollector { onStreamFinished: root.applySnapshot(text) }
    onExited: if (root.refreshQueued) { root.refreshQueued = false; rerun.restart() }
  }
  property bool refreshQueued: false
  Timer { id: rerun; interval: 0; onTriggered: root.refresh() }

  // The look of the desktop copy: wallpaper path and Hyprland's border settings.
  // Runs at start and alongside every open; it never gates the overlay.
  Process {
    id: look
    command: ["bash", "-c", "printf '%s\\n---\\n%s\\n---\\n%s\\n---\\n%s\\n' \"$(readlink -f \"$HOME/.local/state/omarchy/current/background\" 2>/dev/null)\" \"$(hyprctl -j getoption general:border_size)\" \"$(hyprctl -j getoption general:col.active_border)\" \"$(hyprctl -j getoption general:col.inactive_border)\""]
    stdout: StdioCollector { onStreamFinished: root.applyLook(text) }
  }
  function refreshLook() { if (!look.running) look.running = true }
  function applyLook(text) {
    var parts = String(text).split("\n---\n")
    wallpaper = String(parts[0] || "").trim()
    borderSize = optionInt(parts[1], 2)
    activeBorder = optionColor(parts[2], activeBorder)
    inactiveBorder = optionColor(parts[3], inactiveBorder)
  }
  function refresh() { if (snap.running) refreshQueued = true; else snap.running = true }

  function applySnapshot(text) {
    var parts = String(text).split("\n---\n")
    var clients = [], workspaces = [], mons = []
    try {
      clients = JSON.parse(parts[0] || "[]")
      workspaces = JSON.parse(parts[1] || "[]")
      mons = JSON.parse(parts[2] || "[]")
    } catch (e) {
      status = "hyprctl returned something that isn't JSON"
      // Don't latch a pending open on it: the next gesture would be spent clearing the flag, and a
      // later refresh would then take the opening branch with no gesture behind it.
      if (opening) { opening = false; pendingQuery = "" }
      return
    }
    monitors = mons

    // Which screen: the focused monitor when opening; keep the current one on refresh.
    if (opening || !monitor) {
      var focused = null
      for (var m = 0; m < mons.length; m++) if (mons[m].focused) focused = mons[m]
      if (!focused && mons.length) focused = mons[0]
      monitor = focused
      screen = focused ? screenFor(focused.name) : null
    } else {
      monitor = monitorByName(monitor.name) || monitor
    }

    // A special workspace on screen (the scratchpad) is stacked above the normal one, so its windows
    // belong on that workspace's feed — on top — or the copy would be missing what the screen shows.
    // They are never a slot in the strip and never a row in the list; the count stays the workspace's own.
    var known = ({})
    for (var w = 0; w < workspaces.length; w++) known[Number(workspaces[w].id)] = workspaces[w]
    var above = ({})            // special workspace id -> the normal workspace it covers
    for (var sm = 0; sm < mons.length; sm++) {
      var sid = mons[sm].specialWorkspace ? Number(mons[sm].specialWorkspace.id) : 0
      var saw = mons[sm].activeWorkspace ? Number(mons[sm].activeWorkspace.id) : 0
      if (sid !== 0 && saw !== 0 && !isSpecialWorkspace(mons[sm].activeWorkspace)) above[sid] = saw
      if (saw !== 0 && !known[saw]) known[saw] = { id: saw, name: mons[sm].activeWorkspace.name, monitor: mons[sm].name }
    }

    // Clients: mapped, not hidden, on a real workspace (or on a special one that is showing).
    var cmap = ({}), byWs = ({}), byAbove = ({})
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || c.mapped === false || c.hidden === true) continue
      if (!c.workspace) continue
      var cw = Number(c.workspace.id)
      if (!cw || cw === -1) continue        // -1 is Hyprland's "no workspace", not a named one
      if (isSpecialWorkspace(c.workspace)) {
        var onto = above[cw]
        if (!onto) continue                 // a special workspace that isn't on screen
        cmap[normAddr(c.address)] = c
        if (!byAbove[onto]) byAbove[onto] = []
        byAbove[onto].push(c)
        continue
      }
      if (!known[cw]) {
        var clientMon = monitor ? monitor.name : ""
        for (var cm = 0; cm < mons.length; cm++) if (mons[cm].id === c.monitor) clientMon = mons[cm].name
        known[cw] = { id: cw, name: c.workspace.name, monitor: clientMon }
      }
      cmap[normAddr(c.address)] = c
      if (!byWs[cw]) byWs[cw] = []
      byWs[cw].push(c)
    }
    clientMap = cmap

    // Workspace ids: contiguous 1..hi so a workspace's position never moves,
    // plus any occupied id beyond the maximum (windows are never hidden).
    // `hi` is one PAST the highest workspace in use, so the strip always ends with an empty slot —
    // somewhere to go when every workspace you have is taken. Nothing is created by arriving there:
    // the slot is drawn like any other empty workspace and Hyprland makes it real on the commit,
    // exactly as it does for one that was never opened. `maximum` still caps the strip.
    var highest = 0
    for (var wk in byWs) highest = Math.max(highest, Number(wk))
    for (var wi = 0; wi < workspaces.length; wi++) if (workspaces[wi].id > 0 && workspaces[wi].id <= maximum) highest = Math.max(highest, workspaces[wi].id)
    var hi = Math.max(minimum, Math.min(maximum, highest + 1))
    // Named workspaces (negative ids, a newer one always lower) lead the strip in creation order and take
    // their share of `minimum` and `maximum`. The numbered run shrinks to make room for them and for any
    // occupied or on-screen workspace past it, so its trailing empty slot appears only when the cap has room.
    var named = [], required = ({})
    for (var ki in known) if (Number(ki) < 0 && !isSpecialWorkspace(known[ki])) named.push(Number(ki))
    named.sort(function(a, b) { return b - a })
    if (named.length) {
      for (var rk in byWs) if (Number(rk) > 0) required[rk] = true
      for (var rm = 0; rm < mons.length; rm++) {
        var activeId = mons[rm].activeWorkspace ? Number(mons[rm].activeWorkspace.id) : 0
        if (activeId > 0) required[activeId] = true
      }
      hi = Math.max(0, Math.min(maximum - named.length, Math.max(minimum - named.length, highest + 1)))
      while (hi > 0) {
        var overflow = 0
        for (var rid in required) if (Number(rid) > hi) overflow++
        if (named.length + hi + overflow <= maximum) break
        hi--
      }
    }
    var list = []
    for (var n = 1; n <= hi; n++) list.push(n)
    var extra = []
    for (var ek in byWs) if (Number(ek) > hi) extra.push(Number(ek))
    // The workspace actually on screen gets a slot even when it is empty and past the maximum: the
    // opening copy is of that workspace, and Escape has to be able to fly back into it.
    for (var mi = 0; mi < mons.length; mi++) {
      var aw = mons[mi].activeWorkspace ? Number(mons[mi].activeWorkspace.id) : 0
      if (aw > hi && extra.indexOf(aw) === -1) extra.push(aw)
    }
    extra.sort(function(a, b) { return a - b })
    // Numbers stay in ascending order after the named feeds, even when the cap leaves no empty slot to end on.
    list = named.concat(list, extra)

    var map = ({})
    for (var li = 0; li < list.length; li++) {
      var id = list[li]
      var cl = (byWs[id] || []).slice()
      // Most recently focused first: focusHistoryID 0 is the newest.
      cl.sort(function(a, b) { return (a.focusHistoryID || 0) - (b.focusHistoryID || 0) })
      var addrs = []
      var fs = false
      for (var ci = 0; ci < cl.length; ci++) { addrs.push(normAddr(cl[ci].address)); if (cl[ci].fullscreen) fs = true }
      var ab = (byAbove[id] || []).slice()
      ab.sort(function(a, b) { return (a.focusHistoryID || 0) - (b.focusHistoryID || 0) })
      var aboveAddrs = []
      for (var ai = 0; ai < ab.length; ai++) aboveAddrs.push(normAddr(ab[ai].address))
      // Which window holds the focus on this workspace — the scratchpad above it counted in.
      var focusList = cl.concat(ab)
      focusList.sort(function(a, b) { return (a.focusHistoryID || 0) - (b.focusHistoryID || 0) })
      var wsObj = known[id]
      var monName = wsObj ? String(wsObj.monitor || "") : (monitor ? monitor.name : "")
      var name = wsObj && wsObj.name !== undefined ? String(wsObj.name) : String(id)
      map[id] = {
        id: id,
        name: name,
        selector: id < 0 ? "name:" + name : String(id),
        addrs: addrs,
        above: aboveAddrs,                                                   // drawn on top of this feed, never listed
        focusAddr: focusList.length ? normAddr(focusList[0].address) : "",
        exists: !!wsObj,
        fullscreen: fs,
        monitorName: monName,
        elsewhere: !!(monitor && monName && monName !== monitor.name),
        windows: addrs.length
      }
    }
    // Keep array identity stable when membership didn't change so the feed
    // delegates (and their captures) survive title-only refreshes.
    if (JSON.stringify(list) !== JSON.stringify(ids)) ids = list
    wsMap = map

    if (opening) {
      opening = false
      var active = monitor && monitor.activeWorkspace ? Number(monitor.activeWorkspace.id) : 1
      sel = ids.indexOf(active) !== -1 ? active : (ids.length ? ids[0] : 1)
      gatherAgain()                  // also when sel was already the workspace on screen: an open gathers
      rowIdx = -1
      searching = false
      query = ""
      locked = false
      status = ""
      Hyprland.refreshToplevels()
      readyMap = ({})
      stopZoom()
      zoomProgress = zoomMs > 0 ? 0 : 1
      revealed = false
      selPos = selIndex
      open = true
      if (pendingQuery) { setQuery(pendingQuery); pendingQuery = "" }
      revealTries = 0
      revealTimer.restart()
      maybeReveal()
    } else {
      if (ids.indexOf(sel) === -1) sel = ids.length ? ids[0] : 1
      computeMatches()
      var rows = wsMap[sel] ? wsMap[sel].addrs.length : 0
      if (rowIdx >= rows) rowIdx = rows - 1
    }
  }

  function optionInt(json, fallback) {
    try { var o = JSON.parse(json); var n = Number(o["int"]); return isFinite(n) ? n : fallback } catch (e) { return fallback }
  }
  // getoption colors come back as "gradient": "ffd4b350 0deg" (AARRGGBB) or "color": <int>.
  function optionColor(json, fallback) {
    try {
      var o = JSON.parse(json)
      var g = String(o.gradient || o.custom || "").trim().split(/\s+/)[0]
      if (/^[0-9a-fA-F]{8}$/.test(g)) return "#" + g.slice(2)
      if (/^[0-9a-fA-F]{6}$/.test(g)) return "#" + g
      if (o.color !== undefined) { var v = Number(o.color) >>> 0; return "#" + ("000000" + (v & 0xffffff).toString(16)).slice(-6) }
    } catch (e) {}
    return fallback
  }

  // Stacking for a feed: Hyprland draws floating windows above tiled ones; within a tier, older below
  // newer; a special workspace showing over this one sits above everything. This is a Repeater model, so
  // it must not change while a commit is in flight (that would restart the captures inside the copy) —
  // the committed window is raised by its own z instead.
  function paintOrder(ws) {
    var tiled = [], floating = []
    for (var i = ws.addrs.length - 1; i >= 0; i--) {   // addrs is most-recent-first
      var c = clientMap[ws.addrs[i]]
      if (c && c.floating) floating.push(ws.addrs[i]); else tiled.push(ws.addrs[i])
    }
    var out = tiled.concat(floating)
    var ab = ws.above || []
    for (var j = ab.length - 1; j >= 0; j--) out.push(ab[j])
    return out
  }

  // Urgency comes from the event model; hyprctl doesn't expose it.
  function refreshUrgent() {
    var u = ({})
    var tls = Hyprland.toplevels.values
    for (var i = 0; i < tls.length; i++) if (tls[i].urgent) u[normAddr(tls[i].address)] = true
    urgentMap = u
  }
  Connections {
    target: Hyprland
    function onRawEvent(ev) {
      var name = String(ev.name || "")
      // A reload wipes every bind in the session, ours included, and Omarchy
      // reloads Hyprland whenever the theme changes. Give the config's own
      // binds a beat to land before looking at the key again.
      if (name === "configreloaded") { root.bound = false; bindRetry.restart(); return }
      if (!root.open) return
      // Mid-commit a refresh would re-sort the workspace and rebuild the feed being blown up to full
      // screen, restarting every capture inside it: the next open takes a fresh snapshot anyway.
      if (root.committing) return
      if (name === "openwindow" || name === "closewindow" || name === "movewindow" || name === "movewindowv2"
          || name === "workspace" || name === "workspacev2" || name === "fullscreen" || name === "windowtitle"
          || name === "windowtitlev2" || name === "urgent" || name === "createworkspace" || name === "destroyworkspace"
          || name === "renameworkspace" || name === "changefloatingmode" || name === "focusedmon") {
        refreshDebounce.restart()
      }
    }
  }
  Timer { id: refreshDebounce; interval: 60; onTriggered: { root.refreshUrgent(); root.refresh() } }

  // ------------------------------------------------------------------- bind
  // Panorama claims its own key, so installing it is one command and no file
  // edit. Hyprland 0.56 parses binds through its Lua config provider, which
  // refuses `hyprctl keyword bind` outright ("keyword can't work with
  // non-legacy parsers. Use eval."), so the bind goes in through `hyprctl eval`
  // and the very same hl.bind call Omarchy's own o.bind helper makes
  // (default/hypr/helpers.lua). It is session state, not config: nothing is
  // written to disk, a config reload drops it, and the reload event puts it
  // back. `hyprctl binds` reports it under the dispatcher `__lua`, which is
  // where it shows up in `omarchy menu keybindings`.
  //
  // A bind already on the key wins. Anyone who added the line to bindings.lua
  // by hand would otherwise get two dispatchers on one tap, and the double-tap
  // detector would count every tap twice and open on a single one.
  //
  // A bare modifier can only fire on release, and a release of Super is the
  // double-tap gesture, so that key gets `tap`. Any other key is an ordinary
  // press, and presses `toggle`.
  readonly property string bindSpec: {
    var v = setting("bind", "SUPER + SUPER_L")
    if (v === false || v === 0) return ""
    if (v === true) return "SUPER + SUPER_L"
    var t = String(v).trim()
    return (t === "" || t.toLowerCase() === "false" || t.toLowerCase() === "off" || t.toLowerCase() === "none") ? "" : t
  }
  // Key names and pluses, nothing else: what comes out of shell.json reaches a
  // Lua interpreter, and it may only ever arrive there as a bind spec.
  readonly property bool bindSane: /^[A-Za-z0-9_]+([ \t]*\+[ \t]*[A-Za-z0-9_]+)*$/.test(bindSpec)
  readonly property var bindParts: bindSane ? bindSpec.split("+").map(function (x) { return x.trim().toUpperCase() }) : []
  readonly property string bindKey: bindParts.length ? bindParts[bindParts.length - 1] : ""
  readonly property bool bindRelease: ["SUPER_L", "SUPER_R", "ALT_L", "ALT_R", "CTRL_L", "CTRL_R",
    "CONTROL_L", "CONTROL_R", "SHIFT_L", "SHIFT_R"].indexOf(bindKey) !== -1
  // Hyprland's own modifier bits, as reported by `hyprctl -j binds`.
  readonly property int bindMask: {
    var bits = { "SHIFT": 1, "CAPS": 2, "CTRL": 4, "CONTROL": 4, "ALT": 8, "MOD2": 16, "MOD3": 32,
                 "SUPER": 64, "MOD4": 64, "MOD5": 128 }
    var m = 0
    for (var i = 0; i < bindParts.length - 1; i++) m |= (bits[bindParts[i]] || 0)
    return m
  }
  readonly property string bindLua: 'hl.bind("' + bindSpec + '", hl.dsp.exec_cmd("omarchy-shell panorama '
    + (bindRelease ? 'tap' : 'toggle') + '"), { description = "Panorama"'
    + (bindRelease ? ', release = true' : '') + ' })'
  property bool bound: false
  property string boundSpec: ""

  function claimBind() {
    if (compact || bound || bindSpec === "") return
    if (!bindSane) { console.warn("panorama: ignoring bind setting", JSON.stringify(bindSpec)); return }
    if (bindProbe.running || bindApply.running) { bindRetry.restart(); return }
    bindProbe.running = true
  }
  // Dropping the key is fire-and-forget: on destruction the Process objects go
  // with the component, so the unbind has to outlive it.
  function dropBind(spec) {
    if (!spec) return
    bound = false
    boundSpec = ""
    Quickshell.execDetached(["hyprctl", "eval", 'hl.unbind("' + spec + '")'])
  }
  Process {
    id: bindProbe
    command: ["hyprctl", "-j", "binds"]
    stdout: StdioCollector { onStreamFinished: root.applyBinds(text) }
  }
  Process { id: bindApply; onExited: function (code) { root.bindApplied(code) } }
  Timer { id: bindRetry; interval: 250; onTriggered: root.claimBind() }
  // Two more looks at the key, then done. A plugin version swap builds the new
  // instance and tears the old one down in whichever order it likes, so the
  // outgoing unbind can land after the incoming bind, or the incoming instance
  // can see the outgoing one's bind, stand down, and then watch it vanish.
  // Either way the key ends up empty, and a late look puts it back.
  property int bindLooks: 0
  Timer {
    id: bindWatch
    interval: 2500
    repeat: true
    onTriggered: {
      root.bindLooks++
      if (root.bindLooks >= 2) running = false
      if (!bindProbe.running && !bindApply.running) bindProbe.running = true
    }
  }
  function watchBind() { bindLooks = 0; bindWatch.restart() }

  function applyBinds(text) {
    if (compact || bindSpec === "" || !bindSane) return
    var list = []
    try { list = JSON.parse(String(text) || "[]") } catch (e) { return }
    var found = false
    for (var i = 0; i < list.length && !found; i++) {
      var b = list[i]
      found = String(b.submap || "") === "" && String(b.key || "").toUpperCase() === bindKey
        && Number(b.modmask) === bindMask && (!!b.release) === bindRelease
    }
    if (bound) {                                   // a later look: ours should still be listed
      if (!found) { bound = false; bindRetry.restart() }
      return
    }
    if (found) {
      if (bindLooks === 0) {
        console.info("panorama:", bindSpec, "is already bound, leaving it alone")
        watchBind()
      }
      return
    }
    bindApply.command = ["hyprctl", "eval", bindLua]
    bindApply.running = true
  }
  function bindApplied(code) {
    if (Number(code) !== 0) { console.warn("panorama: could not bind", bindSpec); return }
    bound = true
    boundSpec = bindSpec
    console.info("panorama: bound", bindSpec, "to panorama", bindRelease ? "tap" : "toggle")
    watchBind()
  }
  onBindSpecChanged: {
    if (boundSpec !== "" && boundSpec !== bindSpec) dropBind(boundSpec)
    bindRetry.restart()
  }
  Component.onDestruction: dropBind(boundSpec)

  // ------------------------------------------------------------------ query
  function computeMatches() {
    var tight = [], loose = []
    var q = query
    if (q) {
      for (var i = 0; i < ids.length; i++) {
        var ws = wsMap[ids[i]]
        if (!ws) continue
        for (var j = 0; j < ws.addrs.length; j++) {
          var c = clientMap[ws.addrs[j]]
          if (!c) continue
          var text = rowText(c).toLowerCase()
          if (text.indexOf(q) >= 0) tight.push({ ws: ids[i], addr: ws.addrs[j] })
          else if (matchIndices(text, q)) loose.push({ ws: ids[i], addr: ws.addrs[j] })
        }
      }
    }
    matches = tight.length ? tight : loose
  }
  function isMatch(addr) {
    for (var i = 0; i < matches.length; i++) if (matches[i].addr === addr) return true
    return false
  }
  function wsHasMatch(id) {
    for (var i = 0; i < matches.length; i++) if (matches[i].ws === id) return true
    return false
  }
  function setQuery(q) {
    if (committing) return
    query = String(q).toLowerCase()
    if (query.length) searching = true          // openWith over IPC opens it as surely as "/" does
    computeMatches()
    if (query && matches.length) {
      sel = matches[0].ws
      rowIdx = wsMap[sel] ? wsMap[sel].addrs.indexOf(matches[0].addr) : -1
      pickByKey = true
    } else if (!query) {
      rowIdx = -1
      pickByKey = false
    }
  }

  // ----------------------------------------------------------- motion clock
  // cubic-bezier(x1,y1,x2,y2) at x — Newton on the x polynomial, bisection fallback.
  function bez(c, x) {
    if (x <= 0) return 0
    if (x >= 1) return 1
    var x1 = c[0], y1 = c[1], x2 = c[2], y2 = c[3]
    var cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
    var cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
    var t = x, i, xt, d
    for (i = 0; i < 10; i++) {
      xt = ((ax * t + bx) * t + cx) * t - x
      if (Math.abs(xt) < 1e-7) break
      d = (3 * ax * t + 2 * bx) * t + cx
      if (Math.abs(d) < 1e-7) break
      t -= xt / d
    }
    if (t < 0 || t > 1 || Math.abs(xt) >= 1e-7) {
      var lo = 0, hi = 1
      for (i = 0; i < 40; i++) { t = (lo + hi) / 2; xt = ((ax * t + bx) * t + cx) * t; if (xt < x) lo = t; else hi = t }
    }
    return ((ay * t + by) * t + cy) * t
  }
  function clamp01(v) { return v <= 0 ? 0 : (v >= 1 ? 1 : v) }
  function now() { return Date.now() }
  // Progress of a tween started at t0 for dur ms as seen by the latest tick, snapped to the frame grid.
  function tweenP(t0, dur) {
    if (dur <= 0) return 1
    var f = frameMs
    return clamp01(Math.round((frameNow - t0) / f) * f / dur)
  }
  function tweenValue(from, to, t0, dur, ease) {
    var p = tweenP(t0, dur)
    return p >= 1 ? to : from + (to - from) * bez(ease, p)
  }
  // A hold keeps ticks coming for dur ms so bindings on frameNow reach their targets.
  function tweenStart(dur) { var t = now(); holdUntil = Math.max(holdUntil, t + dur); kick(); return t }
  function kick() { if (ticking) return; ticking = true; frameNow = now(); frameSeq++ }
  function startZoom(to) {
    landed = false
    if (zoomMs <= 0) { zoomActive = false; zoomProgress = to; return }
    zoomFrom = zoomProgress; zoomTo = to; zoomT0 = now(); zoomActive = true
    kick()
  }
  function stopZoom() { zoomActive = false; landed = false }
  function startPan(to) {
    if (panMs <= 0 || !open || !revealed) { panActive = false; selPos = to; return }
    panFrom = selPos; panT0 = now(); panActive = true
    kick()
  }
  onSelIndexChanged: startPan(selIndex)
  onOpenChanged: if (!open) { ticking = false; zoomActive = false; panActive = false; landed = false }
  // One tick per presented frame of the overlay window (QQuickWindow.frameSwapped, wired up in the stage).
  function frameTick() {
    if (!ticking) return
    if (landed) { landed = false; ticking = false; Qt.callLater(root.afterCommit); return }
    var t = now()
    // Virtual frame clock: exactly one frame period per presented frame. Date.now() only has
    // millisecond resolution, and snapping raw timestamps onto the 4.17 ms grid made every sixth
    // frame repeat and the next one double-step (a 40 Hz beat). Resync forward only when the
    // compositor really stalled; never run ahead of the wall clock.
    var next = frameNow + frameMs
    if (t - next > frameMs * 1.5) next = t
    else if (next - t > frameMs * 1.5) next = frameNow
    frameNow = next
    frameSeq++
    if (zoomActive) {
      var p = tweenP(zoomT0, zoomMs)
      zoomProgress = p >= 1 ? zoomTo : zoomFrom + (zoomTo - zoomFrom) * bez(zoomEase, p)
      if (p >= 1) { zoomActive = false; if (committing && zoomTo === 0) landed = true }
    }
    if (panActive) {
      var q = tweenP(panT0, panMs)
      selPos = q >= 1 ? selIndex : panFrom + (selIndex - panFrom) * bez(panEase, q)
      if (q >= 1) panActive = false
    }
    if (!zoomActive && !panActive && !landed && t >= holdUntil + frameMs) ticking = false
  }
  // Feed presence by distance from the reticle as drawn (continuous, so a pan carries scale and opacity with it).
  function stepLerp(k, d) {
    if (d >= k.length - 1) return k[k.length - 1]
    var i = Math.floor(d), f = d - i
    return k[i] + (k[i + 1] - k[i]) * f
  }
  function feedScale(d) { return stepLerp([1, 0.86, 0.74, 0.62], d) }
  function feedOpacity(d) { return stepLerp([1, 0.75, 0.5, 0.35], d) }
  // A value that follows `target` through a bezier tween on the frame clock.
  component Fade: QtObject {
    property real target: 0
    property int duration: 220
    property var ease: root.fadeEase
    property real from: 0
    property real prev: 0
    property double t0: -1e12
    readonly property real value: root.tweenValue(from, target, t0, duration, ease)
    Component.onCompleted: { from = target; prev = target }
    onTargetChanged: { from = root.tweenValue(from, prev, t0, duration, ease); prev = target; t0 = root.tweenStart(duration) }
    // Back to v with no tween, so a fresh cascade starts from the beginning instead of tweening out of
    // wherever the last one left the value.
    function snap(v) { t0 = -1e12; from = v; prev = v; if (target !== v) target = v }
  }

  // ---- the dock's gather: each row comes in AS ONE — icon, title and app name together — sliding in
  // from the SIDE the strip itself came from, a short way (`gatherReach`) and one row behind the last.
  // Moving through workspaces is sideways: ←/→ pan the strip, and a step to the right brings the new
  // feed in from the right, so its rows do the same. The earlier tries are what taught the rest of the
  // shape: icons flying the full distance to their own windows streaked at up to 12,000 px/s and swept
  // across the titles above them; once that was bounded the icons still moved hundreds of pixels while
  // the text they landed beside barely stirred, which read as two unrelated events; and a vertical
  // entrance fought the sideways move that caused it. One flight time for every row and one spread for
  // the whole cascade, however many rows there are, so a long list's tail never lands hundreds of ms
  // after the zoom.
  readonly property int gatherMs: 260             // one icon's flight
  readonly property int gatherFadeMs: 180         // it becomes visible faster than it travels
  readonly property int gatherLead: 40            // quiet beat before the first one leaves
  readonly property int gatherSpread: 150         // the cascade's whole spread, at most 30 ms a row
  readonly property var gatherEase: [0.35, 0, 0.15, 1, 1, 1]   // leaves at rest, settles into its row
  property int gatherSeq: 0                       // bumped for every fresh cascade
  property bool gathering: false                  // one is in flight: a row built now joins it
  // Which side the rows come in from: +1 the right, -1 the left. Set by the direction of the step
  // through the strip (`ids` is the strip's own order), and kept for the next cascade — an open has no
  // direction of its own, so it repeats the way you last moved.
  property int gatherFrom: 1
  property int lastSel: -1
  function gatherDelay(i) {
    var rows = wsMap[sel] ? wsMap[sel].addrs.length : 0
    var n = Math.max(1, Math.min(rowsShown, rows))
    var step = n > 1 ? Math.min(30, gatherSpread / (n - 1)) : 0
    return Math.round(gatherLead + step * i)
  }
  function gatherAgain() { gatherSeq++; gathering = true; gatherHold.restart() }
  Timer { id: gatherHold; interval: root.gatherLead + root.gatherSpread + root.gatherMs + 60; onTriggered: root.gathering = false }

  // ------------------------------------------------------------- navigation
  function move(step) {
    if (committing) return
    var i = ids.indexOf(sel)
    var n = Math.max(0, Math.min(ids.length - 1, i + step))
    if (n !== i) jump(ids[n])
  }
  // Land on a workspace with nothing picked inside it (the strip, Home/End, Tab with no query).
  function jump(id) {
    if (committing || ids.indexOf(id) === -1) return
    sel = id; rowIdx = -1; pickByKey = false
  }
  // How many rows the list draws: the dress's cap, bounded by the room left under the strip (the block
  // is unclipped, so further rows would run off the surface). The window slides with the cursor, so
  // Up/Down still reach every window on the workspace and the cursor is always on a row that is drawn.
  readonly property int rowCap: dress.dock ? maxIcons : maxRows
  property int rowFit: 99                        // the stage measures its own space into this
  readonly property int rowsShown: Math.max(1, Math.min(rowCap, rowFit))
  property int rowFirst: 0
  function clampRowWindow() {
    var rows = wsMap[sel] ? wsMap[sel].addrs.length : 0
    var cap = rowsShown
    var first = rowFirst
    if (rows <= cap) first = 0
    else {
      if (rowIdx >= 0 && rowIdx < first) first = rowIdx
      if (rowIdx >= first + cap) first = rowIdx - cap + 1
      first = Math.max(0, Math.min(rows - cap, first))
    }
    if (first !== rowFirst) rowFirst = first
  }
  onRowIdxChanged: clampRowWindow()
  onSelChanged: {
    var to = ids.indexOf(sel), from = ids.indexOf(lastSel)
    if (to >= 0 && from >= 0 && to !== from) gatherFrom = to > from ? 1 : -1
    lastSel = sel
    rowFirst = 0; clampRowWindow(); gatherAgain()
  }
  onRowsShownChanged: clampRowWindow()
  onWsMapChanged: clampRowWindow()      // windows opening and closing under the cursor move the window too
  function moveRow(step) {
    if (committing) return
    var rows = wsMap[sel] ? wsMap[sel].addrs.length : 0
    if (!rows) { rowIdx = -1; pickByKey = false; return }
    rowIdx = Math.max(-1, Math.min(rows - 1, rowIdx + step))
    pickByKey = rowIdx >= 0
  }
  // The pointer's pick: a peek, never a mode.
  function peek(idx) { rowIdx = idx; pickByKey = false }
  // What a key contributes to the query: one printable character. ev.text also carries control
  // characters as single-character strings (Ctrl+A is \u0001, Delete is \u007f) — those are not typing.
  function printable(t) { var c = String(t || ""); return c.length === 1 && c >= " " && c !== "\u007f" }
  function nextMatch(step) {
    if (committing) return
    if (query) {
      if (!matches.length) return
      var k = -1
      for (var i = 0; i < matches.length; i++) {
        var addr = wsMap[sel] && rowIdx >= 0 ? wsMap[sel].addrs[rowIdx] : null
        if (matches[i].ws === sel && matches[i].addr === addr) { k = i; break }
      }
      if (k < 0) k = step > 0 ? matches.length - 1 : 0   // nothing under the cursor: step in from the end we came from
      k = (k + step + matches.length) % matches.length
      sel = matches[k].ws
      rowIdx = wsMap[sel].addrs.indexOf(matches[k].addr)
      pickByKey = true
    } else {
      var occ = []
      for (var j = 0; j < ids.length; j++) if (wsMap[ids[j]] && wsMap[ids[j]].windows > 0) occ.push(ids[j])
      if (!occ.length) return
      var idx = occ.indexOf(sel)
      idx = (idx + step + occ.length) % occ.length
      sel = occ[idx]
      rowIdx = -1
      pickByKey = false
    }
  }

  // ----------------------------------------------------------------- commit
  function dispatch(lua) { Hyprland.dispatch(lua) }
  function commit(wsId, addr) {
    if (cardShowing || locked || committing) return
    var ws = wsMap[wsId]
    var client = addr ? clientMap[addr] : null
    tickClock()
    cardTime = clock
    var what = client
      ? lbl(appName(client["class"])) + " · " + String(client.title || "")
      : windowsLabel(ws ? ws.windows : 0)
    cardSub = "→ " + workspaceLabel(wsId) + " · " + what + (ws && ws.monitorName ? " · " + ws.monitorName : (monitor ? " · " + monitor.name : ""))
    locked = true
    committing = true            // drops the layer's exclusive keyboard focus right now
    // Only zoom out of a frame that is already a copy: before the reveal the captures have no pixels, so
    // blowing the feed up would hold a screenful of bare plates for the whole zoom. Cut instead.
    var zoomIt = zoomMs > 0 && revealed
    revealed = zoomIt
    pendingAddr = addr ? String(addr) : ""
    if (ws && wsId !== sel) { sel = wsId; rowIdx = -1 }   // digit keys and feed clicks: the reticle pans there inside the zoom
    pendingLua = client
      ? "hl.dsp.focus({ window = " + luaString("address:" + String(client.address)) + " })"
      : "hl.dsp.focus({ workspace = " + luaString(ws ? ws.selector : String(wsId)) + " })"
    dispatchTimer.interval = dispatchDelayMs
    dispatchTimer.restart()
    if (zoomIt) startZoom(0)
    // The zoom's landing frame hides the overlay (frameTick); the timer is the fallback for a window that gets no frames.
    // A cut has nothing to wait for: the stage is still at its pre-reveal 0.4 %, so holding the surface
    // for a zoom's worth of time would only keep an invisible overlay over the desktop.
    hideTimer.interval = zoomIt ? zoomMs + 250 : dispatchDelayMs + 20
    hideTimer.restart()
  }
  Timer { id: dispatchTimer; onTriggered: { if (root.pendingLua) root.dispatch(root.pendingLua); root.pendingLua = "" } }
  Timer { id: hideTimer; onTriggered: root.afterCommit() }
  function afterCommit() {
    if (!committing) return
    hideTimer.stop()
    stopZoom()
    open = false
    committing = false
    zoomProgress = 1
    var wasCancel = cancelling
    cancelling = false
    if (cardMs > 0 && !wasCancel) {
      cardShowing = true
      cardTimer.interval = cardMs
      cardTimer.restart()
    } else {
      finish()
    }
  }

  // ---- reveal + zoom
  Timer { id: revealTimer; interval: root.revealCapMs; onTriggered: root.revealCap() }
  // Startup safety net: if the first snapshot found no monitor (IPC not up yet), try again.
  Timer { interval: 2000; repeat: true; running: !root.monitor && !root.open; onTriggered: root.refresh() }
  function selectedReady() {
    if (thumbnails === "off") return true
    var ws = wsMap[sel]
    if (!ws) return true
    for (var i = 0; i < ws.addrs.length; i++) if (!readyMap[ws.addrs[i]]) return false
    return true
  }
  function noteReady(addr) {
    if (readyMap[addr]) return
    var m = ({})
    for (var k in readyMap) m[k] = true
    m[addr] = true
    readyMap = m
    maybeReveal()
  }
  function stageReady() { return !!stageItem && stageItem.width > 1 }
  // The surface must already have its final size: on the first open after the plugin loads the
  // reserved-margin change may still be in flight, and a frame rendered at the old geometry would
  // put the copy 26 px off the real windows.
  function geometryReady() {
    if (compact) return true
    if (!monitor || !stageItem) return false
    var w = Math.round(logicalW(monitor)) - reservedLeft - reservedRight
    var h = Math.round(logicalH(monitor)) - reservedTop - reservedBottom
    return Math.round(stageItem.width) === w && Math.round(stageItem.height) === h
  }
  property int revealTries: 0
  function maybeReveal() { if (open && !revealed && stageReady() && geometryReady() && selectedReady()) reveal() }
  // Reveal cap: captures may never report; geometry gets three more waits before giving up on it.
  function revealCap() {
    if (!open || revealed) return
    if (!geometryReady() && revealTries < 3) { revealTries++; revealTimer.restart(); return }
    reveal()
  }
  function reveal() {
    revealTimer.stop()
    if (!open || revealed) return
    revealed = true
    if (zoomMs > 0 && zoomProgress < 1) startZoom(1)
    else zoomProgress = 1
  }
  function commitCurrent() {
    if (query && !matches.length) return
    var ws = wsMap[sel]
    var addr = ws && rowIdx >= 0 && rowIdx < ws.addrs.length ? ws.addrs[rowIdx] : null
    commit(sel, addr)
  }
  Timer { id: cardTimer; onTriggered: root.finish() }
  function finish() {
    stopZoom()
    ticking = false
    cardShowing = false
    open = false
    committing = false
    cancelling = false
    locked = false
    revealed = true
    zoomProgress = 1
    pendingLua = ""
    pendingAddr = ""
    searching = false
    query = ""
    rowIdx = -1
    matches = []
  }

  // ------------------------------------------------------------- open/close
  function requestOpen(q) {
    if (open) { if (q) setQuery(q); return }
    if (cardShowing) return
    pendingQuery = String(q || "")
    opening = true
    refreshUrgent()
    refreshLook()
    refresh()
  }
  function activeWorkspaceId() {
    var m = monitor ? (monitorByName(monitor.name) || monitor) : null
    return m && m.activeWorkspace ? Number(m.activeWorkspace.id) : sel
  }
  function close() {
    // A close that overtakes a pending open (the snapshot is still on its way) cancels it instead of
    // falling through and letting the overlay come up a moment later.
    if (opening && !open) { opening = false; pendingQuery = ""; return }
    if (!open || committing) return
    revealTimer.stop()
    if (zoomMs > 0 && revealed) {
      // Return the way we came: zoom into the workspace that is actually on screen.
      // The strip pans there (panMs) inside the zoom (zoomMs), so the landing is exact.
      locked = true
      committing = true
      cancelling = true
      pendingLua = ""
      searching = false; query = ""; matches = []; rowIdx = -1
      var active = activeWorkspaceId()
      if (wsMap[active]) sel = active
      startZoom(0)
      hideTimer.interval = zoomMs + 250
      hideTimer.restart()
      return
    }
    stopZoom()
    open = false
    revealed = true
    zoomProgress = 1
    searching = false
    query = ""
    rowIdx = -1
    matches = []
    locked = false
  }
  function toggle() { if (open || opening) close(); else requestOpen("") }

  // Double tap. Timed at arrival, so the IPC round-trip cost is the same for
  // both taps and cancels out. A tap while open is the way out.
  property double lastTap: 0
  function tap() {
    if (committing) return
    var now = Date.now()
    if (open || opening) { close(); opening = false; lastTap = 0; return }
    if (lastTap > 0 && now - lastTap <= doubleTapMs) { lastTap = 0; requestOpen("") }
    else lastTap = now
  }

  IpcHandler {
    target: "panorama"
    function toggle(): void { root.toggle() }
    function open(): void { root.requestOpen("") }
    function close(): void { root.close() }
    function openWith(query: string): void { root.requestOpen(String(query)) }
    function enter(): void { if (root.open) root.commitCurrent() }
    function tap(): void { root.tap() }
    function state(): string { return root.open ? "open" : (root.cardShowing ? "card" : "closed") }
  }

  // ------------------------------------------------------------------ window
  readonly property int reservedTop: monitor && Array.isArray(monitor.reserved) ? Number(monitor.reserved[1]) || 0 : 0
  readonly property int reservedBottom: monitor && Array.isArray(monitor.reserved) ? Number(monitor.reserved[3]) || 0 : 0
  readonly property int reservedLeft: monitor && Array.isArray(monitor.reserved) ? Number(monitor.reserved[0]) || 0 : 0
  readonly property int reservedRight: monitor && Array.isArray(monitor.reserved) ? Number(monitor.reserved[2]) || 0 : 0

  // One decode of the wallpaper, at the monitor's width, shared by the backdrop and every feed (the same
  // source and sourceSize are one texture); kept alive here between opens.
  readonly property int wallpaperDecodeW: monitor && monitor.width > 0 ? monitor.width : 0
  Image {
    visible: false
    source: root.wallpaper ? Util.fileUrl(root.wallpaper) : ""
    sourceSize.width: root.wallpaperDecodeW
    asynchronous: true
    cache: true
  }
  Component.onCompleted: { indexWebapps(); refreshLook(); refresh(); bindRetry.restart() }

  // Harness hooks: the loaded stage item (null while closed) and the veil's stage.
  readonly property var stageItem: content.item
  readonly property var veilItem: veilStage

  PanelWindow {
    id: win
    readonly property bool active: root.open || root.cardShowing
    visible: true                       // never unmapped, never resized (see header)
    screen: root.screen
    color: "transparent"
    WlrLayershell.namespace: "panorama"
    WlrLayershell.layer: root.compact || !win.active ? WlrLayer.Bottom : WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open && !root.committing && !root.compact ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Always the desktop area (the bar keeps its strip); idle it is transparent and input-masked.
    // Compact (harness): 960x540 at the bottom-right.
    anchors { top: !root.compact; left: !root.compact; bottom: true; right: true }
    margins {
      top: root.compact ? 0 : root.reservedTop
      bottom: root.compact ? 0 : root.reservedBottom
      left: root.compact ? 0 : root.reservedLeft
      right: root.compact ? 0 : root.reservedRight
    }
    implicitWidth: root.compact ? root.compactW : 1
    implicitHeight: root.compact ? root.compactH : 1
    mask: root.compact || !win.active ? emptyRegion : null

    Region { id: emptyRegion }

    Loader {
      id: content
      anchors.fill: parent
      focus: true
      active: win.active
      sourceComponent: stageComponent
    }
  }

  // The veil over the bar (see header): the whole monitor, ignoring exclusive zones; over the desktop
  // area it paints nothing and takes no input, so the overlay beneath gets the pointer. Same rules as the
  // overlay: always mapped, never resized, Bottom while idle, Overlay while open; never the keyboard.
  PanelWindow {
    id: veil
    visible: !root.compact || root.veilProbe   // the harness has no bar to cover (probe: the compact rect)
    screen: root.screen
    color: "transparent"
    WlrLayershell.namespace: "panorama-veil"
    WlrLayershell.layer: root.compact || !win.active ? WlrLayer.Bottom : WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors { top: !root.compact; left: !root.compact; bottom: true; right: true }
    implicitWidth: root.compact ? root.compactW : 1
    implicitHeight: root.compact ? root.compactH : 1
    // Input on the bands alone while open (the bar underneath must not take the click), none idle.
    mask: !root.compact && win.active && root.barHidden ? bands : veilIdle
    Region { id: veilIdle }
    Region {
      id: bands
      Region { x: 0; y: 0; width: veil.width; height: root.reservedTop }
      Region { x: 0; y: veil.height - root.reservedBottom; width: veil.width; height: root.reservedBottom }
      Region { x: 0; y: 0; width: root.reservedLeft; height: veil.height }
      Region { x: veil.width - root.reservedRight; y: 0; width: root.reservedRight; height: veil.height }
    }

    Item {
      id: veilStage
      objectName: "panorama.veil"
      anchors.fill: parent
      visible: root.veilAlpha > 0.002
      readonly property real u: dress.fieldBlur > 0 ? 0.5 : 1

      // The picture: the overlay's backdrop, monitor-wide — the same wallpaper mapping, blur and scrim as
      // wallBack, drift included. Rendered once, offscreen (the bands sample it; hideSource keeps it off
      // the screen, and the zero-size clip makes sure of it).
      Item {
        width: 0; height: 0; clip: true
        Item {
          id: veilArt
          width: veilStage.width; height: veilStage.height
          Item {
            id: veilWall
            readonly property bool on: dress.field === "wallpaper" && root.wallpaper.length > 0
            visible: on && veilField.status === Image.Ready
            readonly property real driftMax: Math.round(veilStage.width * 0.012)
            readonly property real drift: root.ids.length > 1 ? -(root.selPos / (root.ids.length - 1) - 0.5) * 2 * driftMax : 0
            x: -driftMax + drift; y: 0; width: (veilStage.width + 2 * driftMax) * veilStage.u; height: veilStage.height * veilStage.u
            scale: 1 / veilStage.u; transformOrigin: Item.TopLeft
            Image {
              id: veilField
              anchors.fill: parent
              visible: veilStage.u === 1
              source: veilWall.on ? Util.fileUrl(root.wallpaper) : ""
              sourceSize.width: root.wallpaperDecodeW
              fillMode: Image.PreserveAspectCrop
              asynchronous: true; cache: true; smooth: true; mipmap: true
            }
            MultiEffect {
              anchors.fill: parent
              visible: veilStage.u < 1
              source: veilField
              autoPaddingEnabled: false
              blurEnabled: true
              blur: dress.fieldBlur
              blurMax: 48
            }
          }
          Rectangle { anchors.fill: parent; color: Util.alpha(dress.backdrop, dress.backdropAlpha) }
        }
      }

      // The bands: one crop of the picture per reserved side, faded with the zoom.
      Repeater {
        model: 4
        ShaderEffectSource {
          required property int index
          // Tiled, never overlapping: two bands drawing the same picture over one corner would
          // composite twice and show a denser square there for the length of the fade.
          readonly property real side: Math.max(0, veilStage.height - root.reservedTop - root.reservedBottom)
          readonly property rect r: index === 0 ? Qt.rect(0, 0, veilStage.width, root.reservedTop)
                                  : index === 1 ? Qt.rect(0, veilStage.height - root.reservedBottom, veilStage.width, root.reservedBottom)
                                  : index === 2 ? Qt.rect(0, root.reservedTop, root.reservedLeft, side)
                                  : Qt.rect(veilStage.width - root.reservedRight, root.reservedTop, root.reservedRight, side)
          objectName: "panorama.band"
          x: r.x; y: r.y; width: r.width; height: r.height
          visible: width > 0 && height > 0
          sourceItem: veilArt
          sourceRect: r
          hideSource: true
          live: true
          opacity: root.veilAlpha
        }
      }
    }
  }

  Component {
    id: stageComponent
    FocusScope {
      id: stage
      focus: true
      opacity: root.revealed ? 1 : (root.open ? 0.004 : 0)   // pre-reveal: warm every texture invisibly
      readonly property int sw: width
      readonly property int sh: height
      readonly property color fg: dress.text
      readonly property color line: dress.line
      readonly property color lineDim: Util.alpha(dress.line, dress.line.a * 0.4)
      readonly property bool lineFocus: dress.frameStyle === "line"   // the selected feed's own border is the focus frame
      readonly property int plateRadius: Math.min(Style.cornerRadius, Style.space(4))
      function track(px) { return dress.upper ? px : 0 }   // letter-spacing belongs to upper-case dresses only
      readonly property color muted: dress.muted
      readonly property color accent: dress.focus
      readonly property color system: dress.readout
      readonly property string family: Style.font.family
      // One size for the whole record block (header, count, rows, notes): user wants a single, larger caption size.
      readonly property int recordPx: Style.font.subtitle
      // The hero clock (and the query in its place): three display steps, bold, as the clock panel's hour but larger.
      readonly property int heroPx: Math.round(Style.font.display * 3)

      // Feed geometry — the strip's slot width is what the pan translates by.
      readonly property real monAspect: root.monitor && root.monitor.width > 0 ? root.monitor.height / root.monitor.width : 9 / 16   // a ratio: the scale cancels
      readonly property int feedW: Math.round(sw * root.feedFrac)
      readonly property real feedH: feedW * monAspect
      readonly property int slot: feedW + Math.round(sw * 0.025)
      readonly property int stripTop: Math.round(sh * 0.27)
      readonly property int centerX: Math.round(sw / 2)
      readonly property real stripX: centerX - feedW / 2 - root.selPos * slot
      readonly property int inset: Style.space(7)
      // No icon starts further from its row than this. A row well below the strip is 700+ px from its
      // window and would cross that in one flight time — a streak next to the drift of a row by the feed.
      // How far to the side of its place a row starts. Sideways there is nothing to sweep across — the
      // rows are stacked, not side by side — so this is the width of a word rather than a hair.
      readonly property real gatherReach: Style.space(40)
      readonly property int band: dress.glass ? inset * 2 : (dress.frameStyle === "brackets" ? inset : 0)   // glass band (or bracket clearance) around every feed

      // Zoom: one uniform scale about a fixed origin maps the reticle slot onto
      // the monitor rect (the bar's reserved strip sits above the overlay, so the
      // screen rect starts at -reserved). Same aspect, so one factor does it.
      readonly property real slotX: centerX - feedW / 2
      readonly property real slotY: stripTop
      readonly property real screenX: -monL
      readonly property real screenY: -monT
      // The monitor rect in stage coordinates (the surface is the desktop area, so it starts at -reserved;
      // compact: the surface itself). The backdrop is mapped onto it, and the veil maps the same picture
      // onto the same rect, so the two surfaces join without a seam at the bar's edge.
      readonly property int monL: root.compact ? 0 : root.reservedLeft
      readonly property int monT: root.compact ? 0 : root.reservedTop
      readonly property int monW: sw + monL + (root.compact ? 0 : root.reservedRight)
      readonly property int monH: sh + monT + (root.compact ? 0 : root.reservedBottom)
      // The selected feed AS DRAWN right now (mid-pan, mid-scale included) is what maps onto the
      // screen rect: every zoom frame is then a perfect scaled copy, and Enter/Escape may interrupt
      // a pan without the landing drifting.
      readonly property var selFeed: feeds.count > 0 && root.selIndex >= 0 && root.selIndex < feeds.count ? feeds.itemAt(root.selIndex) : null
      readonly property real fs: selFeed ? selFeed.scale : 1
      readonly property real fx: strip.x + root.selIndex * slot + (1 - fs) * feedW / 2
      readonly property real fy: stripTop + (1 - fs) * feedH / 2
      readonly property real fw: fs * feedW
      // monW is the monitor rect in stage (logical) coordinates — hyprctl's mode is physical pixels.
      readonly property real k: monW > 0 && fw > 0 ? monW / fw : 1
      readonly property real originX: Math.abs(k - 1) < 1e-6 ? 0 : (screenX - k * fx) / (1 - k)
      readonly property real originY: Math.abs(k - 1) < 1e-6 ? 0 : (screenY - k * fy) / (1 - k)
      readonly property real zoomScale: 1 + (k - 1) * (1 - root.zoomProgress)
      onWidthChanged: root.maybeReveal()

      Component.onCompleted: stage.forceActiveFocus()
      onHeightChanged: root.maybeReveal()

      // Frame clock: one tick per frame the window submits, while anything moves (see header).
      Connections {
        target: stage.Window.window
        function onFrameSwapped() { root.frameTick() }
      }
      // Keeps the scene dirty for one more frame after every tick, so the loop runs at the panel's rate.
      Rectangle { x: root.frameSeq % 2; y: 0; width: 1; height: 1; opacity: 0.002; color: Color.background }

      // Backdrop. `wallpaper` field: the current wallpaper, blurred the way the lock screen blurs it (softer),
      // composed at half resolution when blurred — the blur hides the upscale — from the shared decode. It is
      // opaque from the first frame, so the desktop never shows through while the copy shrinks off it. The
      // scrim (dress.backdrop at backdrop-alpha) lies over it; with the field off and alpha below 1 the
      // desktop itself shows through, as under the image picker. Mapped onto the monitor rect, not the
      // surface: the veil over the bar shows the rest of the same picture (see the veil below).
      Item {
        id: wallBack
        readonly property bool on: dress.field === "wallpaper" && root.wallpaper.length > 0
        readonly property bool blurred: dress.fieldBlur > 0
        readonly property real u: blurred ? 0.5 : 1
        visible: on && wallField.status === Image.Ready
        // Drift: the wallpaper slides a little with the strip's pan — the strip's whole travel maps onto
        // ±driftMax, continuous with the pan tween — so the feeds read as a layer in front of it.
        readonly property real driftMax: Math.round(stage.monW * 0.012)
        readonly property real drift: root.ids.length > 1 ? -(root.selPos / (root.ids.length - 1) - 0.5) * 2 * driftMax : 0
        x: -stage.monL - driftMax + drift; y: -stage.monT; width: (stage.monW + 2 * driftMax) * u; height: stage.monH * u
        scale: 1 / u; transformOrigin: Item.TopLeft
        Image {
          id: wallField
          anchors.fill: parent
          visible: !wallBack.blurred
          source: wallBack.on ? Util.fileUrl(root.wallpaper) : ""
          sourceSize.width: root.wallpaperDecodeW
          fillMode: Image.PreserveAspectCrop
          asynchronous: true; cache: true; smooth: true; mipmap: true
        }
        MultiEffect {
          anchors.fill: parent
          visible: wallBack.blurred
          source: wallField
          autoPaddingEnabled: false
          blurEnabled: wallBack.blurred
          blur: dress.fieldBlur
          blurMax: 48
        }
      }
      Rectangle { anchors.fill: parent; color: Util.alpha(dress.backdrop, dress.backdropAlpha) }
      // ------------------------------------------------------------ input
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(ev) {
        if (root.cardShowing || root.locked) { ev.accepted = true; return }
        var handled = true
        var mods = ev.modifiers
        switch (ev.key) {
        case Qt.Key_Left: root.move(-1); break
        case Qt.Key_Right: root.move(1); break
        case Qt.Key_Home: if (root.ids.length) root.jump(root.ids[0]); break
        case Qt.Key_End: if (root.ids.length) root.jump(root.ids[root.ids.length - 1]); break
        case Qt.Key_Down: root.moveRow(1); break
        case Qt.Key_Up: root.moveRow(-1); break
        case Qt.Key_Tab: root.nextMatch(1); break
        case Qt.Key_Backtab: root.nextMatch(-1); break
        case Qt.Key_Return:
        case Qt.Key_Enter: root.commitCurrent(); break
        case Qt.Key_Escape: if (root.searching) root.endSearch(); else root.close(); break
        // Backspace leaves search once there is nothing left to delete. With search closed it is not
        // ours at all: let it fall through rather than swallow it.
        case Qt.Key_Backspace:
          if (root.query.length) root.setQuery(root.query.slice(0, -1))
          else if (root.searching) root.endSearch()
          else handled = false
          break
        default:
          var plainMods = (mods & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
          if (plainMods && !root.searching && ev.text === "/") {
            root.searching = true                 // the one gesture that opens search; inside it, "/" is text
          } else if (!root.searching && ev.key >= Qt.Key_1 && ev.key <= Qt.Key_9 && plainMods) {
            var n = ev.key - Qt.Key_0
            if (root.ids.indexOf(n) !== -1) root.commit(n, null)
          } else if (root.searching && plainMods && root.printable(ev.text) && (ev.text !== " " || root.query.length > 0)) {
            // Space never starts a query (it is the leading blank of nothing); inside one it is a word gap.
            root.setQuery(root.query + ev.text)
          } else {
            handled = false
          }
        }
        ev.accepted = handled
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: root.close()
        property double lastWheel: 0
        onWheel: function(w) {
          var t = Date.now()
          if (t - lastWheel < 40) { w.accepted = true; return }
          lastWheel = t
          if (w.angleDelta.y !== 0) root.move(w.angleDelta.y > 0 ? -1 : 1)
          w.accepted = true
        }
      }

      // --------------------------------------------------------- overview
      Item {
        id: overview
        anchors.fill: parent
        visible: root.open

        // ------------------------------------------------------- material
        // The field. Four depth layers: specks, far, mid, near — smaller and dimmer further back; each
        // layer's painter scales with the zoom at its own parallax rate about the zoom origin, near the
        // most. Counts are the steady state; each open starts from a fresh burst so the field is full on
        // the first revealed frame. The system runs at quarter scale (u = 0.25 units per px) and is drawn
        // scaled up: emission masks and particle bookkeeping stay small, rendering resolution is unchanged.
        Item {
          id: field
          readonly property real u: 0.25
          x: 0; y: 0; width: parent.width * u; height: parent.height * u
          scale: 1 / u; transformOrigin: Item.TopLeft
          opacity: root.open ? Math.max(0.004, Math.min(1, root.zoomProgress / 0.4)) : 0
          // Density is per screen area (reference counts are for 2560 x 1414), so any monitor gets the
          // same field. Seeding is deferred one event-loop turn: ParticleSystem::setRunning() calls
          // reset() after emitting runningChanged, which would wipe bursts filed inside the handler.
          readonly property real density: root.fieldDensity * dress.fieldDensity * (width * height) / (2560 * 1414 * u * u)
          visible: root.stillsOn
          function seed() {
            if (!sys.running) return
            var es = [e0, e1, e2, e3]
            for (var k = 0; k < es.length; k++) es[k].burst(es[k].count)
          }
          ParticleSystem {
            id: sys
            running: root.open && root.stillsOn
            onRunningChanged: if (running) Qt.callLater(function() { field.seed() })
          }
          // The stage is created lazily on the first open, so the system can start with running already
          // true and never emit runningChanged: seed on creation as well.
          Component.onCompleted: if (sys.running) Qt.callLater(function() { field.seed() })
          // Pictures. One Sprite state per look with uniform random transitions (plus a 7 % glitch), so
          // every tile cuts through the looks in its own order. A single 15-frame Sprite would play them
          // in sequence from frame 0 for every tile (randomStart only randomises the elapsed time inside
          // the first frame): the whole field showed the same picture at open and flipped in a wave.
          // Each tile is born in `start` — one frame of the empty look — and cuts to a random look at once.
          readonly property var looksTo: { var m = {}; for (var i = 0; i < 15; i++) m["l" + i] = 1; m.glitch = 1.1; return m }
          readonly property var looksOnly: { var m = {}; for (var i = 0; i < 15; i++) m["l" + i] = 1; return m }
          component Look: Sprite {
            property int idx: 0; property url src; property int fs: 54
            name: "l" + idx; source: src
            frameX: idx * fs; frameCount: 1; frameWidth: fs; frameHeight: fs
            frameDuration: 2400; frameDurationVariation: 1800
            to: field.looksTo
          }
          component Start: Sprite {
            property url src; property int fs: 54
            name: "start"; source: src
            frameX: 10 * fs; frameCount: 1; frameWidth: fs; frameHeight: fs
            frameDuration: 8
            to: field.looksOnly
          }
          component Glitch: Sprite {
            property url src; property int fs: 54
            name: "glitch"; source: src
            frameX: 15 * fs; frameCount: 1; frameWidth: fs; frameHeight: fs
            frameDuration: 110; frameDurationVariation: 60
            to: field.looksOnly
          }
          // The vanishing point is the reticle's centre. Tiles flow away from it at a speed proportional
          // to their distance (a camera moving forward) and grow a little as they come. Where each depth
          // is born comes from its mask (mask-*.png, dithered emission density): the far layers crowd
          // toward the vanishing point, the near layer lives at the edges — perspective by distribution,
          // no per-particle scripting.
          // Vanishing point in field (= emitter) coordinates. TargetDirection must not use targetItem here: inside a
          // CumulativeDirection its parent is not the Emitter, and Qt warns once per emitted particle.
          readonly property real vx: (stage.slotX + stage.feedW / 2) * u
          readonly property real vy: (stage.slotY + stage.feedH / 2) * u
          component Layer: Emitter {
            property int base: 100
            property url mask
            property real px: 12          // birth size in screen px (before the layer's growth)
            property real pxVar: 6
            property real flow: 0.02      // outward speed: fraction of the distance to the vanishing point, per second
            property real grow: 1.3       // size at the end of life relative to birth
            property real fot: 1          // atlas frame size over tile size (the frame carries a transparent margin)
            readonly property int count: Math.max(1, Math.round(base * field.density))
            system: sys
            x: 0; y: 0; width: field.width; height: field.height
            shape: MaskShape { source: mask }
            emitRate: count * 1000 / lifeSpan
            size: px * fot * field.u; sizeVariation: pxVar * fot * field.u; endSize: size * grow
            velocity: CumulativeDirection {
              TargetDirection { targetX: field.vx; targetY: field.vy; proportionalMagnitude: true; magnitude: -flow }
              AngleDirection { angle: 180; angleVariation: 6; magnitude: 2 * field.u; magnitudeVariation: field.u }
            }
          }
          Layer { id: e0; group: "specks"; mask: Qt.resolvedUrl("mask-specks.png"); base: 700; lifeSpan: 8000; lifeSpanVariation: 6000; px: 4; pxVar: 1; fot: 6 / 4; flow: 0.006; grow: 1.15 }
          Layer { id: e1; group: "far"; mask: Qt.resolvedUrl("mask-far.png"); base: 1000; lifeSpan: 14000; lifeSpanVariation: 8000; px: 12; pxVar: 3; fot: 16 / 12; flow: 0.012; grow: 1.25 }
          Layer { id: e2; group: "mid"; mask: Qt.resolvedUrl("mask-mid.png"); base: 360; lifeSpan: 16000; lifeSpanVariation: 8000; px: 28; pxVar: 6; fot: 28 / 24; flow: 0.025; grow: 1.35 }
          Layer { id: e3; group: "near"; mask: Qt.resolvedUrl("mask-near.png"); base: 60; lifeSpan: 18000; lifeSpanVariation: 8000; px: 62; pxVar: 12; fot: 54 / 48; flow: 0.045; grow: 1.45 }
          // Painters. Each depth rides the zoom by its own fraction (parallax): as the camera pulls back
          // from the 1:1 frame, near tiles travel further than far ones; the close reverses it. Each depth
          // samples its own atlas, area-averaged from the 48-px master down to the size it is drawn at
          // (field-<tile px>.png; no feature thinner than a pixel, a transparent margin around the tile),
          // so sub-pixel motion glides instead of making 1-texel lines and blocks crawl — the plugin's
          // textures have no mipmaps, and the particle clock steps at the shell's 60 Hz animation timer.
          component Painter: ImageParticle {
            id: painter
            property real parallax: 0.1
            property url atlas
            property int fs: 54
            system: sys
            sprites: [
              Start { src: painter.atlas; fs: painter.fs },
              Look { idx: 0; src: painter.atlas; fs: painter.fs },
              Look { idx: 1; src: painter.atlas; fs: painter.fs },
              Look { idx: 2; src: painter.atlas; fs: painter.fs },
              Look { idx: 3; src: painter.atlas; fs: painter.fs },
              Look { idx: 4; src: painter.atlas; fs: painter.fs },
              Look { idx: 5; src: painter.atlas; fs: painter.fs },
              Look { idx: 6; src: painter.atlas; fs: painter.fs },
              Look { idx: 7; src: painter.atlas; fs: painter.fs },
              Look { idx: 8; src: painter.atlas; fs: painter.fs },
              Look { idx: 9; src: painter.atlas; fs: painter.fs },
              Look { idx: 10; src: painter.atlas; fs: painter.fs },
              Look { idx: 11; src: painter.atlas; fs: painter.fs },
              Look { idx: 12; src: painter.atlas; fs: painter.fs },
              Look { idx: 13; src: painter.atlas; fs: painter.fs },
              Look { idx: 14; src: painter.atlas; fs: painter.fs },
              Glitch { src: painter.atlas; fs: painter.fs }
            ]
            spritesInterpolate: false
            colorVariation: 0.05
            transform: Scale {
              origin.x: stage.originX * field.u; origin.y: stage.originY * field.u
              xScale: 1 + (stage.zoomScale - 1) * parallax; yScale: xScale
            }
          }
          Painter { groups: ["specks"]; atlas: root.atlasUrl(4); fs: 6; parallax: 0.05; alpha: 0.55; alphaVariation: 0.25; entryEffect: ImageParticle.None }
          Painter { groups: ["far"]; atlas: root.atlasUrl(12); fs: 16; parallax: 0.12; alpha: 0.65; alphaVariation: 0.2; entryEffect: ImageParticle.None }
          Painter { groups: ["mid"]; atlas: root.atlasUrl(24); fs: 28; parallax: 0.22; alpha: 0.75; alphaVariation: 0.15; entryEffect: ImageParticle.None }
          Painter { groups: ["near"]; atlas: root.atlasUrl(48); fs: 54; parallax: 0.38; alpha: 0.8; alphaVariation: 0.1; entryEffect: ImageParticle.Fade }
        }

        // The field, blurred once at its quarter-scale resolution; every feed's glass band shows its own
        // patch of this (ShaderEffectSource with sourceRect). Kept off-screen and hidden by its consumers.
        MultiEffect {
          id: blurredField
          source: field
          x: -2 * width; y: 0; width: field.width; height: field.height
          blurEnabled: true; blur: 0.8; blurMax: 12
          visible: root.stillsOn && dress.glass     // its only consumer: nothing samples it without the glass bands
        }

        // Time. Plain: a hero clock on the strip's axis, centred in the band above the feeds — the hour large
        // and bold as on the clock panel, the day beneath it. Readouts: the terse form top-left, seconds, ISO
        // date and the screen. The clock itself NEVER moves or leaves while the overview is up: it is the one
        // fixed thing on a screen where everything else pans, and swapping it out for a query was the whole
        // fright. Only the second line — the date, which nobody needs while filtering — gives way, and the
        // query takes exactly that line at exactly that size (queryLine, below).
        Item {
          id: clockBlock
          objectName: "panorama.clock"
          readonly property bool hero: !dress.readouts
          readonly property int gap: hero ? Style.space(6) : Style.space(4)
          x: hero ? Math.round((stage.sw - width) / 2) : Math.round(stage.sw * 0.032)
          y: hero ? Math.round(stage.sh * 0.135 - height / 2) : Math.round(stage.sh * 0.06)
          width: Math.max(timeTxt.implicitWidth, dateTxt.implicitWidth)
          height: timeTxt.implicitHeight + gap + dateTxt.implicitHeight
          opacity: root.chromeAlpha
          visible: opacity > 0.001
          Text {
            id: timeTxt
            x: clockBlock.hero ? Math.round((clockBlock.width - implicitWidth) / 2) : 0; y: 0
            text: dress.readouts ? root.clock : root.clockShort
            color: stage.fg; font.family: stage.family
            font.pixelSize: dress.readouts ? Math.round(Style.font.display * 0.95) : stage.heroPx
            font.bold: !dress.readouts
            font.letterSpacing: stage.track(1.2)
          }
          Text {
            id: dateTxt
            x: clockBlock.hero ? Math.round((clockBlock.width - implicitWidth) / 2) : 0; y: timeTxt.implicitHeight + clockBlock.gap
            text: dress.readouts ? root.today + (root.monitor ? " · " + root.monitor.name : "") : root.dateLong
            color: dress.readouts ? stage.muted : stage.fg
            opacity: (dress.readouts ? 1 : 0.7) * (1 - queryFade.value)
            font.family: stage.family; font.pixelSize: dress.readouts ? Style.font.caption : Style.font.heading; font.letterSpacing: stage.track(1.6)
          }
        }

        // Query. Nothing at all until search is open; then the caret alone, on the date's line, at the
        // date's size — which is the whole announcement search needs, since the matches themselves carry
        // the accent inside the titles and the rest of the list dims. No prompt (a dress with wires keeps
        // its ">"), no placeholder, no counts. It turns urgent when nothing matches, and keeps its last
        // text while it fades out. Nothing else on screen moves when it appears: the line it takes was
        // already there, so there is no reflow and no jump.
        Item {
          id: queryLine
          objectName: "panorama.query"
          property string shown: ""
          readonly property int px: clockBlock.hero ? Style.font.heading : Style.font.caption
          Fade { id: queryFade; target: root.searching ? 1 : 0; duration: 200 }
          opacity: root.chromeAlpha * queryFade.value
          visible: queryFade.value > 0.001
          // The date's own line, to the pixel: same y, and centred the way the date is centred.
          y: clockBlock.y + timeTxt.implicitHeight + clockBlock.gap
          x: clockBlock.hero ? Math.round((stage.sw - width) / 2) : clockBlock.x
          width: clockBlock.hero ? Math.max(Style.space(160), qrow.width + Style.space(32)) : qrow.width
          height: qtext.implicitHeight + Style.space(6)
          Row {
            id: qrow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(8)
            Text { visible: dress.wires; text: ">"; color: stage.accent; font.family: stage.family; font.pixelSize: queryLine.px }
            Text {
              id: qtext
              text: queryLine.shown
              textFormat: Text.PlainText          // what a person typed, never markup
              color: root.query.length && !root.matches.length ? Color.urgent : stage.fg
              font.family: stage.family; font.pixelSize: queryLine.px; font.letterSpacing: stage.track(1.6)
            }
            // The caret is the only thing search adds to the screen, and it stands alone until you type.
            Rectangle { width: 2; height: Math.round(queryLine.px * 1.05); color: stage.accent; anchors.verticalCenter: parent.verticalCenter }
          }
          Rectangle { visible: dress.wires; anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: root.query.length && !root.matches.length ? Color.urgent : stage.line }
        }
        // While search is OPEN the line shows exactly what is typed, the empty string included: deleting the
        // last character really empties it, and opening search again starts blank. It keeps the last text
        // only on the way OUT, so nothing blinks away before the line has finished fading. Latching it on
        // an empty query instead (1.0.16-1.0.17) left the old text on screen after Escape, which read as
        // "Escape did not clear it" and then as a dead line, since retyping the same letters changed nothing.
        Connections {
          target: root
          function onQueryChanged() { if (root.searching) queryLine.shown = root.query }
          function onSearchingChanged() { if (root.searching) queryLine.shown = root.query }
        }
        function occupied() { var n = 0; for (var i = 0; i < root.ids.length; i++) { var w = root.wsMap[root.ids[i]]; if (w && w.windows) n++ } return n }
        function urgentCount() { var n = 0; for (var a in root.urgentMap) if (root.urgentMap[a] && root.clientMap[a]) n++; return n }
        function pad4(n) { return ("0000" + (Math.max(0, n) % 10000)).slice(-4) }

        // Counts, top-right — a readout, so only when the dress asks for readouts.
        Text {
          visible: dress.readouts
          anchors.right: parent.right; anchors.rightMargin: Math.round(stage.sw * 0.032); y: Math.round(stage.sh * 0.06)
          opacity: root.chromeAlpha
          horizontalAlignment: Text.AlignRight
          textFormat: Text.StyledText
          text: "<font color=\"" + stage.fg + "\">" + overview.occupied() + "</font> " + root.lbl("occupied") + " · <font color=\"" + stage.fg + "\">" + root.ids.length + "</font> " + root.lbl("shown") + "<br>"
              + "<font color=\"" + stage.fg + "\">" + overview.urgentCount() + "</font> " + root.lbl("urgent")
          color: stage.muted; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.6); lineHeight: 1.5
        }

        // Stems: the record block hangs from the selected feed's bottom corners as drawn this frame.
        // Behind a Loader: their geometry is derived from the live zoom, so unbuilt is the only way off.
        Loader {
          anchors.fill: parent
          active: dress.wires
          sourceComponent: Item {
          anchors.fill: parent
          opacity: root.decorAlpha
          readonly property real s: stage.zoomScale
          readonly property real x0: stage.originX + (stage.fx - stage.originX) * s
          readonly property real x1: stage.originX + (stage.fx + stage.fw - stage.originX) * s
          readonly property real yb: stage.originY + (stage.fy + stage.fs * (stage.feedH + stage.band) - stage.originY) * s   // below the glass band
          readonly property real yr: record.y + (dress.dock ? 0 : recHdr.height - 1)
          Rectangle { x: Math.round(parent.x0); y: Math.round(parent.yb); width: 1; height: Math.max(0, parent.yr - y); color: stage.line }
          Rectangle { x: Math.round(parent.x1) - 1; y: Math.round(parent.yb); width: 1; height: Math.max(0, parent.yr - y); color: stage.line }
          }
        }

        // Zoom layer: the strip and the reticle scale as one about a fixed origin.
        Item {
          id: zoomLayer
          anchors.fill: parent
          transform: Scale { origin.x: stage.originX; origin.y: stage.originY; xScale: stage.zoomScale; yScale: stage.zoomScale }

          // The strip. Its x is the only thing that pans.
          Item {
            id: strip
            y: stage.stripTop
            height: stage.feedH
            width: parent.width
            x: stage.stripX

            // Links between neighbouring feeds: the strip is one chain. One device pixel at any zoom.
            Repeater {
              model: dress.wires ? Math.max(0, root.ids.length - 1) : 0
              Rectangle {
                required property int index
                readonly property real sa: root.feedScale(Math.abs(index - root.selPos))
                readonly property real sb: root.feedScale(Math.abs(index + 1 - root.selPos))
                x: index * stage.slot + stage.feedW / 2 + sa * (stage.feedW / 2 + stage.band)
                width: Math.max(0, (index + 1) * stage.slot + stage.feedW / 2 - sb * (stage.feedW / 2 + stage.band) - x)
                y: stage.feedH / 2; height: 1 / stage.zoomScale
                visible: dress.wires
                opacity: root.decorAlpha
                color: stage.lineDim
              }
            }

            Repeater {
              id: feeds
              model: root.ids
              delegate: Item {
                id: feed
                objectName: "panorama.feed"
                required property int modelData
                required property int index
                readonly property var ws: root.wsMap[modelData] || null
                readonly property int dist: Math.abs(index - root.selIndex)
                readonly property real d: Math.abs(index - root.selPos)   // as drawn, mid-pan included
                readonly property bool selected: dist === 0
                readonly property bool off: root.query.length > 0 && !root.wsHasMatch(modelData)
                readonly property bool live: root.thumbnails === "live" && dist <= 1
                readonly property bool isLive: root.monitor && root.monitor.activeWorkspace && Number(root.monitor.activeWorkspace.id) === modelData
                property bool hover: false

                x: index * stage.slot
                width: stage.feedW; height: stage.feedH
                transformOrigin: Item.Center
                Fade { id: offFade; target: feed.off ? 1 : 0; duration: 220 }
                // The window under a point of the feed (feed coordinates), topmost first; "" over bare wallpaper.
                function windowAt(px, py) {
                  if (!ws || !mini.mon || !(mini.mon.width > 0)) return ""
                  var mw = root.logicalW(mini.mon), mh = root.logicalH(mini.mon)
                  if (!(mw > 0) || !(mh > 0)) return ""
                  var order = root.paintOrder(ws), sx = mini.width / mw, sy = mini.height / mh
                  for (var i = order.length - 1; i >= 0; i--) {
                    var c = root.clientMap[order[i]]
                    if (!c) continue
                    var x = (c.at[0] - mini.mon.x) * sx, y = (c.at[1] - mini.mon.y) * sy
                    if (px >= x && px <= x + c.size[0] * sx && py >= y && py <= y + c.size[1] * sy) return order[i]
                  }
                  return ""
                }
                scale: root.feedScale(feed.d) * (1 - 0.08 * offFade.value)
                // Presence. Not a group alpha — an Item's opacity blends its children one by one, and the feed's
                // own wallpaper bled through its windows — but a wash over the picture toward the backdrop colour,
                // the image picker's way of dimming unselected slices, with frame and labels faded to match.
                // 1 on the selected feed: nothing is drawn, so the 1:1 copy stays exact.
                readonly property real presence: root.feedOpacity(feed.d) * (1 - offFade.value) + 0.3 * offFade.value

                // Frame: a thick band of smoked glass around the feed — the field behind it, blurred, under a
                // dark tint. A one-device-pixel white line hugs the picture on the band's inner edge; the outer
                // edge has no line — the glass is read by what it dims and blurs. The reticle brackets grip the
                // band's outer corners. Fades with the other decorations.
                Item {
                  id: glass
                  visible: dress.glass
                  readonly property real t: stage.band
                  x: -t; y: -t; width: feed.width + 2 * t; height: feed.height + 2 * t
                  opacity: root.decorAlpha * feed.presence
                  readonly property real ss: feed.scale * stage.zoomScale   // feed px -> device px
                  readonly property real dp: 1 / Math.max(1e-6, ss)
                  // The band's screen rect, then into the blurred field's quarter-scale coordinates.
                  readonly property real sx0: stage.originX + (strip.x + feed.x + (1 - feed.scale) * feed.width / 2 - t * feed.scale - stage.originX) * stage.zoomScale
                  readonly property real sy0: stage.originY + (stage.stripTop + (1 - feed.scale) * feed.height / 2 - t * feed.scale - stage.originY) * stage.zoomScale
                  readonly property color edge: Util.alpha(dress.line, 0.85)
                  ShaderEffectSource {
                    anchors.fill: parent
                    visible: root.stillsOn && feed.d < 2     // the same proximity bound the captures use: invisible = no grab
                    sourceItem: blurredField
                    hideSource: true
                    live: true
                    smooth: true
                    sourceRect: Qt.rect(glass.sx0 * field.u, glass.sy0 * field.u, glass.width * glass.ss * field.u, glass.height * glass.ss * field.u)
                  }
                  Rectangle { anchors.fill: parent; color: Util.alpha(dress.backdrop, 0.50) }   // smoke: dims the blurred field
                  Rectangle { anchors.fill: parent; color: Util.alpha(dress.text, 0.04) }   // a whisper of lift, so the slab still reads over the backdrop
                  // inner edge: white, one device pixel, just outside the picture
                  Rectangle { x: glass.t - glass.dp; y: glass.t - glass.dp; width: feed.width + 2 * glass.dp; height: glass.dp; color: glass.edge }
                  Rectangle { x: glass.t - glass.dp; y: glass.t + feed.height; width: feed.width + 2 * glass.dp; height: glass.dp; color: glass.edge }
                  Rectangle { x: glass.t - glass.dp; y: glass.t; width: glass.dp; height: feed.height; color: glass.edge }
                  Rectangle { x: glass.t + feed.width; y: glass.t; width: glass.dp; height: feed.height; color: glass.edge }
                }
                Rectangle {
                  anchors.fill: parent
                  z: 2                               // above the picture: the frame is drawn over the captures' edge
                  opacity: root.decorAlpha * feed.presence
                  color: "transparent"
                  // One border per feed. In `line` style the selected feed's border is the focus frame itself.
                  border.width: stage.lineFocus && feed.selected ? 2 : 1
                  border.color: stage.lineFocus && feed.selected ? (root.locked ? stage.fg : stage.accent)
                              : feed.hover ? stage.fg : (feed.selected ? stage.line : stage.lineDim)
                  // A populated feed only: an empty one trades this border for the dashed outline below.
                  visible: !(feed.ws && !feed.ws.windows)
                }
                // An empty workspace: the solid border gives way to one dashed strokeRect on a [4,4] dash.
                // Behind a Loader — a full-feed Canvas is a CPU raster into a backing store the size of the
                // slot, and apart from the trailing slot and `minimum`'s padding most feeds are not empty.
                Loader {
                  anchors.fill: parent
                  z: 2
                  active: !!feed.ws && !feed.ws.windows
                  sourceComponent: Canvas {
                    id: dashed
                    opacity: root.decorAlpha * feed.presence
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      ctx.strokeStyle = root.css(feed.hover ? stage.fg : (stage.lineFocus && feed.selected ? stage.accent : stage.lineDim))
                      ctx.lineWidth = stage.lineFocus && feed.selected ? 2 : 1
                      ctx.setLineDash([4, 4])
                      ctx.strokeRect(0.5, 0.5, width - 1, height - 1)
                    }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    Connections { target: feed; function onHoverChanged() { dashed.requestPaint() } function onSelectedChanged() { dashed.requestPaint() } }
                  }
                }

                // Miniature: every window at its real place on its monitor.
                Item {
                  id: mini
                  objectName: "panorama.mini"
                  anchors.fill: parent
                  clip: true
                  readonly property var mon: feed.ws ? root.monitorByName(feed.ws.monitorName) : null
                  Image {
                    objectName: "panorama.miniwall"
                    anchors.fill: parent
                    visible: root.wallpaper.length > 0
                    source: root.wallpaper ? Util.fileUrl(root.wallpaper) : ""
                    sourceSize.width: root.wallpaperDecodeW
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    smooth: true
                    mipmap: true
                  }
                  Repeater {
                    model: feed.ws ? root.paintOrder(feed.ws) : []   // tiled first, floating above; oldest first within each
                    delegate: Item {
                      id: winItem
                      objectName: "panorama.win"
                      required property string modelData
                      readonly property var client: root.clientMap[modelData] || null
                      readonly property var mon: mini.mon
                      // client.at/size and monitor.x/y are logical; monitor.width/height are physical.
                      readonly property real mw: root.logicalW(mon)
                      readonly property real mh: root.logicalH(mon)
                      readonly property real sx: mw > 0 ? mini.width / mw : 0
                      readonly property real sy: mh > 0 ? mini.height / mh : 0
                      x: client && mon ? (client.at[0] - mon.x) * sx : 0
                      y: client && mon ? (client.at[1] - mon.y) * sy : 0
                      width: client && mon ? Math.max(2, client.size[0] * sx) : 0
                      height: client && mon ? Math.max(2, client.size[1] * sy) : 0
                      visible: !!client
                      // Which window on this workspace holds the focus — and, the instant Enter is pressed,
                      // the one the commit is flying to, so the copy the zoom lands on is already right.
                      readonly property bool focusedHere: !!feed.ws && (root.committing && feed.selected && root.pendingAddr
                                                          ? modelData === root.pendingAddr
                                                          : (!!feed.ws.focusAddr && modelData === feed.ws.focusAddr))
                      // A floating window about to take the focus comes to the front. By z, never by
                      // re-ordering the model: that would rebuild every delegate mid-zoom.
                      z: root.committing && feed.selected && modelData === root.pendingAddr && client && client.floating ? 1 : 0
                      readonly property int rowIndex: feed.ws ? feed.ws.addrs.indexOf(modelData) : -1
                      readonly property bool chosen: feed.selected && root.rowIdx >= 0 && root.rowIdx === rowIndex
                      readonly property bool alone: !!feed.ws && feed.ws.windows <= 1   // one window: the feed border already says it all
                      readonly property bool hit: root.query.length > 0 && root.isMatch(modelData)
                      readonly property bool bordered: client && !client.fullscreen && root.borderSize > 0
                      // Hyprland draws the border outside the window box. Scaled faithfully it is
                      // borderSize x 0.3 = 0.6 px in the overview, which the rasteriser mostly skips
                      // (no pixel centre inside the band), so the active window lost its yellow.
                      // The focused window's ring is therefore never thinner than one device pixel
                      // (1 / on-screen scale); at zoomProgress 0 the on-screen scale is 1/sx, so the
                      // floor equals sx and the 1:1 copy keeps the exact borderSize. Inactive rings
                      // stay faithful (invisible until the zoom makes them wider than a pixel).
                      readonly property real ringPx: root.borderSize * winItem.sx
                      readonly property real ring: winItem.focusedHere ? Math.max(ringPx, 1 / Math.max(1e-6, stage.zoomScale * feed.scale)) : ringPx
                      // A real ring (border only), not a filled plate under the window: with the feed
                      // or the capture below full opacity QML blends every item separately, and a
                      // yellow plate under a dark interior bled through as an olive tint.
                      Rectangle {
                        visible: winItem.bordered
                        x: -winItem.ring; y: -winItem.ring
                        width: parent.width + 2 * winItem.ring; height: parent.height + 2 * winItem.ring
                        color: "transparent"
                        border.width: winItem.ring
                        border.color: winItem.focusedHere ? root.activeBorder : root.inactiveBorder
                      }
                      Rectangle { objectName: "panorama.plate"; anchors.fill: parent; color: Color.background }
                      // Hairline on top of the capture. It used to sit under a 1 px inset, which at
                      // zoomProgress 0 (x3.33) shrank the copy by 6.7 px and resampled every glyph.
                      // The focused window shows its yellow ring instead of the hairline.
                      Rectangle { anchors.fill: parent; z: 1; visible: dress.wires && !(winItem.bordered && winItem.focusedHere); opacity: root.decorAlpha; color: "transparent"; border.width: 1; border.color: stage.lineDim }
                      Loader {
                        anchors.fill: parent   // exactly the window box: at zoomProgress 0 the copy is the desktop, pixel for pixel
                        active: root.thumbnails !== "off" && winItem.client !== null
                        sourceComponent: ScreencopyView {
                          captureSource: winItem.client ? root.handleFor(winItem.client) : null
                          live: feed.live
                          paintCursor: false
                          opacity: 0.85 + 0.15 * (1 - root.zoomProgress)
                          onHasContentChanged: if (hasContent) root.noteReady(winItem.modelData)
                          Component.onCompleted: if (hasContent) root.noteReady(winItem.modelData)
                        }
                      }
                      // Spotlight: with a window chosen, the rest of its workspace steps back; the chosen one wears two
                      // device pixels of focus colour over the capture's edge, a match one. All of it dissolves with the zoom.
                      Fade { id: stepBack; target: feed.selected && root.rowIdx >= 0 && root.pickByKey && !winItem.chosen && !winItem.alone ? 1 : 0; duration: 160 }
                      Rectangle { objectName: "panorama.wash"; anchors.fill: parent; z: 2; visible: stepBack.value > 0.001; opacity: root.decorAlpha; color: Util.alpha(dress.backdrop, 0.45 * stepBack.value) }
                      Rectangle {
                        anchors.fill: parent; z: 3
                        visible: (winItem.chosen && !winItem.alone) || winItem.hit
                        opacity: root.decorAlpha
                        color: "transparent"
                        border.width: (winItem.chosen ? 2 : 1) / Math.max(1e-6, stage.zoomScale * feed.scale)
                        border.color: stage.accent
                      }
                      Text {
                        anchors.centerIn: parent
                        visible: root.thumbnails === "off" || !winItem.client
                        text: winItem.client ? root.lbl(root.appName(winItem.client["class"])) : ""
                        textFormat: Text.PlainText     // a window's own class, never markup
                        color: stage.muted; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.6)
                      }
                    }
                  }
                  // The presence wash (above): transparent on the selected feed.
                  Rectangle { anchors.fill: parent; color: Util.alpha(dress.backdrop, 1 - feed.presence) }
                }

                // Label: number, LIVE, FS, other monitor, urgent dot — on a plate so it reads over captures.
                Rectangle {
                  x: 1; y: 1
                  width: labelRow.width + Style.space(12); height: labelRow.height + Style.space(6)
                  radius: stage.plateRadius
                  color: Util.alpha(dress.backdrop, 0.82)
                  opacity: root.decorAlpha * feed.presence
                }
                Row {
                  id: labelRow
                  opacity: root.decorAlpha * feed.presence
                  x: Style.space(7); y: Style.space(4)
                  spacing: Style.space(7)
                  Text { text: root.workspaceLabel(feed.modelData); textFormat: Text.PlainText; color: feed.selected ? stage.fg : stage.muted; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.6) }
                  // The live workspace: the bar's own focused-workspace glyph in the focus colour (a word under readouts).
                  Text { visible: feed.isLive; text: dress.readouts ? root.lbl("live") : "\uDB85\uDCFB"; color: dress.readouts ? stage.muted : stage.accent; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.6); anchors.verticalCenter: parent.verticalCenter }
                  Text { visible: feed.ws && feed.ws.fullscreen; text: root.lbl("fullscreen"); color: stage.muted; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.6) }
                  Text { visible: feed.ws && feed.ws.elsewhere; text: feed.ws ? feed.ws.monitorName : ""; color: stage.muted; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.6) }
                  Rectangle {
                    visible: feed.ws && feed.ws.addrs.some(function(a) { return root.urgentMap[a] })
                    width: Style.space(4); height: width; radius: width / 2; color: Color.urgent
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: feed.hover = true
                  onExited: { feed.hover = false; if (feed.selected) root.peek(-1) }   // the peek goes with the pointer
                  // Inside the selected feed the pointer peeks at windows: ring and row follow, a click takes that window.
                  onPositionChanged: function(m) { if (feed.selected && feed.ws) { var a = feed.windowAt(m.x, m.y); root.peek(a ? feed.ws.addrs.indexOf(a) : -1) } }
                  onClicked: function(m) { m.accepted = true; root.commit(feed.modelData, feed.selected ? (feed.windowAt(m.x, m.y) || null) : null) }
                  onWheel: function(w) { w.accepted = false }
                }
              }
            }
          }

          // The reticle. Fixed while browsing; dissolves with the zoom so the 1:1 frame has none of it.
          Item {
            id: reticle
            opacity: root.zoomProgress
            x: stage.centerX - stage.feedW / 2 - stage.band
            y: stage.stripTop - stage.band
            width: stage.feedW + stage.band * 2
            height: stage.feedH + stage.band * 2
            readonly property int arm: Style.space(14)
            readonly property color c: root.locked ? stage.fg : stage.accent
            // Brackets grip the selected slot's corners (frame-style = brackets). In `line` style the feed's own border carries the focus.
            readonly property bool brackets: dress.frameStyle === "brackets"
            visible: brackets
            Rectangle { visible: reticle.brackets; x: 0; y: 0; width: reticle.arm; height: 1; color: reticle.c }
            Rectangle { visible: reticle.brackets; x: 0; y: 0; width: 1; height: reticle.arm; color: reticle.c }
            Rectangle { visible: reticle.brackets; x: parent.width - reticle.arm; y: 0; width: reticle.arm; height: 1; color: reticle.c }
            Rectangle { visible: reticle.brackets; x: parent.width - 1; y: 0; width: 1; height: reticle.arm; color: reticle.c }
            Rectangle { visible: reticle.brackets; x: 0; y: parent.height - 1; width: reticle.arm; height: 1; color: reticle.c }
            Rectangle { visible: reticle.brackets; x: 0; y: parent.height - reticle.arm; width: 1; height: reticle.arm; color: reticle.c }
            Rectangle { visible: reticle.brackets; x: parent.width - reticle.arm; y: parent.height - 1; width: reticle.arm; height: 1; color: reticle.c }
            Rectangle { visible: reticle.brackets; x: parent.width - 1; y: parent.height - reticle.arm; width: 1; height: reticle.arm; color: reticle.c }
          }

        }

        // Under the selected feed: its windows. `dock` (default): a row per window — app icon, title and
        // app name — lifting into place out of the feed when the workspace is chosen, the one under the
        // cursor wearing the menu's selected fill. `record`: a typed list, on hairlines when wired.
        Item {
          id: record
          objectName: "panorama.record"
          opacity: root.chromeAlpha
          x: stage.centerX - width / 2
          y: reticle.y + reticle.height + Style.space(dress.dock ? 22 : 18)
          width: Math.max(stage.feedW, Style.space(260))
          height: dress.dock ? dockCol.implicitHeight : recordCol.implicitHeight
          readonly property var ws: root.wsMap[root.sel] || null
          readonly property bool isLive: !!ws && !!root.monitor && !!root.monitor.activeWorkspace && Number(root.monitor.activeWorkspace.id) === root.sel
          // How many rows fit under the strip. The block is unclipped, so the surface's bottom edge is the
          // real cap: on a short screen (or at the documented setting extremes) further rows would simply
          // be cut away. What does not fit is reported by the count line, and the window scrolls.
          readonly property real rowPitch: dress.dock ? Style.space(34) + Style.space(4)
                                                      : Math.ceil(stage.recordPx * 1.45) + Style.space(3) + Style.space(2)
          readonly property real rowsTop: y + (dress.dock ? 0 : recHdr.height + recordCol.spacing)
          Binding {
            target: root; property: "rowFit"
            value: Math.max(1, Math.floor((stage.sh - record.rowsTop - Style.space(30) - record.rowPitch) / record.rowPitch))
          }
          readonly property int shown: ws ? Math.max(0, Math.min(root.rowsShown, ws.addrs.length - root.rowFirst)) : 0

          // ---- dock: rows of app icon + title, no surface of their own — the cursor row wears the menu's selected
          // fill and text. A row gathers as one piece when the workspace is chosen (see `gatherMs` above).
          Column {
            id: dockCol
            visible: dress.dock
            width: parent.width
            spacing: Style.space(4)
            // The model is the number of rows drawn, not the addresses in them: scrolling the window
            // (or a title refresh) then only re-reads each row's own address, instead of rebuilding every
            // delegate — which would re-run the whole gather on every step past the window's edge.
            Repeater {
              model: dress.dock ? record.shown : 0        // a record dress builds no icon tiles at all
              delegate: Item {
                id: tile
                objectName: "panorama.tile"
                required property int index
                readonly property int row: root.rowFirst + index
                readonly property string addr: record.ws && tile.row < record.ws.addrs.length ? record.ws.addrs[tile.row] : ""
                readonly property var client: root.clientMap[tile.addr] || null
                readonly property bool cursor: root.rowIdx === row
                readonly property bool hit: root.query.length > 0 && root.isMatch(tile.addr)
                readonly property bool dim: root.query.length > 0 ? !hit : (root.rowIdx >= 0 && root.pickByKey && !cursor)
                readonly property string icon: client ? root.iconSourceFor(client) : ""
                readonly property int iconPx: Style.space(24)
                width: dockCol.width; height: Style.space(34)
                // Where the row lands, and how far to which side it starts. One direction for every row
                // in the cascade — the side the strip came from — so the block keeps a straight edge as
                // it assembles and the whole list reads as the same move that brought it here.
                readonly property real slotX: Style.space(12)
                readonly property real slotY: (height - iconPx) / 2
                readonly property real enterX: root.gatherFrom * stage.gatherReach
                // The approach. The row's offset and the icon's scale ride `gatherEase` (leaves at rest,
                // settles in), presence a shorter ease-out, so the row is solid before it lands.
                property bool flying: false
                Fade { id: gather; target: 0; duration: root.gatherMs; ease: root.gatherEase }
                Fade { id: appear; target: 0; duration: root.gatherFadeMs }
                Timer { id: liftoff; onTriggered: { gather.target = 1; appear.target = 1 } }
                function fly() {
                  tile.flying = true
                  gather.snap(0); appear.snap(0)
                  liftoff.interval = root.gatherDelay(tile.index)
                  liftoff.restart()
                }
                Connections { target: root; function onGatherSeqChanged() { tile.fly() } }
                Component.onCompleted: if (root.gathering) tile.fly()   // built mid-cascade: join it
                Fade { id: tileDim; target: tile.dim ? 1 : 0; duration: 160 }
                Fade { id: cursorFade; target: tile.cursor ? 1 : 0; duration: 120 }
                readonly property real e: tile.flying ? gather.value : 1     // the row's approach
                readonly property real a: tile.flying ? appear.value : 1     // the row's presence
                opacity: 1 - (root.query.length ? 0.7 : 0.45) * tileDim.value
                // Cursor row: the menu's selected fill, no border. The fill is the row's SLOT, so it stays
                // where the row will be and only fades in — and the pointer's target stays with it.
                Rectangle { anchors.fill: parent; radius: Style.cornerRadius; color: Color.menu.selectedBackground; opacity: tile.a * cursorFade.value }
                // Everything the row is made of travels together, under one Translate: only the icon's own
                // scale sets it apart. A transform, never the x/y bindings — moving the title's `x` would
                // re-measure and re-elide it on every frame of the approach.
                Item {
                  id: rowBody
                  anchors.fill: parent
                  opacity: tile.a
                  transform: Translate { x: tile.enterX * (1 - tile.e) }
                  Item {
                    id: iconBox
                    x: tile.slotX
                    y: tile.slotY
                    width: tile.iconPx; height: tile.iconPx
                    scale: 0.86 + 0.14 * tile.e
                    Image {
                      id: iconImg
                      anchors.fill: parent
                      visible: status === Image.Ready
                      source: tile.icon
                      // Decode at physical pixels, as the launcher does, so PNG icons stay sharp on HiDPI.
                      sourceSize.width: width * Screen.devicePixelRatio
                      sourceSize.height: height * Screen.devicePixelRatio
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true; smooth: true
                    }
                    // No icon anywhere: a letter tile on the theme's radius.
                    Rectangle {
                      anchors.fill: parent
                      visible: iconImg.status !== Image.Ready
                      radius: Math.min(Style.cornerRadius, Style.space(6))
                      color: Util.alpha(stage.fg, 0.10)
                      border.width: 1; border.color: Util.alpha(stage.fg, 0.25)
                      Text {
                        anchors.centerIn: parent
                        text: tile.client ? root.appName(tile.client["class"]).charAt(0).toUpperCase() : ""
                        color: stage.fg; font.family: stage.family; font.pixelSize: Style.font.bodySmall; font.weight: Font.DemiBold
                      }
                    }
                  }
                  Text {
                    id: titleTxt
                    objectName: "panorama.rowtitle"
                    x: tile.slotX + tile.iconPx + Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x - appTxt.implicitWidth - Style.space(24)
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: {
                      if (!tile.client) return ""
                      var title = String(tile.client.title || "")
                      return root.query.length ? root.markup(title, root.query, String(stage.accent)) : root.escapeHtml(title)
                    }
                    // The menu's selected text on the cursor row — unless a query is up, when the match itself carries the accent.
                    color: tile.cursor && !root.query.length ? Color.menu.selectedText : stage.fg
                    font.family: stage.family; font.pixelSize: Style.font.title; font.letterSpacing: stage.track(1.2)
                  }
                  Text {
                    id: appTxt
                    anchors.right: parent.right; anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.StyledText
                    text: (tile.client ? root.escapeHtml(root.lbl(root.appName(tile.client["class"]))) : "")
                        + (root.urgentMap[tile.addr] ? " <font color=\"" + Color.urgent + "\">●</font>" : "")
                    color: stage.muted
                    font.family: stage.family; font.pixelSize: Style.font.title; font.letterSpacing: stage.track(1.2)
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.peek(tile.row)
                  onExited: root.peek(-1)
                  onClicked: function(m) { m.accepted = true; root.commit(root.sel, tile.addr) }
                }
              }
            }
            // What the window leaves out, above and below, as a count.
            Text {
              visible: !!record.ws && record.ws.windows > record.shown
              x: Style.space(12)
              text: record.ws ? "+" + (record.ws.windows - record.shown) + " " + root.lbl("more") : ""
              color: stage.muted; font.family: stage.family; font.pixelSize: Style.font.title; font.letterSpacing: stage.track(1.2)
            }
          }
          // ---- record
          Column {
            id: recordCol
            visible: !dress.dock
            width: parent.width
            spacing: Style.space(2)
            Item {
              id: recHdr
              width: parent.width; height: hdr.implicitHeight + Style.space(4)
              Text {
                id: hdr
                x: Style.space(10)
                width: parent.width - x - countTxt.implicitWidth - Style.space(12)
                elide: Text.ElideRight
                textFormat: Text.StyledText
                text: "<font color=\"" + stage.fg + "\">" + root.lbl("workspace") + " " + root.escapeHtml(root.workspaceLabel(root.sel)) + "</font>"
                    + (record.isLive ? " · " + root.lbl("live") : "")
                    + (record.ws && record.ws.elsewhere ? " · " + record.ws.monitorName : "")
                color: stage.muted; font.family: stage.family; font.pixelSize: stage.recordPx; font.letterSpacing: stage.track(1.6)
              }
              Text {
                id: countTxt
                anchors.right: parent.right
                text: record.ws ? root.windowsLabel(record.ws.windows) : ""
                color: stage.muted; font.family: stage.family; font.pixelSize: stage.recordPx; font.letterSpacing: stage.track(1.6)
              }
              Rectangle { visible: dress.wires; anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: stage.lineDim }
            }
            Text {
              visible: record.ws && !record.ws.windows
              x: Style.space(10)
              text: "⏎ " + root.lbl("switches here")
              color: stage.muted; font.family: stage.family; font.pixelSize: stage.recordPx; font.letterSpacing: stage.track(1.6)
            }
            Repeater {
              model: dress.dock || !record.ws ? 0 : record.shown   // a length, so a scroll re-reads rather than rebuilds
              delegate: Item {
                id: row
                required property int index
                readonly property int rowIndex: root.rowFirst + index
                readonly property string addr: record.ws && row.rowIndex < record.ws.addrs.length ? record.ws.addrs[row.rowIndex] : ""
                readonly property var client: root.clientMap[row.addr] || null
                readonly property bool hit: root.query.length > 0 && root.isMatch(row.addr)
                readonly property bool dim: root.query.length > 0 && !hit
                readonly property bool cursor: row.rowIndex === root.rowIdx
                width: recordCol.width; height: rowText.implicitHeight + Style.space(3)
                Fade { id: dimFade; target: row.dim ? 1 : 0; duration: 160 }
                opacity: 1 - 0.7 * dimFade.value
                // Cursor: an outline in the focus colour.
                Rectangle { anchors.fill: parent; radius: stage.plateRadius; color: "transparent"; border.width: row.cursor ? 1 : 0; border.color: stage.accent }
                // Tick: the window that has focus within this workspace (most recent).
                Rectangle { visible: row.rowIndex === 0; x: 0; y: Math.round((parent.height - height) / 2); width: 2; height: Math.round(rowText.implicitHeight * 0.7); color: stage.fg }
                Text {
                  id: rowText
                  x: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(16)
                  elide: Text.ElideRight
                  textFormat: Text.StyledText
                  text: {
                    if (!row.client) return ""
                    var app = root.appName(row.client["class"])
                    var title = String(row.client.title || "")
                    var full = app + " — " + title
                    var html = root.query.length ? root.markup(full, root.query, String(stage.accent)) : root.escapeHtml(full)
                    var cut = html.indexOf(" — ")
                    var head = cut >= 0 ? html.slice(0, cut) : html
                    var tail = cut >= 0 ? html.slice(cut) : ""
                    return "<font color=\"" + stage.fg + "\">" + head + "</font><font color=\"" + stage.muted + "\">" + tail + "</font>"
                        + (root.urgentMap[row.addr] ? " <font color=\"" + Color.urgent + "\">●</font>" : "")
                  }
                  color: stage.fg; font.family: stage.family; font.pixelSize: stage.recordPx
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.peek(row.rowIndex)
                  onExited: root.peek(-1)
                  onClicked: function(m) { m.accepted = true; root.commit(root.sel, row.addr) }
                }
              }
            }
            Text {
              visible: !!record.ws && record.ws.windows > record.shown
              x: Style.space(10)
              text: record.ws ? "+" + (record.ws.windows - record.shown) + " " + root.lbl("more") : ""
              color: stage.muted; font.family: stage.family; font.pixelSize: stage.recordPx; font.letterSpacing: stage.track(1.6)
            }
          }
        }
        // Footer. Nothing by default — the readouts line when the dress asks for it, an error when one is up.
        Item {
          x: Math.round(stage.sw * 0.032); width: stage.sw - 2 * x
          opacity: root.chromeAlpha
          visible: dress.readouts || dress.wires || root.status.length > 0
          y: Math.round(stage.sh * 0.955) - height; height: Style.font.caption + Style.space(10)
          Rectangle { visible: dress.wires; anchors.left: parent.left; anchors.right: parent.right; y: 0; height: 1; color: stage.lineDim }
          Text {
            visible: dress.readouts
            anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom
            textFormat: Text.StyledText
            // Short-circuited on the dress: otherwise frameSeq keeps this ~200-char markup rebuilding
            // and re-parsing on every presented frame for a footer nothing draws.
            text: !dress.readouts ? "" : root.lbl("frame") + " <font color=\"" + stage.system + "\">" + overview.pad4(root.frameSeq) + "</font> · <font color=\"" + stage.system + "\">"
                + (root.monitor && root.monitor.refreshRate > 0 ? Math.round(root.monitor.refreshRate) : "—") + "</font> " + root.lbl("hz") + " · " + root.lbl("zoom") + " <font color=\"" + stage.system + "\">"
                + (root.zoomMs > 0 ? root.zoomMs + "</font> " + root.lbl("ms") : root.lbl("cut") + "</font>") + " · " + root.lbl("capture") + " <font color=\"" + stage.system + "\">" + root.lbl(root.thumbnails) + "</font>"
            color: stage.muted; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.4)
          }
          Text {
            visible: root.status.length > 0
            anchors.right: parent.right; anchors.bottom: parent.bottom
            text: root.status
            color: Color.urgent; font.family: stage.family; font.pixelSize: Style.font.caption; font.letterSpacing: stage.track(1.4)
          }
        }
      }

      // ------------------------------------------------------------- card
      Rectangle {
        anchors.fill: parent
        visible: root.cardShowing
        color: dress.backdrop
        Column {
          x: Math.round(stage.sw * 0.08); anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)
          Text { text: root.cardTime; textFormat: Text.PlainText; color: stage.fg; font.family: stage.family; font.pixelSize: Math.round(Style.font.display * 1.9); font.letterSpacing: stage.track(2) }
          // A window's own title is in here: plain text, never markup.
          Text { text: root.cardSub; textFormat: Text.PlainText; color: stage.muted; font.family: stage.family; font.pixelSize: Style.font.bodySmall; font.letterSpacing: stage.track(1.8); font.capitalization: dress.upper ? Font.AllUppercase : Font.MixedCase }
        }
      }
    }
  }
}
