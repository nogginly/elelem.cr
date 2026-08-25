require "../spec_helper"

# Live specs against the real Anthropic Messages API — the first paid
# endpoint, and the first that can *validate* rather than merely accept. Every
# claim recorded here is one Ollama's Anthropic-compatible port could not
# settle: it ignores thinking signatures and rung/budget spellings alike, so a
# green run there proves acceptance and nothing about correctness. See
# `docs/servers/OLLAMA.md`.
#
# **Recording.** Needs `ANTHROPIC_API_KEY` in the environment and `RECORD=1`
# to cut a transcript. Once committed it replays offline like every other live
# spec — nobody after the first recording needs a key. See *Live specs* in
# `DEVELOPMENT.md` for the two-step recording procedure; the run after the
# recording is the one that proves anything.
#
# **Model.** Pinned to a Haiku throughout. This suite is about protocol
# fidelity, not model capability, so the cheapest current model that exercises
# the path in question is the right one. Flagged per-example if a path turns
# out to need a different model.
private MODEL = "claude-haiku-4-5"

private def anthropic : Elelem::Server
  Elelem::Server.new("anthropic", "https://api.anthropic.com", ENV["ANTHROPIC_API_KEY"]?)
end

private def client(policy : Elelem::Capability::Policy = Elelem::Capability::Policy::Compensating) : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(anthropic, Elelem::ProtocolKind::Anthropic), policy)
end

# What used to live here — a signature-less `thinking` block sent to this
# endpoint and expected to 400 — moved to `spec/conformance/anthropic_spec.cr`
# ("declared divergences") once the fix landed. `Policy::Compensating` now
# refuses that shape before a request is ever built, so there is nothing left
# for a network call to prove: the 400 this file recorded is preserved as
# `spec/transcripts/anthropic_thinking_no_signature.json`, the evidence the
# fix was built from, but nothing replays it any longer — the client no
# longer sends the request that produced it.
#
# Recording A is next: a real signed `thinking` block, requested with
# `Reasoning::Effort` against a budget-only model, replayed on the next turn.
# It confirms the own-vendor Exact path actually works and the
# `REASONING_BUDGETS` clamp is shaped right — both still genuinely need a
# paid call, and neither changed when the fix above landed.
describe "Anthropic" do
  # `claude-haiku-4-5` is in `Catalog::BUDGET_ONLY`, so `Effort::Low` resolves
  # to `thinking.budget_tokens: 1024` — the floor, and the cheapest way to
  # exercise both the clamp and the budget spelling in one call. `cap: 1536`
  # leaves room above the 1024 floor for an actual answer, since thinking and
  # answer tokens share one ceiling (`mapper.cr`'s `clamped_budget`).
  describe "a real signed thinking block" do
    it "is requested, accepted, and replays clean on the next turn" do
      Wiretap.intercept("anthropic_thinking_signature_replay") do
        session = M::Session.new("You are terse.")
        session << M::Message.user("What is the tallest mountain on Earth?")

        first, first_report = client.send(session, MODEL,
          options: Elelem::Options.new(
            reasoning: Elelem::Reasoning::Effort::Low,
            max_output_tokens: 1536))
        session << first

        # Restructured, not Exact — two independent reasons, both by design.
        # `REASONING_BUDGETS` renders a rung as a token count
        # (`reasoning_control.cr`: `Effort → AsBudget` is Restructured even
        # for the vendor's own rung), and separately, `MoveSystemPrompt` is
        # unconditionally Restructured whenever a system prompt exists here —
        # `structural.cr`'s `outcome` does not check whether the destination's
        # own native placement is exactly where it's going. Either alone caps
        # this turn below Exact; nothing here says the budget path failed.
        first_report.worst.should eq M::Outcome::Restructured
        reasoning = first.content.select(M::ReasoningBlock).first?
        reasoning.should_not be_nil
        reasoning.not_nil!.meta?("anthropic", "signature").should_not be_nil

        session << M::Message.user("And the deepest ocean trench?")

        # The point of the second call: not a fresh request, a *replay* of the
        # signature Anthropic itself just issued. Own-vendor, default policy.
        #
        # `report.worst` cannot be the check here — this turn's `system` field
        # alone already caps it at Restructured, same as turn one, and for the
        # same unconditional `MoveSystemPrompt` reason, nothing to do with
        # reasoning. What actually proves the replay: no Degraded or Refused
        # annotation anywhere in this turn. If `replayable?` had rejected the
        # signature, dropping the block would be exactly that.
        second, second_report = client.send(session, MODEL)

        second_report.annotations.map(&.outcome).should_not contain(M::Outcome::Degraded)
        second_report.annotations.map(&.outcome).should_not contain(M::Outcome::Refused)
        second.content.select(M::TextBlock).should_not be_empty
      end
    end
  end
end
