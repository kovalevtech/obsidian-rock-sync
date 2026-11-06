require_relative 'test_helper'

# The vault path rule (Vault::Path): what the sync API answers 400 and MCP refuses
class PathTest < VaultTest
  VALID = ['a/b.md', 'a b/ё.md', 'Folder/.keep', '.keep', 'a~b.md', 'x/~y.md', 'notes/git~1.md', ':/b.md',
           ':(exclude)x', ':!a.md', '*', '*.md', '[ab].md', '-rf', '--help', 'a.git', "#{'a' * 255}.md".b[0, 255]].freeze

  REFUSED = {
    '' => :empty_segment, '/etc/passwd' => :empty_segment, 'a//b.md' => :empty_segment, 'a/' => :empty_segment,
    '.' => :dot_segment, '../x.md' => :dot_segment, 'a/../b.md' => :dot_segment, 'a/./b.md' => :dot_segment,
    "a\0b.md" => :control_character, "a\nb.md" => :control_character, "a\u{7f}.md" => :control_character,
    'a\\b.md' => :backslash, '~root/x' => :tilde, '~nosuchuser' => :tilde, '~' => :tilde,
    "#{'a' * 300}.md" => :segment_too_long, "#{'a/' * 600}b.md" => :too_long, "\xff.md".b => :encoding,
    'git~1/config' => :git_name, 'GIT~1' => :git_name, 'x/git~1. .' => :git_name,
    '.git' => :hidden, '.git/config' => :hidden, 'x/.git/hooks/post-commit' => :hidden, '.gitignore' => :hidden,
    '.gitattributes' => :hidden, '.gitmodules' => :hidden, '.GIT' => :hidden, '.Git/HEAD' => :hidden,
    ".\u{200c}git" => :hidden, "\u{200c}.git/x" => :hidden, '.obsidian/app.json' => :hidden, '.keep/x' => :hidden,
    '.hidden/.keep' => :hidden, 'a/.keep.md' => :hidden
  }.freeze

  def test_valid_paths_pass_as_they_are
    VALID.each { assert_equal _1, Vault::Path.normalize(_1), _1 }
  end

  def test_refused_paths
    REFUSED.each do |path, reason|
      assert_equal reason, Vault::Path.refusal(path), path.inspect
      error = reason == :hidden ? Vault::Path::Hidden : Vault::Path::BadPath
      assert_raises(error, path.inspect) { Vault::Path.normalize(path) }
    end
    assert_raises(Vault::Path::BadPath) { Vault::Path.normalize(nil) }
  end

  # `~user` is never expanded, whatever the path: the rule refuses it before anything joins it under tree/
  def test_a_tilde_never_reaches_the_home_directory
    assert_equal File.join(@vault.tree, 'x/~root'), @vault.file(Vault::Path.normalize('x/~root'))
  end
end
