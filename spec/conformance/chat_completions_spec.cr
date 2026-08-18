require "../spec_helper"
require "../support/conformance"

# Round-trip conformance for Chat Completions.
#
# Every fixture goes MPSH → request → MPSH. Fixtures listed in `EXACT` must come
# back untouched; the rest declare the divergence the capability matrix predicts
# for them. A failure is one of three things, and naming which is mandatory:
# mapping bug, wrong matrix, or a genuine gap in MPSH.
private def round_trip(session : M::Session, policy = C::Policy::Lenient)
  mapper = Elelem::Protocol::ChatCompletions::Mapper.new
  request, report = mapper.map(session, "test-model", policy)
  exporter = Elelem::Protocol::ChatCompletions::Exporter.new(mapper.calls)
  {exporter.export(request), report, request}
end

private def divergences(name : String, policy = C::Policy::Lenient)
  session = Elelem::Fixtures.all[name]
  exported, report, request = round_trip(session, policy)
  {Conformance.compare(session, exported), report, request}
end

# Fixtures that must survive untouched. Anything moving out of this list is a
# regression unless the matrix moved with it. Declared at the top level because
# a `describe` block is a method body, where constants cannot be defined.
EXACT_FIXTURES = %w[
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

describe "Chat Completions round trip" do
  EXACT_FIXTURES.each do |name|
    it "reproduces #{name} exactly" do
      found, _, _ = divergences(name)
      found.map(&.to_s).should be_empty
    end
  end

  describe "the compensation path" do
    it "restores an image-bearing tool result through placeholder and carrier" do
      found, _, _ = divergences("tool_call_image_result")
      found.map(&.to_s).should be_empty
    end

    it "renders a placeholder plus one synthetic message on the wire" do
      _, _, request = divergences("tool_call_image_result")
      roles = request.messages.map(&.role)
      roles.should eq(%w[user assistant tool user assistant])

      tool = request.messages[2]
      tool.content.as(String).should contain("returned separately")

      carrier = request.messages[3]
      carrier.synthetic?.should be_true
      carrier.content.as(Array(Elelem::Protocol::ChatCompletions::Wire::Part))
        .size.should eq(1)
    end

    it "leaves no synthetic message in the exported session" do
      session = Elelem::Fixtures.tool_call_image_result
      exported, _, _ = round_trip(session)

      exported.messages.size.should eq(session.messages.size)
      result = exported.messages[2].content.first.as(M::ToolResultBlock)
      result.content.size.should eq(2)
      result.content[1].should be_a(M::ImageBlock)
    end

    it "records the compensation rather than performing it silently" do
      _, report, _ = divergences("tool_call_image_result")
      report.annotations.map(&.outcome).should contain(M::Outcome::Compensated)
    end

    it "refuses under a strict policy" do
      expect_raises(C::RefusedError) do
        divergences("tool_call_image_result", C::Policy::Strict)
      end
    end
  end

  describe "declared divergences" do
    it "degrades a server-executed tool to text and cannot restore it" do
      found, report, _ = divergences("server_executed_tool")

      report.annotations.map(&.outcome).should contain(M::Outcome::Degraded)
      found.map(&.change).should contain(Conformance::Change::BlockKind)
    end

    # Audio degrades and refuses on Anthropic, which accepts no audio media
    # types at all. This protocol carries WAV natively, so both audio fixtures
    # sit in the exact list above. The degrade-versus-refuse ladder is exercised
    # in Phase 3, against the protocol that actually triggers it.

    it "cannot carry a reference payload without a blob store" do
      expect_raises(C::RefusedError, /blob store/) do
        divergences("reference_payload")
      end
    end

    it "loses redacted reasoning entirely, because the field carries only text" do
      # `reasoning_content` is a string. Redacted reasoning has no text — its
      # content is an opaque payload in `provider_metadata` — so there is
      # nothing to put in the field and the block cannot survive.
      found, report, _ = divergences("reasoning_with_provider_payload")

      report.annotations.map(&.outcome).should contain(M::Outcome::Degraded)
      found.map(&.change).should contain(Conformance::Change::BlockCount)
    end

    it "keeps foreign provider metadata out of the wire and says so" do
      found, _, _ = divergences("foreign_provider_metadata")
      found.map(&.change).should contain(Conformance::Change::ProviderMetadata)
    end

    it "cannot distinguish a reasonless refusal from an empty turn" do
      found, _, _ = divergences("refusal_without_reason")
      found.should_not be_empty
    end
  end

  describe "the wire form" do
    it "never emits a canonical type" do
      _, _, request = divergences("text_and_image")
      json = request.to_json
      json.should contain(%("model":"test-model"))
      json.should contain("data:image/png;base64,")
      json.should_not contain("text_fallback")
      json.should_not contain("provider_metadata")
    end

    it "places the system prompt in the messages array" do
      _, _, request = divergences("with_system_prompt")
      request.messages.first.role.should eq("system")
    end

    it "hoists a tool call onto the assistant message" do
      _, _, request = divergences("tool_call_text_result")
      assistant = request.messages[1]
      assistant.tool_calls.not_nil!.size.should eq(1)
      assistant.tool_calls.not_nil!.first.arguments.should contain("Kyoto")
    end
  end
end
