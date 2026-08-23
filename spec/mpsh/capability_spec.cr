require "../spec_helper"

# Pass B: the capability matrix, exercised before any mapper exists.
#
# Each assertion is the matrix's prediction for one (block, protocol) pair. If
# the resolver and the four declared profiles are right, these hold; if a
# profile is wrong, this is the cheapest possible moment to find out, because
# nothing depends on it yet.
#
# Still entirely structural: no request is built, nothing is sent.
describe "capability resolution" do
  describe "text" do
    it "is exact everywhere" do
      session = Elelem::Fixtures.single_user_turn
      ALL_PROFILES.each do |profile|
        outcome_of(session, 0, 0, profile).should eq(M::Outcome::Exact)
      end
    end
  end

  describe "images in a user message" do
    it "restructures into a data URI for the OpenAI protocols" do
      session = Elelem::Fixtures.text_and_image
      outcome_of(session, 0, 1, CHAT).should eq(M::Outcome::Restructured)
      outcome_of(session, 0, 1, RESPONSES).should eq(M::Outcome::Restructured)
    end

    it "is exact where media type and payload form are both native" do
      session = Elelem::Fixtures.text_and_image
      outcome_of(session, 0, 1, CLAUDE).should eq(M::Outcome::Exact)
      outcome_of(session, 0, 1, GEMINI).should eq(M::Outcome::Exact)
    end

    it "tests the media type, not the block kind" do
      # WEBP is accepted by three profiles and not by Anthropic. Were
      # capability declared per kind, this would resolve identically to the
      # PNG above.
      session = Elelem::Fixtures.unsupported_media_type
      outcome_of(session, 0, 1, GEMINI).should eq(M::Outcome::Exact)
      outcome_of(session, 0, 1, CHAT).should eq(M::Outcome::Restructured)
    end
  end

  describe "audio" do
    it "is exact only where it is natively accepted" do
      session = Elelem::Fixtures.audio_with_transcript
      outcome_of(session, 0, 1, GEMINI).should eq(M::Outcome::Exact)
    end

    it "degrades to the transcript where the media type is not accepted" do
      session = Elelem::Fixtures.audio_with_transcript
      outcome_of(session, 0, 1, CLAUDE).should eq(M::Outcome::Degraded)
    end

    it "refuses when there is no transcript to degrade to" do
      session = Elelem::Fixtures.audio_without_transcript
      outcome_of(session, 0, 1, CLAUDE).should eq(M::Outcome::Refused)
    end
  end

  describe "tool calls" do
    it "is exact where the protocol models a call as a block" do
      session = Elelem::Fixtures.tool_call_text_result
      outcome_of(session, 1, 0, CLAUDE).should eq(M::Outcome::Exact)
      outcome_of(session, 1, 0, GEMINI).should eq(M::Outcome::Exact)
    end

    it "restructures where the call is hoisted to a field or item" do
      session = Elelem::Fixtures.tool_call_text_result
      outcome_of(session, 1, 0, CHAT).should eq(M::Outcome::Restructured)
      outcome_of(session, 1, 0, RESPONSES).should eq(M::Outcome::Restructured)
    end
  end

  # The pair that validates the design. Neither assertion alone proves
  # anything: one protocol must fake the capability, one has it natively, and
  # the same fixture exercises both.
  describe "the image-bearing tool result" do
    it "compensates where a tool result can only be a string" do
      session = Elelem::Fixtures.tool_call_image_result
      outcome_of(session, 2, 0, CHAT).should eq(M::Outcome::Compensated)
      outcome_of(session, 2, 0, RESPONSES).should eq(M::Outcome::Compensated)
    end

    it "is exact where a tool result is a nested block list" do
      session = Elelem::Fixtures.tool_call_image_result
      outcome_of(session, 2, 0, CLAUDE).should eq(M::Outcome::Exact)
    end

    it "leaves a text-only result unremarkable everywhere" do
      session = Elelem::Fixtures.tool_call_text_result
      outcome_of(session, 2, 0, CLAUDE).should eq(M::Outcome::Exact)
      outcome_of(session, 2, 0, CHAT).should eq(M::Outcome::Restructured)
    end
  end

  describe "server-executed tools" do
    it "is exact only for the provider that ran them" do
      session = Elelem::Fixtures.server_executed_tool
      outcome_of(session, 1, 0, CLAUDE).should eq(M::Outcome::Exact)
    end

    it "degrades to text for a protocol that ran no such tool" do
      # Gemini supports server-executed tools; it did not run *this* one.
      session = Elelem::Fixtures.server_executed_tool
      outcome_of(session, 1, 0, GEMINI).should eq(M::Outcome::Degraded)
      outcome_of(session, 1, 0, CHAT).should eq(M::Outcome::Degraded)
    end

    it "degrades the result alongside the call" do
      session = Elelem::Fixtures.server_executed_tool
      outcome_of(session, 2, 0, CHAT).should eq(M::Outcome::Degraded)
      outcome_of(session, 2, 0, CLAUDE).should eq(M::Outcome::Exact)
    end
  end

  describe "reasoning" do
    it "is exact for the provider that produced it, where the form can hold it" do
      # Both protocols own this block. Only one can carry it: the Responses API
      # models reasoning as an item, which keeps an opaque payload, while Chat
      # Completions has only a text field.
      session = Elelem::Fixtures.reasoning_with_provider_payload
      outcome_of(session, 1, 0, RESPONSES).should eq(M::Outcome::Exact)
    end

    it "degrades redacted reasoning where the wire form carries only text" do
      # Ownership plus a declared wire home is still not sufficient — the form
      # has to be able to hold what the block actually contains. Redacted
      # reasoning has no text at all.
      session = Elelem::Fixtures.reasoning_with_provider_payload
      outcome_of(session, 1, 0, CHAT).should eq(M::Outcome::Degraded)
    end

    it "restructures for a foreign provider whose payload it can still hold" do
      # Gemini has nowhere signature-shaped to check, so a foreign opaque
      # payload is still Restructured there: the block stays in MPSH and only
      # the unreadable payload is shed. Were this Degraded on every protocol,
      # strict policy would refuse every cross-provider handoff of a
      # reasoning-model session — precisely the move this shard exists to
      # perform.
      #
      # Not true for Anthropic, and not from principle — from a live 400
      # (`spec/live/anthropic_spec.cr`). This fixture is `redacted: true` with
      # no text at all, so "shed the payload, keep the block" would have sent
      # `{"type":"thinking","thinking":""}` with no `signature`: an empty,
      # invalid block, arguably worse than the unattributed case beside this
      # test. Whether Gemini has the same requirement is genuinely open —
      # nothing here has tested it live yet, unlike Anthropic.
      session = Elelem::Fixtures.reasoning_with_provider_payload
      outcome_of(session, 1, 0, CLAUDE).should eq(M::Outcome::Degraded)
      outcome_of(session, 1, 0, GEMINI).should eq(M::Outcome::Restructured)
    end

    it "treats unattributed reasoning as portable, except where the wire requires a signature to say so" do
      session = Elelem::Fixtures.reasoning_with_text

      # True for three of four: no metadata to lose means nothing foreign to
      # shed, so the block maps straight through.
      [CHAT, RESPONSES, GEMINI].each do |profile|
        outcome_of(session, 1, 0, profile).should eq(M::Outcome::Exact)
      end

      # Not true for Anthropic. Confirmed live, not assumed: a `thinking`
      # block with no `signature` fails Anthropic's own request schema
      # outright (`spec/live/anthropic_spec.cr`), so "unattributed" cannot
      # mean "portable" here the way it does everywhere else — there is
      # nothing to replay, which is indistinguishable on the wire from a
      # foreign signature that was stripped. See
      # `Profile#reasoning_signature_required?`.
      outcome_of(session, 1, 0, CLAUDE).should eq(M::Outcome::Degraded)
    end

    it "refuses to drop a foreign reasoning item mid-tool-call" do
      session = Elelem::Fixtures.reasoning_mid_tool_call
      mid = C::Resolver::Nesting::MidToolCall
      outcome_of(session, 1, 0, CLAUDE, mid).should eq(M::Outcome::Refused)
    end
  end

  describe "refusal" do
    it "is exact where the protocol has a refusal channel" do
      session = Elelem::Fixtures.refusal_with_reason
      outcome_of(session, 1, 0, CHAT).should eq(M::Outcome::Exact)
    end

    it "carries the reason as text where there is no channel" do
      session = Elelem::Fixtures.refusal_with_reason
      outcome_of(session, 1, 0, CLAUDE).should eq(M::Outcome::Restructured)
    end

    it "degrades when there is no reason to carry" do
      session = Elelem::Fixtures.refusal_without_reason
      outcome_of(session, 1, 0, CLAUDE).should eq(M::Outcome::Degraded)
    end
  end

  describe "foreign provider metadata" do
    it "is ignored rather than misread" do
      session = Elelem::Fixtures.foreign_provider_metadata
      block = session.messages[1].content.first
      # Anthropic's cache marker means nothing to OpenAI, and text remains text.
      C::Resolver.outcome(block, CHAT).should eq(M::Outcome::Exact)
      block.meta_for(CHAT.provider).should be_nil
    end
  end
