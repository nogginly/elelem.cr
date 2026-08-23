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
end
