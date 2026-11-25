# The linked session row

`/zensu:doctor` renders one `linked session:` row for a bound Claude Desktop session, that is, a
session whose environment carries `CLAUDE_CODE_HOST_SESSION_ID`. A session started outside the
desktop app gets no row. The row runs the lineage resolver the route hooks run, live, and says
where this session's own desktop record is and which session started it. A session that another
session started inherits that session's recorded `build` route only when its own record is found,
the parent's record sits beside it, and both project roots share one repository. An inherited
`build` is the parent's recorded choice, copied once, when the hooks settle this session's
lineage; `--auto` releases it. The `delivery route:` row names the route that applies; this row
explains the lineage behind it.

Relay the row as printed. Never edit, move or delete a desktop record or a store folder to turn
the row green, and never offer to: the records belong to Claude Desktop.

The hooks settle the lineage once per session and keep that answer
(`linked-session-<key>.json`); an inherited route is the snapshot they wrote at that moment
(`inherited-route-<key>.json`). The row reads both and compares them with its live answer, so a
row that resolves now can sit beside a route the session did not inherit, and the row says so.
It also reads the field the `delivery route:` row renders, so it can tell whether that snapshot
decides the route or this session's own route does.
Every inheritance statement of the live answer, such as
**a resolution made now inherits nothing**, is about a resolution made now: what this session
inherited is the snapshot, and the end of the row names it whenever the live answer does not
(§"What the hooks kept").

## Rows

- **✅ linked session: started from `<session>`, whose project root (`<path>`) is in the same
  repository** → the lineage resolves, and the row names the store that holds both desktop
  records. What follows says what the hooks did with it:
  - **so the hooks inherit that session's build route if it has recorded one by the time they
    settle this lineage** → the hooks have not settled this session's lineage yet;
  - **and this session inherited the build route that session had recorded** → the inheritance
    happened; the `delivery route:` row shows it unless this session's own marker decides;
  - **but nothing was inherited when this session settled its lineage, and a route that session
    records later does not reach this one** → the parent had no `build` route when the hooks
    settled this lineage, or the lineage did not resolve then. The user can still record the
    workflow for this session; say that /zensu:delivery-route --build records the workflow route
    for this session, and leave the choice to them;
  - **⚠️ but whether this session inherited a route could not be read** → a missing check rather
    than an all-clear: the inherited-route snapshot could not be read.
