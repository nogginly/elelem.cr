require "../spec_helper"
require "../../src/elelem_cli/display"

# Pure: defaults in, flags in, a `Display` out. The terminal test is injected
# rather than asked of the real `STDOUT`, since a spec run in a terminal and a
# spec run in CI would otherwise disagree about what this file asserts.
private def a_pipe : IO
  IO::Memory.new
end

private class FakeTerminal < IO::Memory
  def tty? : Bool
    true
  end
end

describe Elelem::Cli::Display do
  off = Elelem::Cli::Defaults.new
  on = Elelem::Cli::Defaults.new(streaming: true, show_reasoning: true)

  describe "streaming" do
    it "stays off when nothing asked for it" do
      Elelem::Cli::Display.resolve(off, stdout: FakeTerminal.new).streaming?.should be_false
    end

    it "follows the config on a terminal" do
      Elelem::Cli::Display.resolve(on, stdout: FakeTerminal.new).streaming?.should be_true
    end

    # The floor. A config is a standing preference; a redirected run is one
    # nobody is watching, and streaming into it buys nothing while adding a
    # way to be truncated that only exists when you stream.
    it "declines to stream into something that is not a terminal, config or not" do
      Elelem::Cli::Display.resolve(on, stdout: a_pipe).streaming?.should be_false
    end

    # …and the one thing that goes through it, because a flag is typed with
    # one particular run in view.
    it "streams into a pipe when the flag says so" do
      Elelem::Cli::Display.resolve(off, stream: true, stdout: a_pipe).streaming?.should be_true
    end

    it "lets --no-stream beat a config that asked for it" do
      Elelem::Cli::Display.resolve(on, stream: false, stdout: FakeTerminal.new).streaming?.should be_false
    end
  end

  describe "reasoning" do
    it "stays off by default" do
      Elelem::Cli::Display.resolve(off, stdout: FakeTerminal.new).show_reasoning?.should be_false
    end

    it "follows the config" do
      Elelem::Cli::Display.resolve(on, stdout: FakeTerminal.new).show_reasoning?.should be_true
    end

    it "takes the flag over the config, in both directions" do
      Elelem::Cli::Display.resolve(off, show_reasoning: true, stdout: a_pipe).show_reasoning?.should be_true
      Elelem::Cli::Display.resolve(on, show_reasoning: false, stdout: a_pipe).show_reasoning?.should be_false
    end

    # No floor here, and the asymmetry is the point: this is a question about
    # what to show, not about how to fetch, so a pipe risks nothing by it.
    it "shows reasoning into a pipe when asked, unlike streaming" do
      display = Elelem::Cli::Display.resolve(on, stdout: a_pipe)

      display.streaming?.should be_false
      display.show_reasoning?.should be_true
    end
  end
end
