require "../spec_helper"

# A stream that ends without its terminal frame, from the byte stream through
# `Client` to what `MPSH::Repair` lets the session keep.
#
# **Why the fixtures are synthetic, and why that is allowed here.** Every other
# transcript in this suite is a recording, because a fixture written by the same
# hand as the code tests the hand rather than the wire. This one cannot be: no
# server sends a truncated stream on request, and the three other `MPSH::Ending`
# members are covered precisely because a server will produce them. What is
# under test is our own response to a cut byte stream — not a guess about what
# a vendor sends — so the usual objection does not apply. The *frames* are still
# recorded; only the cut is ours.
#
# **How each fixture was made.** Copy the recorded transcript, keep the request
# verbatim so its digest still matches, and drop the trailing frames:
#
# Fixture                  |From                      |Kept          |Dropped
# -------------------------|--------------------------|--------------|----------------------------
# `anthropic_stream_cut`   |`anthropic_stream_tools`  |through 15    |`message_delta`, `message_stop`
# `ollama_chat_stream_cut` |`ollama_chat_stream_tools`|through 41    |the `finish_reason` chunk, `[DONE]`
#
# Both cuts land immediately after a tool call has finished arriving, which is
# the one position where the two protocols answer differently and where the
# answer matters most.
#
# **What the pair proves that neither proves alone.** `docs/CLI_DESIGN.md`'s
# *The durable announcement lands after repair, not after `finish`* rests on a
# divergence that had no test: Anthropic closes a `tool_use` block explicitly,
# so a call closed before the cut survives as far as the reply and is removed by
# `Repair`; Chat Completions has no per-call end signal, so a call whose
# arguments arrived whole is refused by the assembler and never reaches the
# reply at all. Same cut, same intent, two different messages — and identical
# sessions afterwards, which is the property that actually has to hold.
private def anthropic : Elelem::Client
  server = Elelem::Server.new("anthropic", "https://api.anthropic.com", ENV["ANTHROPIC_API_KEY"]?)
  Elelem::Client.new(Elelem::Provider.for(server, Elelem::ProtocolKind::Anthropic))
end

private def ollama : Elelem::Client
  server = Elelem::Server.new("ollama", "http://localhost:11434", nil)
  Elelem::Client.new(Elelem::Provider.for(server, Elelem::ProtocolKind::ChatCompletions))
end

private def weather_tool : Elelem::Tool
  Elelem::Tool.new("get_weather", "Look up the current weather in a city",
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}))
end

private def tool_question : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")
  session
end

private def anthropic_armed : Elelem::Options
  Elelem::Options.new(tools: [weather_tool],
    reasoning: Elelem::Reasoning::Effort::Low, max_output_tokens: 1536)
end

private def chat_armed : Elelem::Options
  Elelem::Options.new(tools: [weather_tool], max_output_tokens: 512)
end

