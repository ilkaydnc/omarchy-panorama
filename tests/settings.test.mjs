import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import vm from 'node:vm'

// Settings come off Panorama's own plugins[] entry in shell.json (#1). The QML is not run here: its
// top-level functions, its property bindings and its FileView handlers are lifted out of the source as
// written and evaluated against stubs. A binding becomes a getter, so it re-evaluates on every read the
// way QML re-evaluates it when `config` changes; a FileView becomes a small fake over a real temp file,
// so "the file changed" is a write to disk followed by the watcher's fileChanged.

const qml = readFileSync(new URL('../1.0.20/Panorama.qml', import.meta.url), 'utf8')
const methods = [...qml.matchAll(/^  function \w+\([^\n]*\{(?:[^\n]*\}[^\n]*$|[\s\S]*?^  \})/gm)].map(hit => hit[0]).join('\n')
const pluginId = 'io.github.ilkaydnc.panorama'
const plain = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value))

// A root-level property's binding, as written: the rest of its line, plus the lines it runs on to
// while a bracket is open or the next line carries on with an operator.
function binding(name) {
  const at = qml.search(new RegExp(`^  (?:readonly )?property [\\w<>]+ ${name}: `, 'm'))
  assert.ok(at >= 0, `property ${name} is declared`)
  const lines = qml.slice(at).split('\n')
  let expr = lines[0].replace(/^  (?:readonly )?property [\w<>]+ \w+: /, '')
  let depth = scan(expr)
  for (let i = 1; depth > 0 || /^\s*(\+|-|&&|\|\||\?|:|\.)/.test(lines[i]); i++) {
    expr += '\n' + lines[i]
    depth += scan(lines[i])
  }
  return expr.trimStart().startsWith('{') ? `(function () ${expr}\n)` : `(function () { return (${expr}\n) })`
}
// Bracket depth of one line, outside strings and trailing comments.
function scan(line) {
  let depth = 0, quote = ''
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = ''; continue }
    if (ch === '"' || ch === "'" || ch === '`') quote = ch
    else if (ch === '/' && line[i + 1] === '/') break
    else if ('([{'.includes(ch)) depth++
    else if (')]}'.includes(ch)) depth--
  }
  return depth
}
// A FileView's declared lines: path, flags and handler bodies.
function fileView(id) {
  const block = qml.match(new RegExp(`FileView \\{\\n    id: ${id}\\n([\\s\\S]*?)\\n  \\}`))
  assert.ok(block, `FileView ${id} exists`)
  return Object.fromEntries(block[1].split('\n').map(l => l.trim().match(/^(\w+): ([\s\S]*)$/)).filter(Boolean).map(m => [m[1], m[2]]))
}
const handler = name => qml.match(new RegExp(`^  ${name}: (\\{[\\s\\S]*?^  \\}|[^\\n]*)$`, 'm'))[1]

const settings = ['pluginId', 'userConfigPath', 'defaultsPath', 'config', 'cardMs', 'panMs', 'thumbnails', 'minimum',
  'maximum', 'maxRows', 'maxIcons', 'fieldDensity', 'doubleTapMs', 'zoomMs', 'feedFrac', 'zoomEase', 'barHidden',
  'bindSpec', 'bindSane', 'bindParts', 'bindKey', 'bindRelease', 'bindMask', 'bindLua']

// Omarchy's Util.isPlainObject, verbatim.
const Util = { isPlainObject: value => value !== null && typeof value === 'object' && !Array.isArray(value) }

// What an installed plugin's `shell` is: a PluginShellApi (shell/services/PluginShellApi.qml on quattro
// 33783b17, unchanged in substance since 4.0.4). Its members, and no shellConfig among them.
function scopedShell() {
  const noop = () => false
  return {
    pluginId, appLibrary: null, bar: null, barConfig: { position: 'top' }, idleConfig: {},
    serviceFor: noop, firstPartyServiceFor: noop, pluginShellForBarEntry: noop, summon: noop, hide: noop,
    toggle: noop, isPluginOpen: noop, updateEntryInline: noop, mutateShellConfig: noop
  }
}

