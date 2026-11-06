class Vault
  # The one rule for what a vault path may be, for the sync API and MCP alike, checked before anything touches disk or
  # git. Never expanded (no File.expand_path: it would read `~user` from the client): a valid path joined under tree/
  # stays there by construction
  module Path
    class BadPath < StandardError; end
    # A path refused only for a hidden (dot) segment: MCP answers it as not found, like anything it may not see
    class Hidden < BadPath; end

    KEEP = '.keep' # a folder's marker
    MAX_SEGMENT = 255 # bytes: a file name on most file systems
    MAX_PATH = 1024 # bytes
    # Code points HFS+ ignores in names (git's core.protectHFS): `.<U+200C>git` is `.git` there
    HFS_IGNORED = /[\u{200c}-\u{200f}\u{202a}-\u{202e}\u{206a}-\u{206f}\u{feff}]/
    # NTFS's short name of `.git` (git's core.protectNTFS refuses it)
    NTFS_DOTGIT = /\Agit~1[ .]*(:|\z)/i

    # The path as given (a relative path inside the vault) or BadPath with the reason
    def self.normalize(path)
      reason = refusal(path) or return path
      raise (reason == :hidden ? Hidden : BadPath), "#{path.inspect}: #{reason}"
    end

    def self.valid?(path) = refusal(path).nil?

    # nil if path may be a vault path, else why not (a symbol, for the log). Hidden last: the more basic reasons win
    def self.refusal(path)
      return :not_a_string unless path.is_a?(String)
      return :encoding unless path.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      return :too_long if path.bytesize > MAX_PATH

      path = path.dup.force_encoding(Encoding::UTF_8)
      return :control_character if path.match?(/[[:cntrl:]]/) # NUL, line breaks, C1
      return :backslash if path.include?('\\')
      return :tilde if path.start_with?('~') # `~user` means a home directory to shells and expand_path

      parts = path.split('/', -1).then { _1.empty? ? [''] : _1 } # '' too
      return :empty_segment if parts.any?(&:empty?) # '', leading / trailing / double slashes
      return :dot_segment if parts.any? { %w[. ..].include?(_1) }
      return :segment_too_long if parts.any? { _1.bytesize > MAX_SEGMENT }
      return :git_name if parts.any? { _1.match?(NTFS_DOTGIT) }
      return :hidden if parts.any? { hidden?(_1) } && !allowed_hidden?(parts)

      nil
    end

    # A segment starting with a dot: .git, .gitignore, .gitattributes, .obsidian, …
    def self.hidden?(segment) = segment.gsub(HFS_IGNORED, '').start_with?('.')

    # The hidden paths a vault may hold: a folder's .keep. Plan phase 5 adds `.plugins/<id>/data.json` here
    def self.allowed_hidden?(parts) = parts.last == KEEP && parts[0...-1].none? { hidden?(_1) }

    # What may be 3-way merged: notes, not Excalidraw's (compressed JSON on one line). The plugin's mergeable() in
    # src/paths.js; the sync API goes by its Content-Type instead, MCP writes by this
    def self.mergeable?(rel)
      rel = rel.downcase
      rel.end_with?('.md') && !rel.end_with?('.excalidraw.md')
    end
  end
end
