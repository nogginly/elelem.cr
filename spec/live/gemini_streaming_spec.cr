require "../spec_helper"

# Streaming against the real Gemini API.
#
# Separate from `gemini_spec.cr` because streaming here is a different *method
# on the URL* — `:streamGenerateContent?alt=sse` rather than `:generateContent`
# — so nothing can share a transcript across the two files even where the body
# is identical. That URL difference is itself the reason `Adapter#stream_path`
# exists; every other protocol asks for a stream in the body.
#
# **Recording.** Needs `GEMINI_API_KEY` and `RECORD=1`, as `gemini_spec.cr`
# does. Five transcripts, six paid calls, all on Flash — the resumed one is two
# calls in a single transcript.
#
# **What this has to settle, in order of how expensive it would be to get
# wrong.**
#
# 1. **Does a `functionCall` part arrive whole?** The assembler takes it whole
#    and never merges it, on the belief that Gemini does not fragment calls.
#    If that belief is wrong, a streamed tool call is silently mangled — and
#    on this protocol the arguments are the one thing whose partial form is
#    invalid. `args` parsing as JSON is the check.
# 2. **Does `thoughtSignature` survive a stream?** Signatures must be replayed
#    unmodified or the following turn is rejected, which makes this the point
#    where streaming could break portable history on the protocol that most
#    depends on it. If a signature arrives split across fragments, or not at
#    all when streamed, that is a finding worth the whole recording. Arriving
#    is not the same as being accepted back, which is why a resumed turn sits
#    below rather than the gap being left open as it was.
# 3. **Does text actually need merging, and does it merge correctly?** Pinned
#    by asserting the reply carries *one* text block rather than one per
#    chunk. Offline specs prove the arithmetic; this proves it was the right
#    arithmetic for what the server really sends.
# 4. **Is `MAX_TOKENS` terminal rather than a failure?** The Gemini analogue of
#    `response.incomplete`, and untested on Responses — noted as a gap there,
#    cheap to close here.
#
# **Already settled, the hard way.** The first recording asserted that a plain
# streamed turn carries thoughts, on the assumption that Gemini 3 thinks by
# default. It does think — and bill for it — but returns neither the thought
# text nor the signature unless `includeThoughts` is requested, which the
# mapper emits only alongside a thinking budget or level. So there are two
# text transcripts here rather than one, and the no-thinking case keeps an
# example asserting the silence, because a caller who never mentions reasoning
# is paying for reasoning they cannot see.
#
# **What it cannot settle**, exactly as on Ollama: anything about incremental
# arrival. Wiretap buffers a streamed body before handing it on.
private MODEL = "gemini-3.5-flash"

private STREAM_TEXT     = "gemini_stream_text"
private STREAM_THINKING = "gemini_stream_thinking"
private STREAM_TOOLS    = "gemini_stream_tools"
private STREAM_CAPPED   = "gemini_stream_capped"
private STREAM_RESUMED  = "gemini_stream_resumed"

private def endpoint : Elelem::Server
  Elelem::Server.new("gemini", "https://generativelanguage.googleapis.com", ENV["GEMINI_API_KEY"]?)
end

private def provider : Elelem::Provider
  Elelem::Provider.for(endpoint, Elelem::ProtocolKind::Gemini)
end

private def streamed(retention : Elelem::Capability::ReasoningRetention = Elelem::Capability::ReasoningRetention::All) : Elelem::Client
  Elelem::Client.new(provider, Elelem::Capability::Policy::Compensating, retention)
end

private def plain : Elelem::Options
  Elelem::Options.new(max_output_tokens: 512)
end

# Thinking has to be *asked for* on this protocol, and asking is what makes the
# thoughts visible rather than what makes them happen. Without a budget or a
# level the mapper emits no `thinkingConfig`, so no `includeThoughts`, and
# Gemini reasons anyway while returning neither the text nor the signature.
private def thinking : Elelem::Options
  Elelem::Options.new(max_output_tokens: 512, reasoning: Elelem::Reasoning::Effort::Medium)
end

private def asked : M::Session
  session = M::Session.new("Answer in one short sentence.")
  session << M::Message.user("What is the tallest mountain on Earth?")
  session
end

private def weather_tool : Elelem::Tool
  Elelem::Tool.new("get_weather", "Look up the current weather in a city",
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}))
end

# Tools *and* thinking. Thinking is requested here for the same reason it is
# requested in `thinking` above — without it there is no signature to check —
# and because a signature rides on a function call, which makes this the
# combination where losing one would actually cost something.
private def armed : Elelem::Options
  Elelem::Options.new(tools: [weather_tool], max_output_tokens: 512,
    reasoning: Elelem::Reasoning::Effort::Medium)
end

private def tool_question : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")
  session
end

private def gemini_meta(block, key : String)
  block.meta?(Elelem::Protocol::Gemini::METADATA_KEY, key)
end

