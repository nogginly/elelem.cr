require "../spec_helper"

# Streaming over Ollama's Responses port.
#
# Separate from `ollama_spec.cr` because the request body differs — it carries
# `"stream": true` — so nothing here can share a transcript with anything
# there, and mixing the two would invite someone to try.
#
# **What a recording here settles, and what it cannot.**
#
# Settles: the frame vocabulary. Which event names Ollama's Responses
# emulation actually sends, whether finished items arrive as
# `response.output_item.done`, whether the stream terminates with
# `response.completed`, and whether the body ends with the blank line that
# `Streaming::Sse` requires before it will dispatch a frame. Every one of those
# is a guess until a real server answers, and `docs/STREAMING_DESIGN.md` says
# plainly that emulators are where streaming divergence is expected.
#
# Cannot settle: **anything about incremental arrival.** Wiretap records a
# streamed body by reading it to the end before handing it on, and replays it
# from an `IO::Memory`. So frames arrive here in one go, both when recording
# and when replaying. That is fine for what these examples assert — vocabulary
# and assembly — and it means nobody should read latency, back-pressure or
# time-to-first-token into a green run.
#
# **What the first recording found.** All of it worked. Ollama's Responses
# emulation emits `response.output_item.done` with whole items, terminates with
# `response.completed`, and ends its body with the blank line `Streaming::Sse`
# requires before it will dispatch a frame — so the discard rule does not eat
# the terminal frame here. The accumulation matched the provider's own
# assembly, item for item.
#
# That is a better outcome than expected and it settles the open worry in
# `docs/STREAMING_DESIGN.md` for this deployment only. An emulator doing less
# than the protocol it imitates is still the pattern to expect; this one simply
# does not, on this endpoint, today. The two strict examples below stay strict
# so that a regression says so.
private MODEL = "gemma4:26b-mxfp8"

private STREAM_TEXT    = "ollama_responses_stream_text"
private STREAM_FRAMES  = "ollama_responses_stream_frames"
private STREAM_STOPPED = "ollama_responses_stream_stopped"

private CAP = Elelem::Options.new(max_output_tokens: 512)

private def ollama : Elelem::Server
  Elelem::Server.new("ollama", "http://localhost:11434")
end

private def responses : Elelem::Provider
  Elelem::Provider.for(ollama, Elelem::ProtocolKind::Responses)
end

private def asked : M::Session
  session = M::Session.new("Answer in one short sentence.")
  session << M::Message.user("What is the tallest mountain on Earth?")
  session
end

# Drives the assembler directly, which `Client#send` gives no way to reach.
#
# The oracle needs both halves — what we assembled and what the provider says —
# and the client deliberately exposes only the reply. So this rebuilds the same
# exchange one layer down. Same body as the client would send, but recorded
# under its own name rather than shared: guaranteeing byte-identity across two
# construction paths is exactly the sort of coupling that breaks silently.
private def assembled : Elelem::Protocol::Responses::Assembler
  provider = responses
  exchange = provider.adapter.prepare_stream(asked, MODEL,
    Elelem::Capability::Policy::Compensating,
    Elelem::Capability::ReasoningRetention::All,
    provider.default_max_tokens,
    CAP).should_not be_nil

  assembler = exchange.assembler.as(Elelem::Protocol::Responses::Assembler)
  server = provider.server
  server.stream(provider.adapter.path(MODEL),
    provider.adapter.headers(server.credential), exchange.body) do |frame|
    assembler.absorb(frame) { |_| }
    true
  end

  assembler
end

