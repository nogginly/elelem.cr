require "./policy"
require "./structural"
require "../mpsh/block"

module Elelem::Capability
  # The compensation carrier, in one place.
  #
  # Three protocols cannot put non-text content inside a tool result, so the
  # content is lifted out, a marker is left where it stood, and the content
  # rides in a synthesized user message afterwards. Both directions of that
  # trick were written three times, expressed differently each time, and were
  # wrong once: the Gemini mapper flushed only before user messages, so the
  # carrier landed *after* the model's reply, where export could no longer see
  # the results it belonged to. One missing case, two divergences.
  #
  # What differs between the three protocols is only the wire type — a
  # `Wire::Message`, a `Wire::MessageItem`, a `Wire::Content` — and the wire
  # type is exactly what this module refuses to know. It takes the parts and
  # gives them back; the caller builds its own message. Everything else, which
  # is to say the rule, lives here once.
  #
  # `Structural` is the home because the outcome was already recorded there:
  # deferral is a sequence-level adaptation, not a per-block resolution.
  module Carrier
    extend self

    # The marker left where lifted content stood.
    #
    # One constant, not three. It was three identical strings that had to stay
    # byte-identical forever, since a session mapped by one protocol may be
    # exported by another and the marker is matched *exactly* on the way back.
    # Three copies of a value with that requirement is a bug with a start date.
    #
    # Never localized, for the same reason: this is read by our own exporter,
    # structurally, not by the model. `SCOPE.md`'s *A localizable content
    # synthesizer* draws the line — markers never, glue always.
    PLACEHOLDER = "[elelem: content returned separately in the following message]"

    # ---- Mapping: request out ------------------------------------------------

    # Emits the buffered carrier, if any, and clears the buffer.
    #
    # Ordering is not cosmetic. A single assistant turn may request several
    # tools in parallel, and strict servers — Azure's OpenAI endpoint among
    # them — require every message answering that turn to appear before
    # anything else. Emitting a carrier inline after each result interleaves
    # scaffolding between tool responses and is rejected, even though
    # permissive servers such as Ollama and LM Studio accept it.
    #
    # So carriers are deferred until the run of tool results ends, and several
    # results' worth of content may ride in one carrier. The flush points are
    # the same in all three protocols and are the part that was got wrong:
    # *anything* that is not itself a tool result ends the run — genuine user
    # content, an assistant turn, or the end of the request — not just user
    # content.
    #
    # The block receives the buffered parts and appends whatever message its
    # own protocol spells that with. It is called only when there is something
    # to carry, so a caller need not check first.
    def flush(pending : Array(T), report : Report, & : Array(T) -> Nil) : Nil forall T
      return if pending.empty?

      report.record(
        Structural.outcome(Structural::Adaptation::DeferCompensationCarrier),
        "compensation carrier deferred past #{pending.size} tool result(s)")

      yield pending.dup
      pending.clear
    end

    # ---- Export: request back in ---------------------------------------------

    # Whether a message following a run of tool results is a carrier rather
    # than genuine input opening a new turn.
    #
    # The ambiguity is real and this narrows it rather than closing it. A
    # foreign session produced by another client doing the same twiddling with
    # different marker text is undetectable, and a genuine user message that
    # follows a tool result and carries only an image is a legitimate
    # conversation that will be misread as scaffolding. Three signals, weakest
    # last:
    #
    # 1. `synthetic` — decisive, but only within one process. A carrier read
    #    back from JSON has no such flag and must be recognised structurally.
    # 2. A marker in the run above, which is our own constant.
    # 3. No text of its own, since a carrier only ever holds lifted non-text.
    #
    # `eligible` carries each caller's own precondition — Gemini wants
    # `role: "user"`, Chat Completions' content may be a bare `String` with no
    # parts to inspect at all. It is a parameter rather than a check hoisted to
    # the call site because both sat *below* the synthetic test originally, and
    # lifting them above it would flip the answer for a synthetic message that
    # failed them. Everything after the synthetic short-circuit is a plain
    # conjunction, so where among those it sits does not matter.
    def carrier?(run : Array(MPSH::ToolResultBlock), synthetic : Bool,
                 parts : Array(T), eligible : Bool = true,
                 & : T -> Bool) : Bool forall T
      return false if run.empty?
      return true if synthetic
      return false unless eligible
      return false unless run.any? { |result| placeholders(result) > 0 }

      parts.none? { |part| yield part }
    end

    # Returns carrier content to the results that referenced it, in order.
    #
    # The queue is consumed against marker *counts*, not positions, which is
    # what lets one carrier serve several results: each result takes as many
    # parts as it left markers, in the order it left them. The block converts
    # one wire part to a block, or `nil` for a part this protocol cannot
    # express — in which case the slot is spent and one marker survives, though
    # not in its original position: `replace_placeholder` fills the first
    # marker still open, so a later part slides up into the skipped one. The
    # count stays right and the ordering within that result drifts. Behaviour
    # inherited from the three implementations this replaces, pinned in
    # `spec/capability/carrier_spec.cr` as it is rather than as it ought to be.
    def absorb(run : Array(MPSH::ToolResultBlock), parts : Array(T),
               & : T -> MPSH::Block?) : Nil forall T
      queue = parts.dup

      run.each do |result|
        placeholders(result).times do
          part = queue.shift?
          break unless part
          block = yield part
          replace_placeholder(result, block) if block
        end
      end
    end

    # How many markers this result is still holding open.
    def placeholders(result : MPSH::ToolResultBlock) : Int32
      result.content.count do |block|
        block.is_a?(MPSH::TextBlock) && block.text == PLACEHOLDER
      end
    end

    # Fills the first marker still open, in place.
    def replace_placeholder(result : MPSH::ToolResultBlock, block : MPSH::Block) : Nil
      index = result.content.index do |existing|
        existing.is_a?(MPSH::TextBlock) && existing.text == PLACEHOLDER
      end
      result.content[index] = block if index
    end

    # A tool result arrives from the wire as one string, and the markers inside
    # it record where non-text content belonged. Splitting on the marker
    # restores the block boundaries, which is what lets a carrier be absorbed
    # back into the right positions rather than merely appended.
    #
    # Splitting on the marker itself rather than on newlines matters: genuine
    # tool output contains newlines, and splitting on those would shred it.
    def split(body : String) : Array(MPSH::Block)
      return [] of MPSH::Block if body.empty?

      blocks = [] of MPSH::Block
      segments = body.split(PLACEHOLDER)

      segments.each_with_index do |segment, index|
        trimmed = segment.strip('\n')
        blocks << MPSH::TextBlock.new(trimmed) unless trimmed.empty?
        # Every split point but the last trailing one had a marker.
        blocks << MPSH::TextBlock.new(PLACEHOLDER) if index < segments.size - 1
      end

      blocks
    end
  end
end
