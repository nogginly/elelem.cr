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

  # `:once` locally, so a new live spec records itself. `:none` in CI, so a
  # missing transcript fails the build instead of quietly reaching for the
  # network — which on the paid endpoints would also be a bill.
  c.record_mode = ENV["CI"]? ? :none : :once

  # Minted call identifiers carry a timestamp — `mc_<epoch-ms>_<counter>` — so
  # a request replaying one can never digest the same way twice, and any
  # multi-turn transcript containing a tool call would be unreplayable. Worse,
  # it would look fixed after every re-record, since re-recording is what hid
  # the problem in the first place.
  #
  # Normalised rather than made deterministic: the identifiers only have to be
  # unique within a session, and a process-wide counter would be stable only
  # while example order never changed — trading a replay problem for an
  # ordering dependency. From wiretap 0.4.0 this affects matching only, so the
  # committed transcript still records the identifier that actually went over
  # the wire.
  c.normalize_body = ->(body : String) { body.gsub(/mc_\d+_(\d+)/, "mc_MINTED_\\1") }
end

# Green is not the same as replayed.
#
# Under `:once` a missing transcript is recorded rather than failed, so a suite
# can pass while asserting against a recording the code under test made seconds
# earlier. That is not a hypothetical: three tool specs did exactly this for as
# long as anyone looked at them, and the underlying bug surfaced only when a run
# finally happened without a re-record.
#
# `verify!` raises if anything was recorded, which makes the distinction
# visible. Set `RECORD=1` for the runs where recording is the point — cutting a
# new transcript, or re-cutting one a deliberate request change invalidated.
Spec.after_suite { Wiretap.verify! unless ENV["RECORD"]? }

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
