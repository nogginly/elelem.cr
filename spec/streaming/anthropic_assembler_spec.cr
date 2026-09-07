require "../spec_helper"

# The Anthropic assembler, driven by hand-built frames.
#
# This is the protocol where `Streaming::Assembler`'s rule stops being one
# verdict and becomes a decision per block: text and thinking survive being cut
# off, a half-built `tool_use` does not. Most of what follows is that
# distinction, examined from both sides — kept when it should be, dropped when
# it should be.
#
# The other thing pinned here is index handling. Every block frame carries an
# `index`, this protocol does not promise they arrive in order, and an
# assembler that treated arrival order as block order would be right almost
# always, which is the worst frequency for a bug to occur at.

private def frame(name : String, payload : String) : S::Sse::Frame
  S::Sse::Frame.new(payload, name)
end

private def start(index : Int32, block : String) : S::Sse::Frame
  frame("content_block_start", %({"index":#{index},"content_block":#{block}}))
end

private def delta(index : Int32, body : String) : S::Sse::Frame
  frame("content_block_delta", %({"index":#{index},"delta":#{body}}))
end

private def text_delta(index : Int32, text : String) : S::Sse::Frame
  delta(index, %({"type":"text_delta","text":#{text.to_json}}))
end

private def stop(index : Int32) : S::Sse::Frame
  frame("content_block_stop", %({"index":#{index}}))
end

private def text_block : String
  %({"type":"text","text":""})
end

private def assembler : P::Anthropic::Assembler
  P::Anthropic::Assembler.new(P::Anthropic::Exporter.new)
end

private def run(frames : Array(S::Sse::Frame)) : {P::Anthropic::Assembler, Array(S::Event)}
  subject = assembler
  seen = [] of S::Event
  frames.each { |f| subject.absorb(f) { |event| seen << event } }
  {subject, seen}
end

describe Elelem::Protocol::Anthropic::Assembler do
  describe "text blocks" do
    it "accumulates deltas into one block" do
      subject, _ = run([
        start(0, text_block),
        text_delta(0, "Mount "),
        text_delta(0, "Everest"),
        stop(0),
      ])

      subject.response.content.size.should eq 1
      subject.response.content.first.as(P::Anthropic::Wire::TextBlock).text.should eq "Mount Everest"
    end

    it "reports each delta as it arrives" do
      _, seen = run([start(0, text_block), text_delta(0, "Mount "), text_delta(0, "Everest")])

      seen.map { |event| event.as(S::TextDelta).text }.should eq ["Mount ", "Everest"]
    end

    it "ignores a delta for a block that never started" do
      # Defensive rather than expected. A delta with no `content_block_start`
      # describes a block this has no skeleton for, and inventing one would
      # mean guessing its type.
      subject, seen = run([text_delta(3, "orphan")])

      seen.should be_empty
      subject.response.content.should be_empty
    end
  end

  describe "thinking blocks" do
    it "separates thinking from the answer" do
      subject, seen = run([
        start(0, %({"type":"thinking","thinking":""})),
        delta(0, %({"type":"thinking_delta","thinking":"Let me think."})),
        delta(0, %({"type":"signature_delta","signature":"sig-1"})),
        stop(0),
        start(1, text_block),
        text_delta(1, "Everest."),
        stop(1),
      ])

      seen.select(S::ReasoningDelta).map(&.text).should eq ["Let me think."]
      seen.select(S::TextDelta).map(&.text).should eq ["Everest."]
      subject.response.content.size.should eq 2
    end

    it "keeps the signature, which arrives after the text" do
      # Must be replayed unmodified or the next turn is rejected. It arrives on
      # its own delta at the end of the block, so an assembler that closed on
      # first sight of text would lose it.
      subject, _ = run([
        start(0, %({"type":"thinking","thinking":""})),
        delta(0, %({"type":"thinking_delta","thinking":"hm"})),
        delta(0, %({"type":"signature_delta","signature":"sig-1"})),
        stop(0),
      ])

      thinking = subject.response.content.first.as(P::Anthropic::Wire::ThinkingBlock)
      thinking.thinking.should eq "hm"
      thinking.signature.should eq "sig-1"
    end

    it "does not report a signature as something to watch" do
      _, seen = run([
        start(0, %({"type":"thinking","thinking":""})),
        delta(0, %({"type":"signature_delta","signature":"sig-1"})),
      ])

      seen.should be_empty
    end
  end

  describe "tool calls" do
    it "announces the call when the block opens" do
      _, seen = run([
        start(0, %({"type":"tool_use","id":"tu_1","name":"get_weather","input":{}})),
      ])

      seen.first.as(S::ToolCallStarted).name.should eq "get_weather"
    end

    it "assembles arguments from partial JSON" do
      subject, _ = run([
        start(0, %({"type":"tool_use","id":"tu_1","name":"get_weather","input":{}})),
        delta(0, %({"type":"input_json_delta","partial_json":"{\\"city\\":"})),
        delta(0, %({"type":"input_json_delta","partial_json":"\\"Paris\\"}"})),
        stop(0),
      ])

      call = subject.response.content.first.as(P::Anthropic::Wire::ToolUseBlock)
      call.name.should eq "get_weather"
      JSON.parse(call.input)["city"].as_s.should eq "Paris"
    end

    it "reports no events for argument fragments" do
      # Fragments of an arguments object are not watchable and an event
      # carrying them would invite the accumulation this design refuses.
      # `ToolCallStarted` already said a call was coming, by name alone.
      _, seen = run([
        start(0, %({"type":"tool_use","id":"tu_1","name":"f","input":{}})),
        delta(0, %({"type":"input_json_delta","partial_json":"{\\"a\\":1}"})),
      ])

      seen.size.should eq 1
      seen.first.should be_a S::ToolCallStarted
    end
  end

  describe "a stream cut mid-flight" do
    # The rule, decided per block rather than per reply.

    it "keeps text that was still arriving" do
      subject, _ = run([start(0, text_block), text_delta(0, "Mount Ev")])

      subject.complete?.should be_false
      subject.response.content.size.should eq 1
      subject.finish.text.should eq "Mount Ev"
    end

    it "keeps thinking that was still arriving, signature or not" do
      subject, _ = run([
        start(0, %({"type":"thinking","thinking":""})),
        delta(0, %({"type":"thinking_delta","thinking":"Let me th"})),
      ])

      subject.response.content.size.should eq 1
      subject.response.content.first.as(P::Anthropic::Wire::ThinkingBlock).signature.should be_nil
    end

    it "drops a tool call that was still arriving" do
      # The other half. `partial_json` means nothing until the last fragment,
      # so a call cut short is not a call — and must never reach a session
      # where something might dispatch it.
      subject, _ = run([
        start(0, %({"type":"tool_use","id":"tu_1","name":"get_weather","input":{}})),
        delta(0, %({"type":"input_json_delta","partial_json":"{\\"city\\":"})),
      ])

      subject.response.content.should be_empty
      subject.finish.content.select(M::ToolCallBlock).should be_empty
    end

    it "keeps the text and drops the call from the same cut stream" do
      # Both verdicts in one reply, which is what makes this protocol the one
      # where the rule had to be stated per block.
      subject, _ = run([
        start(0, text_block),
        text_delta(0, "Looking that up."),
        stop(0),
        start(1, %({"type":"tool_use","id":"tu_1","name":"get_weather","input":{}})),
        delta(1, %({"type":"input_json_delta","partial_json":"{\\"ci"})),
      ])

      subject.finish.text.should eq "Looking that up."
      subject.finish.content.select(M::ToolCallBlock).should be_empty
    end

    it "drops an empty text block rather than exporting a blank one" do
      subject, _ = run([start(0, text_block)])

      subject.response.content.should be_empty
    end
  end

  describe "the message envelope" do
    it "is not complete until message_stop" do
      subject, _ = run([
        frame("message_start", %({"message":{"id":"msg_1","model":"claude","role":"assistant"}})),
        start(0, text_block),
        text_delta(0, "hi"),
        stop(0),
        frame("message_delta", %({"delta":{"stop_reason":"end_turn"}})),
      ])

      subject.complete?.should be_false
    end

    it "is complete once message_stop arrives" do
      subject, _ = run([frame("message_stop", %({}))])

      subject.complete?.should be_true
    end

    it "takes identity from message_start and stop reason from message_delta" do
      subject, _ = run([
        frame("message_start", %({"message":{"id":"msg_1","model":"claude-x","role":"assistant"}})),
        frame("message_delta", %({"delta":{"stop_reason":"max_tokens"}})),
        frame("message_stop", %({})),
      ])

      subject.response.id.should eq "msg_1"
      subject.response.model.should eq "claude-x"
      subject.response.stop_reason.should eq "max_tokens"
    end

    it "combines the input and output token counts" do
      # `message_start` reports input tokens and `message_delta` reports
      # output tokens, and neither carries the other. Taking only the later
      # one would silently lose the input count a non-streamed reply reports.
      subject, _ = run([
        frame("message_start", %({"message":{"role":"assistant","usage":{"input_tokens":11}}})),
        frame("message_delta", %({"delta":{},"usage":{"output_tokens":7}})),
      ])

      usage = subject.response.usage.should_not be_nil
      usage.input_tokens.should eq 11
      usage.output_tokens.should eq 7
    end

    it "ignores a ping" do
      subject, seen = run([frame("ping", %({"type":"ping"}))])

      seen.should be_empty
      subject.complete?.should be_false
    end

    it "raises on an error frame" do
      expect_raises(P::StreamError, /overloaded_error/) do
        run([frame("error", %({"error":{"type":"overloaded_error","message":"try later"}}))])
      end
    end
  end

  describe "block indices" do
    it "orders blocks by index, not by arrival" do
      # This protocol does not promise frames arrive in index order. An
      # assembler that appended in arrival order would be right almost always,
      # which is the worst frequency for a bug.
      #
      # Asserted on the wire blocks rather than through `Message#text`, which
      # joins separate blocks with a blank line — a first version of this
      # expected "first second" and got the joining instead, testing the
      # exporter when it meant to test the ordering.
      subject, _ = run([
        start(1, text_block),
        start(0, text_block),
        text_delta(0, "first "),
        text_delta(1, "second"),
        stop(0),
        stop(1),
      ])

      subject.response.content
        .map(&.as(P::Anthropic::Wire::TextBlock).text)
        .should eq ["first ", "second"]
    end

    it "keeps deltas for interleaved blocks apart" do
      subject, _ = run([
        start(0, text_block),
        start(1, text_block),
        text_delta(0, "aaa"),
        text_delta(1, "bbb"),
        text_delta(0, "ccc"),
        stop(0),
        stop(1),
      ])

      blocks = subject.response.content.map(&.as(P::Anthropic::Wire::TextBlock).text)
      blocks.should eq ["aaaccc", "bbb"]
    end
  end
end