function rig({ shell = scopedShell(), user, defaults } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'panorama-home-'))
  const omarchy = mkdtempSync(join(tmpdir(), 'panorama-omarchy-'))
  const userPath = join(home, '.config/omarchy/shell.json')
  const defaultsPath = join(omarchy, 'config/omarchy/shell.json')
  const write = (path, value) => {
    mkdirSync(join(path, '..'), { recursive: true })
    writeFileSync(path, typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n')
  }
  if (user !== undefined) write(userPath, user)
  if (defaults !== undefined) write(defaultsPath, defaults)

  const log = { info: [], warn: [], detached: [] }
  const proc = () => ({ running: false, command: [] })
  const env = { HOME: home.replace(/\\/g, '/'), OMARCHY_PATH: omarchy.replace(/\\/g, '/') }
  const state = {
    shell, manifest: null, compact: false, bound: false, boundSpec: '', bindLooks: 0, Util,
    Quickshell: { env: k => env[k], execDetached: argv => log.detached.push(argv) },
    console: { info: (...a) => log.info.push(a.join(' ')), warn: (...a) => log.warn.push(a.join(' ')), log() {} },
    bindProbe: proc(), bindListing: proc(), bindApply: proc(),
    bindRetry: { restarts: 0, restart() { this.restarts++ } }, bindWatch: { restart() {} }
  }
  const ctx = vm.createContext(state)
  vm.runInContext(methods, ctx)
  ctx.root = ctx
  for (const name of settings) {
    const get = vm.runInContext(binding(name), ctx)
    Object.defineProperty(ctx, name, { get: () => get.call(ctx), configurable: true })
  }
  // Paths on disk: the env holds forward slashes for the QML; node reads either.
  const disk = p => p.replace(/^\/([A-Za-z]:)/, '$1')

  // Two FileViews as the QML declares them, over the real files.
  const views = {}
  for (const id of ['userConfigFile', 'defaultsFile']) {
    const spec = fileView(id)
    const run = body => vm.runInContext(`(function (fv) { with (fv) { ${body} } })`, ctx)
    const fv = {
      spec, contents: null,
      get path() { return vm.runInContext(spec.path, ctx) },
      text() { if (this.contents === null && spec.blockLoading === 'true') this.load(false); return this.contents || '' },
      load(notify = true) {
        const file = disk(this.path)
        const ok = existsSync(file)
        this.contents = ok ? readFileSync(file, 'utf8') : ''
        if (notify) run(ok ? spec.onLoaded : spec.onLoadFailed)(this)
      },
      reload() { this.load(true) },
      // The watcher fired: what the QML does about it is its own onFileChanged.
      fileChanged() { if (spec.watchChanges === 'true') run(spec.onFileChanged)(this) }
    }
    views[id] = fv
    ctx[id] = fv
  }
  // Construction: the initializers read the files synchronously, then the loads report in.
  for (const name of ['userConfig', 'defaultsConfig']) ctx[name] = vm.runInContext(binding(name), ctx).call(ctx)
  views.userConfigFile.load(true)
  views.defaultsFile.load(true)

  // QML's onBindSpecChanged, fired whenever a file event moves bindSpec.
  const onBindSpecChanged = vm.runInContext(`(function () ${handler('onBindSpecChanged')}\n)`, ctx)
  const changed = (fn) => { const before = ctx.bindSpec; fn(); if (ctx.bindSpec !== before) onBindSpecChanged.call(ctx) }
  const edit = (which, value) => changed(() => {
    const path = which === 'user' ? userPath : defaultsPath
    if (value === undefined) rmSync(path, { force: true }); else write(path, value)
    views[which === 'user' ? 'userConfigFile' : 'defaultsFile'].fileChanged()
  })
  const cleanup = () => { rmSync(home, { recursive: true, force: true }); rmSync(omarchy, { recursive: true, force: true }) }
  return { ctx, log, edit, cleanup, env, views }
}

