require "../spec_helper"
require "../../src/elelem_cli/progress"

# `IO::Memory#tty?` is always false, which is exactly the case worth testing
# and useless for testing the other one. This lies about being a terminal so
# both branches are reachable.
private class FakeTty < IO::Memory
  def tty? : Bool
    true
  end
end

describe Elelem::Cli::Progress do
  # The load-bearing test. Redirected stderr is a log file or a CI transcript,
  # and a few hundred carriage returns in one is worse than no indicator.
  it "writes nothing at all when the stream is not a terminal" do
    sink = IO::Memory.new
    Elelem::Cli::Progress.while_waiting("thinking", sink) do
      sleep(Elelem::Cli::Progress::TICK * 3)
    end
    sink.to_s.should be_empty
  end

  it "draws and keeps drawing while the block runs" do
    sink = FakeTty.new
    Elelem::Cli::Progress.while_waiting("thinking", sink) do
      sleep(Elelem::Cli::Progress::TICK * 3)
    end

    drawn = sink.to_s
    drawn.should contain("thinking")
    # More than one frame, i.e. it is a ticker and not a single static line.
    drawn.count('\r').should be > 2
  end

  # A spinner left on the line is worst precisely when the next thing printed
  # is an error, which is when someone is already trying to read carefully.
  it "erases the line even when the block raises" do
    sink = FakeTty.new
    expect_raises(ArgumentError, "boom") do
      Elelem::Cli::Progress.while_waiting("thinking", sink) do
        sleep(Elelem::Cli::Progress::TICK * 2)
        raise ArgumentError.new("boom")
      end
    end

    # Whatever it drew, the last thing it did was blank the line and return
    # the cursor, so a caller printing next starts clean. There are no
    # newlines in any of this, so it is matched at the end of the whole
    # string rather than by picking a line out of it.
    sink.to_s.should match(/ {2,}\r\z/)
  end

  it "reports elapsed seconds, not just motion" do
    sink = FakeTty.new
    Elelem::Cli::Progress.while_waiting("thinking", sink) do
      sleep(Elelem::Cli::Progress::TICK * 5)
    end
    sink.to_s.should match(/\d+s/)
  end

  # The hook streaming will use: relabel mid-flight rather than tearing the
  # indicator down and standing a new one up.
  it "picks up a label changed while running" do
    sink = FakeTty.new
    Elelem::Cli::Progress.while_waiting("thinking", sink) do |indicator|
      sleep(Elelem::Cli::Progress::TICK * 2)
      indicator.label = "aggregating tool call"
      sleep(Elelem::Cli::Progress::TICK * 2)
    end

    drawn = sink.to_s
    drawn.should contain("thinking")
    drawn.should contain("aggregating tool call")
  end

  it "returns the block's value untouched" do
    sink = IO::Memory.new
    result = Elelem::Cli::Progress.while_waiting("thinking", sink) { {1, "two"} }
    result.should eq({1, "two"})
  end

  it "is safe to stop without having started" do
    Elelem::Cli::Progress.new("thinking", IO::Memory.new).stop
  end
end
