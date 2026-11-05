# 3-way merge of mine with the current server version; nothing written (POST /merge, and WriteFile on a stale
# If-Match). base: hash of the version mine started from. mergeable: the client sent mine as text (Content-Type
# text/*) — only then merged: git's own binary detection takes SVG, canvas or excalidraw for text, and markers would
# break them. The server's side comes first: on top in conflicts, labeled with its commit time.
# Returns [status, etag, body, modified_at], etag / modified_at always those of the current server version:
#   :clean     body = merged text
#   :conflict  body = merged text with conflict markers
#   :stale     nothing to merge (not mergeable, base unknown to git, binary): body = the current server version
# No file → Vault::NotFound
class MergeVersions
  # Not git's 7: a line of seven '=' in a side (a markdown setext heading underline) would read as the separator
  MARKER_SIZE = 9

  def self.call(vault, path, mine, base:, mergeable: false)
    rel = vault.normalize(path)
    full = vault.file(rel)
    git = vault.git

    vault.lock do
      raise Vault::NotFound, path unless File.file?(full)

      current = File.binread(full)
      etag = Git.blob_hash(current)
      modified_at = git.last_commit_time(rel)
      stale = [:stale, etag, current, modified_at]
      next stale unless mergeable

      base_content = git.cat_file(base) or next stale
      # Mine goes into the repo first: recoverable even if the merge result is lost or wrong
      git.hash_object(mine)

      # Time in UTC (ISO 8601, minutes): the client shows it in its own time zone
      label = ['server', modified_at&.getutc&.strftime('%Y-%m-%dT%H:%MZ')].compact.join(' ')
      text, conflicts = git.merge_file(current, base_content, mine, labels: [label, 'base', 'mine'], marker_size: MARKER_SIZE)
      next stale unless text

      [conflicts.zero? ? :clean : :conflict, etag, text, modified_at]
    end
  end
end
