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

module Elelem
end
