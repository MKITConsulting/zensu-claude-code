#!/bin/bash
# The ONE spelling of the skill-slug character class that README skill-table rows
# are matched with. NOT a suite — `tests/run-all.sh` iterates `structure/test-*.sh`,
# so this name is deliberately outside that glob and is sourced, never executed.
#
# WHY IT IS SHARED. The class was hand-written in three places, all of them reading
# `README.md`: the row-count grep and the JS row regex in test-chain-recover.sh T39,
# and the header-vs-rows check in test-converge-skill.sh P4c. It was `[a-z-]+` in all
# three, so a skill named like `review-v2` would have dropped out of the row count AND
# surfaced as registered-but-unlisted — failing T39 twice for a reason neither message
# names, while P4c failed with a message about counts. Widening it meant three edits
# that nothing forced to happen together.
#
# WHAT THIS FILE DOES NOT DO. It shares a CONSTANT, not an assertion. The registry
# invariant itself — header count, row count, the "N skills are registered" figure,
# both set differences and the unlisted exemption — still lives in T39, its
# header-vs-rows half is still duplicated in P4c, and every per-skill suite still
# carries its own registration pin. Extracting that invariant into a dedicated
# tests/structure/test-skill-registry.sh remains the right move and remains deliberately
# NOT done here: moving a checked invariant is a change that needs its own review, and
# a constant can be shared without moving one.
SKILL_SLUG_CLASS='[a-z0-9-]+'