end

describe "structural adaptation" do
  it "requires nothing of the permissive protocols" do
    messages = Elelem::Fixtures.consecutive_same_role.messages
    C::Structural.required(messages, CHAT).should be_empty
  end

  it "compensates a merge for an alternation-requiring protocol" do
    messages = Elelem::Fixtures.consecutive_same_role.messages
    required = C::Structural.required(messages, CLAUDE)

    required.should contain(C::Structural::Adaptation::MergeConsecutiveRoles)
    C::Structural.outcome(C::Structural::Adaptation::MergeConsecutiveRoles)
      .should eq(M::Outcome::Compensated)
  end

  it "compensates a placeholder when history opens with the assistant" do
    messages = Elelem::Fixtures.assistant_first.messages
    C::Structural.required(messages, CLAUDE)
      .should contain(C::Structural::Adaptation::PrependUserPlaceholder)
    C::Structural.required(messages, CHAT)
      .should_not contain(C::Structural::Adaptation::PrependUserPlaceholder)
  end

  it "restructures a relocated system prompt" do
    messages = Elelem::Fixtures.with_system_prompt.messages
    C::Structural.required(messages, RESPONSES)
      .should contain(C::Structural::Adaptation::MoveSystemPrompt)
    C::Structural.outcome(C::Structural::Adaptation::MoveSystemPrompt)
      .should eq(M::Outcome::Restructured)
  end
