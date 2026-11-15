'use strict';
// Packs src/shared/*.js and gifenc into one plain script for the editor window
// (the window has no Node, so it can't require() them itself). Run by `npm start`, `npm run dist`
// and by the app itself when it isn't packaged.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const sharedDir = path.join(root, 'src', 'shared');
const outFile = path.join(root, 'src', 'renderer', 'gen', 'shared.bundle.js');

function build() {
  const parts = [];
  for (const file of fs.readdirSync(sharedDir).sort()) {
    if (!file.endsWith('.js')) continue;
    const name = file.replace(/\.js$/, '');
    const src = fs.readFileSync(path.join(sharedDir, file), 'utf8');
    parts.push(`defs[${JSON.stringify(name)}] = function (module, exports, require) {\n${src}\n};`);
  }
  const gifenc = fs.readFileSync(require.resolve('gifenc/dist/gifenc.js'), 'utf8');
  parts.push(`defs["gifenc"] = function (module, exports, require) {\n${gifenc}\n};`);
  const out = `// Made by scripts/bundle.js. Don't edit: change src/shared instead.
(function () {
  'use strict';
  var defs = Object.create(null);
  var cache = Object.create(null);
  function req(name) {
    var key = String(name).replace(/^\\.\\//, '').replace(/\\.js$/, '');
    if (cache[key]) return cache[key].exports;
    if (!defs[key]) throw new Error('Not bundled: ' + name);
    var module = { exports: {} };
    cache[key] = module;
    defs[key].call(module.exports, module, module.exports, req);
    return module.exports;
  }
${parts.join('\n')}
  window.GaleShared = req('index');
  window.GifEnc = req('gifenc');
})();
`;
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  const old = fs.existsSync(outFile) ? fs.readFileSync(outFile, 'utf8') : null;
  if (old !== out) fs.writeFileSync(outFile, out);
  return outFile;
}

module.exports = { build, outFile };

if (require.main === module) {
  console.log(`Wrote ${path.relative(root, build())}`);
}
