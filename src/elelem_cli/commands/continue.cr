require "option_parser"
require "../config"
require "../sessions"
require "../query"
require "../display"
require "../output"
require "../progress"

module Elelem::Cli::Commands
  module Continue
    extend self

    USAGE = "usage: elelem continue <session-id> <prompt...> [--on <deployment>] " \
            "[--stream|--no-stream] [--show-reasoning|--hide-reasoning]"

    def run(args : Array(String)) : Nil
      on_deployment = nil.as(String?)
      stream_flag = nil.as(Bool?)
      show_reasoning = nil.as(Bool?)
      OptionParser.parse(args) do |parser|
        parser.on("--on DEPLOYMENT", "continue on a different deployment than this session last used") do |value|
          on_deployment = value
        end
        parser.on("--stream", "show the reply as it arrives, whatever the config says") { stream_flag = true }
        parser.on("--no-stream", "wait for the whole reply") { stream_flag = false }
        parser.on("--show-reasoning", "put the model's thinking on stderr as it arrives") { show_reasoning = true }
        parser.on("--hide-reasoning", "keep the model's thinking off the terminal") { show_reasoning = false }
      end

      session_id, prompt = parse_positional(args)

      config = Config.load
      # Not the config's own default — a session's own history. What "continue"
      # means is "whoever I was already talking to," which the config's
      # default_deployment never actually recorded; see docs/CLI_DESIGN.md.
      deployment_name = on_deployment || Sessions.latest_deployment(session_id) ||
                        raise SessionError.new(
                          "session #{session_id.inspect} was saved before deployment tracking existed — " \
                          "specify --on once and every snapshot after that will remember it")
      d = config.deployment(deployment_name)
      provider = config.provider_for(deployment_name)

      # Snapshots written before repair existed can hold a turn cut mid-call,
      # and a session is portable enough to have been written by something
      # else entirely. Repairing on load costs one pass over messages that
      # are already in memory and removes the only shape a request cannot be
      # built from.
      session = Sessions.latest(session_id)
      Output.repaired_on_load(session_id) if MPSH::Repair.repair!(session)
      display = Display.resolve(config.defaults, stream_flag, show_reasoning, Output.stream)

      reply, report = Progress.while_waiting("waiting on #{deployment_name}", Output.error_stream) do |ticker|
        Query.run(provider, d.model, session, prompt,
          reasoning: d.reasoning, retention: d.reasoning_retention,
          display: display, indicator: ticker)
      end
      Sessions.snapshot(session_id, session, deployment_name)

      Output.warn_lossy(report)
      Output.warn_cut(reply)
      Output.reply(reply) unless report.streamed?
    end

    private def parse_positional(args : Array(String)) : {String, String}
      session_id = args[0]?
      prompt_words = args[1..]?
      if session_id.nil? || prompt_words.nil? || prompt_words.empty?
        raise ArgumentError.new(USAGE)
      end
      {session_id, prompt_words.join(" ")}
    end
  end
end
