# Chat Completions

Protocol identity `openai.chat_completions`; vendor namespace `openai`.

Phase 1 of `../IMPLEMENTATION_PLAN.md`. Runs against local servers with no key,
which is why it is first — and it is also the protocol that *cannot* express an
image-bearing tool result, so it exercises compensation on day one rather than
after the machinery has settled around protocols that never needed it.

## Declared capabilities

Capability     |Declared    |Note                                                                                           
---------------|------------|-----------------------------------------------------------------------------------------------
Binary content |`DataUri`   |Fused at map time, split again on export. Never stored fused                                   
Tool calls     |`Field`     |Hoisted onto the assistant message as `tool_calls`                                             
Tool results   |`TextOnly`  |A `role: "tool"` message whose content is a string. **The constraint that forces compensation**
Reasoning      |`Field`     |See below — this one is a judgement call                                                       
Server-executed|`false`     |No concept of provider-run tools                                                               
Refusal channel|`true`      |A distinct `refusal` field, which Anthropic and Gemini lack                                    
Alternation    |not required|Consecutive same-role messages are accepted                                                    
System prompt  |`InMessages`|A message, not a parameter                                                                     

### One protocol, two plausible profiles

`reasoning: Field` refers to `reasoning_content`, which is **not** in OpenAI's
specification. It is a de-facto extension implemented by vLLM, Ollama and others
serving reasoning models over this protocol.

We declare `Field` because that is what the servers this protocol actually
reaches will accept. A profile targeting OpenAI's own endpoint strictly would
declare `None`, and reasoning would degrade rather than replay.

This is the clearest evidence so far that a `Profile` describes a **wire shape**,
not an endpoint — and it is the same observation from the other direction as
Ollama, LM Studio and vLLM all sharing this one profile.

### Redacted reasoning does not survive

A string field carries text. Redacted reasoning is by definition a block with no
text, whose content sits in `provider_metadata`. There is nothing to put in the
field, so the block is **Degraded** and does not come back on export.

This corrected the capability matrix, which had claimed Exact on the grounds
that the protocol supports reasoning and the vendor owns the block. Both were
true; neither was sufficient.

## Compensation

A tool result here is a string, so a tool returning a screenshot cannot be
expressed. The canonical form — one user message holding a `tool_result` whose
nested content is `[text, image]` — renders as **two** wire messages:

```
{"role": "tool", "tool_call_id": "call_a",
 "content": "Captured at 1280x720.\n[elelem: content returned separately in the following message]"}
{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}]}
```

The second message is **request-time output only**. What returns to MPSH is the
assistant's reply, never the scaffolding that made the request legal.

### The placeholder is a protocol marker

`Mapper::COMPENSATION_PLACEHOLDER` is not a note to a human. Export recognises
scaffolding by its shape, and this exact string is part of that shape: it marks
the block boundary that content was lifted out of, and export splits the result
string on it to restore that boundary.

Consequences: it must stay stable, stay byte-identical in both directions, and
stay distinctive enough not to collide with genuine tool output. **Improving the
wording is a breaking change.** Splitting on the marker rather than on newlines
is deliberate — real tool output contains newlines.

### Carriers are deferred, not inline

A single assistant turn may request several tools in parallel. Strict servers —
Azure's OpenAI endpoint among them — require every `role: "tool"` message
answering that turn to appear before anything else, and reject scaffolding
interleaved between tool responses. Permissive servers such as Ollama and LM
Studio accept either.

So carriers are buffered and flushed at turn boundaries: when genuine user
content appears, when an assistant turn begins, or at the end of the request.
Several results' worth of content may ride in **one** carrier.

Recorded as `Structural::Adaptation::DeferCompensationCarrier`, because it is a
sequence-level adaptation that no per-block rule can express.

## Export

Three signals, in descending reliability.

Signal                                     |Reliability          |Recovers                         
-------------------------------------------|---------------------|---------------------------------
`call_id` pairing                          |Exact — explicit     |Which result answers which call  
Position plus the placeholder marker       |Strong — our constant|Carrier versus genuine user input
Message boundaries between adjacent results|**Not recoverable**  |Nothing that affects meaning     

`assistant → tool → tool` is never inferred from adjacency; each result names the
call it answers, so pairing survives reordering.

### Declared limit: tool-result boundaries collapse

The wire cannot express whether two adjacent tool results arrived as one MPSH
user message or two, and renders both identically. Export collapses a
consecutive run into one user message.

A session that genuinely held them as separate turns comes back joined. Nothing
is lost but the boundary — content and pairing survive — and the collapse is
declared as `Structural::Adaptation::CollapseAdjacentToolResults` so the
conformance suite asserts the predicted divergence rather than reporting a bug
forever.

### Declared limit: foreign scaffolding is undetectable

A session produced by another client doing the same twiddling with different
placeholder text will re-import its synthetic message as real conversation. A
genuine user message that follows a tool result and carries an image is
indistinguishable from a carrier.

Structural recognition narrows this. It does not close it, and cannot.

## Conformance

`spec/conformance/chat_completions_spec.cr`. Fourteen fixtures must round-trip
untouched; the rest declare the divergence the matrix predicts.

Fixture                          |Expected                                                                                                                    
---------------------------------|----------------------------------------------------------------------------------------------------------------------------
`tool_call_image_result`         |Compensated. Restores exactly; no synthetic message in the export                                                           
`tool_call_image_result`, strict |Refuses                                                                                                                     
`server_executed_tool`           |Degraded to text; cannot return as a tool call                                                                              
`reasoning_with_provider_payload`|Degraded; the block does not survive                                                                                        
`reference_payload`              |Refuses — no blob store configured                                                                                          
`audio_*`                        |**Exact.** WAV is accepted here; the degrade/refuse ladder is exercised in Phase 3 against Anthropic, which accepts no audio

## Not yet built

Export handles **requests**, not responses. Round-tripping a request is what
conformance needs; a live call returns `choices[0].message`, a different shape.
Required for acceptance criterion 8 and tracked in `../../SCOPE.md`.
