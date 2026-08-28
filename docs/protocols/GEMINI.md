# Gemini generateContent

Protocol identity `gemini`; vendor namespace `gemini`.

The checkpoint's other half, and the structurally most divergent of the four.
Written and structurally verified without a key.

## Why this one is the real test

Chat Completions and Responses share every assumption. Anthropic breaks the
structural ones. This protocol breaks an assumption the others all made without
noticing: **that a tool call has an identifier.**

It does not. A `functionCall` carries a name and arguments, and nothing else.
Calls are paired to responses by function name and ordering alone.

That is the case MPSH's identity decision exists for. A stored OpenAI `call_...`
cannot supply what this mapper needs, and a Gemini-originated session has no
identifier to store in the first place — so MPSH mints its own `call_id` and
keeps provider identifiers in translation state. The implementation plan called
retrofitting this "unusually painful"; the checkpoint is where it paid.

## Declared capabilities

Capability      |Declared                                        |Note                                                 
----------------|------------------------------------------------|-----------------------------------------------------
Binary content  |`Native`                                        |`inline_data` keeps mime type and base64 separate    
Tool calls      |`Block`                                         |A `functionCall` part                                
Tool results    |`TextOnly`                                      |Conservative — see *The response shape* below        
Reasoning       |`Block`                                         |Thought parts, with a signature                      
Reasoning unit  |`Either`                                        |`thinkingLevel` or `thinkingBudget`; **never both**  
Server-executed |`true`                                          |Code execution exists; no part is emitted for one yet
Refusal channel |`false`                                         |Carried as text                                      
Media accepted  |widest of the four, **including audio natively**|                                                     
String shorthand|**none**                                        |Every message is `{role, parts}`, always             

## Reasoning control: two units in one object

`thinkingConfig` holds both `thinkingLevel` and `thinkingBudget`, and setting
both is a **400 rather than a precedence rule** — the sharpest argument in the
suite for resolving the unit before anything is rendered. The 2.5 series takes a
budget and has no levels; levels arrived with Gemini 3, where a budget is
accepted only for backwards compatibility. `Capability::Catalog` decides which
per model.

Two smaller divergences follow from it:

- **Three rungs, not five.** `xhigh` and `max` have no spelling here, so they
  clamp to `HIGH` and the mapper records the loss — the same treatment a media
  type outside the accepted set receives, one axis over.
- **No clamp against the output cap.** Anthropic documents that its budget must
  sit below `max_tokens`; this protocol documents no such relationship, so none
  is invented. A budget of 0 disables thinking and -1 asks for dynamic thinking,
  which is the protocol's own idiom for "no constraint" and better than any
  number this shard could pick.
- **`includeThoughts` rides on the unit, not a separate option.** Without it,
  thinking still happens — and is billed — but neither thought text nor the
  signature a later turn needs to replay comes back; the API's default is to
  omit both, silently. Sent whenever a budget or level is, since there is no
  reason to ask for reasoning and not want to see it.

Unconfirmed, and flagged in `SCOPE.md`: whether a budget of 0 reliably disables
thinking on the levels-preferring series, which has no `off` rung of its own.

**Confirmed live, and the answer splits by tier, not by generation.** On
`gemini-3.5-flash`, a budget of 0 reliably disables thinking —
`usageMetadata` carries no `thoughtsTokenCount` at all, not zero, absent
(`spec/live/gemini_spec.cr`). On `gemini-3.1-pro-preview`, the same budget is
an active 400: `Budget 0 is invalid. This model only works in thinking mode.`
Not a silent no-op either way — the first run of the Pro test found this the
hard way.

`Capabilities::CANNOT_DISABLE_THINKING` is a closed, explicit list of models
confirmed to reject a zero budget outright, checked before a request is built
rather than after it fails. A model on the list gets its `Off` request
rendered as the lowest rung this protocol spells instead — a real,
recorded `Degraded` loss, not silently ignored — since the alternative is
either send an invalid request or send an unannounced one, and this shard
does neither. Deliberately a closed list rather than a substring match on
`"pro"`: a differently-behaved Pro model would be silently and wrongly
caught by the substring, where the list just doesn't grow until a live
rejection earns it a place, the same discipline `Catalog::BUDGET_ONLY`
already follows.

**Confirmed live: this protocol's `reasoning_signature_required` stays `false`,
and Anthropic's does not generalize here.** A plain-text `ReasoningBlock` with
no `provider_metadata` — the exact shape a foreign or unattributed reasoning
trace has — replays cleanly on a continuation turn
(`spec/live/gemini_spec.cr`). The signature enforcement that *is* real on this
protocol is narrower than Anthropic's: it is specific to `functionCall`, not
to reasoning text standing alone. See "Pairing without identifiers" below.

One consequence worth knowing before prompt caching arrives: like Anthropic,
this protocol renders the reasoning control into the prompt, so changing
either unit between turns invalidates cached prefixes.

## Structural divergences

Individually mechanical; collectively the reason this protocol is a real test.

