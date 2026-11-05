# What a scoped token may reach (DB[:scoped_token_grants]): folders in vaults, each with a mode — r, w, rw. What that
# means for a path is Access's. A grant's folder is vault-relative, '' = the whole vault; it may name a folder that
# doesn't exist (any more): it just matches nothing there. Its purpose ('' = none) says what the folder is for, in
# the admin's words: MCP tells it to Claude. A token's grants are saved as a whole (the admin's form), checked first:
# every folder grantable, none twice, none that adds nothing to the grants above it.
module Grants
  Grant = Data.define(:id, :vault, :folder, :mode, :purpose)
  MODES = %w[r w rw].freeze
  TABLE = :scoped_token_grants
  MAX_PURPOSE = 2000 # characters

  # The token's grants, by vault and folder
  def self.of(token_id)
    DB[TABLE].join(:vaults, id: :vault_id).where(token_id:).order(Sequel[:vaults][:name], :folder)
             .select(Sequel[TABLE][:id], Sequel[:vaults][:name].as(:vault), :folder, :mode, :purpose)
             .map { Grant.new(**_1) }
  end

  # A typed folder as stored: no slashes around it, no blanks at the ends; '' or '/' = the whole vault
  def self.normalize(folder) = folder.to_s.strip.gsub(%r{\A/+|/+\z}, '')

  # A typed purpose as stored: \n line breaks (a form sends \r\n), no blanks at the ends
  def self.normalize_purpose(text) = text.to_s.gsub(/\r\n?/, "\n").strip

  # rows: [{ vault:, folder:, mode:, purpose: (optional) }], normalized → { row index => message, base: message } (empty = fine).
  # A row adding nothing is judged against the rows above it that are fine themselves
  def self.check(rows)
    return { base: 'Add at least one grant.' } if rows.empty?

    vaults = DB[:vaults].select_map(:name)
    errors = rows.each_with_index.to_h do |row, i|
      vault, folder, mode = row.values_at(:vault, :folder, :mode)
      [i, if !vaults.include?(vault) then "No vault #{vault.to_s.empty? ? 'picked' : "`#{vault}`"}."
          elsif !Access.grantable?(folder) then "`#{folder}` can't be granted: no `..`, `.`, empty or hidden parts."
          elsif !MODES.include?(mode) then "Bad mode `#{mode}`."
          elsif (length = row[:purpose].to_s.length) > MAX_PURPOSE then "The purpose is #{length} characters, at most #{MAX_PURPOSE}."
          elsif rows[...i].any? { _1[:vault] == vault && _1[:folder] == folder } then "`#{folder}` is in #{vault} twice."
          end]
    end.compact
    fine = rows.reject.with_index { errors.key?(_2) }
    rows.each_with_index { |row, i| errors[i] ||= redundant(fine, row) }
    errors.compact
  end

  # A message if the grants on the row's ancestor folders in its vault give everything its mode does
  def self.redundant(rows, row)
    above = rows.select do |other|
      other[:vault] == row[:vault] && other[:folder] != row[:folder] && Access.holds?(other[:folder], row[:folder])
    end
    given = above.flat_map { _1[:mode].to_s.chars }.uniq
    return unless above.any? && (row[:mode].chars - given).empty?

    gives = MODES.find { _1.chars.sort == given.sort } || given.join
    by = above.map { _1[:folder].empty? ? '/' : _1[:folder] }
    "`#{row[:mode]}` on #{row[:folder]} has no effect: #{by.join(' + ')} already #{by.one? ? 'gives' : 'give'} #{gives}."
  end
  private_class_method :redundant

  # The token's grants from now on, if they pass check → its errors (empty = saved)
  def self.save(token_id, rows)
    errors = check(rows)
    replace(token_id, rows) if errors.empty?
    errors
  end

  # Checked rows in, every other grant of the token out
  def self.replace(token_id, rows)
    ids = DB[:vaults].select_hash(:name, :id)
    DB.current.transaction do
      DB[TABLE].where(token_id:).delete
      DB[TABLE].import(%i[token_id vault_id folder mode purpose],
                       rows.map { [token_id, ids.fetch(_1[:vault]), _1[:folder], _1[:mode], _1[:purpose].to_s] })
    end
  end

  # A folder moved (MoveFile, its .keep): grants on `from` and below it follow to `to`, for every token. A grant already
  # at a new folder for the same token can only be a dangling one (`to` didn't exist): the moved one replaces it.
  # Nothing else changes, so access never widens. A nested folder's own .keep move finds nothing left to move
  def self.follow_move(vault, from, to)
    vault_id = DB[:vaults].where(name: vault).get(:id) or return
    DB.current.transaction do
      grants = DB[TABLE].where(vault_id:)
      moved = grants.all.select { !_1[:folder].empty? && Access.holds?(from, _1[:folder]) }
      moved.each do |grant|
        folder = to + grant[:folder].delete_prefix(from)
        grants.where(token_id: grant[:token_id], folder:).exclude(id: moved.map { _1[:id] }).delete
        grants.where(id: grant[:id]).update(folder:)
      end
    end
  end
end
