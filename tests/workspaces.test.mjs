import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import test from 'node:test'
import vm from 'node:vm'

const qml = readFileSync(new URL('../1.0.20/Panorama.qml', import.meta.url), 'utf8')
const methods = [...qml.matchAll(/^  function \w+\([^\n]*\{(?:[^\n]*\}[^\n]*$|[\s\S]*?^  \})/gm)].map(hit => hit[0]).join('\n')
const plain = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value))
const workspace = (id, name = String(id), monitor = 'DP-1') => ({ id, name, monitor })
const client = (id, name, address, title = 'Terminal') => ({ workspace: { id, name }, address, title, class: 'foot', mapped: true })
const monitor = (id, name = String(id), special = { id: 0, name: '' }) => ({ name: 'DP-1', focused: true, activeWorkspace: { id, name }, specialWorkspace: special })

function harness(options = {}) {
  const noop = () => {}
  const state = {
    ids: [], wsMap: {}, clientMap: {}, monitors: [], monitor: null, minimum: 5, maximum: 10,
    sel: 1, rowIdx: -1, query: '', matches: [], committing: false, cardShowing: false, locked: false,
    opening: false, pendingQuery: '', zoomMs: 0, revealed: false, clock: '', dress: { padded: false, upper: false },
    dispatchDelayMs: 24, dispatchTimer: { restart: noop }, hideTimer: { restart: noop },
    revealTimer: { restart: noop }, gatherHold: { restart: noop }, gatherSeq: 0,
    Hyprland: { refreshToplevels: noop }, Quickshell: { screens: [{ name: 'DP-1' }] },
    Qt: { formatDate: () => '' }, ...options
  }
  Object.defineProperty(state, 'selIndex', { get() { return Math.max(0, state.ids.indexOf(state.sel)) } })
  const ctx = vm.createContext(state)
  vm.runInContext(methods, ctx)
  ctx.maybeReveal = noop
  ctx.snapshot = (clients, workspaces, monitors) => ctx.applySnapshot([clients, workspaces, monitors].map(JSON.stringify).join('\n---\n'))
  return ctx
}

test('named clients and empty persistent workspaces appear in creation order and count toward minimum', () => {
  const h = harness({ opening: true })
  const workspaces = Array.from({ length: 7 }, (_, i) => workspace(-1337 - i, ['Web', 'Code', 'Chat', 'Music', 'Mail', 'Games', 'Empty'][i]))
  h.snapshot([client(-1337, 'Web', '0xA')], workspaces.toReversed(), [monitor(-1340, 'Music')])
  assert.deepEqual(plain(h.ids), [-1337, -1338, -1339, -1340, -1341, -1342, -1343, 1])
  assert.equal(h.sel, -1340)
  assert.equal(h.wsMap[-1337].windows, 1)
  assert.equal(h.wsMap[-1343].windows, 0)
  assert.equal(h.wsMap[-1343].name, 'Empty')
})

test('client and active-monitor references retain named workspaces missing from the workspace table', () => {
  const h = harness({ opening: true })
  h.snapshot([client(-1337, 'Code', '0xa')], [], [monitor(-1338, 'Empty')])
  assert.deepEqual(plain(h.ids), [-1337, -1338, 1, 2, 3])
  assert.equal(h.sel, -1338)
  assert.equal(h.wsMap[-1337].selector, 'name:Code')
  assert.equal(h.wsMap[-1338].selector, 'name:Empty')
})

test('visible scratchpads cover named feeds without rows or counts, hidden scratchpads stay absent', () => {
  const h = harness()
  h.snapshot([
    client(-1337, 'Code', '0xa'), client(-99, 'special:scratch', '0xb'),
    client(-98, 'special:hidden', '0xc'), client(-97, 'special', '0xd')
  ], [workspace(-1337, 'Code'), workspace(-99, 'special:scratch'), workspace(-98, 'special:hidden'), workspace(-97, 'special')],
  [monitor(-1337, 'Code', { id: -99, name: 'special:scratch' })])
  assert.deepEqual(plain(h.wsMap[-1337]?.addrs), ['a'])
  assert.deepEqual(plain(h.wsMap[-1337]?.above), ['b'])
  assert.equal(h.wsMap[-1337].windows, 1)
  assert.deepEqual(plain(h.paintOrder(h.wsMap[-1337])), ['a', 'b'])
  assert.equal(h.clientMap.c, undefined)
  assert.equal(h.clientMap.d, undefined)
  assert.ok(!h.ids.includes(-99) && !h.ids.includes(-98) && !h.ids.includes(-97))
})

