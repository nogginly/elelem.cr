require "./function"
require "./mpsh/message"
require "./mpsh/repair"

module Elelem
  # A collection of `Function`s, used at both ends of a turn: `#tools` produces
  # the declarations a request carries, `#dispatch` turns a reply's calls into
  # the results the next request carries.
  #
  # ```
  # toolbox = Elelem::Toolbox.new([Weather.new, Clock.new])
  #
  # loop do
  #   reply, _ = client.send(session, model, options: Options.new(tools: toolbox.tools))
  #   session << reply
  #
  #   results = toolbox.dispatch(reply)
  #   break unless results
  #   session << results
  # end
  # ```
  #
  # It holds functions and pairs results to calls. It does not own the session,
  # does not decide when a conversation is finished, and does not loop —
  # `Client#send`'s turn loop stays caller-owned, as `client.cr` says.
  class Toolbox
    getter functions : Array(Function)

    # Raises if two functions answer to the same name, since a call names one
    # tool and silently preferring either is worse than refusing to start.
    def initialize(@functions : Array(Function))
      @by_name = {} of String => Function
      @functions.each do |function|
        if @by_name.has_key?(function.name)
          raise ArgumentError.new("duplicate tool name in toolbox: #{function.name}")
        end
        @by_name[function.name] = function
      end
    end

    # The declarations, for `Options#tools`.
    def tools : Array(Tool)
      @functions.map(&.to_tool)
    end

    # Runs every call in `reply` and returns one user-role message of results,
    # or `nil` when there is nothing to run — which is also a turn loop's exit
    # condition.
    #
    # Calls are run in the order they arrive, one at a time. No protocol here
    # expresses a dependency between parallel calls — they are a batch issued
    # from one plan, not a sequence — so running them in order is a superset of
    # what any of them guarantees.
    #
    # **Dispatch reads the repaired reply**, which is why this repairs rather
    # than trusting its argument. A cut turn's calls are dropped from the
    # session, and dispatching one that was dropped appends a result whose call
    # is missing, breaking `Repair.sendable?` from the other direction. Repair
    # is idempotent, so passing an already-repaired message is free.
    #
    # Server-executed calls are skipped: the provider ran them and the reply
    # already carries their results.
    def dispatch(reply : MPSH::Message) : MPSH::Message?
      repaired = MPSH::Repair.repaired(reply)
      return nil unless repaired

      calls = repaired.content.select(MPSH::ToolCallBlock).reject(&.server_executed?)
      return nil if calls.empty?

      MPSH::Message.new(MPSH::Role::User, calls.map { |call| run(call).as(MPSH::Block) })
    end

    # Every call gets a result, including a call naming a tool this toolbox does
    # not hold and a call whose tool raised. Skipping either would leave a
    # dangling call and an unsendable session — the one shape the archive exists
    # to prevent — so a failure is reported rather than omitted.
    private def run(call : MPSH::ToolCallBlock) : MPSH::ToolResultBlock
      function = @by_name[call.name]?
      return failed(call, "no tool named #{call.name} is available") unless function

      MPSH::ToolResultBlock.new(call.call_id, function.call(call.arguments))
    rescue error : Function::Failure
      failed(call, error.message || "the tool reported a failure")
    rescue error : Exception
      # `is_error` is set as well as `exception` deliberately. They are
      # different facts — reported failure against dispatch blowing up — but no
      # mapper carries `exception` onto the wire; it is written by `Archive` and
      # read back, and nowhere else. So `exception` is what a later reader sees
      # and `is_error` is what the model sees, and an unexpected raise needs
      # both to be true of it.
      failed(call, "the tool raised: #{error.message}", exception: error.inspect)
    end

    private def failed(call : MPSH::ToolCallBlock, text : String,
                       exception : String? = nil) : MPSH::ToolResultBlock
      MPSH::ToolResultBlock.new(call.call_id,
        [MPSH::TextBlock.new(text).as(MPSH::Block)],
        is_error: true, exception: exception)
    end
  end
end
