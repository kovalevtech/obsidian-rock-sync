# The one place deciding what a scoped token may do with a path (Grants: folders in vaults, each with a mode). Grants
# may overlap: a path's mode is the union of the modes of every grant holding it, so a nested grant only adds. Paths
# are normalized (Vault::Path) before they get here.
module Access
  # Never reachable, whatever the grants: hidden paths — any segment starting with '.': .obsidian, .trash, .plugins/
  # (plugin settings), and the .keep files that stand for folders
  def self.hidden?(rel) = rel.split('/').any? { _1.start_with?('.') }

  # A folder a grant may name: '' (the whole vault) or a clean relative path outside hidden ones
  def self.grantable?(folder)
    folder.empty? || folder.split('/', -1).none? { _1.empty? || _1.start_with?('.') }
  end

  # Does the folder hold rel, segment-wise (`Notes` doesn't hold `Notes2/x.md`)? '' holds everything
  def self.holds?(folder, rel) = folder.empty? || rel == folder || rel.start_with?("#{folder}/")

  # The union of the modes of the vault's grants holding rel: '', 'r', 'w' or 'rw'
  def self.mode(grants, vault, rel)
    chars = grants.select { _1.vault == vault && holds?(_1.folder, rel) }.flat_map { _1.mode.chars }
    Grants::MODES.find { _1.chars.sort == chars.uniq.sort }.to_s
  end

  # mode: :r or :w. Hidden paths never
  def self.allowed?(grants, vault, rel, mode)
    !hidden?(rel) && self.mode(grants, vault, rel).include?(mode.to_s)
  end

  # The vault's folders granted with the mode (for messages)
  def self.folders(grants, vault, mode)
    grants.select { _1.vault == vault && _1.mode.include?(mode.to_s) }.map(&:folder)
  end
end