end

describe "degradation policy" do
  it "permits outcomes no worse than its threshold" do
    C::Policy::Strict.permits?(M::Outcome::Restructured).should be_true
    C::Policy::Strict.permits?(M::Outcome::Compensated).should be_false
    C::Policy::Compensating.permits?(M::Outcome::Compensated).should be_true
    C::Policy::Compensating.permits?(M::Outcome::Degraded).should be_false
    C::Policy::Lenient.permits?(M::Outcome::Degraded).should be_true
    C::Policy::Lenient.permits?(M::Outcome::Refused).should be_false
  end

  it "annotates loss and stays quiet about rearrangement" do
    report = C::Report.new(CHAT.provider, C::Policy::Lenient)
    report.record(M::Outcome::Restructured, "image to data URI")
    report.record(M::Outcome::Degraded, "audio to transcript",
      block_kind: M::BlockKind::Audio)

    report.annotations.size.should eq(1)
    report.annotations.first.outcome.should eq(M::Outcome::Degraded)
    report.worst.should eq(M::Outcome::Degraded)
  end

  it "raises when an outcome exceeds the policy" do
    report = C::Report.new(CHAT.provider, C::Policy::Strict)
    expect_raises(C::RefusedError, /Compensated/) do
      report.record(M::Outcome::Compensated, "image-bearing tool result")
    end
  end
end

describe "reasoning retention" do
  it "keeps everything by default" do
    messages = Elelem::Fixtures.reasoning_across_turns.messages
    plan = C::Retention.plan(messages, C::ReasoningRetention::All)
    plan.dropped.should eq(0)
  end

  it "trims completed turns but never the open one" do
    messages = Elelem::Fixtures.reasoning_across_turns.messages
    plan = C::Retention.plan(messages, C::ReasoningRetention::CompletedTurns)

    plan.dropped.should eq(2)
    plan.retain?(5).should be_true # the open turn's reasoning survives
    plan.retain?(1).should be_false
  end

  it "never trims reasoning that sits mid-tool-call" do
    messages = Elelem::Fixtures.reasoning_mid_tool_call.messages
    plan = C::Retention.plan(messages, C::ReasoningRetention::CompletedTurns)
    plan.dropped.should eq(0)
  end

  it "drops everything on request" do
    messages = Elelem::Fixtures.reasoning_across_turns.messages
    plan = C::Retention.plan(messages, C::ReasoningRetention::None)
    plan.dropped.should eq(3)
    plan.retain?(5).should be_false
  end
end
