require "./elelem_cli/config"
require "./elelem_cli/sessions"
require "./elelem_cli/commands/start"
require "./elelem_cli/commands/continue"

USAGE = <<-USAGE
  elelem — a portable session history

  Usage:
    elelem start <deployment> <prompt...>
    elelem continue <session-id> <prompt...> [--on <deployment>]

  Deployments and their defaults come from ./elelem.yaml or ~/elelem.yaml.
  Sessions are stored under ./.elelem (if present) or ~/.elelem.
  USAGE

verb = ARGV[0]?
rest = ARGV[1..]? || [] of String

begin
  case verb
  when "start"
    Elelem::Cli::Commands::Start.run(rest)
  when "continue"
    Elelem::Cli::Commands::Continue.run(rest)
  when nil, "-h", "--help"
    puts USAGE
  else
    STDERR.puts "unknown command: #{verb}"
    STDERR.puts USAGE
    exit 1
  end
rescue e : Elelem::Cli::ConfigError | Elelem::Cli::SessionError | ArgumentError
  STDERR.puts "elelem: #{e.message}"
  exit 1
rescue e : Elelem::TransportError
  STDERR.puts "elelem: #{e.message}"
  exit 1
end
