# Ollama

One deployment, three protocols, none of them its own vendor. That combination
is why Ollama is the first server this shard was run against: it is free, local,
and the most awkward shape the design has to survive.

Companion to `docs/protocols/*.md`, which describe protocols as specified. This
describes one *implementation* of three of them, and where it diverges.

## What it serves

Protocol        |Path                  |Since  |Notes                            
----------------|----------------------|-------|---------------------------------
Chat Completions|`/v1/chat/completions`|long   |The mature one                   
Responses       |`/v1/responses`       |v0.13.3|Non-stateful only                
Anthropic       |`/v1/messages`        |v0.14.0|For Claude Code and similar tools
Gemini          |—                     |—      |Not served                       

The Responses limitation is *aligned* with this design rather than a
constraint on it: `previous_response_id` and server-side conversations are the
provider-owns-history model, which a portable session never uses.

## Auth

Accepted and ignored. The API key is not validated and `anthropic-version` is
accepted but unused. So the live suite proves the headers are *sent*, never that
they are correct — that waits for a real endpoint.

## Divergences found by recording

### The reasoning field is spelled `reasoning`

Not `reasoning_content`, which is what vLLM and DeepSeek emit and what this
shard's reader originally required. Every Ollama reasoning trace over Chat
Completions was dropped: no error, no annotation, a green suite. Both spellings
are now read.

This is the canonical example of why transcripts exist. The offline fixtures had
been written from the same assumption as the reader, so they agreed with it.

### All three endpoints return reasoning

Anthropic sends a `thinking` block, Responses a `reasoning` item with
`encrypted_content`, Chat Completions the bare `reasoning` field. Worth knowing
before assuming a compatibility layer omits what it cannot fully support.

### Thinking blocks carry no signature

The recorded `thinking` blocks have no `signature` field at all. So nothing here
tested whether a signature replays — that answer had to come from a real
Anthropic recording, which found `signature` is a required field on
Anthropic's own schema. See `docs/protocols/ANTHROPIC.md`.

It also means the vendor-narrowing default could not be falsified here: Ollama
ignores signatures, so a correctly pessimistic provider and a wrongly optimistic
one both pass. Only an endpoint that *validates* can tell them apart — which is
exactly why this server's green runs, however thorough, could not close that
question on their own.

### `encrypted_content` is namespaced to `ollama`

Ollama does emit it on the Responses endpoint. Because the provider's vendor is
`ollama` and not `openai`, it is stored under the `ollama` key and will never be
replayed to a real OpenAI endpoint that could not read it. The pessimistic
default doing its job, on real data.

### Reasoning controls: `none` is translated, rungs are not

**Switching thinking off is honoured, on both endpoints and in both spellings.**
`reasoning_effort: "none"` on Chat Completions returns no `reasoning` field, and
`thinking: {type: "disabled"}` on the Anthropic endpoint returns no thinking
block. So `Off` is genuinely exercised here and a regression would be visible —
the only part of this axis a compatibility layer can falsify for us.

**A rung is accepted and ignored.** `reasoning_effort: "low"` produced a full
reasoning trace, and `output_config: {effort: "low"}` on the Anthropic endpoint
produced a 149-token one. Indistinguishable from an unknown key being dropped;
this server is permissive about fields it does not recognise. The rung examples
in `spec/live/ollama_spec.cr` therefore assert acceptance and nothing more.

The acceptance is worth a recording of its own even so. An unknown model narrows
to `Effort` under the catalog's optimistic default, so `output_config` is what
every rung-setting caller sends to this endpoint. Had it been rejected, the
default would have been wrong on the first server it met.

One trap, seen immediately. A 64-token cap with reasoning enabled spent every
token on reasoning and returned empty content with `finish_reason: "length"` —
the same shape as the runaway that put a cap on every live request in this
suite. Reasoning and answer share one ceiling, so a request that asks for
thinking needs headroom for both.

### Streaming over Responses behaves, which was not the expectation

`docs/STREAMING_DESIGN.md` argues that streaming divergence, when it comes,
will come from emulators rather than vendors — a compatibility port sending a
thinner frame set than the protocol it imitates. Ollama's Responses port was
the first test of that and it passed cleanly.

Recorded facts, each pinned by a live example in
`spec/live/ollama_streaming_spec.cr`:

- **Finished items arrive whole**, as `response.output_item.done`, in the same
  shape `Wire::Response` already reads. This is what makes partial replies
  possible here: a turn stopped part-way yields everything that finished, and
  `Turn#stop` returns a real answer rather than nothing.
