require "../spec_helper"
require "../support/cli_output"

# What the CLI says about a turn that did not finish, and — as much to the
# point — where it says it. Stdout carries the reply and nothing else, which
# is the guarantee `elelem start ... | pbcopy` rests on, so every word here
# belongs on stderr.
describe Elelem::Cli::Output do
  args = M::Object{"city" => "Kyoto".as(M::Value)}

  cut = ->(ending : M::Ending) do
    reply = M::Message.new(M::Role::Assistant, Elelem::Fixtures.blocks(
      Elelem::Fixtures.text("Let me look that up."),
      M::ToolCallBlock.new("mc_cli_weather", "get_weather", args)
    ))
    reply.ending = ending
    reply
  end

  describe ".warn_cut" do
    it "says nothing at all about a turn that finished" do
      printed, warned = captured { Elelem::Cli::Output.warn_cut(M::Message.assistant("Kyoto is mild.")) }

      printed.should be_empty
      warned.should be_empty
    end

    it "distinguishes the three ways a turn ends early" do
      {M::Ending::Truncated   => /stopped short/,
       M::Ending::Stopped     => /was stopped/,
       M::Ending::Interrupted => /stream ended/}.each do |ending, expected|
        _, warned = captured { Elelem::Cli::Output.warn_cut(cut.call(ending)) }
        warned.should match(expected)
      end
    end

    # The discrepancy worth naming out loud: the reply on screen mentions
    # looking something up, and the saved session contains no such call.
    it "counts the tool calls left out of the saved session" do
      _, warned = captured { Elelem::Cli::Output.warn_cut(cut.call(M::Ending::Interrupted)) }

      warned.should match(/1 unfinished tool call/)
    end

    it "stays quiet about calls when a cut turn made none" do
      reply = M::Message.assistant("The capital of Fra")
      reply.ending = M::Ending::Truncated

      _, warned = captured { Elelem::Cli::Output.warn_cut(reply) }

      warned.should match(/stopped short/)
      warned.should_not match(/tool/)
    end

    it "keeps all of it off stdout" do
      printed, warned = captured { Elelem::Cli::Output.warn_cut(cut.call(M::Ending::Truncated)) }

      printed.should be_empty
      warned.should_not be_empty
    end
  end

  describe ".repaired_on_load" do
    it "names the session, since it changed what is on disk" do
      printed, warned = captured { Elelem::Cli::Output.repaired_on_load("brisk-otter") }

      printed.should be_empty
      warned.should match(/brisk-otter/)
    end
  end
end
