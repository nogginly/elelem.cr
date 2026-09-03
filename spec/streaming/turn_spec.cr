require "../spec_helper"

# The cooperative stop handle.
#
# Small enough that the tests are nearly the implementation, which is fine —
# what they pin is not the mechanism but the two promises the type makes:
# stopping is a request rather than an exception, and asking twice is not an
# error. The second matters more than it looks: the obvious block is one that
# calls `stop` on every event after some condition goes true, and a handle that
# objected to that would push callers into tracking state the handle already
# has.

describe Elelem::Streaming::Turn do
  it "starts unstopped" do
    S::Turn.new.stopped?.should be_false
  end

  it "records a request to stop" do
    turn = S::Turn.new
    turn.stop
    turn.stopped?.should be_true
  end

  it "accepts the request more than once" do
    turn = S::Turn.new
    3.times { turn.stop }
    turn.stopped?.should be_true
  end

  it "does not stop itself" do
    # No timeout, no frame budget, no self-cancellation. The only thing that
    # ends a turn early is a caller asking.
    turn = S::Turn.new
    100.times { turn.stopped? }
    turn.stopped?.should be_false
  end
end
