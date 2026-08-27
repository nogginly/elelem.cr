# Azure OpenAI

The server that amended the design rather than merely exercising it. Where
Ollama forces `Server`, `Provider` and vendor apart by serving three protocols
from one host under none of their own names, Azure forces `Adapter` apart from
`Capability::Profile`: it proves path and auth are protocol-*plus*-deployment
facts, not protocol facts alone.

Companion to `docs/protocols/CHAT_COMPLETIONS.md` and `RESPONSES.md`, which
describe the two protocols as specified. This describes one deployment's
implementation of both, and where it diverges from plain OpenAI.

## What it serves

Protocol        |Path                                               |Deployment identity                |Auth     
----------------|---------------------------------------------------|-----------------------------------|---------
Chat Completions|`/openai/deployments/{deployment}/chat/completions`|path segment                       |`api-key`
Responses       |`/openai/responses`                                |body `model` field, no path segment|`api-key`

Both require a dated `api-version` query parameter with no default this shard
supplies — see `Provider.for_azure`'s own doc comment for why.

**The two paths disagree with each other in kind, not just in spelling.**
Confirmed against a live deployment's own portal before either adapter was
written, because the documentation for the Responses path disagreed with
itself: some pages describe an undated `v1` surface with the deployment in the
body only, others a dated, path-based one matching Chat Completions'
convention. What actually answered was `/openai/responses` — no deployment
segment, `api-version` still required. So `AzureChatCompletionsAdapter` and
`AzureResponsesAdapter` exist as separate classes rather than one adapter with
a protocol switch inside `path`; the asymmetry is real, not an implementation
convenience.

## Auth

`api-key`, a plain header value — never `Authorization: Bearer`. Confirmed
live: the 400s and successes both came back keyed correctly once the header
name was right, and Wiretap's default `filter_headers` did not originally
cover it — `Api-Key` is a different header name from `X-Api-Key`, not merely
different casing, so it needed adding explicitly until Wiretap 0.4.1 started
covering it by default. See `spec/spec_helper.cr`.

## Divergences found by recording

### Reasoning models reject `max_tokens`

Not really an Azure fact — an OpenAI fact this shard had no live Chat
Completions coverage to have found earlier. `gpt5.4mini`, a reasoning-capable
deployment, returned `HTTP 400 — Unsupported parameter: 'max_tokens' is not
supported with this model. Use 'max_completion_tokens' instead.` on first
contact. Detail and the fix: `docs/protocols/CHAT_COMPLETIONS.md`'s own *Live
finding* section, `Wire::MaxTokensField`.

### The system-prompt divergence is not protocol-specific — or Azure-specific

Both adapters returned `Restructured`, never `Exact`, for a plain exchange
carrying a system prompt. This was already pinned structurally by
`spec/conformance/layer_spec.cr` before this server was recorded — MPSH holds
a system prompt as a session field, and turning it into any wire form, even
one a protocol calls native, is a restructuring of MPSH's own shape. Worth
recording here anyway: a live 400 earlier in this same effort was nearly
mistaken for a second protocol bug before the assertion itself turned out to
be wrong, twice. A committed, tested claim beat a live surprise on both
occasions; the live call confirmed the claim rather than contradicting it.

### The deployment name is not the model name

Azure lets an operator call a deployment anything —
`gpt5.4mini`, `gpt-5.6-terra`, `prod-reasoning-2`, whatever was typed into the
portal. Two consequences, both already handled rather than newly found here:

- `Capability::Catalog` resolves `reasoning_unit` by exact model string, so an
  arbitrary deployment name simply falls through to the default. Inert for
  both these protocols regardless, since neither has an ambiguous unit to
  resolve (`reasoning_unit: Effort` on both) — the problem is real for
  Anthropic and Gemini behind a gateway, not here.
- The new `max_tokens` vs `max_completion_tokens` choice has the identical
  shape and the identical fix: an explicit per-deployment override
  (`Wire::MaxTokensField`), not a catalog lookup, because a deployment name
  carries no model identity a catalog could match against. See *`max_tokens`
  vs `max_completion_tokens`* in `SCOPE.md`.

## What a green run here does not prove

Two live calls, both plain text, both capped at 64 tokens, against one
reasoning-capable deployment on one Azure resource. This proves path and auth
are right and that the field-name fix works for a model that needed it. It
does **not** exercise tools, reasoning control, compensation, or a
non-reasoning deployment that still wants `max_tokens` — those remain
protocol-level claims already covered by the Ollama and direct-vendor suites,
or open items in `SCOPE.md`. Azure was sequenced to prove the adapter
amendment, not to re-prove the protocol underneath it.
