require "./profile"

module Elelem::Capability
  # The fourth identity, opened one axis at a time.
  #
  # `Profile` says which wire shape, `Server` which deployment, `Provider`
  # whose opaque data is honoured. None of them answers "what can *this model*
  # do", and for reasoning controls that is now the deciding question: two
  # protocols spell both units, reject being handed both, and split on the
  # model rather than the protocol.
  #
  # It earns its place by passing the test `SCOPE.md` sets for any catalog: an
  # entry may only ask for *less* than the protocol declared. Concretely, it
  # resolves `Either` into one of the two units already spelled, and can do
  # nothing else — it cannot add a capability, cannot overturn a refusal, and
  # cannot touch a protocol whose unit is not ambiguous. It also follows the
  # precedent vendor narrowing set: reassign one `Profile` field and let the
  # existing resolver do the work, rather than adding a parallel decision path.
  #
  # ## Why the default is optimistic, when nothing else here is
  #
  # Elsewhere this shard is deliberately pessimistic, because a wrongly
  # optimistic guess breaks a turn while a pessimistic one costs recorded
  # fidelity. The asymmetry runs the other way here, for one reason: **the
  # exception list is closed and shrinking.** Budget-only models are the
  # legacy ones. Every model released since takes a named rung, and so will the
  # next. A stale table therefore fails safe, because an unknown model is far
  # likelier to be new than ancient — and this table only has to be complete
  # about the past, which is the one thing a table can be.
  #
  # ## Exact spellings, never patterns
  #
  # Model strings arrive in at least three naming schemes — bare API names,
  # Ollama tags (`gemma4:26b-mxfp8`), Bedrock identifiers
  # (`anthropic.claude-sonnet-4-20250514-v1:0`) — and a pattern over them
  # misfires silently, which is this project's most expensive failure mode. So
  # entries are literal, matched exactly after downcasing. A spelling that is
  # not listed falls through to the default, where it is right for every
  # current model, and to the explicit override where it is not.
  #
  # Azure is why the override must exist: its model string is a *deployment
  # name* the customer chose, so `prod-reasoning-2` carries no model identity
  # at all. Not a gap to patch by cleverness — the same fact that will amend
  # `Adapter` later.
  module Catalog
    extend self

    # Models that accept a thinking **budget** and no named rung.
    #
    # Anthropic: extended thinking (`thinking.type: "enabled"` with
    # `budget_tokens`) is the only mode on Claude Sonnet 4.5, Claude Haiku 4.5
    # and the earlier Claude 4 models, none of which take an effort parameter.
    # Claude Opus 4.5 accepts both and so is deliberately absent — the default
    # is right for it. From Claude 4.6 the budget is deprecated, and from 4.7 it
    # is rejected outright.
    #
    # Gemini: the 2.5 series takes `thinkingBudget` and does not support
    # `thinkingLevel`, which arrived with Gemini 3.
    #
    # Confirm against current provider documentation rather than memory, as
    # with every other declaration here. This one dates itself faster than most.
    BUDGET_ONLY = Set{
      "claude-3-7-sonnet",
      "claude-3-7-sonnet-latest",
      "claude-3-7-sonnet-20250219",
      "claude-sonnet-4",
      "claude-sonnet-4-0",
      "claude-sonnet-4-20250514",
      "claude-sonnet-4-5",
      "claude-sonnet-4-5-20250929",
      "claude-opus-4",
      "claude-opus-4-0",
      "claude-opus-4-20250514",
      "claude-opus-4-1",
      "claude-opus-4-1-20250805",
      "claude-haiku-4-5",
      "claude-haiku-4-5-20251001",
      "gemini-2.5-pro",
      "gemini-2.5-flash",
      "gemini-2.5-flash-lite",
      "gemini-2.5-flash-preview",
      "gemini-2.5-pro-preview",
    }

    # What this model wants, or `nil` where the catalog has no opinion — which
    # is most of them, and is the answer that leaves the default in charge.
    def reasoning_unit?(model : String) : ReasoningUnit?
      BUDGET_ONLY.includes?(model.downcase) ? ReasoningUnit::Budget : nil
    end

    # Resolve an ambiguous profile for one model. A profile that already names
    # its unit is returned untouched, so this is a no-op on three of the four
    # protocols.
    def narrow(profile : Profile, model : String) : Profile
      return profile unless profile.reasoning_unit.either?
      profile.with_reasoning_unit(reasoning_unit?(model) || ReasoningUnit::Effort)
    end
  end
end
