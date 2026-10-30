'use strict';

const fs = require('node:fs');
const path = require('node:path');

const lowerNormal = (value) => path.posix.normalize(String(value).replace(/\\/g, '/')).toLowerCase();

function realDirectory(value) {
  try {
    return fs.realpathSync(value);
  } catch (_error) {
    return path.resolve(value);
  }
}

function realFile(value) {
  try {
    return fs.realpathSync(value);
  } catch (_error) {
    return path.join(realDirectory(path.dirname(value)), path.basename(value));
  }
}

function declaredRootStateDirectories(document) {
  if (!document || typeof document !== 'object' || !Array.isArray(document.codeRoots)) return [];
  return document.codeRoots
    .flatMap((entry) => (entry && typeof entry === 'object' ? [entry.top, entry.path] : []))
    .filter((value) => typeof value === 'string' && path.isAbsolute(value))
    .map((root) => `${lowerNormal(realDirectory(path.join(root, '.zensu', 'state')))}/`);
}

function editPathClass(filePath, stateDirectory, document) {
  const file = lowerNormal(realFile(path.resolve(filePath || '')));
  const state = `${lowerNormal(realDirectory(path.resolve(stateDirectory || '')))}/`;
  if (file.indexOf(state) === 0) return 'state';
  if (declaredRootStateDirectories(document).some((rootState) => file.indexOf(rootState) === 0)) return 'state';
  if (file.indexOf('/.zensu/') >= 0 || file.endsWith('/.zensu')) return 'zensu';
  return 'other';
}

function owningRootRelative(filePath, document, options) {
  if (!document || typeof document !== 'object' || !Array.isArray(document.codeRoots)) return '';
  let owners = [];
  try {
    const read = require('./code-roots-v1.js').readCodeRoots(document, options);
    if (read.status === 'ok') owners = read.roots.map((root) => root.top);
  } catch (_error) {
    return '';
  }
  const file = realFile(path.resolve(filePath || ''));
  const owner = owners.map(realDirectory).find((root) => lowerNormal(file).indexOf(`${lowerNormal(root)}/`) === 0);
  return owner ? path.relative(owner, file).split(path.sep).join('/') : '';
}

function readDocument(file) {
  try {
    return JSON.parse(fs.readFileSync(file || '', 'utf8'));
  } catch (_error) {
    return null;
  }
}

module.exports = { editPathClass, owningRootRelative };

if (require.main === module) {
  const document = readDocument(process.env.WF);
  const pathClass = editPathClass(process.env.FP, process.env.SD, document);
  const relative = pathClass === 'other'
    ? owningRootRelative(process.env.FP, document, {
      anchor: process.env.AN || '',
      pluginData: process.env.CLAUDE_PLUGIN_DATA || '',
      claudeConfigDir: process.env.CLAUDE_CONFIG_DIR || '',
    })
    : '';
  process.stdout.write(relative ? `${pathClass}\t${relative}\n` : `${pathClass}\n`);
}
