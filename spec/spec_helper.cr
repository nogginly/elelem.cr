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

  # Minted call identifiers carry a timestamp and a process-wide counter —
  # `mc_<epoch-ms>_<counter>` — so the same body can never digest identically
  # twice, and any multi-turn transcript containing a tool call would be
  # unreplayable as recorded.
  #
  # Relabelled by first-occurrence order within each body, not merely
  # stripped: identifiers only have to be unique *within a session*, so what
  # must match between record and replay is which occurrences share an
  # identifier, not what the identifier's literal value was. A regex that kept
  # the counter digits looked like it satisfied this but didn't — the counter
  # is process-wide, so its value depends on how many identifiers every
  # *other* example minted first, which depends on spec execution order,
  # which is not guaranteed identical across platforms. That surfaced as
  # Ubuntu x86 and Windows failing in CI while three other platforms stayed
  # green, from a transcript that had not changed at all.
  #
  # This normalization is a pure function of one body's own content — no
  # counter, no execution order, nothing external — so going forward it stays
  # stable across platforms regardless of spec execution order.
  #
  # It is not retroactive, though: `Transcript#find_interaction` compares
  # against `body_digest` as stored in the transcript file, frozen at record
  # time under whatever `normalize_body` was in effect then — it never
  # recomputes from the stored `body`. Changing this function invalidates the
  # stored digest of any transcript containing an `mc_` id, on every platform,
  # deterministically. Those need one re-record; see `spec/transcripts/` for
  # which ones (`grep -l mc_`).
  c.normalize_body = ->(body : String) {
    seen = {} of String => Int32
    body.gsub(/mc_\d+_\d+/) { |match| "mc_MINTED_#{seen[match] ||= seen.size}" }
  }
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
