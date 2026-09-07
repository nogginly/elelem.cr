require "../spec_helper"

# The Chat Completions assembler, driven by hand-built chunks.
#
# The strictest reading of `Streaming::Assembler`'s rule lives here, because
# this protocol gives the least help: no frame names, no block boundaries, and
# nothing that says a tool call has finished arriving. So calls are withheld
# until a `finish_reason` does, and most of what follows examines that from
# both sides.
#
# Assertions are on `response` — the wire type — except where the exported
# message genuinely is the subject. Reaching through the exporter to check
# something about assembly tests the wrong layer, which is a mistake this suite
# has already made once.

private def chunk(body : String) : S::Sse::Frame
  S::Sse::Frame.new(body)
end

private def delta(body : String, finish : String? = nil) : S::Sse::Frame
  reason = finish ? %("#{finish}") : "null"
  chunk(%({"choices":[{"index":0,"delta":#{body},"finish_reason":#{reason}}]}))
end

private def said(text : String, finish : String? = nil) : S::Sse::Frame
  delta(%({"content":#{text.to_json}}), finish)
end

private def call_fragment(index : Int32, arguments : String,
                          id : String? = nil, name : String? = nil) : S::Sse::Frame
  head = [] of String
  id.try { |value| head << %("id":#{value.to_json}) }
  head << %("index":#{index})
  fn = [] of String
  name.try { |value| fn << %("name":#{value.to_json}) }
  fn << %("arguments":#{arguments.to_json})
  delta(%({"tool_calls":[{#{head.join(',')},"function":{#{fn.join(',')}}}]}))
end

private def assembler : P::ChatCompletions::Assembler
  P::ChatCompletions::Assembler.new(P::ChatCompletions::Exporter.new)
end

private def run(frames : Array(S::Sse::Frame)) : {P::ChatCompletions::Assembler, Array(S::Event)}
  subject = assembler
  seen = [] of S::Event
  frames.each { |f| subject.absorb(f) { |event| seen << event } }
  {subject, seen}
end

private def message(subject : P::ChatCompletions::Assembler) : P::ChatCompletions::Wire::Message
  choice = subject.response.choice.should_not be_nil
  choice.message
end

describe Elelem::Protocol::ChatCompletions::Assembler do
  describe "content" do
    it "accumulates fragments into one message" do
      subject, _ = run([said("Mount "), said("Everest"), said(".", finish: "stop")])

      message(subject).content.should eq "Mount Everest."
    end

    it "reports each fragment as it arrives" do
      _, seen = run([said("Mount "), said("Everest")])

      seen.map { |event| event.as(S::TextDelta).text }.should eq ["Mount ", "Everest"]
    end

    it "says nothing for the empty opening delta" do
      # The first chunk of this protocol customarily carries `"content": ""`
      # alongside the role. An event for it would be a fragment of nothing.
      _, seen = run([delta(%({"role":"assistant","content":""}))])

      seen.should be_empty
    end
  end

  describe "reasoning, spelled two ways" do
    it "reads reasoning_content" do
      _, seen = run([delta(%({"reasoning_content":"hm"}))])

      seen.first.as(S::ReasoningDelta).text.should eq "hm"
    end

    it "reads the bare reasoning field" do
      # Ollama's spelling. Insisting on one silently drops the trace from
      # every server that chose the other, with no error to notice — which is
      # how it was found in the non-streamed reader, by recording.
      _, seen = run([delta(%({"reasoning":"hm"}))])

      seen.first.as(S::ReasoningDelta).text.should eq "hm"
    end

    it "keeps reasoning out of the content" do
      subject, _ = run([delta(%({"reasoning":"thinking"})), said("Everest.", finish: "stop")])

      message(subject).content.should eq "Everest."
      message(subject).reasoning_content.should eq "thinking"
    end
  end

  describe "tool calls" do
    it "assembles arguments from fragments sharing an index" do
      subject, _ = run([
        call_fragment(0, "", id: "call_1", name: "get_weather"),
        call_fragment(0, %({"city":)),
        call_fragment(0, %("Paris"})),
        delta(%({}), finish: "tool_calls"),
      ])

      calls = message(subject).tool_calls.should_not be_nil
      calls.size.should eq 1
      calls.first.name.should eq "get_weather"
      JSON.parse(calls.first.arguments)["city"].as_s.should eq "Paris"
    end

    it "announces the call once, when the name arrives" do
      # Every fragment after the first carries the same index and no name.
      # Announcing per fragment would report one call several times.
      _, seen = run([
        call_fragment(0, "", id: "call_1", name: "get_weather"),
        call_fragment(0, %({"city":"Paris"})),
        delta(%({}), finish: "tool_calls"),
      ])

      seen.select(S::ToolCallStarted).map(&.name).should eq ["get_weather"]
    end

    it "keeps parallel calls apart by index" do
      subject, _ = run([
        call_fragment(0, "", id: "call_1", name: "first"),
        call_fragment(1, "", id: "call_2", name: "second"),
        call_fragment(1, %({"b":2})),
        call_fragment(0, %({"a":1})),
        delta(%({}), finish: "tool_calls"),
      ])

      calls = message(subject).tool_calls.should_not be_nil
      calls.map(&.name).should eq ["first", "second"]
      JSON.parse(calls[0].arguments)["a"].as_i.should eq 1
      JSON.parse(calls[1].arguments)["b"].as_i.should eq 2
    end

    it "reports no events for argument fragments" do
      _, seen = run([
        call_fragment(0, "", id: "call_1", name: "f"),
        call_fragment(0, %({"a":1})),
      ])

      seen.size.should eq 1
      seen.first.should be_a S::ToolCallStarted
    end
  end

  describe "a stream cut mid-generation" do
    # The strictest application of the rule in this shard.

    it "keeps content that was still arriving" do
      subject, _ = run([said("Mount Ev")])

      subject.complete?.should be_false
      message(subject).content.should eq "Mount Ev"
    end

    it "withholds a tool call whose arguments look complete" do
      # The dangerous case, and the reason calls wait for a finish reason
      # rather than for arguments that parse. Nothing in this protocol
      # distinguishes arguments that are complete from arguments that are
      # complete *so far*, so `{"city":"Paris"}` here may still be a prefix of
      # `{"city":"Paris","unit":"c"}`.
      subject, _ = run([
        call_fragment(0, "", id: "call_1", name: "get_weather"),
        call_fragment(0, %({"city":"Paris"})),
      ])

      subject.complete?.should be_false
      message(subject).tool_calls.should be_nil
    end

    it "keeps the content and withholds the call from the same cut stream" do
      subject, _ = run([
        said("Looking that up."),
        call_fragment(0, "", id: "call_1", name: "get_weather"),
        call_fragment(0, %({"city":"Paris"})),
      ])

      message(subject).content.should eq "Looking that up."
      message(subject).tool_calls.should be_nil
      subject.finish.content.select(M::ToolCallBlock).should be_empty
    end

    it "releases the same call once a finish reason arrives" do
      # The other side of the previous example: identical fragments, one more
      # chunk, and the call is now known to be whole.
      subject, _ = run([
        call_fragment(0, "", id: "call_1", name: "get_weather"),
        call_fragment(0, %({"city":"Paris"})),
        delta(%({}), finish: "tool_calls"),
      ])

      message(subject).tool_calls.should_not be_nil
      subject.finish.content.select(M::ToolCallBlock).size.should eq 1
    end
  end

  describe "the envelope" do
    it "is complete once a finish reason arrives" do
      subject, _ = run([said("Everest.", finish: "stop")])

      subject.complete?.should be_true
      choice = subject.response.choice.should_not be_nil
      choice.finish_reason.should eq "stop"
    end

    it "is complete on [DONE] even without a finish reason" do
      subject, _ = run([said("Everest."), chunk("[DONE]")])

      subject.complete?.should be_true
    end

    it "does not mistake [DONE] for JSON" do
      # Why `Sse::Frame#data` is a String. A parser in the shared framing layer
      # would have had to fail here or special-case this one protocol.
      subject, seen = run([chunk("[DONE]")])

      seen.should be_empty
      subject.complete?.should be_true
    end

    it "keeps usage from a final chunk carrying no choices" do
      # `stream_options.include_usage` produces exactly this shape. A reader
      # requiring a choice would throw the token count away.
      subject, _ = run([
        said("Everest.", finish: "stop"),
        chunk(%({"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}})),
      ])

      usage = subject.response.usage.should_not be_nil
      usage.total_tokens.should eq 18
    end

    it "takes identity from whichever chunk carried it" do
      subject, _ = run([
        chunk(%({"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{"role":"assistant"}}]})),
        said("hi", finish: "stop"),
      ])

      subject.response.id.should eq "chatcmpl-1"
      subject.response.model.should eq "gpt-x"
    end

    it "ignores a chunk it cannot parse" do
      subject, seen = run([chunk("not json")])

      seen.should be_empty
      subject.complete?.should be_false
    end

    it "raises on an error chunk" do
      expect_raises(P::StreamError, /rate_limit_exceeded/) do
        run([chunk(%({"error":{"type":"rate_limit_exceeded","message":"slow down"}}))])
      end
    end
  end
end
