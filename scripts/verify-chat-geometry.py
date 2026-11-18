#!/usr/bin/env python3
"""Drive a running --verify-chat-quality disposable app, never the user's app.

Start the separately identified audit bundle, wait for fresh ready.json, then run
this from the repository root. Raw snapshots and a machine-readable summary go
under output/chat-phase5. The app is left open for selection/appearance checks.
"""
import json
import time
import uuid
from pathlib import Path

COMMANDS = Path('output/chat-phase2')
OUTPUT = Path('output/chat-phase5')
OUTPUT.mkdir(parents=True, exist_ok=True)
observations = []

def call(action, **fields):
    ident = uuid.uuid4().hex
    temporary = COMMANDS / 'command.tmp'
    temporary.write_text(json.dumps(dict(id=ident, action=action, **fields)))
    temporary.replace(COMMANDS / 'command.json')
    result = COMMANDS / ('result-' + ident + '.json')
    deadline = time.monotonic() + 120
    while not result.exists():
        if time.monotonic() > deadline:
            raise TimeoutError(action)
        time.sleep(.02)
    s = json.loads(result.read_text())
    s['action'] = action
    observations.append(s)
    (OUTPUT / 'geometry-observations.jsonl').open('a').write(json.dumps(s) + '\n')
    return s

def visible(s):
    r = s.get('render', {})
    assert r.get('visibleIDs'), ('blank viewport', s)
    assert 0 < r.get('materialized', 0) < 150, ('unbounded materialization', r)
    assert not s['metrics'].get('document.blank'), ('blank assertion', s)
    # A hole in mounted coverage, clipped native text, or a blank band inside a
    # piece is what the user reports as disappearing text or empty areas.
    for channel in ('document.blank.band', 'document.text.clipped', 'document.text.blank'):
        assert not s['metrics'].get(channel), (channel, s['metrics'][channel])
    assert r.get('markdownCacheEntries', 0) <= 64, ('markdown cache entries', r)
    assert r.get('markdownCacheBytes', 0) <= 1 << 18, ('markdown cache bytes', r)
    assert not r.get('rendered', {}).get('unmountedGap', 0) or r['rendered']['unmountedGap'] <= 40, ('coverage hole', r['rendered'])
    assert not s['error'], s['error']
    return s

def settled():
    time.sleep(.2)
    return visible(call('state'))

def complete():
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        s = settled()
        if not s['busy'] and not s['pending']:
            return s
    raise TimeoutError('response did not complete')

for stale in ('performance.json', 'wheel-traces.json', 'geometry-result.json'):
    (OUTPUT / stale).unlink(missing_ok=True)
(OUTPUT / 'geometry-observations.jsonl').write_text('')
call('new')
for i in range(12):
    call('prompt', text='chat-scroll-fixture' if i in (3, 7) else 'grouped-fixture' if i % 3 == 0 else 'simple answer ' + str(i))
    time.sleep(.15)
    for char in 'Next one':
        visible(call('type', text=char))
    complete()
    call('draft', text='')
    print('mixed turn', i + 1, flush=True)
mixed = settled()
call('wheelBurst', delta=25, count=30)
settled()
call('wheel', delta=-1000000)
settled()

performance = {}
wheel_traces = {}
for turns in (80, 300, 800):
    call('resetMetrics')
    start = time.monotonic()
    call('seed', turns=turns)
    s = settled()
    elapsed = time.monotonic() - start
    assert s['messages'] == turns * 2, ('duplicate/missing messages', s['messages'])
    assert s['rssBytes'] < 600 * 1024 * 1024, ('RSS', s['rssBytes'])
    assert s['metrics']['main.loop.delay']['max_ms'] < 1500, ('main stall', s['metrics'])
    performance[turns] = dict(elapsed=elapsed, snapshot=s)
    trace = [s]
    for _ in range(40):
        call('wheel', delta=25)
        trace.append(visible(call('state')))
    assert len({s['contentHeight'] for s in trace}) == 1, 'wheel changed the document extent'
    for before, after in zip(trace, trace[1:]):
        dy = after['offset'] - before['offset']
        assert abs(dy + 25) < .5, ('wheel distance', dy)
        expected = dy / (before['contentHeight'] - before['viewportHeight'])
        assert abs((after['scroller'] - before['scroller']) - expected) < .00001, 'disproportionate scrollbar'
    wheel_traces[turns] = trace
    assert not trace[-1]['followsTail'], 'clear upward reading did not exit follow'
    call('wheel', delta=-1000000)
    s = settled()
    for _ in range(5):
        call('wheel', delta=12)
        assert settled()['followsTail'], 'tiny up disabled follow'
        call('wheel', delta=-12)
        settled()
        call('wheel', delta=100)
        assert not settled()['followsTail'], 'read up retained follow'
        call('wheel', delta=-80)
        assert settled()['followsTail'], '20-point gap failed re-entry'
        call('wheel', delta=-1000000)
        settled()
    call('wheel', delta=1000)
    s = settled()
    anchor = s['render']['readingTarget']
    session = s['session']
    old_offset = s['offset']
    call('new')
    settled()
    call('switch', session=session)
    back = settled()
    assert abs(back['offset'] - old_offset) < 1, ('session offset', old_offset, back['offset'])
    assert not back['followsTail'], 'session return stole follow'
    for width in (760, 1200, 900, 1060):
        call('resize', width=width, height=800)
        s = settled()
        assert not s['followsTail'], 'reflow enabled follow'
        assert anchor == s['render']['readingTarget'], ('reflow anchor', anchor, s['render']['readingTarget'])
    for _ in range(2):
        call('sidebar')
        s = settled()
        assert not s['followsTail'], 'sidebar enabled follow'
        assert anchor == s['render']['readingTarget'], 'sidebar lost reading piece'
    before = settled()
    call('keyboard', keyCode=116)
    after = settled()
    assert after['offset'] < before['offset'], 'Page Up did not scroll'
    call('keyboard', keyCode=119)
    assert settled()['followsTail'], 'End did not re-enter follow'
    print('history', turns, 'elapsed', round(elapsed, 3), 'MiB', round(performance[turns]['snapshot']['rssBytes'] / 1048576, 1), flush=True)

