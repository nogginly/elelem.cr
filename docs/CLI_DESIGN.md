# CLI Design

**Status**: Decisions settled so far, ahead of any code. Nothing under
`src/elelem/cli/` exists yet — this document is what it should be built
against, and the record of *why*, so a decision made once in conversation
doesn't get silently re-made differently later.

**Scope**: The `elelem` executable — config resolution, deployment naming,
session storage, and the verb grammar. Does not cover the `Archive` format
itself (`session.cr`'s own comment, `DEVELOPMENT.md` rule 2) or the session
tree/branching work `MPSH_SPECIFICATION.md` explicitly defers.

---

## What this is, and what it deliberately is not

A non-interactive, single-shot CLI: one invocation, one call to a provider,
one saved result. Not a REPL, not an agent framework, not a place for the
deferred session-tree/scatter-gather work to land — if that ever wants a
sentence-like grammar, it's a different, later tool built *on* `elelem`, not
a reason to complicate this one now.

## Ships inside this shard, not a separate project

`elelem` is both a library and a first-party CLI. `shard.yml` gains an
`executables:` entry; no new `dependencies:` entry, because both pieces the
CLI needs — YAML parsing, argument parsing — are already in Crystal's
stdlib. The zero-runtime-dependency posture stays true of what
`require "elelem"` pulls in.

```
src/elelem/            # the library — unchanged by any of this
  mpsh/archive.cr        # NEW, but a library concern: Session ↔ JSON,
                          # independent of the CLI existing at all

src/elelem/cli/        # NEW — CLI-only: config, session-folder naming, commands
  config.cr
  sessions.cr
  commands/
    start.cr
    continue.cr

src/bin/elelem.cr       # NEW — thin entrypoint: OptionParser, dispatch, done

examples/               # NEW — small, standalone, one file each, no CLI machinery
```

Reasoning: someone who `require`s `elelem` to build their own thing should
never transitively get config-file parsing or session-folder conventions
they didn't ask for. `cli/` under the same namespace keeps everything in one
shard and repo while keeping that boundary visible, the same instinct that
already keeps `mpsh/` from knowing HTTP exists.

## Verbs: `start`, `continue`

```
elelem start anthropic "What color is the sky on Mars?"    → SESSID
elelem continue SESSID "Why is that?"
elelem continue SESSID "Why is that?" --on azure-mini
```

Considered and rejected: `ask` (with `--continue` as a flag), and a
SQL-like "everything after `elelem` is one query" grammar.

- **`start`/`continue` over `ask`/`--continue`.** Continuing is a first-class
  operation on a conversation, not a modifier on asking — it deserves its own
  verb. `start` was chosen over `new` because it pairs with `continue` on the
  same axis (two things you can do to a conversation over time), where `new`
  pulls toward a noun-first grammar (`session new`) that isn't the one this
  tool uses anywhere else.
- **Verb-first over a sentence grammar.** SQL's "read the whole thing as one
  query" earns its complexity because SQL queries are genuinely
  compositional — joins, subqueries, an open-ended space. `elelem`'s
  operations are a small, fixed, enumerable set. A sentence grammar needs a
  real parser and fights shell tab-completion and scripting for no benefit
  this tool actually has. `git`, `docker`, `kubectl` all converged on
  verb-first for the same reason.
- **`--on` stays a flag**, not a third verb, because which deployment to
  continue *on* is genuinely optional and orthogonal — continuing itself is
  not.

Both verbs are thin CLI-layer wrappers over one library-level operation
(name TBD, lives under `cli/` or possibly promoted to the library proper if
it turns out other consumers want it too): resolve a `Provider`, load or
start a `Session`, call `Client#send`, hand back what to persist.

## Config: `elelem.yaml`

Search order: `$CWD/elelem.yaml`, then `$HOME/elelem.yaml`. A deployment
name is a config-level identity, deliberately distinct from a protocol —
the same separation `Provider.for` already enforces between server, protocol,
and vendor claim, so a name like `anthropic` can't be quietly ambiguous
between "the vendor" and "whatever's actually listening."

```yaml
deployments:
  anthropic:
    protocol: anthropic
    server: https://api.anthropic.com
    credential_env: ANTHROPIC_API_KEY
    model: claude-haiku-4-5

  azure-mini:
    protocol: chat_completions
    azure: true
    server: https://oxaro-alpha.openai.azure.com
    api_version: "2025-04-01-preview"
    credential_env: AZURE_OPENAI_API_KEY
    model: gpt5.4mini
    max_tokens_field: max_completion_tokens

  home-ollama:
    protocol: chat_completions
    server: http://localhost:11434
    model: llama3.2

default_deployment: anthropic
```

Credentials are referenced by environment variable name, never stored in the
file. `azure: true` selects `Provider.for_azure` over `Provider.for` at
resolution time — everything else in a deployment entry maps directly onto
that call's own parameters, so this table shouldn't need to invent a second
vocabulary as new deployment amendments arrive.

## Session storage

`$CWD/.elelem` if it exists, else `$HOME/.elelem`, else `$ELELEM_HOME` as a
final override — mainly for scripting and CI, where "home" may not mean
what it usually does. A `sessions/` subfolder, one folder per session.

Session IDs: generated, short, memorable — adjective-noun pairs (`brisk-comet`)
over a hash prefix, for the same reason git branch names and Docker container
names do this. Collision handling is a retry-on-directory-exists, nothing
cleverer.

Storage is snapshot-per-turn, not an append-only diff log: `Session`'s own
`Archive` form is already a complete point-in-time record — MPSH rebuilds
the full request from the whole history on every call regardless — so a
session's true state at any point already *is* a full snapshot, and storing
anything less would mean reconstructing what's already free to keep. Each
`continue` writes a new timestamped file into the session's folder; nothing
is overwritten. A future `--no-history` (or similar) to overwrite instead is
cheap to add later and isn't designed in now.

## Deliberately deferred, not forgotten

- **Tool execution.** `Client#send`'s turn loop, including tool dispatch, is
  caller-owned by design (`client.cr`'s own doc comment). Whether `elelem
  start`/`continue` take tool declarations at all in v1, or ship text-only
  first, is still open — leaning text-only first, since it's the smaller
  surface to get the verb grammar and storage shape right against.
- **Streaming.** Doesn't exist in the library yet (`DEVELOPMENT.md`'s event-block
  sketch is forward-looking design prose, not built) — so it can't exist in
  the CLI either. Not this document's problem to solve.
- **Interrupted-turn repair.** `SCOPE.md` MUST FIX, unbuilt. A `continue`
  against a session left dangling by a cut-short turn behaves however the
  library currently behaves — honest, not (yet) repaired.
- **`list`/`show` and any other session-inspection verbs.** Not designed yet;
  `start`/`continue` first.