- **The stream terminates with `response.completed`**, carrying the whole
  response object.
- **The body ends with the blank line** SSE requires before a frame is
  dispatched. Worth stating because `Streaming::Sse` discards an undispatched
  trailing frame, deliberately, so that a cut stream is detectable — and a
  server omitting that final newline would lose its terminal frame to the same
  rule. This one does not.
- **Our accumulation agrees with the provider's own**, item for item, on live
  data. Responses is the only one of the four protocols where that check is
  available at all, since its terminal frame carries the vendor's assembly of
  the very stream we assembled independently.

### The Anthropic port streams the whole shape too

Asked next, and for a sharper reason: the non-streamed path already returns
*thinking blocks* from this endpoint, so a streamed path without them would
have been the emulator divergence this design keeps predicting. It streams
text, thinking and tool calls, closes its blocks, terminates on
`message_stop`, and reports the stop reason on `message_delta` where the
protocol puts it. Pinned in `spec/live/ollama_anthropic_streaming_spec.cr`.

Notable because Anthropic's streaming shape is the most intricate of the four
— indexed blocks opened and closed individually, arguments arriving as
`input_json_delta` fragments, a signature on its own delta — and a
compatibility port had every opportunity to implement a simpler subset. It
did not.

### The Chat Completions port streams too, `include_usage` included

The last of the three, and the one with the least safe assumption in it.
`stream_options.include_usage` is the only way to get a token count from a
streamed Chat Completions reply, it is delivered on a final chunk whose
`choices` array is empty, and that is an odd enough shape for a compatibility
port to skip. This one honours it. It also streams the reasoning trace, under
the bare `reasoning` spelling the non-streamed path already uses here.

### All three ports stream, which is itself the finding

`docs/STREAMING_DESIGN.md` predicted that streaming divergence, when it came,
would come from emulators rather than vendors — a compatibility port
supporting less of the protocol it imitates than the protocol does. Across
Responses, Anthropic and Chat Completions, on this server, that has not
happened once. Each port implements the shape its protocol specifies,
including the fiddly parts: indexed content blocks, `input_json_delta`
fragments, empty-`choices` usage chunks.

That is worth recording precisely because it argues against the prediction.
The prediction is still the right default — it costs nothing to hold and this
is one server on one day — but it should now be held as a caution rather than
as an expectation.

### What remains unproven here

Gemini, which Ollama has never served at all, so this server can say nothing
about it.

And the reverse gaps are worth naming, since they are the mirror image:
**Anthropic's own API and OpenAI's own Chat Completions endpoint have never
been streamed by this shard.** Those two protocols are proven against an
emulator and not their vendors, while Gemini is proven against its vendor and
no emulator. Azure is unstreamed on both counts, and is the more interesting
of them — `max_tokens` versus `max_completion_tokens` already differs there
per deployment.

## Operational notes

**Always cap output.** An uncapped small model spent 4,096 tokens reasoning
without reaching an answer — a real interrupted turn — and an earlier run
stalled for twelve minutes on an uncapped request, with every later request
queuing behind it. Ollama processes serially by default, so one runaway
generation blocks everything after it.

**Model choice changes the wire, not just the speed.** A thinking model
exercises three reasoning paths that a non-thinking one leaves untouched. It
also changes every transcript digest: re-recording with a different model
re-cuts the lot.

Transcripts are currently recorded with `gemma4:26b-mxfp8` — around 100–190
output tokens per reply, against 2,855 for a smaller and more excitable model.
Cheap to re-record, and well behaved.

## What a green run here does not prove

A compatibility layer proves the shape is *accepted*, not that the vendor whose
protocol it imitates would accept it. Reasoning controls are the clearest case:
`output_config` is accepted here and ignored, which says nothing about whether
Anthropic would accept it, and a budget — which this server never sees, because
no Ollama model is in the catalog — is untested entirely. Ollama is permissive about alternation,
first-user ordering and required parameters where a real endpoint may not be.
And a non-Claude model behind an Anthropic-shaped API inherits none of Claude's
capabilities.

The next servers are chosen to close exactly these gaps: **Anthropic** because
it validates signatures, **Gemini** because nothing else will ever exercise that
protocol live, and **Azure** because it will amend the design — it speaks Chat
Completions but puts a deployment name and `api-version` in the path and
authenticates with `api-key`, proving that path and auth are
protocol-*plus*-deployment facts rather than protocol facts alone.
