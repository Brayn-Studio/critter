// Writes Skins/<name>/manifest.json for every skin in the Sprig preview, whose skin data block
// (between the SKIN BEGIN and SKIN END markers) defines SKINS = { name: manifest }. Usage:
//   node scripts/dev/make-skins-from-preview.js docs/superpowers/specs/2026-10-17-sprig-motion-preview.html Skins
const fs = require('fs');
const path = require('path');
const [,, previewPath, skinsDir] = process.argv;
const src = fs.readFileSync(previewPath, 'utf8');
const start = src.indexOf('/* ======================= skin data: SKIN BEGIN');
const end = src.indexOf('/* ======================= SKIN END');
if (start < 0 || end < start) throw new Error('no SKIN BEGIN / SKIN END block in ' + previewPath);
const skins = new Function(src.slice(start, end) + '\nreturn SKINS;')();

for (const [name, manifest] of Object.entries(skins)) {
  // one key per line inside arrays of keys / rows keeps the file reviewable
  const json = JSON.stringify(manifest, null, 2)
    .replace(/\[\n\s+("[^"\n]*"|-?[\d.]+)(,\n\s+("[^"\n]*"|-?[\d.]+))*\n\s+\]/g, (m) => '[' + m.slice(1, -1).split(',').map((s) => s.trim()).join(', ') + ']');
  fs.mkdirSync(path.join(skinsDir, name), { recursive: true });
  fs.writeFileSync(path.join(skinsDir, name, 'manifest.json'), json + '\n');
  console.log(name, 'clips', Object.keys(manifest.clips).length, 'poses', Object.keys(manifest.poses).length, 'parts', Object.keys(manifest.parts).length);
}
