require "../spec_helper"

# Streaming over Ollama's Anthropic Messages port.
#
# Free to record, which changes what this is for. The Gemini spec had to earn
# every call; this one can afford to ask questions it expects to fail, and the
# useful questions here are all of that kind.
#
# **The baseline that makes this interesting.** `ollama_spec.cr` already reads
# a *thinking block* from this endpoint without asking for one, so the model
# behind it reasons by default and the non-streamed path sees it. Whether the
# streamed path does is a separate question, and a divergence would be the
# thing `docs/STREAMING_DESIGN.md` predicted of emulators: a compatibility port
# supporting less of the protocol it imitates than the protocol does. The
# examples below therefore assert rather than tolerate — on this endpoint a
# failure is a finding, and a free one.
#
# **What is not asserted here.** Whether a cut stream keeps its text and drops
# its half-built tool call. That is the heart of this assembler and it cannot
# be provoked reliably against a live server, so it lives in
# `spec/streaming/anthropic_assembler_spec.cr`, where the frames can be
# arranged. This file checks that the frames arriving are the ones that spec
# assumes.
private MODEL = "gemma4:26b-mxfp8"

private STREAM_TEXT  = "ollama_anthropic_stream_text"
private STREAM_TOOLS = "ollama_anthropic_stream_tools"

private CAP = Elelem::Options.new(max_output_tokens: 512)

private def ollama : Elelem::Server
  Elelem::Server.new("ollama", "http://localhost:11434")
end

private def messages : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(ollama, Elelem::ProtocolKind::Anthropic))
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
  Elelem::Options.new(tools: [weather_tool], max_output_tokens: 512)
end

private def tool_question : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")
  session
end

describe "Ollama streaming over the Anthropic Messages API" do
  describe "a plain streamed turn" do
    it "returns an ordinary reply" do
      Wiretap.intercept(STREAM_TEXT) do
        reply, report = messages.send(asked, MODEL, options: CAP) { |_, _| }

        reply.role.should eq M::Role::Assistant
        reply.content.select(M::TextBlock).should_not be_empty
        report.streamed?.should be_true
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "reaches message_stop" do
      # Not directly observable from the client, so it is asserted by its
      # consequence: a stream that never terminates raises rather than
      # returning, because nobody asked it to stop. Reaching this line at all
      # is the assertion.
      Wiretap.intercept(STREAM_TEXT) do
        reply, _ = messages.send(asked, MODEL, options: CAP) { |_, _| }

        reply.text.should_not be_empty
      end
    end

    it "folds many deltas into one text block" do
      # The merging proof, from both sides: many fragments watched, one block
      # exported. If these matched, nothing would have been accumulated.
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = messages.send(asked, MODEL, options: CAP) { |event, _| seen << event }

        deltas = seen.select(S::TextDelta)
        deltas.should_not be_empty
        deltas.size.should be > reply.content.select(M::TextBlock).size
      end
    end

    it "reports the stop reason from message_delta" do
      # Carried on a different frame from everything else about the message,
      # which is the sort of thing an assembler quietly drops.
      Wiretap.intercept(STREAM_TEXT) do
        reply, _ = messages.send(asked, MODEL, options: CAP) { |_, _| }

        key = Elelem::Protocol::Anthropic::METADATA_KEY
        reply.meta?(key, "stop_reason").should_not be_nil
      end
    end
  end

  describe "thinking over a compatibility port" do
    it "streams thinking, as the non-streamed path already returns it" do
      # `ollama_spec.cr` reads a thinking block from this endpoint with no
      # reasoning requested, so the baseline is established. If this fails,
      # the finding is that Ollama's Anthropic port thinks when asked for a
      # body and not when asked for a stream — an emulator supporting less of
      # the protocol than the protocol does, which belongs in
      # `docs/servers/OLLAMA.md` rather than in a softened assertion.
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = messages.send(asked, MODEL, options: CAP) { |event, _| seen << event }

        seen.select(S::ReasoningDelta).should_not be_empty
        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end

    it "keeps thinking out of the answer text" do
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = messages.send(asked, MODEL, options: CAP) { |event, _| seen << event }

        thoughts = seen.select(S::ReasoningDelta)
        next if thoughts.empty?

        reply.text.should_not contain thoughts.first.text
      end
    end
  end

  describe "a streamed tool call" do
    it "arrives with arguments that parse" do
      # The `input_json_delta` path. Arguments are accumulated from fragments
      # that are meaningless until the last one, so parsing at all is the
      # evidence that the accumulation and the close were both handled.
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

        seen.select(S::ToolCallStarted).map(&.name).should contain "get_weather"
      end
    end

    it "reports nothing for the argument fragments themselves" do
      # There is no event kind carrying `partial_json`, deliberately. Every
      # event seen on a tool turn is a call announcement, text or reasoning —
      # never a fragment of an arguments object.
      Wiretap.intercept(STREAM_TOOLS) do
        seen = [] of S::Event
        messages.send(tool_question, MODEL, options: armed) { |event, _| seen << event }

        seen.each do |event|
          event.should be_a(S::TextDelta | S::ReasoningDelta | S::ToolCallStarted)
        end
      end
    end
  end

  describe "stopping a turn" do
    it "returns what had arrived, without raising" do
      Wiretap.intercept(STREAM_TEXT) do
        seen = 0
        reply, report = messages.send(asked, MODEL, options: CAP) do |_, turn|
          seen += 1
          turn.stop
        end

        seen.should be > 0
        report.streamed?.should be_true

        # No stop reason, because `message_delta` never arrived — which is how
        # a stopped turn stays distinguishable from a finished one downstream.
        key = Elelem::Protocol::Anthropic::METADATA_KEY
        reply.meta?(key, "stop_reason").should be_nil
      end
    end
  end
end