const shellJson = (entry, extra = {}) => ({
  version: 1,
  bar: { position: 'top', layout: { left: [{ id: 'omarchy.menu' }], right: [{ id: 'omarchy.clock' }] } },
  plugins: [{ id: 'some.other.plugin', zoom: 5 }, ...(entry ? [{ id: pluginId, ...entry }] : [])],
  ...extra
})
const defaults = { cardMs: 0, panMs: 200, thumbnails: 'live', minimum: 5, maximum: 10, maxRows: 4, maxIcons: 8,
  fieldDensity: 1, doubleTapMs: 300, zoomMs: 340, feedFrac: 0.3, zoomEase: [0.45, 0, 0.15, 1, 1, 1], barHidden: true,
  bindSpec: 'SUPER + SUPER_L' }
const values = ctx => Object.fromEntries(Object.keys(defaults).map(k => [k, plain(ctx[k])]))

test('the entry is read from the user shell.json through a scoped shell that has no shellConfig', t => {
  const r = rig({ user: shellJson({ zoom: 120, zoomEase: [0.2, 0, 0, 1], feed: 40, pan: 90, card: 150, thumbnails: 'static',
    minimum: 3, maximum: 7, rows: 6, icons: 4, doubleTap: 250, field: 0, bar: 'shown', bind: 'SUPER + GRAVE' }) })
  t.after(r.cleanup)
  assert.equal(r.ctx.shell.shellConfig, undefined)
  assert.deepEqual(values(r.ctx), { cardMs: 150, panMs: 90, thumbnails: 'static', minimum: 3, maximum: 7, maxRows: 6,
    maxIcons: 4, fieldDensity: 0, doubleTapMs: 250, zoomMs: 120, feedFrac: 0.4, zoomEase: [0.2, 0, 0, 1, 1, 1],
    barHidden: false, bindSpec: 'SUPER + GRAVE' })
  assert.equal(r.ctx.bindLua, 'hl.bind("SUPER + GRAVE", hl.dsp.exec_cmd("omarchy-shell panorama toggle"), { description = "Panorama" })')
})

test('the files are the ones the shell reads: $HOME/.config and $OMARCHY_PATH/config, read at load and watched', t => {
  const r = rig()
  t.after(r.cleanup)
  assert.equal(r.ctx.userConfigPath, r.env.HOME + '/.config/omarchy/shell.json')
  assert.equal(r.ctx.defaultsPath, r.env.OMARCHY_PATH + '/config/omarchy/shell.json')
  for (const id of ['userConfigFile', 'defaultsFile']) {
    const spec = r.views[id].spec
    assert.equal(spec.blockLoading, 'true', `${id} is read before the first claimBind`)
    assert.equal(spec.watchChanges, 'true')
    assert.equal(spec.onFileChanged, 'reload()')
    assert.equal(spec.printErrors, 'false', 'a missing file is ordinary, not an error')
  }
})

test('a missing user file means the defaults file, and no entry anywhere means every default', t => {
  const r = rig()
  t.after(r.cleanup)
  assert.equal(r.ctx.config, null)
  assert.deepEqual(values(r.ctx), defaults)
  const d = rig({ defaults: shellJson(null) })
  t.after(d.cleanup)
  assert.equal(d.ctx.config.version, 1)
  assert.deepEqual(values(d.ctx), defaults)
})

test('an unreadable user file is passed over for the defaults, as the shell passes over it', t => {
  for (const user of ['', '   \n', '{ "version": 1, "plugins": [', 'null', '[]', '"text"', '42']) {
    const r = rig({ user, defaults: shellJson({ zoom: 77 }) })
    t.after(r.cleanup)
    assert.equal(r.ctx.zoomMs, 77, JSON.stringify(user))
  }
  const none = rig({ user: '{ broken' })
  t.after(none.cleanup)
  assert.deepEqual(values(none.ctx), defaults)
  assert.deepEqual(none.log.warn, [], 'the shell already warns about its own file')
})

