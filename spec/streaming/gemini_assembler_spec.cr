require "../spec_helper"

# The Gemini assembler, driven by hand-built chunks.
#
# Where the Responses spec pins *which frames are kept*, this pins *how parts
# merge* — because that is the whole of what this assembler does and the only
# place a bug can hide. Gemini emits no finished units, so every reply here is
# built by concatenation, and concatenation is where order, interleaving and
# signature survival are either right or quietly wrong.
#
# Chunks are written as literal JSON for the same reason the SSE spec writes
# literal frames: the thing under test is what arrives on the wire. Reading a
# part is `Wire::Response`'s job and is already specced against recorded
# transcripts, so the parts below stay minimal.

private def chunk(body : String) : S::Sse::Frame
  # No event names on this protocol — Gemini sends bare `data:` lines.
  S::Sse::Frame.new(body)
end

private def text_chunk(text : String, finish : String? = nil) : S::Sse::Frame
  reason = finish ? %(,"finishReason":#{finish.to_json}) : ""
  chunk(%({"candidates":[{"content":{"role":"model","parts":[{"text":#{text.to_json}}]}#{reason}}]}))
end

private def assembler : P::Gemini::Assembler
  P::Gemini::Assembler.new(P::Gemini::Exporter.new)
end

private def run(frames : Array(S::Sse::Frame)) : {P::Gemini::Assembler, Array(S::Event)}
  subject = assembler
  seen = [] of S::Event
  frames.each { |f| subject.absorb(f) { |event| seen << event } }
  {subject, seen}
end

private def parts(subject : P::Gemini::Assembler) : Array(P::Gemini::Wire::Part)
  candidate = subject.response.candidate.should_not be_nil
  candidate.content.parts
end

describe Elelem::Protocol::Gemini::Assembler do
  describe "merging text" do
    it "concatenates fragments into one part" do
      # The behaviour the Responses assembler explicitly refuses, and which is
      # correct here: this protocol never sends a finished text unit, so the
      # alternative to concatenating is a reply consisting of the last
      # fragment.
      subject, _ = run([text_chunk("Mount "), text_chunk("Everest"), text_chunk(".")])

      parts(subject).size.should eq 1
      parts(subject).first.as(P::Gemini::Wire::TextPart).text.should eq "Mount Everest."
    end

    it "reports every fragment as it arrives" do
      _, seen = run([text_chunk("Mount "), text_chunk("Everest")])

      seen.map { |event| event.as(S::TextDelta).text }.should eq ["Mount ", "Everest"]
    end

    it "exports one text block, not one per chunk" do
      subject, _ = run([text_chunk("Mount "), text_chunk("Everest")])

      subject.finish.content.select(M::TextBlock).size.should eq 1
      subject.finish.text.should eq "Mount Everest"
    end
  end

  describe "merging thoughts" do
    it "keeps thoughts separate from the answer" do
      subject, _ = run([
        chunk(%({"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"Let me "}]}}]})),
        chunk(%({"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"think."}]}}]})),
        text_chunk("Everest."),
      ])

      list = parts(subject)
      list.size.should eq 2
      list[0].as(P::Gemini::Wire::ThoughtPart).text.should eq "Let me think."
      list[1].as(P::Gemini::Wire::TextPart).text.should eq "Everest."
    end

    it "reports thoughts as reasoning rather than as answer text" do
      _, seen = run([
        chunk(%({"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"hm"}]}}]})),
      ])

      seen.first.should be_a S::ReasoningDelta
    end

    it "keeps a signature that arrived on any fragment" do
      # Signatures must be replayed unmodified or the next turn is rejected.
      # If one arrives on the first fragment and the second carries none,
      # merging must not erase it.
      subject, _ = run([
        chunk(%({"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"a","thoughtSignature":"sig-1"}]}}]})),
        chunk(%({"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"b"}]}}]})),
      ])

      thought = parts(subject).first.as(P::Gemini::Wire::ThoughtPart)
      thought.text.should eq "ab"
      thought.signature.should eq "sig-1"
    end
  end

  describe "parts that are never merged" do
    it "takes a function call whole" do
      subject, seen = run([
        text_chunk("Looking that up. "),
        chunk(%({"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_weather","args":{"city":"Paris"}}}]}}]})),
      ])

      call = parts(subject).last.as(P::Gemini::Wire::FunctionCallPart)
      call.name.should eq "get_weather"
      seen.select(S::ToolCallStarted).map(&.name).should eq ["get_weather"]
    end

    it "does not fold text across a function call" do
      # Order and position are preserved: text on either side of a call stays
      # on its own side. Merging only ever touches the last part, so an
      # interleaving cannot be reordered into something tidier and wrong.
      subject, _ = run([
        text_chunk("Before "),
        chunk(%({"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"f","args":{}}}]}}]})),
        text_chunk("after"),
      ])

      list = parts(subject)
      list.size.should eq 3
      list[0].should be_a P::Gemini::Wire::TextPart
      list[1].should be_a P::Gemini::Wire::FunctionCallPart
      list[2].as(P::Gemini::Wire::TextPart).text.should eq "after"
    end
  end

  describe "the envelope" do
    it "is not complete until a finish reason arrives" do
      subject, _ = run([text_chunk("Mount ")])

      subject.complete?.should be_false
    end

    it "is complete once one does" do
      subject, _ = run([text_chunk("Everest.", finish: "STOP")])

      subject.complete?.should be_true
      subject.response.candidate.should_not be_nil
    end

    it "treats a truncated answer as complete rather than failed" do
      # `MAX_TOKENS` is a stream that finished reporting an answer that did
      # not — the same distinction Responses draws with `response.incomplete`.
      subject, _ = run([text_chunk("Mount Ev", finish: "MAX_TOKENS")])

      subject.complete?.should be_true
      candidate = subject.response.candidate.should_not be_nil
      candidate.finish_reason.should eq "MAX_TOKENS"
    end

    it "keeps usage and model version from whichever chunk carried them" do
      subject, _ = run([
        text_chunk("Everest."),
        chunk(%({"modelVersion":"gemini-3.5-flash","usageMetadata":{"totalTokenCount":42},"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"STOP"}]})),
      ])

      subject.response.model_version.should eq "gemini-3.5-flash"
      usage = subject.response.usage.should_not be_nil
      usage.total_tokens.should eq 42
    end

    it "ignores a chunk carrying no candidates" do
      subject, seen = run([
        chunk(%({"usageMetadata":{"totalTokenCount":7}})),
      ])

      seen.should be_empty
      parts(subject).should be_empty
    end

    it "ignores a chunk it cannot parse" do
      subject, seen = run([chunk("not json")])

      seen.should be_empty
      subject.complete?.should be_false
    end

    it "raises on an error chunk" do
      expect_raises(P::StreamError, /RESOURCE_EXHAUSTED/) do
        run([chunk(%({"error":{"status":"RESOURCE_EXHAUSTED","message":"quota"}}))])
      end
    end
  end

  describe "a stream that stopped early" do
    it "yields everything that had arrived" do
      subject, _ = run([text_chunk("Mount "), text_chunk("Everest")])

      subject.complete?.should be_false
      subject.finish.text.should eq "Mount Everest"
    end

    it "carries no finish reason" do
      subject, _ = run([text_chunk("Mount ")])

      candidate = subject.response.candidate.should_not be_nil
      candidate.finish_reason.should be_nil
    end
  end
end
