require "../spec_helper"
require "../fixtures/response_fixtures"

# Response-shaped export, per protocol.
#
# The round-trip suite next door cannot cover this: it starts from an MPSH
# session, and a response body never was one. These specs start from the wire
# instead, which is the only way to test a reader — a fixture built by our own
# mapper would agree with our own assumptions by construction.
#
# Offline throughout. Every body here is recorded, not fetched.
private alias RF = Elelem::ResponseFixtures

private def chat_reply(body : String)
  mapper = Elelem::Protocol::ChatCompletions::Mapper.new
  Elelem::Protocol::ChatCompletions::Exporter.new(mapper.calls).export_reply(body)
end

private def responses_reply(body : String)
  mapper = Elelem::Protocol::Responses::Mapper.new
  Elelem::Protocol::Responses::Exporter.new(mapper.calls).export_reply(body)
end

private def anthropic_reply(body : String)
  mapper = Elelem::Protocol::Anthropic::Mapper.new
  Elelem::Protocol::Anthropic::Exporter.new(mapper.calls).export_reply(body)
end

private def gemini_reply(body : String)
  mapper = Elelem::Protocol::Gemini::Mapper.new
  Elelem::Protocol::Gemini::Exporter.new(mapper.calls).export_reply(body)
end

describe "response export" do
  describe "Chat Completions" do
    it "reads a plain text reply" do
      reply = chat_reply(RF::CHAT_TEXT)

      reply.role.should eq M::Role::Assistant
      reply.content.size.should eq 1
      reply.content[0].as(M::TextBlock).text.should eq "Mount Everest, at 8,849 metres."
    end

    it "records provenance from the model that answered" do
      reply = chat_reply(RF::CHAT_TEXT)

      provenance = reply.provenance.should_not be_nil
      provenance.model.should eq "llama3.2"
    end

    it "keeps non-content facts out of the content" do
      reply = chat_reply(RF::CHAT_TEXT)
      key = Elelem::Protocol::ChatCompletions::METADATA_KEY

      reply.meta?(key, "finish_reason").should eq "stop"
      reply.meta?(key, "response_id").should_not be_nil
      reply.meta?(key, "usage").should_not be_nil
    end

    # Un-hoisting. `tool_calls` is a message field on the wire and blocks in
    # MPSH, and two calls to the same function is where an id scheme that
    # relies on names would quietly fail.
    it "un-hoists tool calls into blocks with distinct ids" do
      reply = chat_reply(RF::CHAT_TOOL_CALL)

      calls = reply.content.select(M::ToolCallBlock)
      calls.size.should eq 2
      calls.map(&.name).should eq ["get_weather", "get_weather"]
      calls[0].call_id.should_not eq calls[1].call_id
      calls[0].arguments["location"].should eq "Paris, France"
    end

    it "parses fused arguments into an object" do
      reply = chat_reply(RF::CHAT_TOOL_CALL)

      arguments = reply.content.select(M::ToolCallBlock)[1].arguments
      arguments.should be_a M::Object
      arguments["location"].should eq "Bogota, Colombia"
    end

    it "reads the non-standard reasoning field the Ollama path depends on" do
      reply = chat_reply(RF::CHAT_REASONING)

      reasoning = reply.content.select(M::ReasoningBlock)
      reasoning.size.should eq 1
      reasoning[0].text.should_not be_nil
      # Reasoning precedes the answer, as it does on the wire.
      reply.content[0].should be_a M::ReasoningBlock
    end

    it "reads a refusal as a refusal, not as text" do
      reply = chat_reply(RF::CHAT_REFUSAL)

      reply.content.select(M::RefusalBlock).size.should eq 1
      reply.content.select(M::TextBlock).should be_empty
    end
  end

  describe "Responses" do
    it "reads a plain text reply" do
      reply = responses_reply(RF::RESPONSES_TEXT)

      reply.content.size.should eq 1
      reply.content[0].as(M::TextBlock).text.should eq "Mount Everest, at 8,849 metres."
    end

    it "walks output entire rather than taking the first item" do
      reply = responses_reply(RF::RESPONSES_REASONING_AND_CALL)

      reply.content.size.should eq 2
      reply.content[0].should be_a M::ReasoningBlock
      reply.content[1].should be_a M::ToolCallBlock
    end

    # The opaque payload is what makes a reasoning trace replayable. Losing it
    # is a silent failure: the block survives, the trace does not.
    it "preserves the encrypted reasoning payload" do
      reply = responses_reply(RF::RESPONSES_REASONING_AND_CALL)
      key = Elelem::Protocol::Responses::METADATA_KEY

      block = reply.content[0].as(M::ReasoningBlock)
      block.meta?(key, "encrypted_content").should eq "gAAAAABn0zBxAbCdEf1234=="
    end

    it "splits a message carrying both text and a refusal into two blocks" do
      reply = responses_reply(RF::RESPONSES_REFUSAL)

      reply.content.select(M::TextBlock).size.should eq 1
      reply.content.select(M::RefusalBlock).size.should eq 1
    end
  end

  describe "Anthropic" do
    it "reads a plain text reply" do
      reply = anthropic_reply(RF::ANTHROPIC_TEXT)

      reply.content.size.should eq 1
      reply.content[0].as(M::TextBlock).text.should eq "Mount Everest, at 8,849 metres."
    end

    # `input` is structured here and fused on the OpenAI protocols. It is
    # re-serialized by the reader and parsed at export, so this asserts the
    # round trip through text loses nothing.
    it "parses a structured tool input into an object" do
      reply = anthropic_reply(RF::ANTHROPIC_TOOL_USE)

      call = reply.content.select(M::ToolCallBlock)[0]
      call.name.should eq "get_weather"
      call.arguments["location"].should eq "San Francisco, CA"
      call.arguments["unit"].should eq "celsius"
    end

    it "keeps the thinking signature, which must replay unmodified" do
      reply = anthropic_reply(RF::ANTHROPIC_THINKING)
      key = Elelem::Protocol::Anthropic::METADATA_KEY

      block = reply.content[0].as(M::ReasoningBlock)
      block.meta?(key, "signature").should_not be_nil
    end

    # The correctness case, and the reason this reader exists rather than
    # waiting for a live key. A provider-run tool read as client-executed is
    # not a lossy mapping — it is an instruction to run something the caller
    # does not have.
    it "marks a provider-executed tool call as server executed" do
      reply = anthropic_reply(RF::ANTHROPIC_SERVER_TOOL)

      call = reply.content.select(M::ToolCallBlock)[0]
      call.server_executed?.should be_true
    end

    it "keeps a provider-executed call out of what a caller would dispatch" do
      reply = anthropic_reply(RF::ANTHROPIC_SERVER_TOOL)

      dispatchable = reply.content.select(M::ToolCallBlock).reject(&.server_executed?)
      dispatchable.should be_empty
    end

    it "reads the accompanying result as server executed too" do
      reply = anthropic_reply(RF::ANTHROPIC_SERVER_TOOL)

      results = reply.content.select(M::ToolResultBlock)
      results.size.should eq 1
      results[0].server_executed?.should be_true
    end
  end

  describe "Gemini" do
    it "reads a plain text reply and normalizes the role" do
      reply = gemini_reply(RF::GEMINI_TEXT)

      # `model` on the wire, Assistant in MPSH. The commonest silent mapping
      # error on this protocol.
      reply.role.should eq M::Role::Assistant
      reply.content[0].as(M::TextBlock).text.should eq "Mount Everest, at 8,849 metres."
    end

    it "mints distinct ids for calls the wire gave no identifier" do
      reply = gemini_reply(RF::GEMINI_FUNCTION_CALL)

      calls = reply.content.select(M::ToolCallBlock)
      calls.size.should eq 2
      calls[0].call_id.should_not eq calls[1].call_id
      calls[0].arguments["location"].should eq "Paris"
      calls[1].arguments["location"].should eq "Bogota"
    end

    # A thought part also carries `text`. Checked in the wrong order every
    # reasoning trace becomes ordinary prose — no error, no symptom, just a
    # quietly wrong transcript.
    it "reads a flagged text part as reasoning, not as text" do
      reply = gemini_reply(RF::GEMINI_THOUGHT)

      reply.content[0].should be_a M::ReasoningBlock
      reply.content[1].should be_a M::TextBlock
      reply.content.select(M::TextBlock).size.should eq 1
    end

    # Metadata keys are snake_case regardless of the wire's spelling, matching
    # `signature` and `encrypted_content` on the other protocols. The mapper
    # reads this key back when replaying the thought.
    it "keeps the thought signature under the key the mapper replays" do
      reply = gemini_reply(RF::GEMINI_THOUGHT)
      key = Elelem::Protocol::Gemini::METADATA_KEY

      reply.content[0].as(M::ReasoningBlock).meta?(key, "thought_signature").should_not be_nil
    end
  end

  describe "malformed bodies" do
    it "raises rather than returning an empty reply for non-JSON" do
      expect_raises(Elelem::Protocol::MalformedResponseError) do
        chat_reply("not json at all")
      end
    end

    # An error object where a reply was expected is the commonest real
    # failure, and the one where returning an empty message would be worst:
    # the turn would look answered.
    it "raises when the protocol's own envelope is absent" do
      expect_raises(Elelem::Protocol::MalformedResponseError) do
        chat_reply(%({"error": {"message": "model not found", "type": "invalid_request"}}))
      end

      expect_raises(Elelem::Protocol::MalformedResponseError) do
        gemini_reply(%({"error": {"code": 429, "message": "quota exceeded"}}))
      end
    end
  end
end
