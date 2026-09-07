require "../spec_helper"

# Streaming over Ollama's Chat Completions port, closing the last of the four.
#
# Free to record, so this asks the questions that would otherwise stay
# assumptions. Three of them are specific to this protocol, and each is a place
# where a compatibility port could plausibly implement less than the spec:
#
# 1. **Does `stream_options.include_usage` work?** The request asks for it,
#    because without it a streamed reply reports no token count at all — the
#    only protocol of the four where usage must be requested. The final chunk
#    carrying it has an empty `choices` array, which is a shape servers get
#    wrong or omit entirely.
# 2. **Does `[DONE]` arrive?** It is the customary terminator and it is not
#    JSON. The assembler treats a `finish_reason` as sufficient on its own, so
#    a missing `[DONE]` costs nothing — but knowing which of the two this
#    server sends is worth recording rather than guessing.
# 3. **Which spelling of reasoning does it stream?** `ollama_spec.cr` records
#    that the non-streamed path emits the bare `reasoning`, not
#    `reasoning_content`. The streamed reader accepts both; this checks the
#    trace survives at all, since a spelling nobody reads is a trace silently
#    lost with no error to notice.
#
# **Not asserted here:** that a cut stream keeps its content and withholds a
# tool call whose arguments happen to parse. That is the heart of this
# assembler and cannot be provoked against a live server on demand, so it lives
# in `spec/streaming/chat_completions_assembler_spec.cr`. This file checks that
# the frames arriving are the ones that spec assumes.
private MODEL = "gemma4:26b-mxfp8"

private STREAM_TEXT  = "ollama_chat_stream_text"
private STREAM_TOOLS = "ollama_chat_stream_tools"

private CAP = Elelem::Options.new(max_output_tokens: 512)

private def ollama : Elelem::Server
  Elelem::Server.new("ollama", "http://localhost:11434")
end

private def chat : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(ollama, Elelem::ProtocolKind::ChatCompletions))
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

private def chat_meta(reply, key : String)
  reply.meta?(Elelem::Protocol::ChatCompletions::METADATA_KEY, key)
end

describe "Ollama streaming over the Chat Completions API" do
  describe "a plain streamed turn" do
    it "returns an ordinary reply" do
      Wiretap.intercept(STREAM_TEXT) do
        reply, report = chat.send(asked, MODEL, options: CAP) { |_, _| }

        reply.role.should eq M::Role::Assistant
        reply.content.select(M::TextBlock).should_not be_empty
        report.streamed?.should be_true
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "folds many fragments into one text block" do
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = chat.send(asked, MODEL, options: CAP) { |event, _| seen << event }

        deltas = seen.select(S::TextDelta)
        deltas.should_not be_empty
        deltas.size.should be > reply.content.select(M::TextBlock).size
      end
    end

    it "terminates rather than being cut off" do
      # A stream that never reports a finish reason and never sends `[DONE]`
      # raises, because nobody asked it to stop. Returning at all is the
      # assertion; the stop reason confirms which of the two arrived.
      Wiretap.intercept(STREAM_TEXT) do
        reply, _ = chat.send(asked, MODEL, options: CAP) { |_, _| }

        chat_meta(reply, "finish_reason").should_not be_nil
      end
    end

    it "reports usage, which this protocol has to be asked for" do
      # `stream_options.include_usage`, arriving on a final chunk whose
      # `choices` array is empty. If this is nil, the finding is that Ollama's
      # port ignores the option — costing token counts on every streamed turn
      # there, and belonging in `docs/servers/OLLAMA.md`.
      Wiretap.intercept(STREAM_TEXT) do
        reply, _ = chat.send(asked, MODEL, options: CAP) { |_, _| }

        chat_meta(reply, "usage").should_not be_nil
      end
    end

    it "streams a reasoning trace" do
      # The non-streamed path emits the bare `reasoning` spelling from this
      # server. The streamed reader accepts both spellings, so this asks only
      # whether the trace survives streaming at all — a spelling nobody reads
      # is a trace lost with no error to notice.
      Wiretap.intercept(STREAM_TEXT) do
        seen = [] of S::Event
        reply, _ = chat.send(asked, MODEL, options: CAP) { |event, _| seen << event }

        seen.select(S::ReasoningDelta).should_not be_empty
        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end
  end

  describe "a streamed tool call" do
    it "assembles arguments that parse" do
      # Fragments accumulated by index, released only once a finish reason
      # arrives. Arguments that parse are the evidence that both halves
      # happened.
      Wiretap.intercept(STREAM_TOOLS) do
        reply, _ = chat.send(tool_question, MODEL, options: armed) { |_, _| }

        calls = reply.content.select(M::ToolCallBlock)
        calls.should_not be_empty
        calls.first.name.should eq "get_weather"
        calls.first.arguments.has_key?("city").should be_true
      end
    end

    it "announces the call once, not once per fragment" do
      # The name arrives on the first fragment and no other. An assembler
      # announcing per fragment would report one call many times, which is the
      # sort of thing only a live stream has enough fragments to expose.
      Wiretap.intercept(STREAM_TOOLS) do
        seen = [] of S::Event
        chat.send(tool_question, MODEL, options: armed) { |event, _| seen << event }

        seen.select(S::ToolCallStarted).map(&.name).should eq ["get_weather"]
      end
    end

    it "reports nothing for the argument fragments themselves" do
      Wiretap.intercept(STREAM_TOOLS) do
        seen = [] of S::Event
        chat.send(tool_question, MODEL, options: armed) { |event, _| seen << event }

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
        reply, report = chat.send(asked, MODEL, options: CAP) do |_, turn|
          seen += 1
          turn.stop
        end

        seen.should be > 0
        report.streamed?.should be_true

        # No finish reason, because none arrived — which is how a stopped turn
        # stays distinguishable from a finished one downstream, and why no
        # tool call could have been released from it.
        chat_meta(reply, "finish_reason").should be_nil
      end
    end
  end
end
