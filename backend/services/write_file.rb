require 'fileutils'

# PUT /files: writes a file and commits it (`PUT <path>`, or `MERGE <path>` for a merged result).
# if_match: the version the client edited; if_none_match: '*' = create only; mergeable: see MergeVersions;
# author: Vault::Author of the commit; action: the commit's verb instead of PUT (AppendFile: APPEND); keeps: the file's
# folders get their .keep (how the plugin keeps folders on the server) in the same commit — MCP writes; the plugin
# pushes its own.
# Returns [status, etag, body, modified_at]:
#   :written    etag = the new version
#   :unchanged  identical content: success whatever the headers, nothing committed
#   :merged     stale if_match, merged cleanly (MergeVersions) and written; body = the merged text for the client
#   :conflict   stale if_match, the merge left conflicts; nothing written. body = text with markers, etag / modified_at
#               of the current server version
#   :stale      nothing to merge (create-only on an existing file, not mergeable, base unknown to git): body = the
#               current server version. File gone meanwhile: just [:stale]
class WriteFile
  def self.call(vault, path, content, if_match: nil, if_none_match: nil, mergeable: false, author: nil, action: 'PUT', keeps: false)
    rel = vault.normalize(path)
    full = vault.file(rel)

    vault.lock do
      current = File.exist?(full) ? File.binread(full) : nil
      current_etag = current && Git.blob_hash(current)
      etag = Git.blob_hash(content)
      next [:unchanged, etag] if etag == current_etag

      next [:stale, current_etag, current, vault.git.last_commit_time(rel)] if if_none_match == '*' && current

      merged = false
      if if_match && if_match != current_etag
        next [:stale] unless current

        result, server_etag, text, modified_at = MergeVersions.call(vault, path, content, base: if_match, mergeable:)
        next [result, server_etag, text, modified_at] unless result == :clean

        merged = true
        content = text
        etag = Git.blob_hash(content)
        next [:merged, etag, content] if etag == current_etag # nothing new, e.g. a retried merge
      end

      FileUtils.mkdir_p(File.dirname(full))
      add_keeps(vault, rel) if keeps
      File.binwrite(full, content)
      vault.git.add(rel)
      vault.commit("#{merged ? 'MERGE' : action} #{rel}", author:)
      merged ? [:merged, etag, content] : [:written, etag]
    end
  end

  # Every folder above rel without a .keep gets one, staged for the commit at hand
  def self.add_keeps(vault, rel)
    parts = rel.split('/')[0...-1]
    parts.each_index.map { parts[.._1].join('/') }.each do |dir|
      keep = "#{dir}/.keep"
      next if File.exist?(vault.file(keep))

      File.binwrite(vault.file(keep), '')
      vault.git.add(keep)
    end
  end
  private_class_method :add_keeps
end