test('only version: 1 counts, in either file', t => {
  for (const version of [2, '1', 0, null, undefined]) {
    const r = rig({ user: shellJson({ zoom: 120 }, { version }), defaults: shellJson({ zoom: 77 }) })
    t.after(r.cleanup)
    assert.equal(r.ctx.zoomMs, 77, `user version ${JSON.stringify(version)}`)
    const d = rig({ defaults: shellJson({ zoom: 77 }, { version }) })
    t.after(d.cleanup)
    assert.equal(d.ctx.zoomMs, 340, `defaults version ${JSON.stringify(version)}`)
  }
  const ok = rig({ user: shellJson({ zoom: 120 }), defaults: shellJson({ zoom: 77 }) })
  t.after(ok.cleanup)
  assert.equal(ok.ctx.zoomMs, 120, 'a valid user file wins outright, no merge')
})

test('the entry is matched by id, objects only, first one wins', t => {
  const r = rig({ user: { version: 1, plugins: [pluginId, null, { id: 'other', zoom: 1 }, { id: pluginId, zoom: 111 }, { id: pluginId, zoom: 222 }] } })
  t.after(r.cleanup)
  assert.equal(r.ctx.zoomMs, 111)
  const s = rig({ user: { version: 1, plugins: { id: pluginId, zoom: 1 } } })
  t.after(s.cleanup)
  assert.equal(s.ctx.zoomMs, 340, 'plugins must be an array')
})

test('bind: false claims no key, and nor do its spellings', t => {
  for (const bind of [false, 0, 'false', 'off', 'None', '', '  ']) {
    const r = rig({ user: shellJson({ bind }) })
    t.after(r.cleanup)
    assert.equal(r.ctx.bindSpec, '', JSON.stringify(bind))
    r.ctx.claimBind()
    assert.equal(r.ctx.bindProbe.running, false, `${JSON.stringify(bind)} never probes`)
    r.ctx.applyBinds('[]')
    assert.equal(r.ctx.bindApply.running, false, `${JSON.stringify(bind)} never binds`)
  }
  for (const bind of [true, null]) {
    const r = rig({ user: shellJson({ bind }) })
    t.after(r.cleanup)
    assert.equal(r.ctx.bindSpec, 'SUPER + SUPER_L', JSON.stringify(bind))
  }
})

test('edits land live: every setting follows the file as it changes, goes and comes back', t => {
  const r = rig({ user: shellJson(null) })
  t.after(r.cleanup)
  assert.deepEqual(values(r.ctx), defaults)
  r.edit('user', shellJson({ zoom: 0, feed: 18, minimum: 2, maximum: 4, thumbnails: 'off', bar: 'SHOWN', doubleTap: 5000 }))
  assert.deepEqual(values(r.ctx), { ...defaults, zoomMs: 0, feedFrac: 0.18, minimum: 2, maximum: 4, thumbnails: 'off',
    barHidden: false, doubleTapMs: 1000 })
  r.edit('user', '{ "version": 1, "plugins": [ { "id": "' + pluginId + '", "zoom": ')   // a save caught half-written
  assert.deepEqual(values(r.ctx), defaults)
  r.edit('user', shellJson({ zoom: 500 }))
  assert.equal(r.ctx.zoomMs, 500)
  r.edit('user', undefined)
  assert.deepEqual(values(r.ctx), defaults)
  r.edit('defaults', shellJson({ zoom: 64 }))
  assert.equal(r.ctx.zoomMs, 64, 'with no user file the defaults file is live too')
  r.edit('user', shellJson({ zoom: 500 }, { version: 2 }))
  assert.equal(r.ctx.zoomMs, 64)
})

