#!/usr/bin/env node
'use strict';

// Git Bash exposes drive-qualified Windows paths in its own namespace
// (`/d/work/file`). Native Node does not apply MSYS argument conversion to
// paths embedded in JSON or manifest contents, so translate that one spelling
// explicitly before any node:path or filesystem operation. Other POSIX-rooted
// spellings have no unambiguous native Windows meaning and fail closed.
function normalizeHostPathInput(value, label = 'path', platform = process.platform) {
  if (typeof value !== 'string') throw new TypeError(`${label} must be a string`);
  if (platform !== 'win32') return value;

  const msysDrive = /^\/([A-Za-z])(?:\/(.*))?$/.exec(value);
  if (msysDrive) {
    return `${msysDrive[1].toUpperCase()}:/${msysDrive[2] || ''}`;
  }

  if (/^[A-Za-z]:(?![\\/])/.test(value)) {
    throw new Error(`${label} uses a drive-relative Windows path`);
  }

  // Normalize complete UNC/extended paths into one ordinary native spelling.
  // Device namespaces are not filesystem identity aliases: they can address
  // pipes, raw devices, or GLOBALROOT and must never cross this boundary.
  if (/^[\\/]/.test(value)) {
    const native = value.replaceAll('/', '\\');
    if (native.startsWith('\\\\.\\')) {
      throw new Error(`${label} uses a Windows device namespace`);
    }
    if (native.startsWith('\\\\?\\')) {
      const extended = native.slice(4);
      if (/^[A-Za-z]:\\/.test(extended)) return extended;
      const extendedUnc = /^UNC\\([^\\\0]+)\\([^\\\0]+)(\\.*)?$/i.exec(extended);
      if (extendedUnc && !['.', '..', '?'].includes(extendedUnc[1])
          && !['.', '..'].includes(extendedUnc[2])) {
        return `\\\\${extendedUnc[1]}\\${extendedUnc[2]}${extendedUnc[3] || ''}`;
      }
      throw new Error(`${label} uses an unsupported Windows extended namespace`);
    }
    const completeUnc = /^\\\\([^\\\0]+)\\([^\\\0]+)(\\.*)?$/.exec(native);
    if (completeUnc && !['.', '..', '?'].includes(completeUnc[1])
        && !['.', '..'].includes(completeUnc[2])) {
      return `\\\\${completeUnc[1]}\\${completeUnc[2]}${completeUnc[3] || ''}`;
    }
    // A single slash/backslash root, incomplete UNC server, or MSYS mount
    // spelling other than /<drive>/... is current-drive/mount-table dependent.
    throw new Error(`${label} uses an unsupported rooted path on Windows`);
  }
  return value;
}

module.exports = { normalizeHostPathInput };
