# DELETE /files: removes the file and commits `DELETE <path>`. if_match: the version the client deleted;
# author: Vault::Author of the commit.
# Returns [status, etag, body, modified_at]:
#   :deleted
#   :gone   already gone: nothing to do
#   :stale  edited elsewhere since: nothing deleted; body = the current version
class DeleteFile
  def self.call(vault, path, if_match:, author: nil)
    rel = vault.normalize(path)
    full = vault.file(rel)

    vault.lock do
      next [:gone] unless File.file?(full)

      current = File.binread(full)
      etag = Git.blob_hash(current)
      next [:stale, etag, current, vault.git.last_commit_time(rel)] if if_match != etag

      vault.commit("DELETE #{rel}", remove: [rel], author:)
      [:deleted]
    end
  end
end