test('a live bind edit moves the key: the old one is dropped and the new one claimed', t => {
  const r = rig({ user: shellJson(null) })
  t.after(r.cleanup)
  const c = r.ctx
  c.claimBind()
  assert.equal(c.bindProbe.running, true)
  c.bindProbe.running = false
  c.applyBinds('[]')
  assert.deepEqual(plain(c.bindApply.command), ['hyprctl', 'eval',
    'hl.bind("SUPER + SUPER_L", hl.dsp.exec_cmd("omarchy-shell panorama tap"), { description = "Panorama", release = true })'])
  c.bindApply.running = false
  c.bindApplied(0)
  assert.equal(c.boundSpec, 'SUPER + SUPER_L')

  const retries = c.bindRetry.restarts
  r.edit('user', shellJson({ bind: 'SUPER + GRAVE' }))
  assert.deepEqual(plain(r.log.detached.at(-1)), ['hyprctl', 'eval', 'hl.unbind("SUPER + SUPER_L")'])
  assert.equal(c.bound, false)
  assert.equal(c.bindRetry.restarts, retries + 1)
  c.claimBind()
  c.bindProbe.running = false
  c.applyBinds('[]')
  assert.deepEqual(plain(c.bindApply.command), ['hyprctl', 'eval',
    'hl.bind("SUPER + GRAVE", hl.dsp.exec_cmd("omarchy-shell panorama toggle"), { description = "Panorama" })'])
  c.bindApply.running = false
  c.bindApplied(0)

  const unbinds = r.log.detached.length
  r.edit('user', shellJson({ zoom: 200, bind: 'SUPER + GRAVE' }))
  assert.equal(r.log.detached.length, unbinds, 'an unrelated edit leaves the key alone')
  r.edit('user', shellJson({ bind: false }))
  assert.deepEqual(plain(r.log.detached.at(-1)), ['hyprctl', 'eval', 'hl.unbind("SUPER + GRAVE")'])
  c.claimBind()
  assert.equal(c.bindProbe.running, false, 'bind: false claims nothing after the edit either')
})

test('a shell that hands over shellConfig (first-party, dev) is still read first', t => {
  const r = rig({ shell: { shellConfig: shellJson({ zoom: 200 }) }, user: shellJson({ zoom: 120 }) })
  t.after(r.cleanup)
  assert.equal(r.ctx.zoomMs, 200)
  r.ctx.shell = scopedShell()
  assert.equal(r.ctx.zoomMs, 120, 'and the file takes over once the shell is a scoped one')
  r.ctx.shell = null
  assert.equal(r.ctx.zoomMs, 120, 'before the shell hands anything over at all')
})

// `hyprctl binds` exactly as Hyprland 0.56 formats it (src/debug/HyprCtl.cpp, bindsRequest): the plain
// listing, and 0.56.0's JSON, whose values run one field out of step from has_description on.
const plainListing = (binds) => binds.map(b => 'bind' + (b.release ? 'r' : '') + 'd'
  + `\n\tmodmask: ${b.modmask}\n\tsubmap: \n\tkey: ${b.key}\n\tkeycode: 0\n\tcatchall: false\n\tdescription: ${b.description}\n\tdispatcher: __lua\n\targ: \n\n`).join('')
const json0560 = (binds) => '[' + binds.map(b => `
{
    "locked": false,
    "mouse": false,
    "release": ${!!b.release},
    "repeat": false,
    "longPress": false,
    "non_consuming": false,
    "auto_consuming": false,
    "has_description": false,
    "modmask": true,
    "submap": "${b.modmask}",
    "submap_universal": "",
    "key": "false",
    "keycode": ${b.key},
    "catch_all": 0,
    "description": "false",
    "allow_input_capture": ${b.description},
    "dispatcher": "__lua",
    "arg": ""
},`).join('').replace(/,$/, '') + ']'

