require "../spec_helper"

# The compensation carrier's rule, tested away from any protocol.
#
# The three mappers and three exporters that used to hold copies of this each
# tested it only through their own wire types, which is why the same rule could
# be expressed three ways and be wrong in one of them without any suite
# noticing: every protocol's fixtures passed against that protocol's own
# implementation. Testing the module directly is the regression net that
# arrangement never had.
#
# Parts here are plain `String`s. The module is generic over the part type by
# design — it exists precisely so it cannot know what a wire part is — so a
# spec that reached for `Wire::Part` would be testing a protocol again.

# A part converts to a block, or to `nil` for one the protocol cannot express.
private def to_block(part : String) : M::Block?
  return nil if part == "unmappable"
  M::ImageBlock.new(
    M::InlinePayload.new("aGk=", "image/png", 2_i64), text_fallback: part)
end

private def result(*, markers : Int32, text : String = "ok") : M::ToolResultBlock
  content = [M::TextBlock.new(text).as(M::Block)]
  markers.times { content << M::TextBlock.new(C::Carrier::PLACEHOLDER) }
  M::ToolResultBlock.new("call-1", content)
end

private def report : C::Report
  C::Report.new("spec")
end

describe Elelem::Capability::Carrier do
  describe ".flush" do
    it "yields the buffered parts, records the deferral, and empties the buffer" do
      pending = ["one", "two"]
      carried = [] of Array(String)
      log = report

      C::Carrier.flush(pending, log) { |parts| carried << parts }

      carried.should eq([["one", "two"]])
      pending.should be_empty
      log.worst.should eq(M::Outcome::Compensated)
    end

    # The buffer is cleared after the block runs, so a caller that keeps what it
    # was handed must be handed a copy. Aliasing it would leave the carrier
    # message empty the moment the next flush point arrived — silently, and only
    # for sessions with two carriers.
    it "hands over a copy rather than the buffer itself" do
      pending = ["one"]
      carried = [] of Array(String)

      C::Carrier.flush(pending, report) { |parts| carried << parts }

      carried.first.should eq(["one"])
    end

    # Nothing buffered is the overwhelmingly common case — every session
    # without lifted content — and it must not record an adaptation that did
    # not happen. A spurious `Compensated` would be indistinguishable from a
    # real one in any report a caller inspects.
    it "does nothing at all when the buffer is empty" do
      called = false
      log = report

      C::Carrier.flush([] of String, log) { called = true }

      called.should be_false
      log.worst.should eq(M::Outcome::Exact)
      log.annotations.should be_empty
    end
  end

  describe ".carrier?" do
    it "is false when no tool results precede it — there is nothing to belong to" do
      C::Carrier.carrier?([] of M::ToolResultBlock, false, ["x"]) { |_| false }.should be_false
    end

    # Decisive, and the only signal available within one process. It outranks
    # every other check, including a caller's own precondition — which is the
    # reason `eligible` is a parameter rather than a guard at the call site.
    it "is true for a synthetic message even with no markers above it" do
      C::Carrier.carrier?([result(markers: 0)], true, ["x"]) { |_| true }.should be_true
    end

    it "is true for a synthetic message even when the caller's precondition fails" do
      C::Carrier.carrier?([result(markers: 0)], true, ["x"], eligible: false) { |_| true }
        .should be_true
    end

    # The structural path: what an export reading JSON from a server has to go
    # on, with no synthetic flag anywhere.
    it "is true when markers are open above and the message carries no text" do
      C::Carrier.carrier?([result(markers: 1)], false, ["image"]) { |part| part == "text" }
        .should be_true
    end

    it "is false when the run above left no markers" do
      C::Carrier.carrier?([result(markers: 0)], false, ["image"]) { |part| part == "text" }
        .should be_false
    end

    # A genuine user turn opening with words is not scaffolding, whatever sits
    # above it. This is the check that keeps ordinary conversation out.
    it "is false when the message carries text of its own" do
      C::Carrier.carrier?([result(markers: 1)], false, ["text", "image"]) { |part| part == "text" }
        .should be_false
    end

    it "is false when the caller's own precondition fails" do
      C::Carrier.carrier?([result(markers: 1)], false, ["image"], eligible: false) { |_| false }
        .should be_false
    end
  end

  describe ".absorb" do
    it "returns one part to the one marker that referenced it" do
      target = result(markers: 1)

      C::Carrier.absorb([target], ["a cat"]) { |part| to_block(part) }

      target.content.size.should eq(2)
      target.content[0].as(M::TextBlock).text.should eq("ok")
      target.content[1].as(M::ImageBlock).text_fallback.should eq("a cat")
    end

    # The reason one carrier can serve a whole run: parts are dealt out against
    # each result's *marker count*, in order, not matched by position or
    # identifier. Getting this wrong gives every result the first image.
    it "deals parts across several results by marker count, in order" do
      first = result(markers: 2, text: "first")
      second = result(markers: 1, text: "second")

      C::Carrier.absorb([first, second], ["a", "b", "c"]) { |part| to_block(part) }

      first.content[1].as(M::ImageBlock).text_fallback.should eq("a")
      first.content[2].as(M::ImageBlock).text_fallback.should eq("b")
      second.content[1].as(M::ImageBlock).text_fallback.should eq("c")
    end

    it "leaves results alone once the carrier runs out" do
      first = result(markers: 1, text: "first")
      second = result(markers: 1, text: "second")

      C::Carrier.absorb([first, second], ["a"]) { |part| to_block(part) }

      first.content[1].as(M::ImageBlock).text_fallback.should eq("a")
      second.content[1].as(M::TextBlock).text.should eq(C::Carrier::PLACEHOLDER)
    end

    # A part this protocol cannot express consumes its slot, and one marker
    # survives — but not the one it was meant for. `replace_placeholder` fills
    # the *first* marker still open, so the next part that does convert slides
    # up into the skipped position and the surviving marker trails at the end.
    #
    # Pinned as it behaves, not as it ought to. This predates the extraction
    # and is unchanged by it; the count is right and only the ordering within
    # one tool result drifts, which is why it is recorded here rather than
    # quietly fixed inside a refactor whose whole safety argument is that it
    # changes nothing.
    it "consumes the slot for a part it cannot convert, leaving one marker behind" do
      target = result(markers: 2)

      C::Carrier.absorb([target], ["unmappable", "b"]) { |part| to_block(part) }

      target.content[1].as(M::ImageBlock).text_fallback.should eq("b")
      target.content[2].as(M::TextBlock).text.should eq(C::Carrier::PLACEHOLDER)
    end

    it "does nothing to a result holding no markers" do
      target = result(markers: 0)

      C::Carrier.absorb([target], ["a"]) { |part| to_block(part) }

      target.content.size.should eq(1)
    end
  end

  describe ".split" do
    it "returns nothing for an empty body" do
      C::Carrier.split("").should be_empty
    end

    it "returns one text block when there is no marker" do
      blocks = C::Carrier.split("plain output")
      blocks.size.should eq(1)
      blocks[0].as(M::TextBlock).text.should eq("plain output")
    end

    # The marker's *position* is the information being recovered: it is where
    # the lifted content stood, so absorption can put it back rather than
    # append it.
    it "keeps a marker between the text on either side of it" do
      blocks = C::Carrier.split("before\n#{C::Carrier::PLACEHOLDER}\nafter")

      blocks.size.should eq(3)
      blocks[0].as(M::TextBlock).text.should eq("before")
      blocks[1].as(M::TextBlock).text.should eq(C::Carrier::PLACEHOLDER)
      blocks[2].as(M::TextBlock).text.should eq("after")
    end

    it "keeps one marker per lifted part, with nothing between them" do
      blocks = C::Carrier.split("#{C::Carrier::PLACEHOLDER}\n#{C::Carrier::PLACEHOLDER}")

      blocks.size.should eq(2)
      blocks.each { |block| block.as(M::TextBlock).text.should eq(C::Carrier::PLACEHOLDER) }
    end

    it "counts a trailing marker, and adds no empty block after it" do
      blocks = C::Carrier.split("output\n#{C::Carrier::PLACEHOLDER}")

      blocks.size.should eq(2)
      blocks[1].as(M::TextBlock).text.should eq(C::Carrier::PLACEHOLDER)
    end

    # Splitting on newlines instead of on the marker would shred this, and
    # genuine tool output — JSON, logs, tables — is full of newlines.
    it "leaves newlines inside genuine output intact" do
      blocks = C::Carrier.split("line one\nline two\n#{C::Carrier::PLACEHOLDER}")

      blocks[0].as(M::TextBlock).text.should eq("line one\nline two")
    end
  end

  # Round trip: what a mapper lifts out, an exporter puts back. Neither half is
  # worth much alone, and the bug this module was extracted after was a
  # mismatch between them rather than a fault in either.
  it "puts back what it lifted, in the positions it was lifted from" do
    lifted = C::Carrier.split("before\n#{C::Carrier::PLACEHOLDER}\nafter")
    restored = M::ToolResultBlock.new("call-1", lifted)

    C::Carrier.absorb([restored], ["a cat"]) { |part| to_block(part) }

    restored.content[0].as(M::TextBlock).text.should eq("before")
    restored.content[1].as(M::ImageBlock).text_fallback.should eq("a cat")
    restored.content[2].as(M::TextBlock).text.should eq("after")
  end
end
