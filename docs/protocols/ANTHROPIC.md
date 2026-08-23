# Anthropic Messages

Protocol identity `anthropic`; vendor namespace `anthropic`.

The checkpoint, together with Gemini. Written and structurally verified without
a key: **keys gate execution, not mapping.**

## Why this protocol is the pair to Chat Completions

It is simultaneously the **most capable** target and the **strictest**
validator, and the conformance suite leans on both.

Most capable, because `tool_result.content` is an array of blocks including
images. The fixture Chat Completions can only fake maps here natively, with no
compensation at all. That pair — one protocol inventing a capability, one with
it built in, exercised by the same fixture — is what validates the design.
Neither alone proves anything.

Strictest, because roles must alternate, the first message must come from the
user, and `max_tokens` is required with no default. None of that is expressible
as a block outcome, which is why sequence-level adaptations exist.

## Declared capabilities

Capability     |Declared   |Note                                                              
---------------|-----------|------------------------------------------------------------------
Binary content |`Native`   |Media type and base64 stay separate, as MPSH stores them          
Tool calls     |`Block`    |`tool_use`, a content block                                       
Tool results   |`Blocks`   |**Nested block array — the capability that forced the union rule**
Reasoning      |`Block`    |`thinking`, carrying a signature                                  
Reasoning unit |`Either`   |**Both, and the model decides which.** See below                  
Server-executed|`true`     |Distinct block types, not a flag                                  
Refusal channel|`false`    |A refusal is carried as text                                      
Media accepted |images, PDF|**No audio at all**                                               
Alternation    |required   |Sequence-level normalisation                                      
System prompt  |`Parameter`|The `system` field                                                

## The exact path

Canonical form: one user message holding a `tool_result` whose nested content is
`[text, image]`. Wire form: exactly that, in position, with no placeholder and
no synthesized message.

It also **passes under strict policy**, which Chat Completions cannot. That
single assertion is the cleanest statement of what the capability model buys.

Two smaller wins fall out of the wire shape. Media type and base64 stay
separate, so there is no fusing and nothing to parse back apart. And
`tool_use.input` is a structured object rather than a JSON string, so MPSH's
decision to store arguments structured needs no conversion here.

## Sequence-level normalisation

Applied after rendering, before sending. Three adaptations, and two of them are
one-way.

Adaptation              |Outcome        |Recoverable on export?                        
------------------------|---------------|----------------------------------------------
Move system prompt      |Restructured   |Yes — it is a parameter                       
Merge consecutive roles |**Compensated**|**No** — export cannot know where the seam was
Prepend user placeholder|**Compensated**|Only by its exact text                        
Drop empty message      |Degraded       |No                                            

`FIRST_USER_PLACEHOLDER` is a protocol marker on the same terms as the
compensation placeholder: matched exactly on export, so it must stay
byte-identical, and a foreign session using different wording is undetectable.

Dropping an empty message is **recorded**, not done quietly. It is easy to reach
for `reject` and lose a message silently — which is the failure this whole
design objects to, and it happened once here before being caught.

## Server-executed tools

Provider-run tools are a **distinct block type** here — `server_tool_use` and a
tool-specific result such as `web_search_tool_result` — rather than a flag on an
ordinary call. That is the protocol agreeing with MPSH's own categorisation: a
server-executed call is a different category, not a variation, and a client must
never dispatch one.

Consequence: the `server_executed` flag survives a round trip here and degrades
on every other protocol.

The result block type is tool-specific and not derivable, so it is preserved
under `provider_metadata["anthropic"]["result_type"]` rather than guessed at on
the next mapping.

Emitting a provider-run call as an ordinary `tool_use` would be worse than a
fidelity bug: a client re-importing it would see a call awaiting dispatch and
try to run a tool it does not have.

## Degrade versus refuse

The first protocol where the ladder actually fires. No audio media type is
accepted, so a voice note becomes its transcript — or stops the request if it
has none.

Note that `unsupported_media_type` (a WEBP image) is **exact** here. WEBP is
accepted; the fixture name describes the OpenAI case that motivated it, not a
universal fact. Read declarations, not fixture names.

## Two controls, two homes, and a 400 for the wrong one

This protocol asks for reasoning in two units, and which one it accepts depends
on the **model**, not the protocol.

Mode                                       |Where            |Accepted on                           
-------------------------------------------|-----------------|--------------------------------------
`thinking: {type: enabled, budget_tokens:}`|`thinking`       |4.5 and earlier only; **400 from 4.7**
`output_config: {effort:}`                 |its own parameter|4.5 onward, and the current default   

So `reasoning_unit` is declared `Either` and `Capability::Catalog` resolves it
per call. Declaring whichever unit today's models want would be a profile
describing a moment rather than a protocol, and the failure is loud: a budget
sent to a current model is a rejected request, not a degraded one.

Two rules the budget path must obey, both from the vendor's documentation: the
budget is **at least 1,024** and **strictly below `max_tokens`**, because
thinking tokens count against the same ceiling as the answer. The mapper clamps
to fit and, where the clamp would fall under the floor, drops the control and
records it — it never raises the caller's cap to make a budget fit.

`effort` is deliberately not inside `thinking`: it shapes the whole response,
tool calls included, and works whether or not thinking is enabled.

One consequence worth knowing before prompt caching arrives: **changing either
control between turns invalidates cached prefixes**, because the value is
rendered into the prompt.

## Known gap: thinking without a signature

A `thinking` block must carry the signature the provider issued, replayed
unmodified. Signatures are preserved correctly where they exist — but nothing
stops a reasoning block that arrived from *another* vendor being mapped here,
producing a `thinking` block with no signature, which this protocol will reject
at request time.

The resolver calls foreign reasoning **Restructured**, which is right in the
abstract. This protocol turns it into a hard rejection rather than a graceful
drop. Likely correct answer is **Degraded**, dropping the block from the wire
rather than emitting an invalid one — but confirm against a live call first.
Tracked in `../../SCOPE.md`.

This is exactly the class of thing structural verification cannot settle.

## Conformance

`spec/conformance/anthropic_spec.cr`. Ten fixtures round-trip untouched.

Fixture                   |Expected                                                
--------------------------|--------------------------------------------------------
`tool_call_image_result`  |**Exact**, and passes under strict policy               
`consecutive_same_role`   |Compensated — 3 messages become 2, declared             
`assistant_first`         |Compensated — placeholder prepended, discarded on export
`audio_with_transcript`   |Degraded to the transcript                              
`audio_without_transcript`|**Refuses**                                             
`server_executed_tool`    |Flag survives; `tool_name` metadata dropped and named   
`empty_message`           |Degraded, and recorded                                  

## Not yet built

Response-shaped export, and prompt caching (`cache_control` markers), which is
`provider_metadata` territory when it arrives. Both tracked in `../../SCOPE.md`.