call('longAnswer', sections=160)
s = settled()
assert s['render']['logicalRows'] > 800
call('wheelBurst', delta=500, count=20)
settled()
call('wheel', delta=-1000000)
s = settled()
assert s['followsTail']

# Reproduce Phase 4's final blank path exactly against a fresh streamed session.
call('new')
call('prompt', text='chat-scroll-fixture')
complete()
for delta in (12, -12, 100, -80, -100000):
    call('wheel', delta=delta)
    settled()

# Active-tail changes must not move a reader above it or enable follow.
call('prompt', text='chat-scroll-fixture')
time.sleep(.3)
call('wheel', delta=420)
s = settled()
y = s['offset']
assert not s['followsTail']
time.sleep(.6)
s = settled()
assert not s['followsTail'] and abs(s['offset'] - y) < 1, 'streaming stole viewport'
complete()
call('wheel', delta=-1000000)
assert settled()['followsTail']

# A disclosure changes layout without moving the tail. The reader stays on the
# same piece, and the tail is only re-adopted when the kept position is the bottom.
# The disclosure needs a transcript that genuinely scrolls: seeded history carries
# real restored thinking blocks and is far larger than one fixture turn.
call('new')
call('seed', turns=20, varied=True)
settled()
call('wheel', delta=-1000000)
bottom = settled()
assert bottom['contentHeight'] > bottom['viewportHeight'] + 100, 'disclosure case needs room to scroll'


def find_thinking():
    """Scroll upward until a mounted thinking disclosure is in the viewport."""
    for _ in range(30):
        keys = call('state')['render'].get('thinkingKeys') or []
        if keys:
            return keys[0]
        if call('wheel', delta=300)['offset'] <= 1:
            break
    return ''


key = find_thinking()
assert key, 'no visible thinking disclosure to expand'
# Locating the disclosure may have scrolled; re-baseline from the tail.
call('wheel', delta=-1000000)
bottom = settled()
assert abs(bottom['offset'] - (bottom['contentHeight'] - bottom['viewportHeight'])) < 1
expanded = call('disclose', key=key)
assert expanded['disclosed'] == key, ('disclosure found nothing to toggle', key, expanded['disclosed'])
expanded = settled()
assert expanded['contentHeight'] > bottom['contentHeight'], 'disclosure did not grow the document'
growth = expanded['contentHeight'] - bottom['contentHeight']
moved = expanded['offset'] - bottom['offset']
assert abs(moved) < 1 or abs(moved - growth) < 1, ('disclosure jumped the viewport', bottom['offset'], expanded['offset'], growth)
assert expanded['render']['readingTarget'] == bottom['render']['readingTarget'], ('disclosure changed reading piece', bottom['render']['readingTarget'], expanded['render']['readingTarget'])
# Following survives exactly when the kept position genuinely is the new bottom
# (the same 24pt threshold ChatFollowTailState uses to re-adopt the tail).
assert expanded['followsTail'] == (abs(expanded['offset'] - (expanded['contentHeight'] - expanded['viewportHeight'])) < 24), \
    ('disclosure follow state', expanded['offset'], expanded['contentHeight'], expanded['viewportHeight'], expanded['followsTail'])
for channel in ('document.blank.band', 'document.text.clipped', 'document.text.blank'):
    assert not expanded['metrics'].get(channel), (channel, expanded['metrics'][channel])
call('wheel', delta=300)
reading = settled()
assert not reading['followsTail']
before = (reading['offset'], reading['contentHeight'], reading['render']['readingTarget'])
call('disclose', key=key)
collapsed = settled()
moved = collapsed['offset'] - reading['offset']
growth = collapsed['contentHeight'] - reading['contentHeight']
assert abs(moved) < 1 or abs(moved - growth) < 1, ('collapse jumped the viewport', before, collapsed['offset'], growth)
assert collapsed['render']['readingTarget'] == reading['render']['readingTarget'], ('collapse changed reading piece', before, collapsed['render'])
assert not collapsed['followsTail'], 'collapse above the tail invented follow'
for _ in range(3):
    call('disclose', key=key)
    state = settled()
    call('disclose', key=key)
    assert settled()['render']['readingTarget'] == state['render']['readingTarget'], 'repeat disclosure lost the piece'
visible(call('state'))

(OUTPUT / 'performance.json').write_text(json.dumps(performance, indent=2))
(OUTPUT / 'wheel-traces.json').write_text(json.dumps(wheel_traces, indent=2))
(OUTPUT / 'geometry-result.json').write_text(json.dumps(dict(passed=True, samples=len(observations), mixed=mixed), indent=2))
print('PASS native geometry / mixed conversation / hysteresis / resize / sessions / streaming', flush=True)