describe "a stream that ends without its terminal frame" do
  describe "on Anthropic" do
    it "returns the partial reply rather than raising" do
      # `Client` used to raise here, which kept the session clean by giving the
      # caller nothing to append — honest while there was nowhere to record
      # *why* a reply was partial. `MPSH::Ending` is that somewhere.
      Wiretap.intercept("anthropic_stream_cut") do
        reply, report = anthropic.send(tool_question, "claude-haiku-4-5",
          options: anthropic_armed) { |_, _| }

        reply.role.should eq M::Role::Assistant
        report.streamed?.should be_true
      end
    end

    it "records the ending as Interrupted, not Stopped" do
      # The two are indistinguishable to an assembler — `complete?` is false for
      # both, because neither knows whether anybody asked — so this is the one
      # fact only `Client` can set. Nothing asked the turn to stop here.
      Wiretap.intercept("anthropic_stream_cut") do
        reply, _ = anthropic.send(tool_question, "claude-haiku-4-5",
          options: anthropic_armed) { |_, _| }

        reply.ending.should eq M::Ending::Interrupted
      end
    end

    it "carries a tool call that closed before the cut" do
      # `content_block_stop` arrived for this block, so the assembler can vouch
      # for it and does. The reply is an honest account of what the server sent;
      # deciding it cannot be built on is `Repair`'s job, one layer up.
      Wiretap.intercept("anthropic_stream_cut") do
        reply, _ = anthropic.send(tool_question, "claude-haiku-4-5",
          options: anthropic_armed) { |_, _| }

        calls = reply.content.select(M::ToolCallBlock)
        calls.size.should eq 1
        calls.first.name.should eq "get_weather"
      end
    end

    it "is repaired to something a session can be built on" do
      # A complete-looking call set may be half a parallel plan, and nothing in
      # the reply says whether another call was about to arrive. So the closed
      # call goes too, and the thinking that preceded it stays.
      Wiretap.intercept("anthropic_stream_cut") do
        reply, _ = anthropic.send(tool_question, "claude-haiku-4-5",
          options: anthropic_armed) { |_, _| }

        M::Repair.needed?(reply).should be_true
        repaired = M::Repair.repaired(reply).should_not be_nil
        repaired.content.select(M::ToolCallBlock).should be_empty
        repaired.content.select(M::ReasoningBlock).should_not be_empty
        repaired.ending.should eq M::Ending::Interrupted

        session = tool_question
        session << repaired
        M::Repair.sendable?(session).should be_true
      end
    end
  end

  describe "on Chat Completions" do
    it "records the ending as Interrupted" do
      Wiretap.intercept("ollama_chat_stream_cut") do
        reply, report = ollama.send(tool_question, "gemma4:26b-mxfp8",
          options: chat_armed) { |_, _| }

        report.streamed?.should be_true
        reply.ending.should eq M::Ending::Interrupted
      end
    end

    it "refuses a call whose arguments arrived whole" do
      # The strictest reading of the assembler rule anywhere in this shard, and
      # the fixture is cut to sit exactly on it: the fragment carrying
      # `{"city":"Paris"}` is kept and the `finish_reason` chunk after it is
      # not. Without that signal there is nothing to distinguish arguments that
      # are complete from arguments that are complete *so far*, and a fragment
      # that happens to parse is the dangerous case rather than the reassuring
      # one. So no call reaches the reply, and `Repair` has nothing to do.
      Wiretap.intercept("ollama_chat_stream_cut") do
        reply, _ = ollama.send(tool_question, "gemma4:26b-mxfp8",
          options: chat_armed) { |_, _| }

        reply.content.select(M::ToolCallBlock).should be_empty
        M::Repair.needed?(reply).should be_false
      end
    end

    it "keeps what a prefix can legitimately be" do
      Wiretap.intercept("ollama_chat_stream_cut") do
        reply, _ = ollama.send(tool_question, "gemma4:26b-mxfp8",
          options: chat_armed) { |_, _| }

        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end
  end

  describe "the two protocols cut at the same point" do
    it "disagree about the reply and agree about the session" do
      # Why announcing a tool call at `finish` would make the terminal's claim
      # depend on which vendor answered, and announcing it after repair does
      # not. The first assertion is the divergence; the second is why it never
      # reaches anything downstream.
      Wiretap.intercept("anthropic_stream_cut") do
        strict, _ = anthropic.send(tool_question, "claude-haiku-4-5",
          options: anthropic_armed) { |_, _| }

        Wiretap.intercept("ollama_chat_stream_cut") do
          lenient, _ = ollama.send(tool_question, "gemma4:26b-mxfp8",
            options: chat_armed) { |_, _| }

          strict.content.select(M::ToolCallBlock).size.should eq 1
          lenient.content.select(M::ToolCallBlock).size.should eq 0

          M::Repair.repaired(strict).not_nil!.content.select(M::ToolCallBlock).should be_empty
          M::Repair.repaired(lenient).not_nil!.content.select(M::ToolCallBlock).should be_empty
        end
      end
    end
  end
end
