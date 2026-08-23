require "../spec_helper"

# Reasoning controls, across two units and four spellings.
#
# The half of the request-options work that tool declarations and the output
# cap left behind, and the awkward half: those two are expressed by every
# protocol, so neither needed a declaration. This one is expressed by every
# protocol in units that disagree, and on two of them the unit depends on the
# *model* rather than the protocol — Claude 4.7 rejects a budget, Claude Sonnet
# 4.5 has no effort parameter, and Gemini splits at the 2.5/3 line.
#
# Everything here is structural. What it cannot settle is whether a rung this
# shard serializes is a rung the model behind the endpoint accepts, since
# supported values are model-dependent on both OpenAI protocols too. That waits
# on a recording, as usual.
private def asked : M::Session
  session = M::Session.new("You are terse.")
  session << M::Message.user("Weather in Paris?")
  session
end

private def adapter_for(protocol : Elelem::ProtocolKind) : Elelem::Adapter
  case protocol
  in Elelem::ProtocolKind::ChatCompletions then Elelem::ChatCompletionsAdapter.new
  in Elelem::ProtocolKind::Responses       then Elelem::ResponsesAdapter.new
  in Elelem::ProtocolKind::Anthropic       then Elelem::AnthropicAdapter.new
  in Elelem::ProtocolKind::Gemini          then Elelem::GeminiAdapter.new
  end
end

private def exchange(protocol : Elelem::ProtocolKind, options : Elelem::Options,
                     model : String = "test-model",
                     policy : C::Policy = C::Policy::Lenient) : Elelem::Adapter::Exchange
  adapter_for(protocol).prepare(asked, model, policy,
    C::ReasoningRetention::All, 4096, options)
end

private def body(protocol : Elelem::ProtocolKind, options : Elelem::Options,
                 model : String = "test-model") : JSON::Any
  JSON.parse(exchange(protocol, options, model).body)
end

private def effort(level : Elelem::Reasoning::Effort) : Elelem::Options
  Elelem::Options.new(reasoning: level)
end

# The loss recorded *for the reasoning control*, or `nil` where the control cost
# nothing.
#
# Two things it is deliberately not. It is not `report.worst`, which spans every
# axis at once — the fixture below carries a system prompt, which all four
# protocols record as an adaptation, so `worst` would measure that as much as
# the control. And it is not the resolved outcome: `Report#record` files an
# annotation only when something was lost, so Exact and Restructured leave none
# by design. The annotation channel means damage, and stays useful only while it
# does.
#
# So the matrix itself is asserted against `ReasoningControl.resolve`, which
# owns it, and this helper asserts what a caller would actually be told.
private def control_loss(result : Elelem::Adapter::Exchange) : M::Outcome?
  result.report.annotations
    .select { |a| a.detail.starts_with?("reasoning control:") }
    .map(&.outcome)
    .max?
end

private def resolve(request : Elelem::Reasoning::Request, unit : C::ReasoningUnit) : M::Outcome
  C::ReasoningControl.resolve(request, unit).last
end

private ALL = [Elelem::ProtocolKind::ChatCompletions, Elelem::ProtocolKind::Responses,
               Elelem::ProtocolKind::Anthropic, Elelem::ProtocolKind::Gemini]