describe "Gemini streaming" do
  describe "a plain streamed turn" do
    it "is accepted at the streaming URL" do
      # First byte ever sent to `:streamGenerateContent`. A wrong path or a
      # missing `alt=sse` surfaces here as a transport error rather than as
      # something subtle, which is why this example exists separately from the
      # ones that assert content.
      Wiretap.intercept(STREAM_TEXT) do
        reply, report = streamed.send(asked, MODEL, options: plain) { |_, _| }

        reply.role.should eq M::Role::Assistant
        report.streamed?.should be_true
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "merges fragments into a single text block" do
      # The claim this protocol's assembler exists to make. Gemini sends text
      # in pieces with no finished unit anywhere, so a reply carrying one block
      # is proof the merging happened; a reply carrying several would mean each
      # chunk had become a block of its own.
      Wiretap.intercept(STREAM_TEXT) do
        reply, _ = streamed.send(asked, MODEL, options: plain) { |_, _| }

        reply.content.select(M::TextBlock).size.should eq 1
        reply.text.should_not be_empty
      end
    end

    it "reports more fragments than the reply has blocks" do
      # The other half of the same point, from the watcher's side: many deltas,
      # one block. If these were equal, nothing would have been merged.
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = streamed.send(asked, MODEL, options: plain) { |event, _| seen << event }

        deltas = seen.select(S::TextDelta)
        deltas.should_not be_empty
        deltas.size.should be > reply.content.select(M::TextBlock).size
        deltas.map(&.text).join.should contain reply.text.strip.split(' ').first
      end
    end

    it "streams no thoughts when none were asked for" do
      # **A live finding, discovered by asserting the opposite.** Gemini 3
      # reasons on this question regardless — and bills for it — but the API's
      # default is to return neither the thought text nor the signature unless
      # `includeThoughts` is set, which the mapper emits only alongside a
      # thinking budget or level. `Options.new(max_output_tokens:)` sets
      # neither, so a caller who never mentions reasoning silently gets a
      # stream with none in it.
      #
      # Pinned rather than papered over, because the failure mode is quiet: the
      # reasoning is happening and being paid for, and only the visibility is
      # missing.
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = streamed.send(asked, MODEL, options: plain) { |event, _| seen << event }

        seen.select(S::ReasoningDelta).should be_empty
        reply.content.select(M::ReasoningBlock).should be_empty
      end
    end
  end

  describe "a streamed turn that was asked to think" do
    it "reports the model thinking, and keeps the thoughts out of the answer" do
      # The separation matters and is easy to get wrong: a thought part also
      # carries `text`, so a reader checking `text` before `thought` turns
      # reasoning into assistant prose.
      Wiretap.intercept(STREAM_THINKING) do
        seen = [] of S::Event
        reply, _ = streamed.send(asked, MODEL, options: thinking) { |event, _| seen << event }

        seen.select(S::ReasoningDelta).should_not be_empty
        reply.content.select(M::ReasoningBlock).should_not be_empty
        reply.text.should_not contain seen.select(S::ReasoningDelta).first.text
      end
    end

    it "folds thoughts into a single reasoning block" do
      # **A live finding.** Gemini sent this entire thought summary as one
      # part, where the answer text arrived in many — so thought fragments are
      # not necessarily fragments at all, and an example asserting more deltas
      # than blocks was asserting something this protocol does not promise.
      #
      # The invariant that does hold either way is below: however many parts
      # arrive, contiguous thoughts fold into one block. That catches the
      # regression that matters — merging failing and producing a block per
      # part — and stays true when a longer question does fragment the summary.
      # The merging arithmetic itself is pinned offline, where the fragments
      # can be arranged rather than hoped for.
      Wiretap.intercept(STREAM_THINKING) do
        seen = [] of S::Event
        reply, _ = streamed.send(asked, MODEL, options: thinking) { |event, _| seen << event }

        seen.select(S::ReasoningDelta).should_not be_empty
        reply.content.select(M::ReasoningBlock).size.should eq 1
      end
    end

    it "reports reasoning even when the caller keeps none of it" do
      # Shares the transcript legitimately: retention rewrites the outbound
      # mapping of prior assistant turns, and this session has none, so the
      # body is byte-identical. The decision itself is recorded in
      # `docs/STREAMING_DESIGN.md` — retention governs the next request, never
      # the reply, so `None` must not silence the event stream.
      Wiretap.intercept(STREAM_THINKING) do
        seen = [] of S::Event
        none = Elelem::Capability::ReasoningRetention::None
        streamed(none).send(asked, MODEL, options: thinking) { |event, _| seen << event }

        seen.select(S::ReasoningDelta).should_not be_empty
      end
    end
  end

  describe "a streamed tool call" do
    it "arrives whole, with parseable arguments" do
      # The expensive-to-get-wrong one. The assembler never merges a
      # `functionCall` part, on the belief that this protocol does not split
      # them. Arguments that parse are that belief holding; arguments that do
      # not would mean a streamed call is being silently mangled.
      Wiretap.intercept(STREAM_TOOLS) do
        reply, _ = streamed.send(tool_question, MODEL, options: armed) { |_, _| }

        calls = reply.content.select(M::ToolCallBlock)
        calls.should_not be_empty
        calls.first.name.should eq "get_weather"
        # Already an `MPSH::Object` — the exporter parsed it. That it parsed
        # at all is the point: a fragmented call would not have.
        calls.first.arguments.has_key?("city").should be_true
      end
    end

    it "announces the call by name before the reply exists" do
      Wiretap.intercept(STREAM_TOOLS) do
        seen = [] of S::Event
        streamed.send(tool_question, MODEL, options: armed) { |event, _| seen << event }

        seen.select(S::ToolCallStarted).map(&.name).should contain "get_weather"
      end
    end

    it "carries a thought signature through the stream" do
      # Where streaming could break portable history. A signature must be
      # replayed unmodified on the next turn, so it has to survive both the
      # fragmenting and the merging.
      #
      # **Both block kinds are inspected, and that is not belt-and-braces.**
      # The exporter writes `thought_signature` from `ThoughtPart#signature`
      # *and* from `FunctionCallPart#thought_signature`, and the recorded
      # transcript carries exactly one signature — so an example looking only
      # at reasoning blocks would skip silently if the call was the part that
      # carried it. An earlier version did exactly that, and was green while
      # proving nothing.
      #
      # Asserted rather than reported, now that a signature is known to be in
      # the transcript. `gemini_thought_no_signature.json` records that Gemini
      # omits signatures under conditions it does not document, so this may go
      # red on a future re-record — and that is worth seeing rather than
      # tolerating, because a turn whose signature vanished is a turn the
      # provider will reject when it is replayed.
      Wiretap.intercept(STREAM_TOOLS) do
        reply, _ = streamed.send(tool_question, MODEL, options: armed) { |_, _| }

        signed = reply.content.compact_map { |block| gemini_meta(block, "thought_signature") }

        signed.should_not be_empty
        signed.each { |signature| signature.as(String).should_not be_empty }
      end
    end
  end

  describe "a thought signature replayed on the next turn" do
    it "is accepted by the provider that issued it" do
      # The difference between a signature that is *present* and one that is
      # *intact*. The example above proves bytes arrived and survived export;
      # only sending them back proves they were the right bytes, unmodified.
      # A signature damaged by fragmenting or merging looks identical to a good
      # one until the following request is rejected.
      #
      # **Two things make this turn the one worth paying for.** The signature
      # rides on the `functionCall` part here, which is the shape Gemini 3
      # requires and the shape `elelem` had nowhere to carry until recently.
      # And `Resolver` checks for a missing signature ahead of `own?`, so a
      # call that lost one is reported `Degraded` and refused by the default
      # `Compensating` policy — which means a lost signature raises here rather
      # than passing quietly.
      #
      # **The second turn is deliberately not streamed.** What is under test is
      # the signature a streamed turn produced, not the streaming of the reply
      # that accepts it. Same choice as `anthropic_streaming_spec.cr`, for the
      # same reason.
      #
      # **A tool result is required, not decoration.** Replaying the call
      # without one leaves the session holding a dangling call, which
      # `MPSH::Repair`'s invariant forbids and this protocol's validator
      # rejects — so the request would fail for a reason that has nothing to do
      # with the signature under test.
      #
      # Multi-turn, which `DEVELOPMENT.md` warns re-cuts every turn when
      # re-recorded. Accepted here because the second turn is the whole point.
      Wiretap.intercept(STREAM_RESUMED) do
        session = tool_question
        first, _ = streamed.send(session, MODEL, options: armed) { |_, _| }
        session << first

        calls = first.content.select(M::ToolCallBlock).reject(&.server_executed?)
        calls.size.should eq 1
        first.content.compact_map { |block| gemini_meta(block, "thought_signature") }
          .should_not be_empty

        session << M::Message.new(M::Role::User, calls.map do |call|
          M::ToolResultBlock.new(call.call_id,
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)
        end)

        answer, report = streamed.send(session, MODEL, options: armed)

        answer.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Degraded
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  describe "a turn that runs out of room" do
    it "treats MAX_TOKENS as a finished stream, not a failure" do
      # A stream that completed, reporting an answer that did not. The
      # distinction matters because the other reading — treating it as a cut
      # stream — would raise and throw away a perfectly good short answer.
      Wiretap.intercept(STREAM_CAPPED) do
        reply, report = streamed.send(asked, MODEL,
          options: Elelem::Options.new(max_output_tokens: 16)) { |_, _| }

        report.streamed?.should be_true
        gemini_meta(reply, "finishReason").should eq "MAX_TOKENS"
      end
    end
  end

  describe "stopping a turn" do
    it "returns what had arrived, without raising" do
      Wiretap.intercept(STREAM_TEXT) do
        seen = 0
        reply, report = streamed.send(asked, MODEL, options: plain) do |_, turn|
          seen += 1
          turn.stop
        end

        seen.should be > 0
        report.streamed?.should be_true

        # No finish reason, because none arrived — which is exactly how a
        # stopped turn is distinguishable from a completed one downstream.
        gemini_meta(reply, "finishReason").should be_nil
        reply.ending.should eq M::Ending::Stopped
      end
    end
  end
end
