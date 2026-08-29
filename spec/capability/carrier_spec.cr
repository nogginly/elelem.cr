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

    # The reason one carrier can serve a whole run: parts are dealt out to each
    # result's markers in turn, not matched by identifier. Getting this wrong
    # gives every result the first image.
    it "deals parts across several results, in order" do
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

    # A part the target cannot express spends its slot and leaves that marker
    # standing — in the position it always occupied. The three implementations
    # this module replaced counted markers but filled the first one still open,
    # so the next part that did convert slid up into the skipped slot and the
    # surviving marker trailed at the end. Right count, wrong order.
    it "keeps the marker in place for a part it cannot convert" do
      target = result(markers: 2)

      C::Carrier.absorb([target], ["unmappable", "b"]) { |part| to_block(part) }

      target.content[1].as(M::TextBlock).text.should eq(C::Carrier::PLACEHOLDER)
      target.content[2].as(M::ImageBlock).text_fallback.should eq("b")
    end

    # The same rule across a result boundary, which first-open filling also got
    # wrong: a skipped slot in one result must not draw the following result's
    # content forward into it.
    it "keeps a skipped slot from pulling a later result's content into it" do
      first = result(markers: 1, text: "first")
      second = result(markers: 1, text: "second")

      C::Carrier.absorb([first, second], ["unmappable", "b"]) { |part| to_block(part) }

      first.content[1].as(M::TextBlock).text.should eq(C::Carrier::PLACEHOLDER)
      second.content[1].as(M::ImageBlock).text_fallback.should eq("b")
    end

    # Markers are located before anything is written, so the indices taken up
    # front stay valid. This is the case that would break if a replacement ever
    # resized the content array.
    it "writes each part to its own marker when text surrounds them" do
      target = M::ToolResultBlock.new("call-1", [
        M::TextBlock.new("before").as(M::Block),
        M::TextBlock.new(C::Carrier::PLACEHOLDER).as(M::Block),
        M::TextBlock.new("between").as(M::Block),
        M::TextBlock.new(C::Carrier::PLACEHOLDER).as(M::Block),
        M::TextBlock.new("after").as(M::Block),
      ])

      C::Carrier.absorb([target], ["a", "b"]) { |part| to_block(part) }

      target.content[0].as(M::TextBlock).text.should eq("before")
      target.content[1].as(M::ImageBlock).text_fallback.should eq("a")
      target.content[2].as(M::TextBlock).text.should eq("between")
      target.content[3].as(M::ImageBlock).text_fallback.should eq("b")
      target.content[4].as(M::TextBlock).text.should eq("after")
    end

    it "does nothing to a result holding no markers" do
      target = result(markers: 0)

      C::Carrier.absorb([target], ["a"]) { |part| to_block(part) }

      target.content.size.should eq(1)
    end
  end

  describe ".marker_indices" do
    it "reports where the markers are, in order" do
      target = M::ToolResultBlock.new("call-1", [
        M::TextBlock.new("before").as(M::Block),
        M::TextBlock.new(C::Carrier::PLACEHOLDER).as(M::Block),
        M::TextBlock.new("between").as(M::Block),
        M::TextBlock.new(C::Carrier::PLACEHOLDER).as(M::Block),
      ])

      C::Carrier.marker_indices(target).should eq([1, 3])
      C::Carrier.placeholders(target).should eq(2)
    end

    # Text that merely resembles the marker is not one. It is matched exactly,
    # which is the whole reason it may never be localized.
    it "ignores text that only looks like the marker" do
      target = M::ToolResultBlock.new("call-1", [
        M::TextBlock.new("[elelem: content returned separately]").as(M::Block),
      ])

      C::Carrier.marker_indices(target).should be_empty
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