test('workspace IDs distinguish ordinary special names from renamed scratchpads', () => {
  const h = harness({ opening: true })
  h.snapshot([
    client(-1337, 'special', '0xa'), client(-1338, 'special:Code', '0xb'),
    client(-99, 'Renamed scratchpad', '0xc'), client(-2, 'Hidden scratchpad', '0xd')
  ], [workspace(-1337, 'special'), workspace(-1338, 'special:Code'), workspace(-99, 'Renamed scratchpad'), workspace(-2, 'Hidden scratchpad')],
  [monitor(-1337, 'special', { id: -99, name: 'Renamed scratchpad' })])
  assert.deepEqual(plain(h.ids), [-1337, -1338, 1, 2, 3])
  assert.equal(h.sel, -1337)
  assert.deepEqual(plain(h.wsMap[-1337].addrs), ['a'])
  assert.deepEqual(plain(h.wsMap[-1337].above), ['c'])
  assert.equal(h.wsMap[-1337].windows, 1)
  assert.deepEqual(plain(h.wsMap[-1338].addrs), ['b'])
  assert.equal(h.wsMap[-1338].selector, 'name:special:Code')
  assert.equal(h.clientMap.d, undefined)
  h.commit(-1337, '')
  assert.equal(h.pendingLua, 'hl.dsp.focus({ workspace = "name:special" })')
})

test('a window on no workspace (Hyprland reports id -1) never becomes a named feed', () => {
  const h = harness({ opening: true })
  h.snapshot([client(-1, '', '0xa'), client(-1337, 'Code', '0xb')], [workspace(-1337, 'Code')], [monitor(-1337, 'Code')])
  assert.deepEqual(plain(h.ids), [-1337, 1, 2, 3, 4])
  assert.equal(h.wsMap[-1], undefined)
  assert.equal(h.clientMap.a, undefined)
})

test('numbered strips retain contiguous slots, cap, occupied overflow and active empty overflow', () => {
  const h = harness({ maximum: 5, minimum: 3 })
  h.snapshot([client(2, '2', '0xa'), client(12, '12', '0xb')], [workspace(2), workspace(19)], [monitor(20)])
  assert.deepEqual(plain(h.ids), [1, 2, 3, 4, 5, 12, 20])
  h.snapshot([], [workspace(2)], [monitor(2)])
  assert.deepEqual(plain(h.ids), [1, 2, 3])
})

test('mixed strips keep named feeds and numbered destinations without exceeding the cap for fillers', () => {
  const h = harness({ maximum: 5, minimum: 3 })
  h.snapshot([client(2, '2', '0xa')], [workspace(2), workspace(-1338, 'Chat'), workspace(-1337, 'Code')], [monitor(2)])
  assert.deepEqual(plain(h.ids), [-1337, -1338, 1, 2, 3])
  h.snapshot([], Array.from({ length: 6 }, (_, i) => workspace(-1337 - i, 'Name' + i)), [monitor(-1337, 'Name0')])
  assert.deepEqual(plain(h.ids), [-1337, -1338, -1339, -1340, -1341, -1342])
  h.snapshot([client(12, '12', '0xa')], [workspace(-1337, 'Code')], [monitor(-1337, 'Code')])
  assert.deepEqual(plain(h.ids), [-1337, 1, 2, 3, 12])
})

test('mixed strips keep numbered slots ascending when the cap leaves no trailing empty slot', () => {
  const h = harness({ maximum: 10, minimum: 5 })
  const named = [workspace(-1337, 'Web'), workspace(-1338, 'Code'), workspace(-1339, 'Chat')]
  const busy = [1, 2, 3, 5, 6, 7]
  h.snapshot(busy.map(id => client(id, String(id), '0x' + id)), named.concat(busy.map(id => workspace(id))), [monitor(7)])
  assert.deepEqual(plain(h.ids), [-1337, -1338, -1339, 1, 2, 3, 4, 5, 6, 7])
  h.snapshot([client(1, '1', '0x1'), client(5, '5', '0x5')], named.slice(0, 2).concat(workspace(1), workspace(5)), [monitor(1)])
  assert.deepEqual(plain(h.ids), [-1337, -1338, 1, 2, 3, 4, 5, 6])
  const capped = harness({ maximum: 5, minimum: 3 })
  capped.snapshot([client(1, '1', '0x1'), client(5, '5', '0x5')], named.slice(0, 2).concat(workspace(1), workspace(5)), [monitor(1)])
  assert.deepEqual(plain(capped.ids), [-1337, -1338, 1, 2, 5])
})

