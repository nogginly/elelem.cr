require "../spec_helper"

# `"usage": null`, in all four protocols at once.
#
# One file rather than four scattered examples, because this is one bug with
# four copies: every `Usage.parse` guarded against an *absent* key and none
# against a present one holding a JSON null. A null passes a truthiness check —
# `JSON::Any` wrapping nil is not Crystal's `nil` — and is then indexed into as
# a hash, which raises from inside the reader with a message about Hash that
# says nothing about usage.
#
# Found live against Azure, which sends `"usage": null` on every streamed chunk
# until the last. OpenAI does the same. Ollama omits the key entirely, so three
# protocols were proven against an emulator more forgiving than the endpoints
# it imitates — the opposite of the divergence this design kept predicting, and
# the reason the vendor recordings were worth their cost.
#
# Kept as a shared spec so that a fifth protocol, or a rewritten reader, is
# checked against the same expectation without anyone having to remember why.

private def null_usage : JSON::Any
  JSON.parse(%({"usage":null}))["usage"]
end

private def absent : JSON::Any?
  JSON.parse(%({}))["usage"]?
end

describe "Usage.parse with an explicitly null value" do
  it "reads null as no usage on Chat Completions" do
    P::ChatCompletions::Wire::Usage.parse(null_usage).should be_nil
  end

  it "reads null as no usage on Anthropic" do
    P::Anthropic::Wire::Usage.parse(null_usage).should be_nil
  end

  it "reads null as no usage on Gemini" do
    P::Gemini::Wire::Usage.parse(null_usage).should be_nil
  end

  it "reads null as no usage on Responses" do
    P::Responses::Wire::Usage.parse(null_usage).should be_nil
  end

  it "still reads an absent key as no usage" do
    # The case the original guard did handle, kept so a fix for the null case
    # cannot quietly break it.
    P::ChatCompletions::Wire::Usage.parse(absent).should be_nil
    P::Anthropic::Wire::Usage.parse(absent).should be_nil
    P::Gemini::Wire::Usage.parse(absent).should be_nil
    P::Responses::Wire::Usage.parse(absent).should be_nil
  end

  it "still reads a real usage object" do
    parsed = JSON.parse(%({"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}))
    usage = P::ChatCompletions::Wire::Usage.parse(parsed).should_not be_nil

    usage.total_tokens.should eq 18
  end

  it "reads a chunk carrying a null usage alongside real content" do
    # The shape that actually arrives: every streamed chunk carries the key,
    # and only the last one fills it in.
    subject = P::ChatCompletions::Assembler.new(P::ChatCompletions::Exporter.new)
    subject.absorb(S::Sse::Frame.new(
      %({"usage":null,"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}))) { |_| }
    subject.absorb(S::Sse::Frame.new(
      %({"choices":[],"usage":{"total_tokens":18}}))) { |_| }

    subject.response.usage.should_not be_nil
  end
end
