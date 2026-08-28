require "../config"
require "../sessions"
require "../query"
require "../output"
require "../progress"

module Elelem::Cli::Commands
  module Start
    extend self

    USAGE = "usage: elelem start <deployment> <prompt...>"

    def run(args : Array(String)) : Nil
      deployment_name, prompt = parse(args)

      config = Config.load
      d = config.deployment(deployment_name)
      provider = config.provider_for(deployment_name)

      session = MPSH::Session.new
      reply, report = Progress.while_waiting("waiting on #{deployment_name}") do
        Query.run(provider, d.model, session, prompt)
      end

      id = Sessions.generate_id
      Sessions.snapshot(id, session, deployment_name)

      Output.session_id(id)
      Output.warn_lossy(report)
      Output.reply(reply)
    end

    private def parse(args : Array(String)) : {String, String}
      deployment_name = args[0]?
      prompt_words = args[1..]?
      if deployment_name.nil? || prompt_words.nil? || prompt_words.empty?
        raise ArgumentError.new(USAGE)
      end
      {deployment_name, prompt_words.join(" ")}
    end
  end
end
