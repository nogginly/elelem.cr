require "./elelem_cli/config"
require "./elelem_cli/sessions"
require "./elelem_cli/commands/start"
require "./elelem_cli/commands/continue"
require "./elelem_cli/commands/list"
require "./elelem_cli/commands/show"
require "./elelem_cli/commands/delete"
require "./elelem_cli/commands/prune"

USAGE = <<-USAGE
  elelem — a portable session history

  Usage:
    elelem start <deployment> <prompt...> [--id <session-id>]
    elelem continue <session-id> <prompt...> [--on <deployment>]
    elelem list
    elelem show <session-id> [--snapshots] [--json]
    elelem prune <session-id> --keep <n>
    elelem delete <session-id>

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
  when "list"
    Elelem::Cli::Commands::List.run(rest)
  when "show"
    Elelem::Cli::Commands::Show.run(rest)
  when "prune"
    Elelem::Cli::Commands::Prune.run(rest)
  when "delete"
    Elelem::Cli::Commands::Delete.run(rest)
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
