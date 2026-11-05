# GET /manifest: [version, { path => [blob hash, size] }] of the current tree. version = HEAD sha, nil before the first commit
class BuildManifest
  def self.call(vault)
    version = vault.version
    [version, version ? vault.git.ls_tree(version) : {}]
  end
end
