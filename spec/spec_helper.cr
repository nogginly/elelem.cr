require "spec"
require "../src/elelem"
require "./fixtures/mpsh_fixtures"

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
