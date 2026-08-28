require "./profile"

module Elelem::Capability
  # The fourth identity, opened one axis at a time.
  #
  # `Profile` says which wire shape, `Server` which deployment, `Provider`
  # whose opaque data is honoured. None of them answers "what can *this model*
  # do", and twice now that has been the deciding question:
  #
  # - **Reasoning unit.** Two protocols spell both units, reject being handed
  #   both, and split on the model rather than the protocol.
  # - **Tool call signatures.** Gemini 3 authenticates its own tool calls and
  #   Gemini 2.5 does not, so one protocol needs two answers.
  #
  # It earns its place by passing the test `SCOPE.md` sets for any catalog: an
  # entry may only ask for *less* than the protocol declared. Each axis is
  # narrowing in that sense — resolving `Either` into one of the two units
  # already spelled, or adding a condition to a mapping that was otherwise
  # unconditional. Neither can add a capability or overturn a refusal, and
  # both leave a profile with nothing to narrow untouched. Both also follow the
  # precedent vendor narrowing set: reassign one `Profile` field and let the
  # existing resolver do the work, rather than adding a parallel decision path.
  #
  # This is what `SCOPE.md` anticipated as "a second axis on the same entry,
  # not a second mechanism." It arrived for tool signatures rather than the
  # reasoning rungs that were expected, which changes nothing about the shape.
  #
  # ## Why the default is optimistic, when nothing else here is
  #
  # Stated for the reasoning-unit axis, which is where it originated. It is
  # *not* a property of the catalog as a whole: `SIGNED_TOOL_CALLS` reaches
  # the same optimistic default by a different argument, and says so in its
  # own comment. Read both before adding a third axis on the assumption that
  # one rule covers them.
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

    # Models that reject a tool call carrying no signature of their own.
    #
    # Gemini 3 attaches a `thoughtSignature` to every `functionCall` part it
    # emits and requires it back on replay; a call minted anywhere else has
    # none, and the request is a 400 (`Function call is missing a
    # thought_signature in functionCall parts`). The 2.5 series has no such
    # requirement, which is the whole reason this is a catalog entry and not a
    # line in Gemini's `PROFILE`.
    #
    # ## This axis is open and growing, where `BUDGET_ONLY` is closed and shrinking
    #
    # The optimistic default above is justified by the exception list only
    # having to be complete about the *past*. That argument does not transfer
    # here: signed tool calls are the new behaviour, so an unlisted model is
    # likelier to need this entry than not, and a stale table fails *open*.
    #
    # It stays optimistic anyway, for a different reason. Being wrong in this
    # direction produces a 400 that names the missing field outright — the
    # error that put this entry here in the first place — which costs one line
    # in this set and nothing else. Being wrong in the other direction drops
    # every tool call handed to a 2.5 deployment, silently, with only a
    # `Degraded` annotation nobody reads to say so. A loud failure on an
    # unlisted new model beats a silent one on every old model, and
    # `catalog.cr`'s own rule about patterns that misfire silently is the same
    # judgement one level down.
    #
    # So: expect to add to this. That is the design working, not a gap.
    #
    # ## Entries are Gemini 3 spellings this repository has actually seen
    #
    # Every name below appears in `spec/live/gemini_spec.cr` — either used
    # there directly, or named by the API itself in a 404 pointing at a
    # replacement. Plausible-looking siblings are deliberately *not* added on
    # spec, because the two directions of error are not symmetric here: a
    # missing entry is a 400 naming the field, while a wrong entry silently
    # degrades every tool call sent to a model that never needed it. Guessing
    # only helps in the direction that hurts.
    #
    # The criterion is the Gemini 3 series, which Google documents as
    # generation-wide rather than tier-specific — contrast
    # `Gemini::CANNOT_DISABLE_THINKING`, which is a tier fact and stays a much
    # shorter list for that reason.
    SIGNED_TOOL_CALLS = Set{
      # Confirmed by a live 400 in this repository.
      "gemini-3.5-flash",
      # Same generation, in use here for the reasoning-tier specs.
      "gemini-3.1-pro-preview",
      # Named by the API's own 404 as the current replacements for the
      # retired 2.5 models.
      "gemini-3.5-flash-lite",
      "gemini-3.6-flash",
    }

    # What this model wants, or `nil` where the catalog has no opinion — which
    # is most of them, and is the answer that leaves the default in charge.
    def reasoning_unit?(model : String) : ReasoningUnit?
      BUDGET_ONLY.includes?(model.downcase) ? ReasoningUnit::Budget : nil
    end

    # Whether this model authenticates its own tool calls. Exact spelling,
    # downcased, no patterns — the same rule `reasoning_unit?` follows and for
    # the same reason.
    def tool_call_signature_required?(model : String) : Bool
      SIGNED_TOOL_CALLS.includes?(model.downcase)
    end

    # Resolve a profile for one model, one axis at a time.
    #
    # Both axes narrow the same `Profile` and neither knows about the other,
    # which is the property that makes a third cheap to add. A profile with
    # nothing to narrow on either axis is returned untouched, so this remains
    # a no-op on three of the four protocols.
    def narrow(profile : Profile, model : String) : Profile
      if profile.reasoning_unit.either?
        profile = profile.with_reasoning_unit(reasoning_unit?(model) || ReasoningUnit::Effort)
      end

      if tool_call_signature_required?(model) && !profile.tool_call_signature_required?
        profile = profile.with_tool_call_signature_required(true)
      end

      profile
    end
  end
end
