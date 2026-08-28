require "../spec_helper"
require "../support/conformance"

# Round-trip conformance for Gemini `generateContent`.
#
# The structurally most divergent protocol, and the last mapper. If MPSH has a
# gap left, this is where it shows: tool calls carry no identifier at all, so
# pairing must be reconstructed from function name and ordering — the case the
# `CallIdTable` design exists for, and the first time it has run without a
# provider id to lean on.
private def rt(session : M::Session, policy = C::Policy::Lenient)
  mapper = Elelem::Protocol::Gemini::Mapper.new
  request, report = mapper.map(session, "gemini-test", policy)
  exporter = Elelem::Protocol::Gemini::Exporter.new(mapper.calls)
  {exporter.export(request), report, request}
end

private def diverges(name : String, policy = C::Policy::Lenient)
  session = Elelem::Fixtures.all[name]
  exported, report, request = rt(session, policy)
  {Conformance.compare(session, exported), report, request}
end

GEMINI_EXACT = %w[
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
  reasoning_with_text
]

describe "Gemini round trip" do
  GEMINI_EXACT.each do |name|
    it "reproduces #{name} exactly" do
      found, _, _ = diverges(name)
      found.map(&.to_s).should be_empty
    end
  end

  describe "structural divergence" do
    it "spells the assistant role as model" do
      _, _, request = diverges("multi_turn_alternating")
      request.contents.map(&.role).should eq(%w[user model user model])
    end

    it "wraps every message in parts, with no string shorthand" do
      _, _, request = diverges("single_user_turn")
      json = request.to_json
      json.should contain(%("parts":[{"text":))
      json.should_not contain(%("content":))
    end

    it "keeps the model in the URL path rather than the body" do
      _, _, request = diverges("single_user_turn")
      request.path.should eq("models/gemini-test:generateContent")
      request.to_json.should_not contain("gemini-test")
    end

    it "structures systemInstruction like any other content object" do
      _, _, request = diverges("with_system_prompt")
      request.to_json.should contain(%("systemInstruction":{"parts":[{"text":))
    end

    it "keeps media type and base64 separate, with no data URI" do
      _, _, request = diverges("text_and_image")
      json = request.to_json
      json.should contain(%("mime_type":"image/png"))
      json.should_not contain("data:image/png;base64,")
    end
  end

  # The reason this protocol is the real test of the identity design.
  describe "tool pairing without identifiers" do
    it "emits no identifier on a function call" do
      _, _, request = diverges("tool_call_text_result")
      json = request.to_json
      json.should contain(%("functionCall":{"name":"get_weather"))
      json.should_not contain("call_id")
      json.should_not contain(Elelem::Fixtures::CALL_WEATHER)
    end

    it "reconstructs the pairing from name and ordering" do
      session = Elelem::Fixtures.tool_call_text_result
      exported, _, _ = rt(session)

      call = exported.messages[1].content.first.as(M::ToolCallBlock)
      result = exported.messages[2].content.first.as(M::ToolResultBlock)
      result.call_id.should eq(call.call_id)
    end

    it "names the function on the response, since nothing else identifies it" do
      _, _, request = diverges("tool_call_text_result")
      request.to_json.should contain(%("functionResponse":{"name":"get_weather"))
    end
  end

  describe "the compensation path" do
    it "restores an image-bearing tool result" do
      found, _, _ = diverges("tool_call_image_result")
      found.map(&.to_s).should be_empty
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

    it "restructures a refusal into text, having no refusal channel" do
      found, _, _ = diverges("refusal_with_reason")
      found.map(&.change).should contain(Conformance::Change::BlockKind)
    end

    it "keeps another vendor's metadata off the wire and says so" do
      found, _, _ = diverges("reasoning_with_provider_payload")
      found.map(&.change).should contain(Conformance::Change::ProviderMetadata)
    end

    it "cannot carry a reference payload without a blob store" do
      expect_raises(C::RefusedError, /blob store/) { diverges("reference_payload") }
    end
  end

  # The Gemini 3 requirement, and the reason it is keyed on the model rather
  # than declared on the protocol.
  #
  # Every test above runs on `gemini-test`, which is in no catalog entry and
  # therefore behaves like the 2.5 series — which is why `tool_call_text_result`
  # is still in `GEMINI_EXACT` above and must stay there. These run the same
  # mapper over the same fixture with the profile the catalog resolves for a
  # Gemini 3 model, so the two behaviours are pinned side by side rather than
  # one of them being assumed.
  describe "tool call signatures, keyed on the model" do
    signed = Elelem::Capability::Catalog.narrow(
      Elelem::Protocol::Gemini::PROFILE, "gemini-3.5-flash")

    it "requires a signature on Gemini 3 and not on the 2.5 series" do
      signed.tool_call_signature_required?.should be_true

      unsigned = Elelem::Capability::Catalog.narrow(
        Elelem::Protocol::Gemini::PROFILE, "gemini-2.5-flash")
      unsigned.tool_call_signature_required?.should be_false
    end

    it "degrades a tool call carrying no signature of this vendor's" do
      session = Elelem::Fixtures.tool_call_text_result
      mapper = Elelem::Protocol::Gemini::Mapper.new(signed)
      request, report = mapper.map(session, "gemini-3.5-flash", C::Policy::Lenient)

      report.annotations
        .select { |a| a.block_kind == M::BlockKind::ToolCall }
        .map(&.outcome).should contain(M::Outcome::Degraded)

      # The point of the check: the invalid part never reaches the wire.
      request.to_json.should_not contain("functionCall")
    end

    it "refuses rather than degrading under a strict policy" do
      session = Elelem::Fixtures.tool_call_text_result
      mapper = Elelem::Protocol::Gemini::Mapper.new(signed)
      expect_raises(C::RefusedError) { mapper.map(session, "gemini-3.5-flash", C::Policy::Strict) }
    end

    it "maps a signed call exactly, since it has something to replay" do
      session = Elelem::Fixtures.tool_call_text_result
      call = session.messages[1].content.first.as(M::ToolCallBlock)
      call.put_meta("gemini", "thought_signature", "CtEHAdHtim9Cn1t7A0hSFtT8yTWM0")

      mapper = Elelem::Protocol::Gemini::Mapper.new(signed)
      request, report = mapper.map(session, "gemini-3.5-flash", C::Policy::Lenient)

      report.annotations
        .select { |a| a.block_kind == M::BlockKind::ToolCall }
        .should be_empty
      request.to_json.should contain(%("thoughtSignature":"CtEHAdHtim9Cn1t7A0hSFtT8yTWM0"))
    end

    # Narrowing is one-directional here as everywhere else, and this axis is
    # the one where the permissive value is `false` — so the guard reads
    # backwards and is worth pinning.
    it "will not let a catalog entry waive a requirement" do
      expect_raises(ArgumentError, /never remove/) do
        signed.with_tool_call_signature_required(false)
      end
    end
  end
end
