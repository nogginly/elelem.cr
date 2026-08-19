require "../spec_helper"
require "../support/conformance"

# Round-trip conformance for Anthropic Messages.
#
# This is the checkpoint, and the first real test of the abstraction. Chat
# Completions and Responses differ in surface while sharing every assumption;
# this protocol shares almost none of them. It is simultaneously the most
# capable target and the strictest validator, which is why it is the pair to
# Phase 1 rather than a repeat of it.
#
# Unexecuted against a live model, deliberately: keys gate execution, not
# mapping.
private def rt(session : M::Session, policy = C::Policy::Lenient)
  mapper = Elelem::Protocol::Anthropic::Mapper.new
  request, report = mapper.map(session, "test-model", policy)
  exporter = Elelem::Protocol::Anthropic::Exporter.new(mapper.calls)
  {exporter.export(request), report, request}
end

private def diverges(name : String, policy = C::Policy::Lenient)
  session = Elelem::Fixtures.all[name]
  exported, report, request = rt(session, policy)
  {Conformance.compare(session, exported), report, request}
end

ANTHROPIC_EXACT = %w[
  single_user_turn
  multi_turn_alternating
  with_system_prompt
  without_system_prompt
  single_text_block
  multiple_text_blocks
  text_and_image
  unsupported_media_type
  tool_call_text_result
  tool_result_error
  reasoning_with_text
]

describe "Anthropic round trip" do
  ANTHROPIC_EXACT.each do |name|
    it "reproduces #{name} exactly" do
      found, _, _ = diverges(name)
      found.map(&.to_s).should be_empty
    end
  end

  # Criterion 4, and the counterpart to Chat Completions' compensation. The
  # same fixture, one protocol faking the capability and one with it natively.
  # Neither assertion alone proves anything.
  describe "the exact path" do
    it "maps an image-bearing tool result with no compensation" do
      found, report, _ = diverges("tool_call_image_result")

      found.map(&.to_s).should be_empty
      report.annotations.map(&.outcome).should_not contain(M::Outcome::Compensated)
    end

    it "nests the image inside tool_result rather than synthesizing a message" do
      _, _, request = diverges("tool_call_image_result")

      request.messages.size.should eq(4)
      result = request.messages[2].content.first
        .as(Elelem::Protocol::Anthropic::Wire::ToolResultBlock)
      result.content.size.should eq(2)
      result.content[1].should be_a(Elelem::Protocol::Anthropic::Wire::ImageBlock)
      request.to_json.should_not contain("returned separately")
    end

    it "passes under a strict policy, which Chat Completions cannot" do
      found, _, _ = diverges("tool_call_image_result", C::Policy::Strict)
      found.map(&.to_s).should be_empty
    end
  end

  describe "strict validation" do
    it "merges consecutive same-role messages, which does not round-trip" do
      found, report, request = diverges("consecutive_same_role")

      request.messages.size.should eq(2)
      report.annotations.map(&.outcome).should contain(M::Outcome::Compensated)
      found.map(&.change).should contain(Conformance::Change::MessageCount)
    end

    it "prepends a placeholder when history opens with an assistant turn" do
      _, report, request = diverges("assistant_first")

      request.messages.first.role.should eq("user")
      request.messages.first.synthetic?.should be_true
      report.annotations.map(&.outcome).should contain(M::Outcome::Compensated)
    end

    it "discards its own placeholder on export" do
      session = Elelem::Fixtures.assistant_first
      exported, _, _ = rt(session)
      exported.messages.size.should eq(session.messages.size)
      exported.messages.first.role.should eq(M::Role::Assistant)
    end

    it "records dropping an empty message rather than doing it quietly" do
      _, report, _ = diverges("empty_message")
      report.annotations.map(&.outcome).should contain(M::Outcome::Degraded)
    end

    it "always sends max_tokens" do
      _, _, request = diverges("single_user_turn")
      request.max_tokens.should eq(Elelem::Protocol::Anthropic::DEFAULT_MAX_TOKENS)
      request.to_json.should contain(%("max_tokens":))
    end

    it "puts the system prompt in a parameter, not the messages array" do
      _, _, request = diverges("with_system_prompt")
      request.system.should eq("You are a helpful assistant")
      request.messages.none? { |message| message.role == "system" }.should be_true
    end
  end

  # The first protocol where the ladder actually fires: no audio media type is
  # accepted here, so the fixtures that were exact on both OpenAI protocols
  # separate for the first time.
  describe "degrade versus refuse" do
    it "degrades audio to its transcript" do
      found, report, _ = diverges("audio_with_transcript")

      report.annotations.map(&.outcome).should contain(M::Outcome::Degraded)
      found.map(&.change).should contain(Conformance::Change::BlockKind)
    end

    it "refuses audio with no transcript" do
      expect_raises(C::RefusedError) { diverges("audio_without_transcript") }
    end

    it "tests the media type rather than the block kind" do
      # WEBP is accepted here, so the fixture named `unsupported_media_type` is
      # exact against this protocol — the name describes the OpenAI case that
      # motivated it, not a universal fact. Audio is where this protocol's
      # per-media-type gap actually lies: the kind is unsupported entirely
      # because no audio media type is accepted, which the two tests above
      # cover.
      found, _, _ = diverges("unsupported_media_type")
      found.map(&.to_s).should be_empty
    end
  end

  # Provider-run tools are a distinct block type here — `server_tool_use` and a
  # tool-specific result — rather than a flag on an ordinary call. That
  # agreement with MPSH's own categorisation is why the flag survives here and
  # degrades on every other protocol.
  describe "server-executed tools" do
    it "keeps the server_executed flag across a round trip" do
      session = Elelem::Fixtures.server_executed_tool
      exported, _, _ = rt(session)

      exported.messages[1].content.first.as(M::ToolCallBlock).server_executed?.should be_true
      exported.messages[2].content.first.as(M::ToolResultBlock).server_executed?.should be_true
    end

    it "emits distinct block types rather than an ordinary tool_use" do
      _, _, request = diverges("server_executed_tool")
      json = request.to_json
      json.should contain(%("type":"server_tool_use"))
      json.should contain(%("type":"web_search_tool_result"))
    end

    it "preserves the tool-specific result type, which is not derivable" do
      session = Elelem::Fixtures.server_executed_tool
      exported, _, _ = rt(session)
      exported.messages[2].content.first
        .meta?("anthropic", "result_type").should eq("web_search_tool_result")
    end

    it "drops vendor bookkeeping the wire has no slot for" do
      # `tool_name` duplicates the block's own `name` field and no wire field
      # carries it, so it is dropped — named here rather than silently.
      found, _, _ = diverges("server_executed_tool")
      found.map(&.change).should contain(Conformance::Change::ProviderMetadata)
    end
  end

  describe "declared divergences" do
    it "restructures a refusal into text, losing the refusal channel" do
      found, _, _ = diverges("refusal_with_reason")
      found.map(&.change).should contain(Conformance::Change::BlockKind)
    end

    it "keeps foreign provider metadata off the wire and says so" do
      found, _, _ = diverges("reasoning_with_provider_payload")
      found.map(&.change).should contain(Conformance::Change::ProviderMetadata)
    end

    it "cannot carry a reference payload without a blob store" do
      expect_raises(C::RefusedError, /blob store/) { diverges("reference_payload") }
    end
  end
end
