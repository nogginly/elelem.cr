require "option_parser"
require "../config"
require "../sessions"
require "../query"
require "../output"
require "../progress"

module Elelem::Cli::Commands
  module Continue
    extend self

    USAGE = "usage: elelem continue <session-id> <prompt...> [--on <deployment>]"

    def run(args : Array(String)) : Nil
      on_deployment = nil.as(String?)
      OptionParser.parse(args) do |parser|
        parser.on("--on DEPLOYMENT", "continue on a different deployment than this session last used") do |value|
          on_deployment = value
        end
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

      session = Sessions.latest(session_id)
      reply, report = Progress.while_waiting("waiting on #{deployment_name}", Output.error_stream) do
        Query.run(provider, d.model, session, prompt,
          reasoning: d.reasoning, retention: d.reasoning_retention)
      end
      Sessions.snapshot(session_id, session, deployment_name)

      Output.warn_lossy(report)
      Output.reply(reply)
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
