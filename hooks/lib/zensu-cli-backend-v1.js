'use strict';

const OPAQUE = String.fromCharCode(0);
const DYNAMIC = String.fromCharCode(1);
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '0.0.0.0', '[::1]']);
const LOCAL_START = /^(?:https?:\/\/)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?![^:\/?#])/i;

function unquoted(value) {
  let start = 0;
  let end = value.length;
  while (start < end && (value.charCodeAt(start) === 34 || value.charCodeAt(start) === 39)) start += 1;
  while (end > start && (value.charCodeAt(end - 1) === 34 || value.charCodeAt(end - 1) === 39)) end -= 1;
  return value.slice(start, end);
}

function isDynamic(word) {
  return word.indexOf(DYNAMIC) !== -1 || word.indexOf('$') !== -1;
}

function runTime(word) {
  return isDynamic(word) || word.indexOf(OPAQUE) !== -1;
}

function isLocalUrl(value) {
  let text = String(value || '');
  const cut = text.search(/[\u0000\u0001$]/);
  if (cut !== -1) {
    text = text.slice(0, cut);
    if (!/[\/?#]/.test(text.replace(/^https?:\/\//i, ''))) return false;
  }
  if (!LOCAL_START.test(text) || /[^\x21-\x7e]|\\/.test(text)) return false;
  let url = null;
  try {
    url = new URL(/^https?:\/\//i.test(text) ? text : `http://${text}`);
  } catch (_error) {
    return false;
  }
  return url.username === '' && url.password === '' && LOCAL_HOSTS.has(url.hostname);
}

function shellWords(tokens) {
  const words = [];
  let open = '';
  let word = null;
  for (const token of tokens) {
    if (word === null && token.charAt(0) === '#') break;
    word = word === null ? token : `${word} ${token}`;
    for (let k = 0; k < token.length; k++) {
      const ch = token.charAt(k);
      if (open === "'") { if (ch === "'") open = ''; }
      else if (ch === '\\') k++;
      else if (open !== '') { if (ch === open) open = ''; }
      else if (ch === '"' || ch === "'") open = ch;
    }
    if (open === '') {
      words.push(word);
      word = null;
    }
  }
  if (word !== null) words.push(word);
  return words;
}

function apiNames(text) {
  return (text.match(/--api-url/gi) || []).length;
}

function spellsVariable(command) {
  try {
    return /ZENSU_API_URL/i.test(require('./powershell-command-v1.js').spellings(command));
  } catch (_error) {
    return true;
  }
}

function backendReading({ command, plain, tool, invocations, apiUrl, modeled, zensuName, platform }) {
  const ps = tool === 'PowerShell';
  const psHidden = ps && (/(?:^|\s)--%(?!\S)/.test(command)
    || apiNames(command.replace(/`/g, '')) > invocations.filter((c) => !c.derived).reduce((n, c) => n + apiNames(c.rest.join(' ')), 0));
  const envNamed = /ZENSU_API_URL/i.test(plain.replace(/`/g, '')) || (ps && spellsVariable(command));
  const envAppended = /(?:^|[^A-Za-z0-9_])ZENSU_API_URL\+=/.test(command);
  const oneWordTrusted = !/[$`{*?[\r]/.test(command)
    && !/(?:^|[^A-Za-z0-9_.-])(?:xargs|watch)(?![A-Za-z0-9_-])/iu.test(plain)
    && !(platform === 'win32' && command.indexOf('\\') !== -1)
    && (ps || modeled === (plain.match(new RegExp(zensuName.source, 'giu')) || []).length);
  return function backendLocal(invocation) {
    const rest = ps ? invocation.rest.map((w) => w.toLowerCase()) : invocation.rest;
    const exact = ps || invocation.exact === true;
    const raw = exact ? rest : shellWords(rest);
    const words = exact ? raw : raw.map(unquoted);
    const end = words.indexOf('--');
    const dyn = raw.findIndex(runTime);
    if (psHidden && dyn !== -1) return false;
    const read = oneWordTrusted && !invocation.derived && dyn === -1;
    let sure = false;
    for (let i = 0; i < words.length; i++) {
      const one = words[i].startsWith('--api-url=');
      if (!one && words[i] !== '--api-url') continue;
      if (!(one ? read && isLocalUrl(exact ? words[i].slice(10) : unquoted(words[i].slice(10))) : isLocalUrl(words[i + 1]))) return false;
      const before = i > 0 ? words[i - 1] : '';
      if ((end === -1 || i < end) && (dyn === -1 || i < dyn) && !(before.length > 1 && before.charAt(0) === '-' && before.indexOf('=') === -1)) sure = true;
    }
    if (sure) return true;
    if (Object.prototype.hasOwnProperty.call(invocation.envp, 'ZENSU_API_URL')) return !envAppended && isLocalUrl(invocation.envp.ZENSU_API_URL);
    return !envNamed && isLocalUrl(apiUrl);
  };
}

module.exports = { backendReading, isDynamic, isLocalUrl, runTime, shellWords, unquoted };
