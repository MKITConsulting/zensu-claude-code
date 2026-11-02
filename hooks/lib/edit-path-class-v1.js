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

function editPathClass(filePath, stateDirectory) {
  const file = lowerNormal(realFile(path.resolve(filePath || '')));
  const state = `${lowerNormal(realDirectory(path.resolve(stateDirectory || '')))}/`;
  if (file.indexOf(state) === 0) return 'state';
  if (file.indexOf('/.zensu/') >= 0 || file.endsWith('/.zensu')) return 'zensu';
  return 'other';
}

module.exports = { editPathClass };

if (require.main === module) process.stdout.write(`${editPathClass(process.env.FP, process.env.SD)}\n`);
