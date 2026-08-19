require "../spec_helper"
require "../support/conformance"

# Round-trip conformance for the Responses API.
#
# The comparator is reused unchanged, which is itself a small proof: a
# comparator needing protocol-specific special-casing would mean the
# abstraction leaks.
#
# What this phase does *not* prove is worth restating. This protocol shares
# every assumption with Chat Completions — flexible roles, no alternation, model
# in the body — so passing here means the mapper works, not that the abstraction
# does. That test is the checkpoint.
private def rt(session : M::Session, policy = C::Policy::Lenient)
  mapper = Elelem::Protocol::Responses::Mapper.new
  request, report = mapper.map(session, "test-model", policy)
  exporter = Elelem::Protocol::Responses::Exporter.new(mapper.calls)
  {exporter.export(request), report, request}
end

private def diverges(name : String, policy = C::Policy::Lenient)
  session = Elelem::Fixtures.all[name]
  exported, report, request = rt(session, policy)
  {Conformance.compare(session, exported), report, request}
end

RESPONSES_EXACT = %w[
  single_user_turn
  multi_turn_alternating
  with_system_prompt
  without_system_prompt
  consecutive_same_role
  assistant_first
  single_text_block
  multiple_text_blocks
  text_and_image
  unsupported_media_type
  audio_with_transcript
  audio_without_transcript
  tool_call_text_result
  tool_result_error
  reasoning_with_text
  refusal_with_reason
]

describe "Responses API round trip" do
  RESPONSES_EXACT.each do |name|
    it "reproduces #{name} exactly" do
      found, _, _ = diverges(name)
      found.map(&.to_s).should be_empty
    end
  end

  # The point of Phase 2. Same fixture, same suite, opposite outcomes — decided
  # by declared capability alone, with no protocol-specific test code.
  describe "divergence from Chat Completions" do
    it "round-trips redacted reasoning, which the sibling protocol degrades" do
      found, report, _ = diverges("reasoning_with_provider_payload")

      found.map(&.to_s).should be_empty
      report.annotations.map(&.outcome).should_not contain(M::Outcome::Degraded)
    end

    it "carries the opaque payload as an item field" do
      _, _, request = diverges("reasoning_with_provider_payload")
      json = request.to_json
      json.should contain(%("type":"reasoning"))
      json.should contain(%("encrypted_content":"b3BhcXVl"))
    end

    it "puts the system prompt in instructions, not the input array" do
      _, _, request = diverges("with_system_prompt")
      request.instructions.should eq("You are a helpful assistant")
      request.to_json.should contain(%("instructions":))
    end
  end

  describe "the compensation path" do
    it "restores an image-bearing tool result" do
      found, _, _ = diverges("tool_call_image_result")
      found.map(&.to_s).should be_empty
    end

    it "renders a placeholder output item plus one synthetic message" do
      _, _, request = diverges("tool_call_image_result")
      types = request.input.map(&.class.name.split("::").last)
      types.should eq(%w[MessageItem FunctionCallItem FunctionCallOutputItem MessageItem MessageItem])

      request.input[2].as(Elelem::Protocol::Responses::Wire::FunctionCallOutputItem)
        .output.should contain("returned separately")
      request.input[3].as(Elelem::Protocol::Responses::Wire::MessageItem)
        .synthetic?.should be_true
    end

    it "refuses under a strict policy" do
      expect_raises(C::RefusedError) { diverges("tool_call_image_result", C::Policy::Strict) }
    end
  end

  describe "declared divergences" do
    it "cannot express a server-executed tool it did not run" do
      found, report, _ = diverges("server_executed_tool")
      report.annotations.map(&.outcome).should contain(M::Outcome::Degraded)
      found.should_not be_empty
    end

    it "cannot carry a reference payload without a blob store" do
      expect_raises(C::RefusedError, /blob store/) { diverges("reference_payload") }
    end

    it "keeps foreign provider metadata off the wire and says so" do
      found, _, _ = diverges("foreign_provider_metadata")
      found.map(&.change).should contain(Conformance::Change::ProviderMetadata)
    end
  end
end
