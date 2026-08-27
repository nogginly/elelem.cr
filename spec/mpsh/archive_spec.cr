require "../spec_helper"
require "../support/conformance"

# Archive's own conformance gate, same shape as every protocol's: not a
# hand-picked example, the whole fixture set, and the same `Conformance.compare`
# every protocol suite already trusts rather than a second equality check
# invented for this file alone.
#
# The bar here is higher than any protocol's, and worth saying explicitly:
# Archive is not a capability adaptation, it has no matrix, and it is allowed
# exactly zero divergences, for every fixture, always. A protocol mapper is
# permitted to lose fidelity where the matrix predicts it; this file is not
# permitted to lose any, because losing fidelity here silently corrupts
# whatever `continue` resumes.
describe "MPSH::Archive" do
  Elelem::Fixtures.all.each do |name, session|
    it "round-trips '#{name}' with zero divergence" do
      written = M::Archive.write(session)
      restored = M::Archive.read(written)

      Conformance.compare(session, restored).should be_empty
    end
  end

  # No fixture calls `Session#annotate` — annotations are the mapper's own
  # audit trail, not conversation content, so the fixture set (built to
  # exercise mapping, not archiving) never populates them. Covered directly
  # here instead.
  it "round-trips annotations, which Conformance.compare does not check" do
    session = Elelem::Fixtures.single_user_turn
    session.annotate(M::Annotation.new(M::Outcome::Degraded, "anthropic",
      "unsupported media type, text fallback used", 0, M::BlockKind::Image))

    restored = M::Archive.read(M::Archive.write(session))

    restored.annotations.size.should eq(1)
    a = restored.annotations.first
    a.outcome.should eq(M::Outcome::Degraded)
    a.provider.should eq("anthropic")
    a.detail.should eq("unsupported media type, text fallback used")
    a.message_index.should eq(0)
    a.block_kind.should eq(M::BlockKind::Image)
  end

  it "rejects a source that isn't an MPSH archive" do
    expect_raises(M::Archive::FormatError) { M::Archive.read(%({"hello": "world"})) }
  end
end
