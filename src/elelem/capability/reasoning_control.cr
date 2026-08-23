require "./profile"
require "../reasoning"
require "../mpsh/annotation"

module Elelem::Capability
  # One rule, four spellings — `Resolver`'s argument applied to a request
  # option rather than to a block.
  #
  # It lives beside `Structural` rather than inside `Resolver` for the same
  # reason `Structural` does: the resolver answers questions about blocks, and
  # a reasoning control is not one. What the two share is that the answer is
  # *derived* from a declared `Profile`, so the outcome a caller is told about
  # and the branch a mapper takes cannot drift apart.
  #
  # This is also where `SCOPE.md`'s note about `Report` comes true: the report
  # now describes request fidelity as well as history fidelity. Deliberate. A
  # caller who asks the model to think hard, against a protocol that cannot
  # pass the request on, has lost something — and silence is the failure this
  # whole model exists to prevent.
  module ReasoningControl
    extend self

    # What the mapper should put on the wire. The *values* are the protocol's
    # own business; this only decides the shape.
    enum Rendering
      AsEffort # a named rung, in the protocol's spelling
      AsBudget # a token count, clamped by the protocol's own rules
      Disable  # ask for no thinking at all
      Drop     # emit nothing; the request loses what the caller asked for
    end

    # The whole matrix, and small enough to read as one.
    #
    # The asymmetry between the two conversions is the point, and it is not
    # aesthetic. A rung rendered as a budget adopts a mapping the vendor
    # publishes for its own product, so the information survives the change of
    # unit: **Restructured**. A budget rendered as a rung throws away a number
    # that nobody can recover, using a ladder we invented because no vendor
    # publishes that direction: **Degraded**. The second also cannot honour
    # what the caller actually asked for, since a rung is a behavioural signal
    # and not a cap — a distinction that matters most to the caller who chose
    # to name a budget in the first place.
    def resolve(request : Reasoning::Request, unit : ReasoningUnit) : {Rendering, MPSH::Outcome}
      case unit
      in ReasoningUnit::None
        # The protocol has no control at all. Nothing to send, and the caller
        # asked for something they will not get.
        {Rendering::Drop, MPSH::Outcome::Degraded}
      in ReasoningUnit::Either
        # Unresolved: the protocol spells both units and nobody said which one
        # this deployment wants. `Catalog` narrows this per model before a
        # mapper ever sees it, so reaching here means the model was unknown to
        # the catalog *and* the default was declined — in which case guessing
        # is a rejected request and dropping is a recorded loss.
        {Rendering::Drop, MPSH::Outcome::Degraded}
      in ReasoningUnit::Effort
        case request
        in Reasoning::Effort then {Rendering::AsEffort, MPSH::Outcome::Exact}
        in Reasoning::Budget then {Rendering::AsEffort, MPSH::Outcome::Degraded}
        in Reasoning::Off    then {Rendering::Disable, MPSH::Outcome::Exact}
        end
      in ReasoningUnit::Budget
        case request
        in Reasoning::Effort then {Rendering::AsBudget, MPSH::Outcome::Restructured}
        in Reasoning::Budget then {Rendering::AsBudget, MPSH::Outcome::Exact}
        in Reasoning::Off    then {Rendering::Disable, MPSH::Outcome::Exact}
        end
      end
    end

    # Wording for the annotation, kept here so four mappers describe the same
    # event the same way.
    def detail(request : Reasoning::Request, rendering : Rendering,
               unit : ReasoningUnit) : String
      asked = case request
              in Reasoning::Effort then "effort #{request.wire_name}"
              in Reasoning::Budget then "budget #{request.tokens}"
              in Reasoning::Off    then "reasoning off"
              end

      case rendering
      in Rendering::Drop     then "reasoning control: #{asked} not expressible (#{unit})"
      in Rendering::AsEffort then "reasoning control: #{asked} sent as a named rung"
      in Rendering::AsBudget then "reasoning control: #{asked} sent as a token budget"
      in Rendering::Disable  then "reasoning control: #{asked}"
      end
    end
  end
end
