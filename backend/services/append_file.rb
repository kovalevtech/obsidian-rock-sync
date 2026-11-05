# MCP append_file: text added at the end of a file, after a line break unless the file ends with one (or is empty);
# a missing file is created with the text. Commit `APPEND <path>`; keeps: as WriteFile's. Read and write under the
# vault lock: nothing changes the file in between, so no base, no merge, no conflict.
# Returns [status, etag]:
#   :appended   etag = the new version
#   :created
#   :unchanged  empty text: nothing written (etag nil if there's no file)
#   :not_text   the file isn't valid UTF-8: nothing written
class AppendFile
  def self.call(vault, path, text, author: nil, keeps: false)
    rel = vault.normalize(path)
    full = vault.file(rel)

    vault.lock do
      current = File.file?(full) ? File.binread(full) : nil
      next [:not_text] if current && !current.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      next [:unchanged, current && Git.blob_hash(current)] if text.empty?

      content = current ? current + (current.empty? || current.end_with?("\n") ? '' : "\n") + text.b : text.b
      _, etag = WriteFile.call(vault, rel, content, if_match: current && Git.blob_hash(current),
                                                         if_none_match: current ? nil : '*', author:, action: 'APPEND',
                                                         keeps:)
      [current ? :appended : :created, etag]
    end
  end
end
