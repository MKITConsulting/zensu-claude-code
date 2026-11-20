'use strict';

const fs = require('fs');

const fixtureDir = process.argv[2];
const args = process.argv.slice(3);
const own = Object.prototype.hasOwnProperty;
const INT64_MIN = -(2n ** 63n);
const INT64_MAX = 2n ** 63n - 1n;

function unmodelled() {
  process.stderr.write('fake gh: unmodelled call: ' + args.join(' ') + '\n');
  process.exit(2);
}

function typed(value) {
  if (value.charAt(0) === '@') unmodelled();
  if (/^[+-]?[0-9]+$/.test(value)) {
    const number = BigInt(value);
    if (number >= INT64_MIN && number <= INT64_MAX) return number;
  }
  if (value === 'true') return true;
  if (value === 'false') return false;
  if (value === 'null') return null;
  return value;
}

if (args[0] !== 'api') unmodelled();
let endpoint = null;
let paginate = false;
let slurp = false;
let query = '';
const vars = {};
for (let i = 1; i < args.length; i++) {
  const flag = args[i];
  if (flag === '--paginate') paginate = true;
  else if (flag === '--slurp') slurp = true;
  else if (flag === '--hostname' || flag === '-H' || flag === '--header') {
    if (++i >= args.length) unmodelled();
  } else if (flag === '-f' || flag === '--raw-field' || flag === '-F' || flag === '--field') {
    if (++i >= args.length) unmodelled();
    const at = args[i].indexOf('=');
    if (at < 1) unmodelled();
    const key = args[i].slice(0, at);
    const raw = args[i].slice(at + 1);
    const value = flag === '-F' || flag === '--field' ? typed(raw) : raw;
    if (key === 'query') query = String(value);
    else vars[key] = value;
  } else if (endpoint === null) endpoint = flag;
  else unmodelled();
}
if (endpoint !== 'graphql' || (slurp && !paginate)) unmodelled();

function print(pages) {
  process.stdout.write(slurp ? '[' + pages.join(',') + ']' : pages.join(''));
}

function refuse(errors, data) {
  print([JSON.stringify(data === undefined ? { errors } : { data, errors })]);
  process.stderr.write('gh: ' + errors.map((error) => error.message).join('\n') + '\n');
  process.exit(1);
}

function messages(list) {
  return list.map((message) => ({ message }));
}

if (process.env.FAKE_REVIEWS === 'fail') refuse(messages(['fixture: the review listing failed']));

const head = /^\s*(?:query\s*(?:\(([^)]*)\))?\s*)?\{/.exec(query);
if (!head) unmodelled();
const declaration = /\$(\w+)\s*:\s*(\w+)\s*(!?)/g;
const header = head[1] || '';
if (header.replace(declaration, '').replace(/[\s,]/g, '')) unmodelled();
const declared = [];
for (const found of header.matchAll(declaration)) {
  if (found[2] !== 'String' && found[2] !== 'Int') unmodelled();
  declared.push({ name: found[1], type: found[2] + found[3], int: found[2] === 'Int', nonNull: found[3] === '!' });
}

const body = query.slice(head[0].length);
const path = /^\s*repository\s*\(([^)]*)\)\s*\{\s*pullRequest\s*\(([^)]*)\)\s*\{\s*reviews\s*(?:\(([^)]*)\))?\s*\{/.exec(body);
if (!path) unmodelled();

function bindings(list, keys) {
  const bound = {};
  for (const part of list.split(',')) {
    const pair = /^\s*(\w+)\s*:\s*\$(\w+)\s*$/.exec(part);
    if (!pair || own.call(bound, pair[1])) unmodelled();
    bound[pair[1]] = pair[2];
  }
  if (Object.keys(bound).sort().join(',') !== keys) unmodelled();
  return bound;
}

const repository = bindings(path[1], 'name,owner');
const pullRequest = bindings(path[2], 'number');
const connection = {};
if (path[3] !== undefined) {
  for (const part of path[3].split(',')) {
    const pair = /^\s*(?:(first|last)\s*:\s*(-?[0-9]+)|(after|before)\s*:\s*\$(\w+))\s*$/.exec(part);
    const key = pair && (pair[1] || pair[3]);
    if (!pair || own.call(connection, key)) unmodelled();
    connection[key] = pair[1] ? Number(pair[2]) : pair[4];
  }
}

function selection(from) {
  let depth = 0;
  let flat = '';
  for (let j = from; j < body.length; j++) {
    const c = body.charAt(j);
    if (c === '{') depth++;
    else if (c === '}') {
      if (!depth) {
        const fields = flat.replace(/\([^)]*\)/g, ' ').split(/[\s,]+/).filter(Boolean);
        return { fields, end: j + 1 };
      }
      depth--;
      if (!depth) flat += ' ';
    } else if (!depth) flat += c;
  }
  unmodelled();
}

const reviews = selection(path[0].length);
if (!/^\s*\}\s*\}\s*\}\s*$/.test(body.slice(reviews.end))) unmodelled();
if (reviews.fields.some((field, k) => (field !== 'nodes' && field !== 'pageInfo') || reviews.fields.indexOf(field) !== k)) unmodelled();

