require "../spec_helper"

# Live specs against the real Gemini API — the last of the four protocols to
# be executed against anything at all. Ollama never served it
# (`docs/servers/OLLAMA.md`), so unlike Anthropic, there is no compatibility
# port to have already exercised the wire shape. Everything here is a first.
#
# **Recording.** Needs `GEMINI_API_KEY` in the environment and `RECORD=1` to
# cut a transcript. Once committed it replays offline like every other live
# spec.
#
# **Model.** `gemini-3.5-flash` for everything except one test. This started
# as a two-model file — a 2.5-series control alongside it, to isolate what's
# specific to Gemini 3 from what's a general elelem bug. Both
# `gemini-2.5-flash-lite` and `gemini-2.5-flash` came back 404 with a message
# pointing at successively newer replacements (`gemini-3.5-flash-lite`, then
# `gemini-3.6-flash`) — the whole 2.5 generation looks retired for newer API
# keys, not one model within it. The control isn't run live here; the
# "optional on 2.5, mandatory on Gemini 3" claim it would have confirmed is
# already well supported by Google's own docs and three independent
# third-party bug reports hitting the identical error text (see
# `docs/protocols/GEMINI.md`).
#
# `gemini-3.1-pro-preview` appears once, for the one claim specific to a tier
# rather than a generation: Google's docs say thinking cannot be turned off on
# Gemini 3 Pro at all, only lowered — the opposite of what Flash confirmed.
private MODEL_35  = "gemini-3.5-flash"
private MODEL_PRO = "gemini-3.1-pro-preview"

private def gemini : Elelem::Server
  Elelem::Server.new("gemini", "https://generativelanguage.googleapis.com", ENV["GEMINI_API_KEY"]?)
end

private def client(policy : Elelem::Capability::Policy = Elelem::Capability::Policy::Compensating) : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(gemini, Elelem::ProtocolKind::Gemini), policy)
end

private def weather_tool : Elelem::Tool
  Elelem::Tool.new("get_weather", "Look up the current weather in a city",
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}))
end

private def armed : Elelem::Options
  Elelem::Options.new(tools: [weather_tool], max_output_tokens: 512)
end

private def tool_question : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")
  session
end