test('Hyprland 0.56.0 JSON that will not parse falls back to the plain listing', t => {
  const r = rig({ user: shellJson(null) })
  t.after(r.cleanup)
  const c = r.ctx
  const theirs = [{ modmask: 64, key: 'SUPER_L', release: true, description: 'Mine' }, { modmask: 64, key: 'TAB', description: 'Next workspace' }]
  assert.throws(() => JSON.parse(json0560(theirs)))
  c.applyBinds(json0560(theirs))
  assert.equal(c.bindListing.running, true)
  assert.equal(c.bindApply.running, false)
  c.bindListing.running = false
  c.checkBinds(c.plainBinds(plainListing(theirs)))
  assert.match(r.log.info.at(-1), /SUPER \+ SUPER_L is already bound, leaving it alone/)
  assert.equal(c.bindApply.running, false)

  const others = [{ modmask: 64, key: 'SUPER_L', description: 'A press, not a release' }, { modmask: 65, key: 'SUPER_L', release: true, description: 'With shift' }]
  c.checkBinds(c.plainBinds(plainListing(others)))
  assert.equal(c.bindApply.running, true)
  assert.match(c.bindApply.command[2], /^hl\.bind\("SUPER \+ SUPER_L"/)

  assert.deepEqual(plain(c.plainBinds(plainListing(theirs))), [
    { release: true, modmask: '64', submap: '', key: 'SUPER_L', keycode: '0', catchall: 'false', description: 'Mine', dispatcher: '__lua', arg: '' },
    { release: false, modmask: '64', submap: '', key: 'TAB', keycode: '0', catchall: 'false', description: 'Next workspace', dispatcher: '__lua', arg: '' }])
})

test('the palette is reached as Commons.Color and the scrim no longer hangs on a removed token', () => {
  assert.match(qml, /^import qs\.Commons as Commons$/m)
  const code = qml.split('\n').map(l => l.replace(/\/\/.*$/, '')).join('\n')
  assert.deepEqual(code.match(/(^|[^\w.])Color\.\w+/gm) || [], [], 'no bare Color.* (Qt 6.12 shadows it)')
  assert.doesNotMatch(code, /imagePicker\.scrim/)
  assert.match(code, /scrim: Commons\.Color\.composed\("image-picker\.scrim", "image-picker\.scrim-alpha", Commons\.Color\.background, 0\.5\)/)
})

// Against a real Omarchy checkout, when one is named: OMARCHY_SHELL=<checkout>/shell node --test tests/
test('paths, parse rule and the scoped shell match the Omarchy shell named by OMARCHY_SHELL', t => {
  const dir = process.env.OMARCHY_SHELL
  if (!dir) return t.skip('OMARCHY_SHELL is not set')
  const shellQml = readFileSync(join(dir, 'shell.qml'), 'utf8')
  const api = readFileSync(join(dir, 'services/PluginShellApi.qml'), 'utf8')
  assert.match(shellQml, /property string home: Quickshell\.env\("HOME"\)/)
  assert.match(shellQml, /property string omarchyPath: Quickshell\.env\("OMARCHY_PATH"\)/)
  assert.match(shellQml, /userConfigPath: home \+ "\/\.config\/omarchy\/shell\.json"/)
  assert.match(shellQml, /defaultsPath: omarchyPath \+ "\/config\/omarchy\/shell\.json"/)
  assert.match(shellQml, /Util\.isPlainObject\(parsed\) && parsed\.version === 1\) user = parsed/)
  assert.match(shellQml, /shellConfig = user \|\| defaults/)
  assert.match(shellQml, /function pluginShellFor\(manifest\) \{\n\s*if \(!manifest \|\| manifest\.__isFirstParty\) return shell/)
  assert.doesNotMatch(api, /property [\w<>]+ shellConfig\b/, 'the scoped shell still has no shellConfig to read')
})


test('workspaceOrder uses the watched plugin entry and defaults malformed values to an empty list', t => {
  const r = rig({ user: shellJson({ workspaceOrder: ['name:Code', 'name:Web'] }) })
  t.after(r.cleanup)
  const get = vm.runInContext(binding('workspaceOrder'), r.ctx)
  Object.defineProperty(r.ctx, 'workspaceOrder', { get: () => get.call(r.ctx) })
  assert.deepEqual(plain(r.ctx.workspaceOrder), ['name:Code', 'name:Web'])
  r.edit('user', shellJson({ workspaceOrder: ['name:Web'] }))
  assert.deepEqual(plain(r.ctx.workspaceOrder), ['name:Web'])
  for (const value of [null, {}, 'name:Code', 2, false]) {
    r.edit('user', shellJson({ workspaceOrder: value }))
    assert.deepEqual(plain(r.ctx.workspaceOrder), [])
  }
  r.edit('user', shellJson({}))
  assert.deepEqual(plain(r.ctx.workspaceOrder), [])
})
