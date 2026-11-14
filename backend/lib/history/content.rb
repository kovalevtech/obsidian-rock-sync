module History
  # How the history page shows a version (after) against the one before it (before; nil: a creation), or a deleted
  # version (after nil): raw text or a unified diff, an image inline, anything else as its size and a download. The
  # type comes from the first bytes (images, PDF) or, for SVG, the name. Over TEXT_MAX (either side) or a diff over
  # DIFF_MAX lines → too large, download only. Returns { kind:, sha:, size:, … }:
  #   :diff       lines: the diff's
  #   :text       text; unchanged: true when before has the same content (a rename)
  #   :image      mime_type (shown through <img>, from the blob route)
  #   :pdf, :binary, :too_large, :missing (git doesn't have it)
  module Content
    TEXT_MAX = 1024 * 1024 # bytes
    DIFF_MAX = 5000 # lines

    module_function

    def of(git, before, after, path)
      sha = after || before
      sizes = git.blob_sizes([before, after].compact.uniq)
      size = sizes[sha] or return { kind: :missing, sha: }
      base = { sha:, size: }

      if (mime_type = type(git.blob_head(sha), path))
        return base.merge(kind: mime_type == 'application/pdf' ? :pdf : :image, mime_type:)
      end
      return base.merge(kind: :too_large) if sizes.values.any? { _1 > TEXT_MAX }

      text = text(git.cat_file(sha)) or return base.merge(kind: :binary)
      return base.merge(kind: :text, text:) unless after && before

      old = text(git.cat_file(before)) or return base.merge(kind: :text, text:)
      return base.merge(kind: :text, text:, unchanged: true) if old == text

      lines = git.diff(before, after).force_encoding(Encoding::UTF_8).scrub.lines
      lines.size > DIFF_MAX ? base.merge(kind: :too_large, lines: lines.size) : base.merge(kind: :diff, lines:)
    end

    # Images by their first bytes (as MCP's read_file), SVG by its name, PDF by its header
    def type(head, path)
      return nil unless head

      McpTools.image_type(head) || ('image/svg+xml' if path.to_s.downcase.end_with?('.svg')) ||
        ('application/pdf' if head.start_with?('%PDF-'))
    end

    # UTF-8 without NUL, or nil
    def text(bytes)
      text = bytes&.dup&.force_encoding(Encoding::UTF_8)
      text if text&.valid_encoding? && !text.include?("\0")
    end
  end
end
