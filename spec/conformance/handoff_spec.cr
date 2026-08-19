require "../spec_helper"
require "../fixtures/response_fixtures"
require "../support/conformance"

# The handoff, in miniature and offline.
#
# Everything before this has tested halves: a session mapped out and back, or a
# body read in. This is the first spec that exercises the product claim —
# answer arrives from one provider, conversation continues on another — and it
# needs no network to do it, because a recorded body is as real as a fetched
# one for every purpose except proving the provider still exists.
#
# What it cannot prove is that the *next* request would be accepted. That needs
# the Ollama run.
private alias RF = Elelem::ResponseFixtures

private def continued(reply : M::Message) : M::Session
  session = M::Session.new("You are terse.")
  session << M::Message.user("What is the tallest mountain?")
  session << reply
  session
end

describe "cross-protocol handoff" do
  # The plain case, and the one that must never be interesting.
  it "carries a Chat Completions reply into an Anthropic request" do
    mapper = Elelem::Protocol::ChatCompletions::Mapper.new
    reply = Elelem::Protocol::ChatCompletions::Exporter.new(mapper.calls)
      .export_reply(RF::CHAT_TEXT)

    session = continued(reply)
    request, report = Elelem::Protocol::Anthropic::Mapper.new
      .map(session, "claude-sonnet-4-6", C::Policy::Lenient)

    report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
    request.messages.size.should eq 2
    request.messages[1].role.should eq "assistant"
  end

  # Provenance is historical. A session that acquired a *home* from the
  # provider that answered would not be portable, so the record must be
  # inert — present, and never consulted.
  it "does not let the answering provider influence the next mapping" do
    mapper = Elelem::Protocol::ChatCompletions::Mapper.new
    reply = Elelem::Protocol::ChatCompletions::Exporter.new(mapper.calls)
      .export_reply(RF::CHAT_TEXT)

    reply.provenance.should_not be_nil

    session = continued(reply)
    theirs, _ = Elelem::Protocol::Gemini::Mapper.new.map(session, "gemini-2.0-flash")

    naive = M::Session.new("You are terse.")
    naive << M::Message.user("What is the tallest mountain?")
    naive << M::Message.new(M::Role::Assistant,
      [M::TextBlock.new("Mount Everest, at 8,849 metres.").as(M::Block)])
    ours, _ = Elelem::Protocol::Gemini::Mapper.new.map(naive, "gemini-2.0-flash")

    theirs.to_json.should eq ours.to_json
  end

  # The pairing case. A tool call minted on one protocol must survive being
  # rendered on another, in both the call and the result that answers it.
  it "pairs a tool call read from Gemini with a result rendered on Anthropic" do
    gemini = Elelem::Protocol::Gemini::Mapper.new
    reply = Elelem::Protocol::Gemini::Exporter.new(gemini.calls)
      .export_reply(RF::GEMINI_FUNCTION_CALL)

    calls = reply.content.select(M::ToolCallBlock)
    session = continued(reply)
    session << M::Message.new(M::Role::User, calls.map do |call|
      M::ToolResultBlock.new(call.call_id,
        [M::TextBlock.new("18C").as(M::Block)]).as(M::Block)
    end)

    request, report = Elelem::Protocol::Anthropic::Mapper.new
      .map(session, "claude-sonnet-4-6", C::Policy::Lenient)

    report.annotations.map(&.outcome).should_not contain M::Outcome::Refused

    rendered = request.messages[1].content.select(Elelem::Protocol::Anthropic::Wire::ToolUseBlock)
    results = request.messages[2].content.select(Elelem::Protocol::Anthropic::Wire::ToolResultBlock)

    rendered.size.should eq 2
    results.size.should eq 2
    # Each result names the call it answers, and the two do not collide.
    results.map(&.tool_use_id).sort.should eq rendered.map(&.id).sort
  end

  # The Gemini reader keys reply calls in a provisional space to avoid
  # colliding with session ordinals. That is only safe if the next map rebinds
  # them — so map twice and require the second to agree with the first.
  it "rebinds provisional Gemini call keys on the next map" do
    gemini = Elelem::Protocol::Gemini::Mapper.new
    reply = Elelem::Protocol::Gemini::Exporter.new(gemini.calls)
      .export_reply(RF::GEMINI_FUNCTION_CALL)

    session = continued(reply)
    first, _ = Elelem::Protocol::Gemini::Mapper.new.map(session, "gemini-2.0-flash")
    second, _ = Elelem::Protocol::Gemini::Mapper.new.map(session, "gemini-2.0-flash")

    first.to_json.should eq second.to_json
  end

  # A provider-executed call must not survive into a protocol that would read
  # it as something the caller should run.
  it "does not ask a second provider to dispatch a call the first already ran" do
    anthropic = Elelem::Protocol::Anthropic::Mapper.new
    reply = Elelem::Protocol::Anthropic::Exporter.new(anthropic.calls)
      .export_reply(RF::ANTHROPIC_SERVER_TOOL)

    session = continued(reply)
    _, report = Elelem::Protocol::ChatCompletions::Mapper.new
      .map(session, "llama3.2", C::Policy::Lenient)

    # Chat Completions has no notion of a provider-run tool, so the loss must
    # be *named*. Silence here would be the failure this whole design exists
    # to prevent.
    report.annotations.map(&.outcome).should_not contain M::Outcome::Exact
  end

  # Reasoning is the most protocol-specific thing a reply carries, and the
  # obvious place for a silent drop. But the drop here is only on the *wire*:
  # the signature lives in the block's metadata, which stays in the session.
  # So this is `Restructured`, not `Degraded`, and deliberately not annotated —
  # annotating a shape change that loses nothing would cry wolf on every
  # cross-vendor turn, which is how a fidelity record comes to be ignored.
  #
  # The real requirement is that the signature comes home. A trace signed by
  # Anthropic, sent through a protocol that cannot carry the signature, must
  # still replay to Anthropic afterwards.
  it "survives a detour through a protocol that cannot carry its signature" do
    anthropic = Elelem::Protocol::Anthropic::Mapper.new
    reply = Elelem::Protocol::Anthropic::Exporter.new(anthropic.calls)
      .export_reply(RF::ANTHROPIC_THINKING)

    session = continued(reply)
    key = Elelem::Protocol::Anthropic::METADATA_KEY
    signature = reply.content[0].as(M::ReasoningBlock).meta?(key, "signature")
    signature.should_not be_nil

    # The detour. Nothing worse than Restructured, and no annotation.
    _, report = Elelem::Protocol::ChatCompletions::Mapper.new
      .map(session, "llama3.2", C::Policy::Lenient)
    report.worst.should eq M::Outcome::Restructured
    report.annotations.should be_empty

    # And home again, signature intact — because the wire dropped it, not the
    # session.
    request, _ = Elelem::Protocol::Anthropic::Mapper.new
      .map(session, "claude-sonnet-4-6", C::Policy::Lenient)

    thinking = request.messages[1].content
      .select(Elelem::Protocol::Anthropic::Wire::ThinkingBlock)
    thinking.size.should eq 1
    thinking[0].signature.should eq signature
  end

  # Round the houses: four protocols, one conversation, every reply read from a
  # different wire. If portability means anything, this is it.
  it "accepts replies from all four protocols in one session" do
    session = M::Session.new("You are terse.")
    session << M::Message.user("What is the tallest mountain?")

    chat = Elelem::Protocol::ChatCompletions::Mapper.new
    session << Elelem::Protocol::ChatCompletions::Exporter.new(chat.calls)
      .export_reply(RF::CHAT_TEXT)
    session << M::Message.user("And the deepest ocean?")

    responses = Elelem::Protocol::Responses::Mapper.new
    session << Elelem::Protocol::Responses::Exporter.new(responses.calls)
      .export_reply(RF::RESPONSES_TEXT)
    session << M::Message.user("And the longest river?")

    claude = Elelem::Protocol::Anthropic::Mapper.new
    session << Elelem::Protocol::Anthropic::Exporter.new(claude.calls)
      .export_reply(RF::ANTHROPIC_TEXT)
    session << M::Message.user("And the largest desert?")

    google = Elelem::Protocol::Gemini::Mapper.new
    session << Elelem::Protocol::Gemini::Exporter.new(google.calls)
      .export_reply(RF::GEMINI_TEXT)

    session.messages.size.should eq 8

    # Every protocol must accept the whole thing, whoever answered which turn.
    chat_request, chat_report = Elelem::Protocol::ChatCompletions::Mapper.new
      .map(session, "llama3.2", C::Policy::Lenient)
    claude_request, claude_report = Elelem::Protocol::Anthropic::Mapper.new
      .map(session, "claude-sonnet-4-6", C::Policy::Lenient)
    gemini_request, gemini_report = Elelem::Protocol::Gemini::Mapper.new
      .map(session, "gemini-2.0-flash", C::Policy::Lenient)

    [chat_report, claude_report, gemini_report].each do |report|
      report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
    end

    chat_request.messages.size.should eq 9 # system prompt is a message here
    claude_request.messages.size.should eq 8
    gemini_request.contents.size.should eq 8
  end
end
