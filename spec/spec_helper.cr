require "spec"
require "wiretap"
require "../src/elelem"
require "./fixtures/mpsh_fixtures"

# Live specs record once against a real server and replay from disk thereafter.
# Transcripts are committed: they are the evidence for the handoff milestone,
# and they are what makes the suite offline and deterministic for everyone who
# did not record them.
Wiretap.configure do |c|
  c.transcript_dir = "spec/transcripts"
  c.record_mode = :once
end

# Shorthands shared by every spec file. Declared once here rather than in each
# file, since specs reopen the same namespace and a repeated `alias` is a
# redefinition error.
alias M = Elelem::MPSH
alias C = Elelem::Capability

module SpecHelpers
  extend self

  CHAT      = Elelem::Protocol::ChatCompletions::PROFILE
  RESPONSES = Elelem::Protocol::Responses::PROFILE
  CLAUDE    = Elelem::Protocol::Anthropic::PROFILE
  GEMINI    = Elelem::Protocol::Gemini::PROFILE

  ALL_PROFILES = [CHAT, RESPONSES, CLAUDE, GEMINI]

  # Resolve the capability outcome for one content block of one message.
  def outcome_of(session : M::Session, message : Int32, block : Int32,
                 profile : C::Profile,
                 nesting = C::Resolver::Nesting::TopLevel) : M::Outcome
    C::Resolver.outcome(session.messages[message].content[block], profile, nesting)
  end
end

include SpecHelpers
