// Builds the schema 2 skin manifest from the approved motion preview. Usage:
//   node scripts/dev/make-manifest-from-preview.js docs/superpowers/specs/2026-10-17-critter-motion-preview.html Skins/clawd/manifest.json
const fs = require('fs');
const [,, previewPath, outPath] = process.argv;
const src = fs.readFileSync(previewPath, 'utf8');
const start = src.indexOf('const L = (n)');
const end = src.indexOf('const VARIANTS');
const M = new Function(src.slice(start, end) + '\nreturn M;')();

const r2 = (v) => Math.round(v * 100) / 100;
const DUST = '#B4BAC4', GREY = '#A3A9B4';
const poof = Array.from({ length: 8 }, (_, i) => {
  const t = (i / 8) * Math.PI * 2;
  return { glyph: i % 2 ? 'spark' : 'dot', color: DUST, x: 8, y: 6, vx: r2(Math.cos(t) * 16), vy: r2(Math.sin(t) * 10 - 4), life: 6 };
});
const effects = {
  dust: { particles: [{ glyph: 'dot', color: DUST, x: 2, y: 9, vx: -12, vy: -3, life: 4 }, { glyph: 'dot', color: DUST, x: 15, y: 9, vx: 12, vy: -3, life: 4 }] },
  dust_small: { particles: [{ glyph: 'dot', color: DUST, x: 3, y: 9, vx: -8, vy: -2, life: 3 }, { glyph: 'dot', color: DUST, x: 14, y: 9, vx: 8, vy: -2, life: 3 }] },
  tilde: { particles: [{ glyph: 'tilde', color: DUST, x: -1, y: 8, vx: -6, vy: -2, life: 5 }, { glyph: 'tilde', color: DUST, x: 16, y: 8, vx: 6, vy: -2, life: 5 }] },
  puff: { particles: [{ glyph: 'tilde', color: DUST, x: 16, y: 3, vx: 10, vy: -3, life: 6 }] },
  sigh: { particles: [{ glyph: 'tilde', color: GREY, x: 15, y: 5, vx: 5, vy: -2, life: 9 }] },
  confetti: { particles: [{ count: 16, glyph: 'dot', colors: ['#D97757', '#34C759', '#FFD60A', '#64D2FF', '#FF7096', '#F2F2F7'], x: [5, 12], y: -1, vx: [-18, 18], vy: [-34, -16], ay: 80, life: [13, 19] }] },
  zzz: { cycle: [[{ glyph: 'z', color: GREY, x: 15, y: -2, vx: 3, vy: -5, sway: 1, life: 30 }], [{ glyph: 'Z', color: GREY, x: 15, y: -2, vx: 3, vy: -5, sway: 1, life: 30 }]] },
  heart: { particles: [{ glyph: 'heart', color: '#FF7096', x: [3, 13], y: -2, vx: [-2, 2], vy: -11, life: 10 }] },
  code: { cycle: [
    [{ glyph: 'sl', color: '#DDE1E7', x: 1, y: 1, vx: -4, vy: -7, life: 9 }],
    [{ glyph: 'gt', color: '#DDE1E7', x: 15, y: 1, vx: 4, vy: -7, life: 9 }],
    [{ glyph: 'lt', color: '#DDE1E7', x: 15, y: 1, vx: 4, vy: -7, life: 9 }],
  ] },
  bang_err: { particles: [{ glyph: 'bang', color: '#FF3B30', x: 16, y: -7, pop: true, life: 10 }] },
  bang_grey: { particles: [{ glyph: 'bang', color: '#E5E7EB', x: 16, y: -7, pop: true, life: 7 }] },
  sweat: { particles: [{ glyph: 'drop', color: '#86C8FF', x: 15, y: -2, vx: 0, vy: 4, life: 14 }] },
  poof: { particles: poof },
  twinkle: { particles: [{ glyph: 'spark', color: '#E9EDF2', x: 14, y: -9, life: 6, shrinkTo: 'dot' }] },
};

