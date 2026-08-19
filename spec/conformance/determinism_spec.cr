require "../spec_helper"

# Mapping must be a pure function of session plus options.
#
# This is not tidiness. Prompt caching keys on a byte-identical prefix, so a
# mapper that is deterministic and prefix-stable makes caching work without
# storing any wire text, and one that is not produces a cache-hit collapse that
# is invisible until it shows up in a bill.
#
# Both properties are also the entire precondition for caching the mapped prefix
# locally, which is how the O(n)-per-turn mapping cost is avoided later. Asserted
# now so it stays true, rather than built now on a cost nobody has measured.
private def map_chat(session : M::Session)
  Elelem::Protocol::ChatCompletions::Mapper.new.map(session, "test-model", C::Policy::Lenient)[0].to_json
end

private def map_responses(session : M::Session)
  Elelem::Protocol::Responses::Mapper.new.map(session, "test-model", C::Policy::Lenient)[0].to_json
end

# Fixtures that map without refusing under a lenient policy.
DETERMINISTIC_FIXTURES = Elelem::Fixtures.all.keys - %w[reference_payload]

describe "mapping determinism" do
  describe "Chat Completions" do
    DETERMINISTIC_FIXTURES.each do |name|
      it "maps #{name} to identical bytes twice" do
        session = Elelem::Fixtures.all[name]
        map_chat(session).should eq(map_chat(session))
      end
    end
  end

  describe "Responses" do
    DETERMINISTIC_FIXTURES.each do |name|
      it "maps #{name} to identical bytes twice" do
        session = Elelem::Fixtures.all[name]
        map_responses(session).should eq(map_responses(session))
      end
    end
  end

  # Prefix stability: extending a session must not rewrite what came before.
  # Without this, every turn invalidates the provider's prompt cache.
  describe "prefix stability" do
    it "leaves the mapped prefix untouched when a turn is appended" do
      base = Elelem::Fixtures.multi_turn_alternating
      extended = base.fork
      extended << M::Message.user("And Portugal?")

      before = map_chat(base)
      after = map_chat(extended)

      # The trailing `]}` of the shorter request is the only part that differs.
      prefix = before.rchop(%(]}))
      after.starts_with?(prefix).should be_true
    end

    it "holds for the Responses API too" do
      base = Elelem::Fixtures.multi_turn_alternating
      extended = base.fork
      extended << M::Message.user("And Portugal?")

      prefix = map_responses(base).rchop(%(]}))
      map_responses(extended).starts_with?(prefix).should be_true
    end
  end
end
