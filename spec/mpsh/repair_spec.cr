require "../spec_helper"

# The acceptance test for `SCOPE.md`'s interrupted-turn entry, stated as the
# entry states it: **the session is never left in a state a subsequent `send`
# cannot build on.** Everything below is one of the three rows of its table, or
# the invariant itself.
#
# Pure MPSH throughout — no protocol, no provider, no transcript. That is the
# point of putting repair here rather than in the client: a session reloaded
# from an archive can be repaired with none of them available.
describe "MPSH::Repair" do
  args = M::Object{"city" => "Kyoto".as(M::Value)}

  cut_with_call = ->(ending : M::Ending) do
    reply = M::Message.new(M::Role::Assistant, Elelem::Fixtures.blocks(
      Elelem::Fixtures.text("Let me look that up."),
      M::ToolCallBlock.new("mc_repair_weather", "get_weather", args)
    ))
    reply.ending = ending
    reply
  end

  describe "the three states" do
    it "leaves a complete turn alone, tool calls and all" do
      reply = cut_with_call.call(M::Ending::Complete)

      M::Repair.needed?(reply).should be_false
      M::Repair.repaired(reply).should be(reply)
    end

    it "keeps the text of a cut turn that called no tools" do
      reply = M::Message.assistant("The capital of Fra")
      reply.ending = M::Ending::Truncated

      M::Repair.needed?(reply).should be_false
      M::Repair.repaired(reply).try(&.text).should eq("The capital of Fra")
    end

    # The awkward row. A partial set may be half a parallel plan, and nothing
    # in the reply says whether another call was about to arrive.
    it "drops the calls and keeps any text" do
      repaired = M::Repair.repaired(cut_with_call.call(M::Ending::Interrupted)).should_not be_nil

      repaired.content.size.should eq(1)
      repaired.text.should eq("Let me look that up.")
      repaired.content.none?(M::ToolCallBlock).should be_true
    end

    it "reports nothing to keep when the cut turn was only calls" do
      reply = M::Message.new(M::Role::Assistant,
        Elelem::Fixtures.blocks(M::ToolCallBlock.new("mc_repair_weather", "get_weather", args)))
      reply.ending = M::Ending::Interrupted

      M::Repair.repaired(reply).should be_nil
    end
  end

  it "drops calls under every cause, since repair does not vary by cause" do
    {M::Ending::Truncated, M::Ending::Stopped, M::Ending::Interrupted}.each do |ending|
      M::Repair.needed?(cut_with_call.call(ending)).should be_true
    end
  end

  # The original is what actually arrived, and a caller may be holding it to
  # show someone. Repair produces a second message rather than editing it.
  it "does not modify the message it repairs" do
    reply = cut_with_call.call(M::Ending::Stopped)
    M::Repair.repaired(reply)

    reply.content.size.should eq(2)
  end

  it "carries the ending and the provider metadata onto the repaired turn" do
    reply = cut_with_call.call(M::Ending::Stopped)
    reply.put_meta("anthropic", "stop_reason", "max_tokens")

    repaired = M::Repair.repaired(reply).should_not be_nil

    repaired.ending.should eq(M::Ending::Stopped)
    repaired.meta?("anthropic", "stop_reason").should eq("max_tokens")
  end

  describe "the invariant" do
    it "holds for a session whose calls were all answered" do
      M::Repair.sendable?(Elelem::Fixtures.tool_call_text_result).should be_true
    end

    it "fails for a session ending on an unanswered call" do
      session = Elelem::Fixtures.single_user_turn
      session << cut_with_call.call(M::Ending::Interrupted)

      M::Repair.sendable?(session).should be_false
    end

    it "holds again once the session is repaired" do
      session = Elelem::Fixtures.single_user_turn
      session << cut_with_call.call(M::Ending::Interrupted)

      M::Repair.repair!(session).should be_true
      M::Repair.sendable?(session).should be_true
      session.messages.last.text.should eq("Let me look that up.")
    end

    it "removes a turn repair emptied, so the session is immediately resendable" do
      session = Elelem::Fixtures.single_user_turn
      reply = M::Message.new(M::Role::Assistant,
        Elelem::Fixtures.blocks(M::ToolCallBlock.new("mc_repair_weather", "get_weather", args)))
      reply.ending = M::Ending::Interrupted
      session << reply

      M::Repair.repair!(session).should be_true
      session.size.should eq(1)
      session.messages.last.role.user?.should be_true
    end

    # An empty message is a fixture in its own right and divergent provider
    # handling of one is a real case. Repair removes only what it emptied.
    it "leaves a message that arrived empty where it is" do
      session = Elelem::Fixtures.session(
        Elelem::Fixtures.user(Elelem::Fixtures.text("Hello")),
        Elelem::Fixtures.empty_user)

      M::Repair.repair!(session).should be_false
      session.size.should eq(2)
    end
  end

  # The reload path, and the reason the ending is archived rather than kept on
  # a report: nothing about the report survives the process that made it.
  it "repairs a session that was archived mid-turn" do
    session = Elelem::Fixtures.single_user_turn
    session << cut_with_call.call(M::Ending::Interrupted)

    restored = M::Archive.read(M::Archive.write(session))

    M::Repair.sendable?(restored).should be_false
    M::Repair.repair!(restored).should be_true
    M::Repair.sendable?(restored).should be_true
    restored.messages.last.ending.should eq(M::Ending::Interrupted)
  end
end