describe "Gemini" do
  # First-ever live execution of this mapper against a real endpoint.
  # Everything below assumes the basic shape is accepted; this is what
  # actually establishes that, rather than trusting a green offline suite for
  # a protocol nothing has ever sent a byte to.
  describe "a plain turn" do
    it "is accepted" do
      Wiretap.intercept("gemini_baseline_text") do
        session = M::Session.new("Answer in one short sentence.")
        session << M::Message.user("What is the tallest mountain on Earth?")

        reply, report = client.send(session, MODEL_35,
          options: Elelem::Options.new(max_output_tokens: 256))

        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain(M::Outcome::Refused)
      end
    end
  end

  # The core risk this file exists to test. `elelem` writes no `id` on either
  # `functionCall` or `functionResponse` — the entire ordinal-pairing design
  # (`Mapper`'s own comment, `translation.cr`) assumes the field does not
  # exist, which was true for the 2.5 series this protocol was built against.
  # Gemini 3's own docs describe a real `thoughtSignature`, sibling to
  # `functionCall`, and enforce it strictly on replay. Confirmed live: the
  # first run of this test 400'd exactly that way, which is what motivated the
  # signature-capture plumbing now in `export.cr` and `mapper.cr`. This run is
  # the one that proves the plumbing alone was sufficient — no `Resolver`-level
  # check needed for elelem's own same-protocol round trip, only (potentially)
  # for a tool call handed to this protocol from elsewhere, which remains open
  # in `SCOPE.md`.
  describe "a tool call, paired without an identifier" do
    it "carries its thought signature and pairs correctly" do
      Wiretap.intercept("gemini_tool_pairing_35") do
        session = tool_question
        reply, _ = client.send(session, MODEL_35, options: armed)
        session << reply

        calls = reply.content.select(M::ToolCallBlock)
        calls.size.should eq 1

        session << M::Message.new(M::Role::User, calls.map { |call|
          M::ToolResultBlock.new(call.call_id,
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)
        })

        answer, report = client.send(session, MODEL_35, options: armed)
        answer.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain(M::Outcome::Refused)
      end
    end
  end

  # The other half of the signature story, and the half `SCOPE.md` carried as
  # "not yet reproduced live". Above proves elelem's own same-protocol round
  # trip replays a signature correctly. This proves what happens when there is
  # no signature to replay because the call was minted somewhere else — the
  # handoff this shard exists to perform, and the one shape the plumbing alone
  # could not save.
  #
  # The call below is built by hand with `anthropic` metadata precisely as a
  # cross-protocol handoff would leave it: a real tool call, correctly paired
  # with its result, carrying an opaque payload Gemini cannot read. Before the
  # `Resolver` check it went to the wire as-is and 400'd. Now `Catalog` marks
  # this model as signing its own calls, the call degrades, and the request is
  # sent without it.
  #
  # `Policy::Lenient` for the same reason the Pro reasoning test needs it: the
  # loss is real and the default policy would refuse before anything reached
  # the wire. That refusal is the correct default — this test deliberately
  # opts out of it to observe what the degraded request actually does.
  describe "a tool call handed over from another protocol" do
    it "degrades the unsignable call rather than sending an invalid request" do
      Wiretap.intercept("gemini_foreign_tool_call_35") do
        session = tool_question

        call = M::ToolCallBlock.new("call_ext_1", "get_weather",
          M::Object{"city" => "Paris".as(M::Value)})
        call.put_meta("anthropic", "id", "toolu_01ABCDEF")
        session << M::Message.new(M::Role::Assistant, [call.as(M::Block)])
        session << M::Message.new(M::Role::User, [
          M::ToolResultBlock.new("call_ext_1",
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block),
        ])

        session << M::Message.user("Given that, what should I wear?")

        reply, report = client(Elelem::Capability::Policy::Lenient)
          .send(session, MODEL_35, options: armed)

        # The check fired, and named the block kind it fired on.
        report.annotations
          .select { |a| a.block_kind == M::BlockKind::ToolCall }
          .map(&.outcome).should contain(M::Outcome::Degraded)

        # And the request was still accepted, which is the whole point: the
        # 400 this replaces was not recoverable, a degradation is.
        reply.content.select(M::TextBlock).should_not be_empty
      end
    end
  end

  # Confirmed live on Flash: a budget of 0 reliably disables thinking — closes
  # the item `SCOPE.md` carried as unconfirmed. Checked via
  # `usageMetadata.thoughtsTokenCount` rather than the presence of a thought
  # part, since `includeThoughts` governs visibility, not whether thinking
  # happened at all. Pro is a different story entirely — see below.
  describe "reasoning off" do
    it "actually disables thinking rather than merely being accepted" do
      Wiretap.intercept("gemini_reasoning_off_35") do
        session = M::Session.new("Answer in one short sentence.")
        session << M::Message.user("What is 12 times 14?")

        reply, _ = client.send(session, MODEL_35,
          options: Elelem::Options.new(reasoning: Elelem::Reasoning::Off.new, max_output_tokens: 256))

        usage = reply.meta?("gemini", "usage").as?(M::Object)
        thoughts = usage.try(&.["thoughtsTokenCount"]?)
        (thoughts.nil? || thoughts == 0_i64).should be_true
      end
    end
  end

  # Confirmed on Flash above; Google's own docs make a sharper, opposite claim
  # about Pro specifically: thinking cannot be turned off on Gemini 3 Pro at
  # all, only lowered to `LOW`, which "still performs some reasoning." Not a
  # generation-wide fact — a tier-specific one, and the first run of this test
  # found it the hard way: `thinkingBudget: 0` against this model wasn't
  # silently ignored, it was an active 400 (`Budget 0 is invalid. This model
  # only works in thinking mode.`). `CANNOT_DISABLE_THINKING`
  # (`capabilities.cr`) now catches this before the request is built and
  # substitutes the lowest rung instead — a real, recorded loss, which is why
  # this call needs `Policy::Lenient`: under the default policy the
  # `Degraded` outcome would refuse the call before anything reaches the wire,
  # the same guard the Anthropic signature fix relies on.
  describe "reasoning off, on the tier documented as unable to disable it" do
    it "substitutes the lowest rung rather than sending an invalid budget" do
      Wiretap.intercept("gemini_reasoning_off_pro") do
        session = M::Session.new("Answer in one short sentence.")
        session << M::Message.user("What is 12 times 14?")

        reply, report = client(Elelem::Capability::Policy::Lenient).send(session, MODEL_PRO,
          options: Elelem::Options.new(reasoning: Elelem::Reasoning::Off.new, max_output_tokens: 512))

        report.annotations.map(&.outcome).should contain(M::Outcome::Degraded)

        usage = reply.meta?("gemini", "usage").as?(M::Object)
        thoughts = usage.try(&.["thoughtsTokenCount"]?)
        (thoughts.as?(Int64) || 0_i64).should be > 0_i64
      end
    end
  end

  # Mirrors the Anthropic falsifying test exactly (`spec/live/anthropic_spec.cr`'s
  # history, now offline in `spec/conformance/anthropic_spec.cr`). Built
  # directly rather than earned through a prior live call — what's under test
  # is the shape, not its provenance: a `ReasoningBlock` with no
  # `provider_metadata` at all is exactly what an unattributed or
  # cross-protocol reasoning trace looks like, and `Profile#reasoning_signature_required?`
  # is currently `false` for Gemini — meaning `Resolver#own?`'s "empty
  # metadata is portable" rule is trusted here the same way it was wrongly
  # trusted for Anthropic before that fix.
  #
  # Confirmed live: Gemini accepts this cleanly. Unlike Anthropic's `thinking`
  # block, a plain-text thought carries no strict requirement here — the
  # signature enforcement that *is* real on this protocol (see the tool-call
  # test above) is specific to `functionCall`, not to reasoning text on its
  # own. `false` stands for this protocol, earned by evidence rather than
  # merely undisturbed by it.
  describe "a thought part with no signature, replayed on the next turn" do
    it "is accepted, unlike the equivalent case on Anthropic" do
      Wiretap.intercept("gemini_thought_no_signature") do
        session = M::Session.new("You are terse.")
        session << M::Message.user("What is the tallest mountain on Earth?")
        session << M::Message.new(M::Role::Assistant, [
          M::ReasoningBlock.new(
            "The user is asking about the tallest mountain. It's Everest.").as(M::Block),
          M::TextBlock.new("The tallest mountain on Earth is Mount Everest.").as(M::Block),
        ])
        session << M::Message.user("And the deepest ocean trench?")

        reply, report = client.send(session, MODEL_35,
          options: Elelem::Options.new(max_output_tokens: 256))

        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain(M::Outcome::Refused)
      end
    end
  end
end