function inner(name) {
  if (!reviews.fields.includes(name)) return null;
  const pattern = new RegExp('\\b' + name + '\\s*\\{', 'g');
  pattern.lastIndex = path[0].length;
  const found = pattern.exec(body);
  if (!found) unmodelled();
  return selection(found.index + found[0].length).fields;
}

const nodeFields = inner('nodes');
const infoFields = inner('pageInfo');

const used = [];
for (const found of body.matchAll(/\$(\w+)/g)) if (!used.includes(found[1])) used.push(found[1]);
const names = declared.map((d) => d.name);
const problems = [];
for (const d of declared) if (!used.includes(d.name)) problems.push('Variable $' + d.name + ' is declared by anonymous query but not used');
for (const name of used) if (!names.includes(name)) problems.push('Variable $' + name + ' is used by anonymous query but not declared');
if (problems.length) refuse(messages(problems));

for (const [variable, type] of [[repository.owner, 'String!'], [repository.name, 'String!'], [pullRequest.number, 'Int!']]) {
  if (!declared.some((d) => d.name === variable && d.type === type)) unmodelled();
}

function invalid(values) {
  return declared.filter((d) => {
    const value = own.call(values, d.name) ? values[d.name] : null;
    if (value === null) return d.nonNull;
    return d.int ? typeof value !== 'bigint' : typeof value !== 'string';
  }).map((d) => 'Variable $' + d.name + ' of type ' + d.type + ' was provided invalid value');
}

const invalidValues = invalid(vars);
if (invalidValues.length) refuse(messages(invalidValues));

const owner = vars[repository.owner];
const name = vars[repository.name];
if (owner !== 'acme' || name !== 'widget') {
  refuse([{ type: 'NOT_FOUND', path: ['repository'], message: "Could not resolve to a Repository with the name '" + owner + '/' + name + "'." }],
    { repository: null });
}
const number = vars[pullRequest.number];
if (number !== 42n) {
  refuse([{ type: 'NOT_FOUND', path: ['repository', 'pullRequest'], message: 'Could not resolve to a PullRequest with the number of ' + number + '.' }],
    { repository: { pullRequest: null } });
}

const reviewsPath = ['repository', 'pullRequest', 'reviews'];
const unpaged = { repository: { pullRequest: { reviews: null } } };
if (!own.call(connection, 'first') && !own.call(connection, 'last')) {
  refuse([{ type: 'MISSING_PAGINATION_BOUNDARIES', path: reviewsPath, message: 'You must provide a `first` or `last` value to properly paginate the `reviews` connection.' }], unpaged);
}
if (own.call(connection, 'first') && own.call(connection, 'last')) {
  refuse([{ path: reviewsPath, message: 'Passing both `first` and `last` to paginate the `reviews` connection is not supported.' }], unpaged);
}
if (!own.call(connection, 'first')) unmodelled();
if (connection.first < 0) {
  refuse([{ type: 'INVALID_PAGINATION', path: reviewsPath, message: '`first` on the `reviews` connection cannot be less than zero.' }], unpaged);
}
if (connection.first > 100) {
  refuse([{ type: 'EXCESSIVE_PAGINATION', path: reviewsPath, message: 'Requesting ' + connection.first + ' records on the `reviews` connection exceeds the `first` limit of 100 records.' }], unpaged);
}

const fixture = (process.env.FAKE_PAGES || 'page1.json page2.json').split(' ')
  .map((file) => JSON.parse(fs.readFileSync(fixtureDir + '/' + file, 'utf8')));

function reviewsOf(page) {
  return page.data.repository.pullRequest.reviews;
}

function after(value) {
  if (value === null || value === undefined) return 0;
  for (let k = 0; k < fixture.length - 1; k++) if (reviewsOf(fixture[k]).pageInfo.endCursor === value) return k + 1;
  unmodelled();
}

function pick(object, fields) {
  const copy = {};
  for (const field of fields) {
    if (!own.call(object, field)) unmodelled();
    copy[field] = object[field];
  }
  return copy;
}

const request = Object.assign({}, vars);
const served = [];
const pages = [];
for (;;) {
  if (connection.before && request[connection.before] != null) unmodelled();
  const index = after(connection.after ? request[connection.after] : null);
  if (served.includes(index)) unmodelled();
  served.push(index);
  const source = reviewsOf(fixture[index]);
  if (source.nodes.length > connection.first) unmodelled();
  const shaped = {};
  if (nodeFields) shaped.nodes = source.nodes.map((review) => pick(review, nodeFields));
  if (infoFields) shaped.pageInfo = pick(source.pageInfo, infoFields);
  pages.push(JSON.stringify({ data: { repository: { pullRequest: { reviews: shaped } } } }));
  const info = shaped.pageInfo;
  if (!paginate || !info || info.hasNextPage !== true || typeof info.endCursor !== 'string' || !info.endCursor) break;
  request.endCursor = info.endCursor;
  if (invalid(request).length) unmodelled();
}
print(pages);
