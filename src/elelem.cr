require "./elelem/version"

# Canonical layer. Nothing under `mpsh/` knows that HTTP, or any provider,
# exists — and nothing under it serializes into a request body.
require "./elelem/mpsh/meta"
require "./elelem/mpsh/payload"
require "./elelem/mpsh/block"
require "./elelem/mpsh/message"
require "./elelem/mpsh/annotation"
require "./elelem/mpsh/session"
require "./elelem/mpsh/turns"
require "./elelem/mpsh/translation"

# Capability layer. Depends on the canonical layer; never the reverse.
require "./elelem/capability/profile"
require "./elelem/capability/policy"
require "./elelem/capability/resolver"
require "./elelem/capability/structural"
require "./elelem/capability/retention"

# Protocol layer. One directory per protocol: capabilities, wire vocabulary
# (request out, response in), mapper and exporter.
require "./elelem/protocol/errors"
# - Chat completions
require "./elelem/protocol/chat_completions/capabilities"
require "./elelem/protocol/chat_completions/wire/request"
require "./elelem/protocol/chat_completions/wire/response"
require "./elelem/protocol/chat_completions/mapper"
require "./elelem/protocol/chat_completions/export"
# - Responses
require "./elelem/protocol/responses/capabilities"
require "./elelem/protocol/responses/wire/request"
require "./elelem/protocol/responses/wire/response"
require "./elelem/protocol/responses/mapper"
require "./elelem/protocol/responses/export"
# - Anthropic
require "./elelem/protocol/anthropic/capabilities"
require "./elelem/protocol/anthropic/wire/request"
require "./elelem/protocol/anthropic/wire/response"
require "./elelem/protocol/anthropic/mapper"
require "./elelem/protocol/anthropic/export"
# - Gemini
require "./elelem/protocol/gemini/capabilities"
require "./elelem/protocol/gemini/wire/request"
require "./elelem/protocol/gemini/wire/response"
require "./elelem/protocol/gemini/mapper"
require "./elelem/protocol/gemini/export"

# The live layer: a deployment, the protocol it speaks, and one request per
# send. Flat files for now — group them under a directory when there are five,
# or when the first unambiguously-transport concern arrives.
require "./elelem/server"
require "./elelem/adapter"
require "./elelem/provider"
require "./elelem/client"

module Elelem
end
