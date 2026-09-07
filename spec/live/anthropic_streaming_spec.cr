require "../spec_helper"

# Streaming against the real Anthropic API.
#
# **Why this one earns its cost.** A `thinking` block must carry the signature
# the provider issued, replayed unmodified, or the following turn is rejected
# outright — `signature` is a required field on Anthropic's own request schema,
# not merely validated when present. The streamed shape delivers that signature
# on its own `signature_delta`, after the thinking text and before the block
# closes, which means an assembler can lose it in two distinct ways: by not
# reading that delta, or by closing the block before it arrives.
#
# Neither failure is observable anywhere else. **Ollama's Anthropic port emits
# no signatures at all** — confirmed zero on both the streamed and non-streamed
# transcripts, which is not a streaming divergence but the expected limit of an
# emulator: a signature is Anthropic's own attestation and a local model cannot
# mint one. So the signature path in `Protocol::Anthropic::Assembler` has been
# tested only against frames written by the same hand that wrote the code, and
# that is the exact shape of test this repository distrusts.
#
# **Four paid calls on Haiku**, across three transcripts. The third is a
# multi-turn recording, which `DEVELOPMENT.md` warns re-cuts every turn when
# re-recorded — accepted here because the second turn is the whole point.
#
# **What "present" does not prove.** A signature arriving and surviving export
# is not the same as a signature the provider will accept back. Only a resumed
# turn shows that, which is why one exists below rather than being left as the
# gap it currently is on Gemini too.
private MODEL = "claude-haiku-4-5"

private STREAM_THINKING = "anthropic_stream_thinking"
private STREAM_TOOLS    = "anthropic_stream_tools"
private STREAM_RESUMED  = "anthropic_stream_resumed"

private def endpoint : Elelem::Server
  Elelem::Server.new("anthropic", "https://api.anthropic.com", ENV["ANTHROPIC_API_KEY"]?)
end

private def messages : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(endpoint, Elelem::ProtocolKind::Anthropic))
end

# Thinking must be asked for, and `max_output_tokens` must exceed the budget it
# implies or the request is rejected before a frame is sent.
private def thinking : Elelem::Options
  Elelem::Options.new(reasoning: Elelem::Reasoning::Effort::Low, max_output_tokens: 1536)
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

private def armed : Elelem::Options
  Elelem::Options.new(tools: [weather_tool],
    reasoning: Elelem::Reasoning::Effort::Low, max_output_tokens: 1536)
end

private def tool_question : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")
  session
end

private def signatures(reply) : Array(String)
  key = Elelem::Protocol::Anthropic::METADATA_KEY
  reply.content.select(M::ReasoningBlock)
    .compact_map { |block| block.meta?(key, "signature").try(&.as(String)) }
end

describe "Anthropic streaming" do
  describe "a streamed thinking turn" do
    it "returns an ordinary reply" do
      Wiretap.intercept(STREAM_THINKING) do
        reply, report = messages.send(asked, MODEL, options: thinking) { |_, _| }

        reply.role.should eq M::Role::Assistant
        reply.content.select(M::TextBlock).should_not be_empty
        report.streamed?.should be_true
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "carries the signature from its own delta" do
      # The reason this spec exists. `signature_delta` arrives after the
      # thinking text and before `content_block_stop`, so an assembler that
      # ignored that delta — or closed the block on first sight of text —
      # would produce a thinking block the provider rejects on the next turn,
      # and every offline test would still pass.
      Wiretap.intercept(STREAM_THINKING) do
        reply, _ = messages.send(asked, MODEL, options: thinking) { |_, _| }

        reply.content.select(M::ReasoningBlock).should_not be_empty
        signatures(reply).should_not be_empty
        signatures(reply).each(&.should_not be_empty)
      end
    end

    it "keeps thinking out of the answer" do
      Wiretap.intercept(STREAM_THINKING) do
        seen = [] of S::Event
        reply, _ = messages.send(asked, MODEL, options: thinking) { |event, _| seen << event }

        thoughts = seen.select(S::ReasoningDelta)
        thoughts.should_not be_empty
        reply.text.should_not contain thoughts.first.text
      end
    end

    it "folds many deltas into one text block" do
      Wiretap.intercept(STREAM_THINKING) do
        seen = [] of S::Event
        reply, _ = messages.send(asked, MODEL, options: thinking) { |event, _| seen << event }

        deltas = seen.select(S::TextDelta)
        deltas.size.should be > reply.content.select(M::TextBlock).size
      end
    end

    it "reports usage from both halves of the message" do
      # `message_start` carries input tokens, `message_delta` carries output
      # tokens, and neither carries the other. A streamed reply reporting only
      # one of them would be quietly wrong rather than visibly broken.
      Wiretap.intercept(STREAM_THINKING) do
        reply, _ = messages.send(asked, MODEL, options: thinking) { |_, _| }

        key = Elelem::Protocol::Anthropic::METADATA_KEY
        usage = reply.meta?(key, "usage").should_not be_nil
        usage.as(M::Object).has_key?("input_tokens").should be_true
        usage.as(M::Object).has_key?("output_tokens").should be_true
      end
    end
  end

  describe "a signature replayed on the next turn" do
    it "is accepted by the provider that issued it" do
      # The difference between a signature that is *present* and one that is
      # *intact*. Everything else here checks that bytes arrived; only sending
      # them back checks they were the right bytes, unmodified.
      #
      # The second turn is deliberately not streamed. What is under test is the
      # signature a streamed turn produced, not the streaming of the reply that
      # accepts it — and the default `Compensating` policy refuses a Degraded
      # outcome, so a signature this protocol would not replay raises here
      # rather than passing quietly.
      Wiretap.intercept(STREAM_RESUMED) do
        session = asked
        first, _ = messages.send(session, MODEL, options: thinking) { |_, _| }
        session << first
        signatures(first).should_not be_empty

        session << M::Message.user("And the second tallest?")
        second, report = messages.send(session, MODEL, options: thinking)

        second.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Degraded
      end
    end
  end

  describe "a streamed tool call" do
    it "assembles arguments from input_json_delta" do
      Wiretap.intercept(STREAM_TOOLS) do
        reply, _ = messages.send(tool_question, MODEL, options: armed) { |_, _| }

        calls = reply.content.select(M::ToolCallBlock)
        calls.should_not be_empty
        calls.first.name.should eq "get_weather"
        calls.first.arguments.has_key?("city").should be_true
      end
    end

    it "announces the call at block open, by name alone" do
      Wiretap.intercept(STREAM_TOOLS) do
        seen = [] of S::Event
        messages.send(tool_question, MODEL, options: armed) { |event, _| seen << event }

        seen.select(S::ToolCallStarted).map(&.name).should eq ["get_weather"]
      end
    end

    it "reports a stop reason of tool_use" do
      Wiretap.intercept(STREAM_TOOLS) do
        reply, _ = messages.send(tool_question, MODEL, options: armed) { |_, _| }

        key = Elelem::Protocol::Anthropic::METADATA_KEY
        reply.meta?(key, "stop_reason").should eq "tool_use"
      end
    end
  end
end
