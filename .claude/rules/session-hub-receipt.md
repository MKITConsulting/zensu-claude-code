---
paths:
  - "hooks/user-prompt-session-hub-receipt.sh"
  - "hooks/lib/session-hub-receipt-v1.mjs"
  - "skills/session-trail/handover-contract.json"
  - "tests/structure/test-session-hub-receipt.sh"
  - "tests/structure/session-hub-receipt-v1.test.js"
---

# Session Hub Receipt (`hooks/user-prompt-session-hub-receipt.sh` + `session-hub-receipt-v1.mjs`)

The Zensu Session Hub (a separate macOS app in `MKITConsulting/zensu-session-hub`) hands a
session to another account by typing `/zensu:session-trail takeover <session id> --all
--receipt <token>` into a new Code session of that account. The hook writes
`<config root>/zensu/session-hub/v1/receipts/<token>.json` when exactly that prompt arrives, and
the Hub reads that one file to tell a command the plugin received from one that reached a session
where the plugin did not load. The Hub renames both sessions only after it read the receipt.

**`handover-contract.json` is the Hub's contract with this skill.** The Hub refuses to type
anything unless every applicable install of this plugin declares `takeover.contract` 1 with
exactly these `prefix`, `suffix` and `receipt` strings and this receipt directory. The Hub never
takes text to type from the file; it only compares. Changing any value, or the grammar the module
accepts, is a contract change: give it a new `contract` number and change the Hub in step.
`test-session-hub-receipt.sh` R3 pins the file byte for byte, and the unit suite requires the
module's constants to equal it.

**The grammar is exact.** The raw prompt, or the command-tag spelling with `command-name`
`/zensu:session-trail` and `command-args` `takeover <session id> --all --receipt <token>`, after
leading `<system-reminder>` blocks. The session id is a lowercase hyphenated UUID and the token 32
lowercase hexadecimal characters. Everything else writes nothing.

**What the receipt holds.** `schemaVersion`, `kind`, `token`, `event`, `plugin` and `recordedAt`.
It deliberately names no session, path or account, so `lineage --forget` has nothing to remove
from it and it is no handover record: the lineage edge is still written only after the plan
confirmation (`references/takeover.md` step 0 states the exception). Retention is seven days,
pruned on each write while examining at most 512 entries. `hooks.sessionHubReceipt: false` turns
it off; the Hub then reports every handover as not confirmed.

**The hook never blocks.** It exits 0 on every path, including a `CLAUDE_PLUGIN_ROOT` that names
another installation, which its siblings answer with exit 2: exit 2 on `UserPromptSubmit` would
erase the prompt the Hub typed. It prints nothing, because plain stdout becomes model context.
It writes only while `SKILL.md` and `scripts/trail.mjs` exist, because a receipt claims the skill
can run.

**Store safety reuses the ledger's guard.** `ensureLedgerDir` refuses a symlinked or non-directory
component below the config root and leaves the directories at 0700; the file lands 0600 through a
temp file and `link`, so an existing receipt is never replaced. Pruning checks the directory with
`ledgerPathUnlinked` first and unlinks only regular files whose names match the receipt or temp
shape.

**`trail.mjs` accepts `--receipt <token>` on `show`, `handoff` and `takeover` and ignores it**, so
the model may pass the Hub's arguments on unchanged. `L66d` in `test-session-trail-lineage.sh`
counts the flag in both `parseArgs` and `refuseForeignFlags`.

## Version

`patch`, walked against `.claude/rules/runtime-lineage.md`: an advisory `UserPromptSubmit` hook
with no output at all, a permissively read config key, an accepted flag and a new data file. No
schema field, strict key set, matcher or `permissionDecision` changes.

## Known gaps

- Whether Claude Desktop's bundled Claude Code fires `UserPromptSubmit` for a typed plugin slash
  command, and in which spelling, was not measured; both spellings are accepted.
- A `CLAUDE_CONFIG_DIR` set for the receiving session moves the receipt where the Hub, which reads
  only `~/.claude`, does not look; the Hub then reports the handover as not confirmed.