Divergence                             |Consequence                                              
---------------------------------------|---------------------------------------------------------
The assistant role is spelled `model`  |The single most common source of a silently wrong mapping
Everything is `{role, parts}`          |No string shorthand to fall back on                      
Model name in the **URL path**         |`Request#path`, deliberately excluded from `to_json`     
`systemInstruction` is a content object|Not a bare string — `{parts: [{text: ...}]}`             
Generation settings nested             |Inside `generationConfig`                                

## Pairing without identifiers

Both directions count occurrences of each function name and agree on
`name#ordinal`, which is minted into an MPSH `call_id` through the same
`CallIdTable` the other protocols use for real identifiers.

Nothing is invented on the wire. An unexpected key is a request a provider can
reject, so no identifier field is added.

**The limit, stated because it cannot be detected:** this works because
responses arrive in the order their calls were made. A provider that reordered
them, or omitted one, would break the correspondence, and there is nothing in
the wire to notice with.

**A real field arrived on Gemini 3, found live rather than assumed.**
`functionCall` carries a `thoughtSignature` as a sibling field on the same
part — not a separate `ThoughtPart` preceding it — and Gemini 3 enforces it
strictly on replay: omitting it is a 400
(`Function call is missing a thought_signature in functionCall parts`),
confirmed against a real endpoint (`spec/live/gemini_spec.cr`), not merely
documented. Optional on the 2.5 series, which is why the model chosen for a
tool-call test matters here in a way it doesn't on the other three protocols.

Captured and replayed the same way a `ThoughtPart`'s signature is —
`provider_metadata`, same key — so `export.cr` and `mapper.cr` round-trip it
on this protocol's own history.

### A foreign tool call, and why the check is keyed on the model

A `ToolCallBlock` handed to this protocol from elsewhere has no such metadata
and none to offer. That is the same shape of question the Anthropic
`reasoning_signature_required` fix answered for reasoning blocks, and it now
has the same shape of answer: `Profile#tool_call_signature_required?`, checked
by `Resolver` ahead of `own?`, reporting `Degraded` rather than sending a
request that cannot succeed. The call is dropped, the loss is annotated, and a
`Strict` caller still gets a refusal.

The one thing that is *not* like the Anthropic fix is where the flag is
declared. `reasoning_signature_required` sits on Anthropic's `PROFILE`, true
for the whole protocol. This one sits in `Capability::Catalog::SIGNED_TOOL_CALLS`,
keyed on the model, because the requirement arrived with Gemini 3 and the 2.5
series does not have it.

Declaring it protocol-wide was written first and rejected. The two errors are
not symmetric:

Wrong how                      |What happens                                                                          |Cost                 
-------------------------------|--------------------------------------------------------------------------------------|---------------------
Protocol-wide, on a 2.5 model  |Every tool call handed to that deployment is dropped, with only an annotation         |Silent, permanent    
Catalog, on an unlisted 3 model|A 400 naming the missing field outright — the error that found this in the first place|Loud, one line to fix

`catalog.cr`'s own rule about silent misfires being this project's most
expensive failure mode is the same judgement one level down, so the catalog
default stays optimistic here even though the argument that justified optimism
for `BUDGET_ONLY` — a closed, shrinking exception list — runs the other way on
this axis. Both comments say so explicitly; read them together before adding a
third axis.

**Expect to add entries.** Only spellings this repository has actually
observed are listed, because a wrong entry fails in the silent direction while
a missing one does not. Guessing at plausible siblings only helps in the
direction that hurts.

## The response shape

`functionResponse.response` is an **object** on this protocol, not a string. We
write `{"output": ...}` and read that key back.

That is a convention we chose, not something the protocol dictates. A session
produced by another Gemini client will have used a different shape, so export
keeps the whole JSON as text rather than guessing at a key that may not exist.

`tool_results` is declared `TextOnly` conservatively, pending confirmation that
`functionResponse` can carry inline binary data. If it can, this becomes
`Blocks` and the image-bearing tool result stops compensating here — a change to
the declaration alone, with no mapper change and no test change.

## Compensation

Same placeholder constant, same rules, same deferral as elsewhere.

Worth recording that the deferral condition was **wrong here first**. The mapper
flushed carriers only before user messages, so a carrier landed after the
model's reply, where export could no longer see the tool results it belonged to.
Two divergences from one missing case: a message count off by one, and an image
that stayed a placeholder.

The rule is identical across three mappers and was expressed differently in each
— see `../../SCOPE.md` on extracting it before a fifth protocol arrives.

## Conformance

`spec/conformance/gemini_spec.cr`. Fourteen fixtures round-trip untouched,
including both audio cases, which this protocol takes natively.

Fixture                          |Expected                                            
---------------------------------|----------------------------------------------------
`tool_call_text_result`          |Exact — pairing reconstructed with no identifier    
`tool_call_image_result`         |Compensated; refuses under strict policy            
`audio_with_transcript`          |**Exact** — audio is native here, unlike Anthropic  
`server_executed_tool`           |Degraded — the concept exists, this tool is not ours
`reasoning_with_provider_payload`|Another vendor's payload dropped, and named         
