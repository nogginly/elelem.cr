require "../spec_helper"

# The Responses assembler, driven by hand-built frames.
#
# Hand-built is the right call *here* and would be the wrong call for the reply
# content: what these pin is the assembler's arithmetic — which frames are
# stored, which become events, which win — and that is transport shape rather
# than model output. The item bodies below are deliberately minimal, because
# reading items is `Wire::Response`'s job and is already specced against
# recorded transcripts. Duplicating that here would test the same code twice
# and pin the fixtures to a shape a provider is free to extend.
#
# The one thing no offline spec can settle is whether Ollama's Responses
# emulation actually emits `response.output_item.done`. That is what the live
# recording is for.

private def frame(name : String, payload : String) : S::Sse::Frame
  S::Sse::Frame.new(payload, name)
end

private def text_item(text : String) : String
  %({"type":"message","role":"assistant","content":[{"type":"output_text","text":#{text.to_json}}]})
end

private def call_item(name : String, id : String) : String
  %({"type":"function_call","name":#{name.to_json},"call_id":#{id.to_json},"arguments":"{}"})
end

private def assembler : P::Responses::Assembler
  P::Responses::Assembler.new(P::Responses::Exporter.new)
end

# Feeds frames in and collects whatever came out to be watched.
private def run(frames : Array(S::Sse::Frame)) : {P::Responses::Assembler, Array(S::Event)}
  subject = assembler
  seen = [] of S::Event
  frames.each { |f| subject.absorb(f) { |event| seen << event } }
  {subject, seen}
end

describe Elelem::Protocol::Responses::Assembler do
  describe "events" do
    it "reports text fragments as they arrive" do
      _, seen = run([
        frame("response.output_text.delta", %({"delta":"Hel"})),
        frame("response.output_text.delta", %({"delta":"lo"})),
      ])

      seen.map { |event| event.as(S::TextDelta).text }.should eq(["Hel", "lo"])
    end

    it "reports reasoning fragments" do
      _, seen = run([
        frame("response.reasoning_summary_text.delta", %({"delta":"thinking"})),
      ])

      seen.first.should be_a(S::ReasoningDelta)
      seen.first.as(S::ReasoningDelta).text.should eq("thinking")
    end

    it "announces a tool call by name and nothing more" do
      # The event carries no identifier and no arguments on purpose, so that
      # nothing can be dispatched from it. See `Streaming::ToolCallStarted`.
      _, seen = run([
        frame("response.output_item.added",
          %({"item":{"type":"function_call","name":"get_weather","call_id":"c1"}})),
      ])

      seen.first.should be_a(S::ToolCallStarted)
      seen.first.as(S::ToolCallStarted).name.should eq("get_weather")
    end

    it "says nothing when a plain message begins" do
      _, seen = run([
        frame("response.output_item.added", %({"item":{"type":"message","role":"assistant"}})),
      ])

      seen.should be_empty
    end

    it "falls back to the payload's own type when the frame is unnamed" do
      # Compatibility ports have been known to send bare `data:` frames.
      subject = assembler
      seen = [] of S::Event
      subject.absorb(S::Sse::Frame.new(
        %({"type":"response.output_text.delta","delta":"hi"}))) { |event| seen << event }

      seen.first.as(S::TextDelta).text.should eq("hi")
    end

    it "ignores lifecycle frames it has no use for" do
      _, seen = run([
        frame("response.created", %({"response":{"id":"r1"}})),
        frame("response.in_progress", %({})),
        frame("response.content_part.added", %({"part":{"type":"output_text"}})),
        frame("response.output_text.done", %({"text":"Hello"})),
      ])

      seen.should be_empty
    end

    it "ignores a frame it cannot parse" do
      # Nothing is lost quietly: had this been the terminal frame, `complete?`
      # would stay false and the client would raise.
      subject, seen = run([frame("response.output_text.delta", "not json at all")])

      seen.should be_empty
      subject.complete?.should be_false
    end
  end

  describe "assembling from finished items" do
    it "collects an item each time one finishes" do
      subject, _ = run([
        frame("response.output_item.done", %({"item":#{text_item("Hello")}})),
      ])

      subject.accumulated.output.size.should eq(1)
      subject.response.output.size.should eq(1)
    end

    it "never stores a delta" do
      # Deltas are watched and discarded. If they were accumulated, this would
      # produce an item.
      subject, _ = run([
        frame("response.output_text.delta", %({"delta":"Hel"})),
        frame("response.output_text.delta", %({"delta":"lo"})),
      ])

      subject.accumulated.output.should be_empty
    end

    it "keeps items in the order they finished" do
      subject, _ = run([
        frame("response.output_item.done", %({"item":#{text_item("first")}})),
        frame("response.output_item.done", %({"item":#{call_item("get_weather", "c1")}})),
      ])

      subject.accumulated.output[0].should be_a(P::Responses::Wire::MessageItem)
      subject.accumulated.output[1].should be_a(P::Responses::Wire::FunctionCallItem)
    end
  end

  describe "the terminal frame" do
    it "is what gets exported once it arrives" do
      subject, _ = run([
        frame("response.output_item.done", %({"item":#{text_item("Hello")}})),
        frame("response.completed",
          %({"response":{"id":"r1","status":"completed","output":[#{text_item("Hello")}]}})),
      ])

      subject.complete?.should be_true
      subject.response.id.should eq("r1")
      subject.response.status.should eq("completed")
    end

    it "treats an incomplete response as terminal rather than as a failure" do
      # The model hit a limit. The object says so honestly and the status
      # reaches the reply's metadata; there is nothing here to raise about.
      subject, _ = run([
        frame("response.incomplete",
          %({"response":{"status":"incomplete","output":[#{text_item("Hel")}]}})),
      ])

      subject.complete?.should be_true
      subject.response.status.should eq("incomplete")
    end

    it "leaves the independent accumulation intact for comparison" do
      # The oracle. On a live transcript these two are asserted equal, which is
      # a real check against the vendor's own assembly rather than against a
      # hand-written expectation.
      subject, _ = run([
        frame("response.output_item.done", %({"item":#{text_item("Hello")}})),
        frame("response.completed",
          %({"response":{"status":"completed","output":[#{text_item("Hello")}]}})),
      ])

      subject.accumulated.output.size.should eq(subject.response.output.size)
    end

    it "raises when the provider reports a failed response" do
      expect_raises(P::StreamError, /rate_limit/) do
        run([frame("response.failed",
          %({"response":{"error":{"code":"rate_limit","message":"slow down"}}}))])
      end
    end

    it "raises on a mid-stream error frame" do
      expect_raises(P::StreamError, /overloaded/) do
        run([frame("error", %({"code":"overloaded","message":"try later"}))])
      end
    end
  end

  describe "a stream that stopped early" do
    it "is not complete" do
      subject, _ = run([
        frame("response.output_item.done", %({"item":#{text_item("Hello")}})),
      ])

      subject.complete?.should be_false
    end

    it "still yields the finished items as a reply" do
      # The reason the shortcut of keeping only the terminal frame was
      # rejected: without this, `Turn#stop` returns nothing at all.
      subject, _ = run([
        frame("response.output_item.done", %({"item":#{text_item("Hello")}})),
      ])

      reply = subject.finish
      reply.text.should eq("Hello")
    end

    it "reports itself incomplete" do
      subject, _ = run([
        frame("response.output_item.done", %({"item":#{text_item("Hello")}})),
      ])

      subject.response.status.should eq("incomplete")
    end

    it "omits a tool call that had not finished arriving" do
      # `output_item.added` announced it; no `output_item.done` ever came. It
      # is not in the reply, which is what keeps a half-received call out of a
      # session.
      subject, _ = run([
        frame("response.output_item.added",
          %({"item":{"type":"function_call","name":"get_weather","call_id":"c1"}})),
        frame("response.function_call_arguments.delta", %({"delta":"{\\"city\\":"})),
      ])

      subject.finish.content.select(M::ToolCallBlock).should be_empty
    end

    it "yields an empty reply when nothing finished at all" do
      subject, _ = run([frame("response.output_text.delta", %({"delta":"Hel"}))])

      subject.finish.content.should be_empty
    end
  end
end