- **⚠️ … is in the same repository, but this session settled its lineage as none on an earlier
  prompt and keeps that answer, so it inherits nothing, while a session started from now on
  resolves its parent** → the hooks answered `none` before the record could be found, for example
  under a plugin release that did not search this store yet. While this session has no route of
  its own, the row names
  **/zensu:delivery-route --build records the workflow route for this session**; say so, and leave
  the choice to the user.
  - **✅ … keeps that answer, so it inherits nothing, while a session started from now on resolves
    its parent; the route this session has, …, decides instead** → this session's own marker or
    `hooks.defaultDeliveryRoute` decides its route, which the `delivery route:` row shows. Nothing
    is missing, so offer nothing.
  - When the hooks also kept an inherited build route that the `delivery route:` row follows, or
    the doctor could not read that snapshot or the route field, the row does not say that it
    inherits nothing and names no remedy; its end says what the hooks kept (§"What the hooks
    kept").
- A project root shown as **(not rendered — the recorded value carries a parenthesis this row
  cannot delimit)** is withheld on purpose: a path with a closing parenthesis could end the row's
  own parenthetical. Read the parent's root from its session instead.
- **✅ linked session: not started from another session** → the record names no starting session,
  so there is nothing to inherit.
- **✅ started from `<session>`, whose project root (`<path>`) is in another repository, and
  a route is never inherited across repositories**, or **whose Session Control record is not in
  this plugin's data (parent-context-unavailable)**, or **whose recorded project root no longer
  exists (parent-root-unavailable)** → a resolution made now inherits nothing, by design: the
  route is never carried across repositories or from a session whose project is gone. A session
  that resolved its lineage before that keeps what it inherited then, and the end of the row
  names it.
- **⚠️ started from `<session>`, whose project root (`<path>`)
  could not be compared with this session's** → a missing check rather than an all-clear: git named no repository for at least
  one of the two roots, because a root lies outside git or git failed or timed out. A resolution
  made now inherits nothing, and the hooks keep their answer for the rest of the session. A project outside git
  never inherits a route; when both roots are git work trees, a session started after the fault
  is resolved again.
- **⚠️ … own desktop record is in none of the `<N>` desktop session stores searched
  (own-record-missing)**, or the same row with **(no-session-store)** after a list of stores that
  all lack a usable folder → a store miss: no store this plugin reads holds this session's own
  record, so if another session started this one, a resolution made now cannot inherit that
  session's build route.
  The row lists every store searched, in the order the hooks search them, each with its state:
  - **no folder for this account and organization** — the store has no records of this account;
  - **no record of this session** — the store was searched and holds no record under this
    session's name;
  - **holds this session's record**;
  - **the same folder as an earlier store** — two names reach one folder, which is read once;
  - **refused: the store folder …**, **refused: its folder for this account …** or
    **refused: its folder for this organization …** — the named folder is a symbolic link,
    is not a directory, is owned by another account, is writable by group or others, or
    could not be inspected; the hooks never read such a store. The row names the folder that
    failed, not only its store.

  Session Hub profile stores are named by their profile folder, under the directory the row
  names. When this Claude Desktop keeps its records in a data folder of its own, the remedy is the
  row's own: name that folder's `claude-code-sessions` directory in ZENSU_CCD_EXTRA_STORES
  (several, separated by the platform's list separator), and remember that
  ZENSU_CCD_STORE replaces every other store, so a stale value there hides them all. When the
  row says **ZENSU_CCD_STORE is set, so it is the only store searched** and that
  `ZENSU_CCD_EXTRA_STORES` is not read, the remedy is to point that variable at the right
  directory or unset it. A changed store variable
  helps only a session whose lineage is still open when the change reaches its hooks: a session
  that already answered keeps its answer.
- **⚠️ … own desktop record cannot be found: there is no desktop session store to search
  (no-session-store)** → there is no store at all, and the row names the one cause that holds:
  ZENSU_CCD_STORE names no absolute path, and while it is set no other store is searched; or
  ZENSU_CCD_EXTRA_STORES names no absolute path and the platform's data directory is unknown
  (`HOME` on macOS, `XDG_CONFIG_HOME` or `HOME` on Linux, `APPDATA` or `LOCALAPPDATA` on Windows).
  The user corrects that variable or the environment the desktop app starts with.
- **⚠️ two desktop session stores hold this session's own record (own-record-ambiguous)** → which
  copy is its own cannot be told, so a resolution made now inherits nothing. Name both stores the
  row lists; the user
  removes the stale copy or sets `ZENSU_CCD_STORE` to the store that is current.
- **⚠️ … own desktop record … could not be read (own-record-unreadable)**, **was refused
  (own-record-refused)**, **names another desktop session (own-record-mismatch)**, **names
  another Claude Code session than this one (cli-session-mismatch)** or **names its starting
  session in a form this plugin does not accept (malformed-parent)** → the record was found and
  the lineage stops at it. A record the desktop has not yet updated for a new session id answers
  `cli-session-mismatch` until it does. Relay the reason; nothing in the plugin repairs a desktop
  record.
- **⚠️ started from `<session>`, whose desktop record is not readable beside this session's own
  (parent-record-unavailable)** or **names no Claude Code session id (parent-session-unknown)**
  → the parent's record is missing, private to another account or incomplete, so a resolution made
  now inherits nothing.
- **⚠️ started from `<session>`; whether a resolution made now inherits its build route was not checked
  — this plugin's Session Control records could not be read (records-unavailable)** → a missing
  check rather than an all-clear.
- **⚠️ linked session: not checked — …** → a missing check rather than an all-clear: the
  identity variables are malformed, `CLAUDE_CODE_SESSION_ID` did not reach the report, or the
  resolver could not be loaded or failed. Point at the cause the row names.

## What the hooks kept

The row ends with what the hooks kept for this session when that differs from what the live
answer suggests:

- **this session resolved its lineage as linked on an earlier prompt and keeps that answer** →
  the live answer is not the same-repository resolution, but the session keeps its earlier
  `linked`, and the row adds what it inherited then:
  - **and with it the build route it inherited from its parent then** → the `delivery route:`
    row follows that `build` unless this session's own marker decides, whatever the live answer
    says now;
  - **and nothing was inherited then** → no route reached this session from its parent;
  - **⚠️ but whether it inherited a route then could not be read** → a missing check rather than
    an all-clear: the inherited-route snapshot could not be read;
- **this session settled its lineage as none on an earlier prompt and keeps that answer** → no
  fix to a store or a record reaches this session any more. When the hooks kept no inherited
  route, or one that this session's own marker sets aside, the row adds that it inherits nothing,
  and then either that /zensu:delivery-route --build records the workflow route for this session,
  or, when this session's own marker or `hooks.defaultDeliveryRoute` decides its route,
  **the route this session has, …, decides instead**;
- **the hooks found no readable record on an earlier prompt and look once more on a later one,
  then keep that answer** → the hooks have one more look left; nothing to do;
- **the hooks have not settled this lineage yet** → they look once more on a later prompt when
  their first answer finds no readable record, then keep that answer;
- **the hooks also kept an inherited build route for this session although they kept no linked lineage answer**
  → an inherited-route snapshot without the linked answer that belongs beside it, which an
  interrupted settle can leave behind. The row goes on with what the snapshot does now:
  - **and this session's own marker sets it aside** → the `delivery route:` field comes from
    this session's own marker, or, after /zensu:delivery-route --auto released that marker, from
    `hooks.defaultDeliveryRoute` or the question, so the snapshot decides nothing;
  - **⚠️ and the delivery route follows it unless this session's own marker decides** → the
    field reads `build (inherited from parent session)`, or the doctor could not read it; the
    user can release the snapshot with /zensu:delivery-route --auto;
- **⚠️ whether the hooks kept an inherited route for this session could not be read** → a missing
  check rather than an all-clear: the doctor could not read the inherited-route snapshot;
- **⚠️ the answer the hooks kept for this session could not be read** → a missing check rather
  than an all-clear: the doctor could not read the session's lineage marker.
