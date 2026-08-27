# Responses API

Protocol identity `openai.responses`; vendor namespace `openai`, shared with
Chat Completions.

Phase 2 of `../IMPLEMENTATION_PLAN.md`. Runs against local servers with no key.

## What this phase proves, and what it does not

This protocol differs from Chat Completions in surface and shares every
underlying assumption: flexible roles, no alternation rule, string shorthand
permitted, model in the request body. **Passing both proves the mapper works; it
does not prove the abstraction works.** That is the checkpoint's job, against a
protocol from another family.

One capability genuinely diverges, and it is the only fixture in the suite where
two protocols in the same family disagree — see *Reasoning as an item* below.

## Declared capabilities

Capability     |Declared      |Note                                                            
---------------|--------------|----------------------------------------------------------------
Binary content |`DataUri`     |Fused at map time, split on export                              
Tool calls     |`Field`       |A `function_call` item, not a message field                     
Tool results   |`TextOnly`    |`function_call_output.output` is a string — compensation applies
Reasoning      |`Item`        |**Carries an opaque payload**, unlike a text field              
Reasoning unit |`Effort`      |`reasoning.effort` — the same rungs as Chat Completions, nested 
Server-executed|`true`        |Built-in tools exist; no item is emitted for one yet            
Refusal channel|`true`        |A distinct refusal content type                                 
System prompt  |`Instructions`|A top-level parameter, not a message                            

## The shape: items, not messages with fields

There are no messages with sibling fields here. There is one flat `input` array
of **items**, and a message is merely one item type among several. A tool call
is an item, its output is an item, a reasoning trace is an item.

That sits closer to MPSH's block list than Chat Completions does, and makes both
directions shallower: nothing is hoisted, so nothing needs un-hoisting.

The export direction has one wrinkle in exchange. Assistant items arrive
separately — reasoning, then a call, then a message — but describe **one** MPSH
message, so they are gathered and flushed at a boundary rather than emitted one
per item.

## Reasoning as an item

The divergence from Chat Completions, and the clearest evidence in the suite
that the capability model does real work.

A `reasoning` item carries `encrypted_content` and an `id`. Redacted reasoning —
a block with no text, whose content is an opaque payload in `provider_metadata`
— therefore **round-trips exactly here** and **degrades on Chat Completions**,
whose `reasoning_content` is a string with nothing to hold.

Same fixture, same suite, opposite outcomes, decided by declared capability with
no protocol-specific test code anywhere.

## Compensation

`function_call_output.output` is a string, so an image-bearing tool result needs
the same treatment as on Chat Completions: a placeholder in the output item plus
a synthesized user message carrying the content.

`COMPENSATION_PLACEHOLDER` is the same constant, with the same rules — a
protocol marker rather than a note to a human, byte-identical in both
directions, and improving the wording is a breaking change.

Carriers are deferred past the run of tool outputs for the same reason as
elsewhere: strict servers require every output answering one turn to precede
anything else. See `../../SCOPE.md` on extracting this shared logic.

## Statefulness, deliberately unused

This protocol can hold history server-side — `previous_response_id` chaining, or
a Conversations object — and accept only the new turn.

We target the stateless mode. Three reasons, in order of weight:

- A handle is a **disposable optimization over an authoritative local record**.
  The moment a session is handed to another vendor, the handle is worthless and
  the canonical record is all there is.
- Handles, bindings and drift detection are Phase 5. `MPSH::CallIdTable` is
  shaped like what a binding will hold, and is the only piece present early.
- It saves **transfer, not cost**: OpenAI bills the full reprocessed context as
  input tokens on every call in a chain regardless.

When handles arrive they live in a provider binding, never in the profile.

## Azure

Same wire shape as plain OpenAI Responses — nothing in this document changes.
Only path and auth differ, in `AzureResponsesAdapter`.

**Unlike Azure's own Chat Completions surface, the deployment is not in the
path here.** Confirmed against a live deployment's own portal rather than
documentation, which disagreed with itself on this point (some pages describe
an undated `v1` surface with the deployment in the body only; others a dated,
path-based one). What is actually served: `/openai/responses`, deployment name
in the body's `model` field exactly as `Protocol::Responses::Mapper` already
writes it, `api-version` as a required dated query parameter. So Azure amends
Chat Completions and Responses **differently from each other**, not by one
shared rule — the asymmetry `AzureChatCompletionsAdapter` and
`AzureResponsesAdapter` exist separately to express.

Built via `Provider.for_azure(server, ProtocolKind::Responses, api_version, ...)`.

Reasoning unit is `Effort` here too, so the deployment-name-is-not-a-model-name
problem that matters for Anthropic and Gemini is inert on this protocol as
well — see the equivalent note in `CHAT_COMPLETIONS.md`.

### Live finding: the path shape held, and so did the system-prompt divergence

`/openai/responses` with no deployment segment was confirmed against a real
Azure resource's own portal before this section first existed; `spec/live/azure_spec.cr`
confirms it was also the URL that actually answered — the recorded interaction
matches on exactly that path and query, so a wrong guess here would have
surfaced as a transport error, not a subtle one.

Same session, same system prompt, same result as Chat Completions:
`Restructured`, never `Exact`, for the reason `CHAT_COMPLETIONS.md`'s
equivalent note gives — this is a fact about MPSH's own shape, not this
protocol's declared placement, so it was never going to differ by server.

## Conformance

`spec/conformance/responses_spec.cr`. Sixteen fixtures round-trip untouched.

Fixture                          |Expected                                               
---------------------------------|-------------------------------------------------------
`reasoning_with_provider_payload`|**Exact** — the payload survives as an item field      
`tool_call_image_result`         |Compensated; refuses under strict policy               
`server_executed_tool`           |Degraded — no item is emitted for a tool we did not run
`reference_payload`              |Refuses — no blob store configured                     
