require 'fileutils'

# POST /move: renames a file in one commit `RENAME <from> → <to>` (git log --follow keeps its history). Paths only, no
# If-Match: whatever version is at from moves; the client reconciles content afterwards with a normal PUT.
# A folder's .keep moving = the folder renamed: grants on it follow (Grants.follow_move).
# author: Vault::Author of the commit.
# Returns [:moved, etag at to] or [:exists] (to taken). from missing → Vault::NotFound
class MoveFile
  def self.call(vault, from, to, author: nil)
    src = vault.normalize(from)
    dst = vault.normalize(to)
    src_full = vault.file(src)
    dst_full = vault.file(dst)

    vault.lock do
      raise Vault::NotFound, from unless File.file?(src_full)
      next [:exists] if File.exist?(dst_full)

      FileUtils.mkdir_p(File.dirname(dst_full))
      vault.git.mv(src, dst)
      vault.commit("RENAME #{src} → #{dst}", author:)
      vault.prune_dirs(File.dirname(src_full))
      follow_grants(vault, src, dst)
      [:moved, Git.blob_hash(File.binread(dst_full))]
    end
  end

  # After the commit: a failure here doesn't undo the move (a grant left dangling grants nothing), it's logged
  def self.follow_grants(vault, src, dst)
    from, to = [src, dst].map { File.dirname(_1) }
    return unless [src, dst].all? { File.basename(_1) == '.keep' } && from != '.' && to != '.'

    Grants.follow_move(vault.name, from, to)
  rescue StandardError => e
    warn "vault-sync: grants on #{from} not moved to #{to}: #{e.class}: #{e.message}"
  end
  private_class_method :follow_grants
end
