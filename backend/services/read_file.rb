# GET /files: [etag, content, modified_at] of the current version (etag = blob hash, modified_at = time of the last
# commit touching it). No file → Vault::NotFound
class ReadFile
  def self.call(vault, path)
    rel = vault.normalize(path)
    full = vault.file(rel)

    vault.lock do # not a half-written file
      raise Vault::NotFound, path unless File.file?(full)

      content = File.binread(full)
      [Git.blob_hash(content), content, vault.git.last_commit_time(rel)]
    end
  end
end