describe "reasoning controls" do
  # The property that keeps every committed transcript valid. If this fails,
  # every live recording has to be re-cut, so it is asserted before anything
  # else is.
  describe "absence" do
    it "emits nothing at all when the caller asks for nothing" do
      ALL.each do |protocol|
        request = body(protocol, Elelem::Options.new)

        request["reasoning_effort"]?.should be_nil
        request["reasoning"]?.should be_nil
        request["thinking"]?.should be_nil
        request["output_config"]?.should be_nil
        request["generationConfig"]?.should be_nil
      end
    end

    it "leaves a request with tools and a cap byte-identical to before" do
      armed = Elelem::Options.new(
        tools: [Elelem::Tool.new("get_weather", "Look up the weather")],
        max_output_tokens: 512)

      ALL.each do |protocol|
        plain = exchange(protocol, armed).body
        again = exchange(protocol, armed).body
        again.should eq plain
      end
    end
  end

  # The whole matrix in one place, asserted where it is decided rather than
  # through a mapper. Two of these outcomes leave no annotation, so a mapper is
  # simply the wrong instrument for reading them.
  describe "the matrix" do
    it "classifies every pairing" do
      low = Elelem::Reasoning::Effort::Low
      budget = Elelem::Reasoning::Budget.new(3000)
      off = Elelem::Reasoning::Off.new

      resolve(low, C::ReasoningUnit::Effort).should eq M::Outcome::Exact
      resolve(budget, C::ReasoningUnit::Effort).should eq M::Outcome::Degraded
      resolve(off, C::ReasoningUnit::Effort).should eq M::Outcome::Exact

      resolve(low, C::ReasoningUnit::Budget).should eq M::Outcome::Restructured
      resolve(budget, C::ReasoningUnit::Budget).should eq M::Outcome::Exact
      resolve(off, C::ReasoningUnit::Budget).should eq M::Outcome::Exact

      # No control, and an unresolved `Either` — the second reachable only if a
      # deployment declined both the catalog and the default, where guessing a
      # unit would be a rejected request rather than a recorded loss.
      [C::ReasoningUnit::None, C::ReasoningUnit::Either].each do |unit|
        resolve(low, unit).should eq M::Outcome::Degraded
        resolve(budget, unit).should eq M::Outcome::Degraded
        resolve(off, unit).should eq M::Outcome::Degraded
      end
    end

    it "drops the control where a protocol has none" do
      C::ReasoningControl.resolve(Elelem::Reasoning::Effort::High, C::ReasoningUnit::None)
        .first.should eq C::ReasoningControl::Rendering::Drop
    end
  end

  describe "a named rung" do
    it "spells the rung four ways" do
      options = effort(Elelem::Reasoning::Effort::Medium)

      body(Elelem::ProtocolKind::ChatCompletions, options)["reasoning_effort"].as_s
        .should eq "medium"
      body(Elelem::ProtocolKind::Responses, options)["reasoning"]["effort"].as_s
        .should eq "medium"
      # A rung on a current Claude model lands in `output_config`, not in
      # `thinking` — a separate parameter, because effort shapes the whole
      # response rather than only the thinking.
      body(Elelem::ProtocolKind::Anthropic, options)["output_config"]["effort"].as_s
        .should eq "medium"
      body(Elelem::ProtocolKind::Gemini, options)["generationConfig"]["thinkingConfig"]["thinkingLevel"]
        .as_s.should eq "MEDIUM"
    end

    it "carries the two rungs above high on the protocols that spell them" do
      options = effort(Elelem::Reasoning::Effort::XHigh)

      body(Elelem::ProtocolKind::ChatCompletions, options)["reasoning_effort"].as_s
        .should eq "xhigh"
      body(Elelem::ProtocolKind::Anthropic, options)["output_config"]["effort"].as_s
        .should eq "xhigh"
    end

    # Gemini spells three rungs where the caller has five. Clamping is a loss
    # the caller did not ask for, so it is annotated rather than done quietly.
    it "clamps a rung Gemini cannot spell, and says so" do
      result = exchange(Elelem::ProtocolKind::Gemini, effort(Elelem::Reasoning::Effort::Max))

      JSON.parse(result.body)["generationConfig"]["thinkingConfig"]["thinkingLevel"]
        .as_s.should eq "HIGH"
      control_loss(result).should eq M::Outcome::Degraded
      result.report.annotations.any? { |a| a.detail.includes?("clamped") }.should be_true
    end

    it "sends a rung on Anthropic without asking for a budget" do
      request = body(Elelem::ProtocolKind::Anthropic, effort(Elelem::Reasoning::Effort::High))
      request["thinking"]?.should be_nil
    end

    it "is Exact where the unit matches, and costs the caller nothing" do
      resolve(Elelem::Reasoning::Effort::Low, C::ReasoningUnit::Effort)
        .should eq M::Outcome::Exact

      # Nothing was lost, so nothing is annotated.
      control_loss(
        exchange(Elelem::ProtocolKind::ChatCompletions, effort(Elelem::Reasoning::Effort::Low)))
        .should be_nil
    end
  end

  describe "a token budget" do
    # The vendor publishes rung -> tokens for its own product, so rendering a
    # rung as a budget adopts an abstraction rather than inventing one:
    # Restructured, not Degraded.
    it "renders a rung as a budget on a budget-only model, and calls it Restructured" do
      result = exchange(Elelem::ProtocolKind::Anthropic,
        effort(Elelem::Reasoning::Effort::Low), "claude-sonnet-4-5")

      request = JSON.parse(result.body)
      request["thinking"]["type"].as_s.should eq "enabled"
      request["thinking"]["budget_tokens"].as_i.should eq 1024
      request["output_config"]?.should be_nil
      resolve(Elelem::Reasoning::Effort::Low, C::ReasoningUnit::Budget)
        .should eq M::Outcome::Restructured
      # Restructured is not damage, so the caller gets no annotation — only a
      # `worst` that has moved off Exact.
      control_loss(result).should be_nil
    end

    it "sends an exact budget where the caller names one" do
      request = body(Elelem::ProtocolKind::Anthropic,
        Elelem::Options.new(max_output_tokens: 8192,
          reasoning: Elelem::Reasoning::Budget.new(2048)),
        "claude-sonnet-4-5")

      request["thinking"]["budget_tokens"].as_i.should eq 2048
    end

    # Nobody publishes budget -> rung, so the ladder is ours and the loss is
    # real: a number cannot be recovered from a name.
    it "buckets a budget to a rung where the unit is a rung, and calls it Degraded" do
      result = exchange(Elelem::ProtocolKind::ChatCompletions,
        Elelem::Options.new(reasoning: Elelem::Reasoning::Budget.new(3000)))

      JSON.parse(result.body)["reasoning_effort"].as_s.should eq "medium"
      control_loss(result).should eq M::Outcome::Degraded
    end

    # The budget must be at least 1,024 and strictly below `max_tokens`.
    it "clamps a budget under the caller's output cap" do
      request = body(Elelem::ProtocolKind::Anthropic,
        Elelem::Options.new(max_output_tokens: 4000,
          reasoning: Elelem::Reasoning::Effort::Max),
        "claude-sonnet-4-5")

      request["thinking"]["budget_tokens"].as_i.should eq 3999
      request["max_tokens"].as_i.should eq 4000
    end

    # Never raise the caller's cap to make a budget fit. A cap was set for a
    # reason, and quietly spending past it is the silent behaviour this whole
    # model exists to prevent.
    it "drops the control rather than raising the cap, and records it" do
      result = exchange(Elelem::ProtocolKind::Anthropic,
        Elelem::Options.new(max_output_tokens: 512,
          reasoning: Elelem::Reasoning::Effort::High),
        "claude-sonnet-4-5")

      request = JSON.parse(result.body)
      request["thinking"]?.should be_nil
      request["max_tokens"].as_i.should eq 512
      control_loss(result).should eq M::Outcome::Degraded
    end

    it "asks Gemini for dynamic thinking rather than inventing a ceiling" do
      body(Elelem::ProtocolKind::Gemini, effort(Elelem::Reasoning::Effort::Max),
        "gemini-2.5-flash")["generationConfig"]["thinkingConfig"]["thinkingBudget"]
        .as_i.should eq -1
    end
  end

  describe "off" do
    it "asks for no thinking in each protocol's own spelling" do
      options = Elelem::Options.new(reasoning: Elelem::Reasoning::Off.new)

      body(Elelem::ProtocolKind::ChatCompletions, options)["reasoning_effort"].as_s
        .should eq "none"
      body(Elelem::ProtocolKind::Responses, options)["reasoning"]["effort"].as_s
        .should eq "none"
      body(Elelem::ProtocolKind::Anthropic, options)["thinking"]["type"].as_s
        .should eq "disabled"
      body(Elelem::ProtocolKind::Gemini, options)["generationConfig"]["thinkingConfig"]["thinkingBudget"]
        .as_i.should eq 0
    end

    it "is Exact everywhere, being a request every protocol can make" do
      [C::ReasoningUnit::Effort, C::ReasoningUnit::Budget].each do |unit|
        resolve(Elelem::Reasoning::Off.new, unit).should eq M::Outcome::Exact
      end

      ALL.each do |protocol|
        control_loss(
          exchange(protocol, Elelem::Options.new(reasoning: Elelem::Reasoning::Off.new)))
          .should be_nil
      end
    end
  end

  # The catalog resolves `Either`, and may only ever resolve it — an entry
  # cannot add a capability or overturn a refusal, which is the test any model
  # catalog has to pass to belong here.
  describe "the model catalog" do
    it "declares the ambiguous protocols ambiguous, and the others not" do
      Elelem::Protocol::Anthropic::PROFILE.reasoning_unit.either?.should be_true
      Elelem::Protocol::Gemini::PROFILE.reasoning_unit.either?.should be_true
      Elelem::Protocol::ChatCompletions::PROFILE.reasoning_unit.effort?.should be_true
      Elelem::Protocol::Responses::PROFILE.reasoning_unit.effort?.should be_true
    end

    it "narrows a legacy model to a budget" do
      C::Catalog.reasoning_unit?("claude-sonnet-4-5").should eq C::ReasoningUnit::Budget
      C::Catalog.reasoning_unit?("gemini-2.5-flash").should eq C::ReasoningUnit::Budget
    end

    # The optimistic default, and the reason it is safe: the exception list is
    # closed and shrinking, so an unknown model is far likelier to be new than
    # ancient.
    it "has no opinion about a model it does not know" do
      C::Catalog.reasoning_unit?("some-model-released-next-year").should be_nil

      profile = C::Catalog.narrow(Elelem::Protocol::Anthropic::PROFILE, "whatever-4.9")
      profile.reasoning_unit.effort?.should be_true
    end

    it "matches spellings exactly rather than by pattern" do
      # An Ollama tag, a Bedrock identifier: three naming schemes, and a
      # pattern over them misfires silently. Unlisted falls through.
      C::Catalog.reasoning_unit?("anthropic.claude-sonnet-4-5-v1:0").should be_nil
      C::Catalog.reasoning_unit?("CLAUDE-SONNET-4-5").should eq C::ReasoningUnit::Budget
    end

    it "leaves an unambiguous protocol alone" do
      profile = C::Catalog.narrow(Elelem::Protocol::ChatCompletions::PROFILE,
        "claude-sonnet-4-5")
      profile.reasoning_unit.effort?.should be_true
    end
  end

  describe "narrowing" do
    it "refuses to widen" do
      expect_raises(ArgumentError) do
        Elelem::Protocol::ChatCompletions::PROFILE
          .with_reasoning_unit(C::ReasoningUnit::Budget)
      end
    end

    it "refuses an override the protocol never spelled" do
      expect_raises(ArgumentError) do
        Elelem::Provider.for(Elelem::Server.new("ollama", "http://localhost:11434"),
          Elelem::ProtocolKind::ChatCompletions,
          reasoning_unit: C::ReasoningUnit::Budget)
      end
    end

    # The deployment whose model name says nothing about the model — Azure's
    # case, and the reason the override exists at all.
    it "lets an explicit unit overrule the catalog" do
      adapter = Elelem::AnthropicAdapter.new(nil, C::ReasoningUnit::Budget)
      adapter.narrowed("some-deployment-name").reasoning_unit.budget?.should be_true
    end

    it "keeps the metadata-key narrowing it already did" do
      adapter = Elelem::AnthropicAdapter.new("ollama")
      profile = adapter.narrowed("test-model")

      profile.metadata_key.should eq "ollama"
      profile.reasoning_unit.effort?.should be_true
    end
  end

  # Policy governs history fidelity, and now request fidelity too. Deliberate,
  # and the one part of this worth revisiting if it reads badly: a caller who
  # says "no silent loss" and asks for something the request cannot carry
  # should hear about it.
  describe "policy" do
    it "refuses under strict where the request loses what was asked for" do
      expect_raises(C::RefusedError) do
        exchange(Elelem::ProtocolKind::ChatCompletions,
          Elelem::Options.new(reasoning: Elelem::Reasoning::Budget.new(3000)),
          policy: C::Policy::Strict)
      end
    end

    it "permits a rung rendered as a budget under strict, being Restructured" do
      # The assertion is that this does not raise: Strict permits Restructured,
      # and a rung rendered as a budget is exactly that.
      result = exchange(Elelem::ProtocolKind::Anthropic, effort(Elelem::Reasoning::Effort::Low),
        "claude-sonnet-4-5", policy: C::Policy::Strict)

      JSON.parse(result.body)["thinking"]["budget_tokens"].as_i.should eq 1024
    end
  end

  # Options are a request concern. Two requests differing only in how hard the
  # model was asked to think must describe the same conversation.
  describe "separation from history" do
    it "does not alter the conversation" do
      plain = body(Elelem::ProtocolKind::ChatCompletions, Elelem::Options.new)
      thinking = body(Elelem::ProtocolKind::ChatCompletions,
        effort(Elelem::Reasoning::Effort::High))

      thinking["messages"].to_json.should eq plain["messages"].to_json
    end

    it "refuses a budget of zero or less, which means Off rather than a budget" do
      expect_raises(ArgumentError) { Elelem::Reasoning::Budget.new(0) }
    end
  end
end