describe "Ollama streaming over the Responses API" do
  describe "a watched exchange" do
    it "returns the same shape of reply a plain send would" do
      # The claim the whole design rests on: a streamed reply is an ordinary
      # `MPSH::Message`, because it took the same `export_reply`. Asserted on
      # shape rather than against a recorded non-streamed reply, since two
      # generations differ and that comparison would be testing the model's
      # determinism instead of ours.
      Wiretap.intercept(STREAM_TEXT) do
        reply, report = Elelem::Client.new(responses).send(asked, MODEL, options: CAP) { |_, _| }

        reply.role.should eq M::Role::Assistant
        reply.content.select(M::TextBlock).should_not be_empty
        report.streamed?.should be_true
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "reports the answer arriving" do
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = Elelem::Client.new(responses).send(asked, MODEL, options: CAP) do |event, _|
          seen << event
        end

        deltas = seen.select(S::TextDelta)
        deltas.should_not be_empty

        # What was watched and what was returned are the same answer. Not
        # asserted as equality: the reply is assembled from finished items and
        # the deltas are fragments, so the honest claim is containment.
        reply.text.should contain(deltas.first.text.strip) unless deltas.first.text.strip.empty?
      end
    end
  end

  describe "the frames this deployment actually sends" do
    it "terminates with a completed response" do
      # If this fails, `Streaming::Sse`'s rule of discarding an undispatched
      # trailing frame is the first suspect: a server that omits the final
      # blank line loses its last event, and the last event is this one.
      Wiretap.intercept(STREAM_FRAMES) do
        assembled.complete?.should be_true
      end
    end

    it "delivers finished items whole" do
      # Strict on purpose — see the note at the top of this file. This is the
      # assertion that tells us whether partial replies exist on Ollama.
      Wiretap.intercept(STREAM_FRAMES) do
        assembled.accumulated.output.should_not be_empty
      end
    end

    it "agrees with the provider's own assembly" do
      # The oracle, and the reason Responses was built first. Every other
      # protocol can only be checked against an expectation someone wrote
      # down; this one is checked against the vendor's assembly of the very
      # same stream, on live data.
      Wiretap.intercept(STREAM_FRAMES) do
        subject = assembled

        subject.accumulated.output.size.should eq subject.response.output.size
        subject.accumulated.output.map(&.class)
          .should eq subject.response.output.map(&.class)
      end
    end
  end

  describe "reasoning under retention" do
    # The decision recorded in `docs/STREAMING_DESIGN.md`, proved rather than
    # argued: reasoning deltas reach the event stream under **every** retention
    # setting, `None` included. The argument was that retention is applied only
    # in `Mapper#map` and so governs the *next* request, never the reply — and
    # here is a live turn where the caller asked for no retention and watched
    # the model think anyway.
    #
    # This shares `STREAM_TEXT` legitimately. Retention changes the outbound
    # mapping of prior assistant turns, and this session has none: one system
    # prompt and one user message. So the body is byte-identical to the default
    # -retention request above, which is the rule for sharing a name.
    it "reports reasoning even when the caller keeps none of it" do
      Wiretap.intercept(STREAM_TEXT) do
        client = Elelem::Client.new(responses,
          retention: Elelem::Capability::ReasoningRetention::None)

        seen = [] of S::Event
        reply, _ = client.send(asked, MODEL, options: CAP) { |event, _| seen << event }

        seen.select(S::ReasoningDelta).should_not be_empty

        # And the reply carries it too, which is the other half of the same
        # point: the event stream is not showing something the message hides.
        # A caller wanting reasoning neither shown nor stored needs a control
        # that does not exist — see `SCOPE.md`.
        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end
  end

  describe "stopping a turn" do
    it "finishes without raising, and says the reply is partial" do
      # Stopping is cooperative: the client stops reading at a frame boundary
      # and finalises through the ordinary path. What the partial reply
      # *contains* is pinned offline in `spec/streaming`, where the frames can
      # be arranged; here the claim is that the whole path survives being cut
      # short, including the connection being dropped afterwards.
      #
      # The event count is deliberately not asserted. Annotations are emitted
      # before any frame arrives, so stopping on the first *event* may still
      # let the frame currently being absorbed yield its own — one or two,
      # depending on what the mapping had to say, and neither is interesting.
      Wiretap.intercept(STREAM_STOPPED) do
        seen = 0
        reply, report = Elelem::Client.new(responses).send(asked, MODEL, options: CAP) do |_, turn|
          seen += 1
          turn.stop
        end

        seen.should be > 0
        report.streamed?.should be_true

        # The load-bearing part: this came from the accumulation, not from a
        # terminal frame that never arrived. A stopped turn on the shortcut
        # assembler would have produced nothing at all.
        key = Elelem::Protocol::Responses::METADATA_KEY
        reply.meta?(key, "status").should eq "incomplete"
      end
    end
  end
end