test('refresh keeps feed identity and named selection while updating window titles', () => {
  const h = harness()
  h.snapshot([client(-1337, 'Code', '0xa')], [workspace(-1337, 'Code')], [monitor(-1337, 'Code')])
  h.jump(-1337)
  const ids = h.ids
  h.snapshot([client(-1337, 'Code', '0xa', 'Changed title')], [workspace(-1337, 'Code')], [monitor(-1337, 'Code')])
  assert.equal(h.ids, ids)
  assert.equal(h.sel, -1337)
  assert.equal(h.clientMap.a.title, 'Changed title')
})

test('navigation and search keep numeric workspace identity for named feeds', () => {
  const h = harness()
  h.snapshot([client(-1337, 'Code', '0xa', 'Editor'), client(-1338, 'Web', '0xb', 'Editor docs')],
    [workspace(-1337, 'Code'), workspace(-1338, 'Web')], [monitor(-1337, 'Code')])
  h.jump(-1337)
  h.move(1)
  assert.equal(h.sel, -1338)
  h.setQuery('editor')
  assert.equal(h.sel, -1337)
  assert.equal(h.rowIdx, 0)
  h.nextMatch(1)
  assert.equal(h.sel, -1338)
  assert.equal(h.matches[1].ws, -1338)
  h.jump(1)
  assert.equal(h.sel, 1)
})

test('feed, record and commit receipt display workspace names and escape rich text', () => {
  const h = harness()
  h.snapshot([], [workspace(-1337, 'Code<&>')], [monitor(-1337, 'Code<&>')])
  h.jump(-1337)
  h.root = h
  h.feed = { modelData: -1337 }
  h.stage = { fg: '#fff' }
  h.record = { isLive: false, ws: h.wsMap[-1337] }
  const feedText = qml.match(/Text \{ text: ([^;]+);[^\n]*color: feed.selected/)[1]
  assert.match(qml.match(/Text \{ text: [^\n]*color: feed.selected/)[0], /textFormat: Text.PlainText/)
  const heading = qml.match(/text: ("<font color=[^\n]+)\n\s*\+ \(record.isLive[^\n]+\n\s*\+ \(record.ws[^\n]+/)[0].slice(6)
  assert.equal(vm.runInContext(feedText, h), 'Code<&>')
  assert.match(vm.runInContext(heading, h), /Code&lt;&amp;&gt;/)
  h.commit(-1337, '')
  assert.ok(h.cardSub.startsWith('→ Code<&> · '))
  const numbered = harness({ dress: { padded: true, upper: false } })
  numbered.snapshot([], [workspace(2, 'Work')], [monitor(2, 'Work')])
  assert.equal(numbered.workspaceLabel(2), 'Work')
  assert.equal(numbered.workspaceLabel(1), '01')
  numbered.commit(2, '')
  assert.equal(numbered.pendingLua, 'hl.dsp.focus({ workspace = "2" })')
})

function quotedDispatch() {
  const name = 'Code " \\ café ' + Array.from({ length: 32 }, (_, i) => String.fromCharCode(i)).join('') + '\x7f9'
  const h = harness()
  h.snapshot([], [workspace(-1337, name)], [monitor(-1337, name)])
  h.commit(-1337, '')
  return { name, lua: h.pendingLua }
}

test('named dispatch quotes backslashes, Unicode and every control byte for Lua', () => {
  assert.equal(quotedDispatch().lua, String.raw`hl.dsp.focus({ workspace = "name:Code \" \\ café \000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031\1279" })`)
  const numbered = harness()
  numbered.snapshot([], [workspace(2)], [monitor(2)])
  numbered.commit(2, '')
  assert.equal(numbered.pendingLua, 'hl.dsp.focus({ workspace = "2" })')
})

test('Lua round-trips the dispatched name when an interpreter is available', t => {
  const { name, lua } = quotedDispatch()
  try {
    // Bytes, not text: a text-mode stdout (Windows) would turn the name's \n into \r\n.
    assert.equal(execFileSync(process.env.LUA || 'lua', ['-'], {
      input: 'hl = {dsp = {focus = function(v) io.write(table.concat({v.workspace:byte(1, -1)}, ",")) end}}\n' + lua,
      encoding: 'utf8'
    }), [...Buffer.from('name:' + name)].join(','))
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
    t.skip('lua is not installed; the exact dispatch source is checked above')
  }
})
