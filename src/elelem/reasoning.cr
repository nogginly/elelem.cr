module Elelem
  # What the caller asks of the model's *reasoning* on this request.
  #
  # A closed union of three, matching `MPSH::Block`'s convention rather than a
  # struct with nilable fields: a mapper writes `case … in` and the compiler
  # refuses to let it forget a case. A struct carrying an optional level and an
  # optional budget would also permit both at once, which is a request every
  # protocol here rejects.
  #
  # These are request options, never session content. A stored conversation
  # that remembered how hard the model was asked to think would have acquired a
  # provider's assumptions, and portability is the thing this shard refuses to
  # give up.
  module Reasoning
    # Named rungs, in the vendors' own vocabulary.
    #
    # Not an invented abstraction. Anthropic and OpenAI both present exactly
    # these five today, down to the spelling of `xhigh`, and both default to
    # `high`. Adopting a vendor's ladder is the whole justification for a shared
    # enum here — inventing a scale and then guessing at equivalences is the
    # move this deliberately avoids.
    #
    # `minimal` and `none` are excluded. `none` is what `Off` means, and
    # `minimal` appears on one family only, where `Low` is the honest neighbour.
    enum Effort
      Low
      Medium
      High
      XHigh
      Max

      # Lowercase on both OpenAI protocols and on Anthropic. Gemini shouts its
      # levels, and spells fewer of them; see that protocol's mapper.
      def wire_name : String
        case self
        in Effort::Low    then "low"
        in Effort::Medium then "medium"
        in Effort::High   then "high"
        in Effort::XHigh  then "xhigh"
        in Effort::Max    then "max"
        end
      end
    end

    # An exact token budget, for callers who want one.
    struct Budget
      getter tokens : Int32

      def initialize(@tokens : Int32)
        raise ArgumentError.new("reasoning budget must be positive") unless @tokens > 0
      end

      # The coarse bucket used when a budget must be rendered as a rung.
      #
      # Deliberately one ladder for every protocol, and deliberately lossy: the
      # resolver already classifies this direction as **Degraded**, because a
      # number cannot be recovered from a name. The vendors publish rung → tokens
      # and nobody publishes the inverse, so any table here is ours and is
      # therefore kept in one place where it can be argued with.
      def to_effort : Effort
        case tokens
        when .< 2_048  then Effort::Low
        when .< 8_192  then Effort::Medium
        when .< 24_576 then Effort::High
        when .< 65_536 then Effort::XHigh
        else                Effort::Max
        end
      end
    end

    # "Do not think." Distinct from asking for nothing at all, which leaves the
    # provider's default alone — and the knob that would have stopped a local
    # model spending 4,096 tokens reasoning without reaching an answer.
    struct Off
    end

    alias Request = Effort | Budget | Off
  end
end