// effect names used inside clips must exist; the preview's engine-only hooks are renamed
const clips = {};
for (const [name, keys] of Object.entries(M.clips)) {
  if (name === 'hidden') continue; // engine-generated in the app
  clips[name] = keys.map((k) => {
    const out = [k[0], k[1]];
    const dx = k[2] || 0, dy = k[3] || 0, fx = k[4];
    if (fx === 'badge_pop') { if (dx || dy) out.push(dx, dy); return out; } // the badge now pops when `enter` starts
    if (dx || dy || fx) out.push(dx, dy);
    if (fx) out.push(fx);
    return out;
  });
}

const poses = {};
for (const [name, parts] of Object.entries(M.poses)) poses[name] = ['body', ...parts];

const glyphs = { ...M.glyphs };
delete glyphs.ptr; delete glyphs.grab; // preview-only pointer art

const manifest = {
  schema: 2,
  name: 'clawd',
  tickMs: 60,
  grid: [18, 10],
  palette: M.palette,
  parts: M.parts,
  poses,
  glyphs,
  clips,
  effects,
  accessories: {
    spinner: { frames: ['s0', 's1', 's2', 's3', 's4', 's5'], color: '#D97757', periodMs: 2000, box: 5, reduced: 'dotbig' },
    q: { glyph: 'q', color: '#FF9F0A', bobEvery: 7 },
    check: { glyph: 'check', color: '#34C759', twinkleEvery: 43, twinkle: 'twinkle' },
    bang: { glyph: 'bang', color: '#FF3B30' },
  },
  states: {
    idle: { loop: 'idle', tint: 'dim', still: 'base',
      fidget: { every: M.states.idle.fidget.every, pick: M.states.idle.fidget.pick },
      sleep: { after: M.states.idle.sleepAfter, doze: 'doze', loop: 'sleep', wake: 'wake', still: 'shut' } },
    running: { enter: 'work_enter', accessory: 'spinner', still: 'lap_a', defaultVariant: 'laptop',
      fidget: { every: M.states.running.fidget.every, pick: M.states.running.fidget.pick },
      variants: {
        laptop: { loop: 'laptop', enter: 'lap_open', exit: 'lap_close' },
        think: { loop: 'think' },
        read: { loop: 'read' },
        bash: { loop: 'bash' },
        juggle: { loop: 'juggle', prop: 'juggle' },
      } },
    waiting: { enter: 'alert', loop: 'ask', accessory: 'q', still: 'raise',
      badge: { glyph: 'bang', color: '#FF9F0A', x: 16, hopEvery: 20, impatientHopEvery: 8 },
      impatient: { after: M.states.waiting.impatientAfter, loop: 'impatient' } },
    done: { enter: 'celebrate', loop: 'content', accessory: 'check', still: 'happy', seen: 'seen',
      fidget: { every: M.states.done.fidget.every, pick: M.states.done.fidget.pick } },
    error: { enter: 'oops', loop: 'slump', tint: 'dim', accessory: 'bang', still: 'slump', stillDy: -1 },
  },
  interactions: {
    notice: 'notice', pet: 'pet', petEnd: 'pet_end', press: 'press', boopEnd: 'boop_end',
    held: 'held', heldStill: 'held_a', drop: 'drop', blink: 'blink',
    join: 'peekaboo', leave: 'leave', appear: 'appear', vanish: 'vanish',
    hop: 'air', land: 'base', blinkPose: 'shut', landDust: 'dust_small',
    walkLeft: ['walk_l_a', 'walk_l_b'], walkRight: ['walk_r_a', 'walk_r_b'],
    lookLeft: 'look_l', lookRight: 'look_r', lookUp: 'look_up', lookDown: 'look_down', lookCenter: 'base',
  },
  props: { juggle: { glyph: 'ball', colors: ['#D97757', '#F0A487', '#D97757'] } },
};

// one key per line inside arrays of keys / rows keeps the file reviewable
const json = JSON.stringify(manifest, (k, v) => v, 2)
  .replace(/\[\n\s+("[^"\n]*"|-?[\d.]+)(,\n\s+("[^"\n]*"|-?[\d.]+))*\n\s+\]/g, (m) => '[' + m.slice(1, -1).split(',').map((s) => s.trim()).join(', ') + ']');
fs.writeFileSync(outPath, json + '\n');
console.log('clips', Object.keys(clips).length, 'poses', Object.keys(poses).length, 'glyphs', Object.keys(glyphs).length, 'effects', Object.keys(effects).length);
