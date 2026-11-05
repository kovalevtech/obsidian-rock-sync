class Vault
  module Path
    class BadPath < StandardError; end

    # Relative path inside tree; rejects anything escaping it (.., absolute paths). Expanded to absolute first
    def self.normalize(path, tree)
      full = File.expand_path(path, tree)
      raise BadPath, path unless full.start_with?("#{tree}/")

      full.delete_prefix("#{tree}/")
    end

    # What may be 3-way merged: notes, not Excalidraw's (compressed JSON on one line). The plugin's mergeable() in
    # src/paths.js; the sync API goes by its Content-Type instead, MCP writes by this
    def self.mergeable?(rel)
      rel = rel.downcase
      rel.end_with?('.md') && !rel.end_with?('.excalidraw.md')
    end
  end
end
