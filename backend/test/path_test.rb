require_relative 'test_helper'

class PathTest < VaultTest
  def test_normalize
    assert_equal 'a/b.md', Vault::Path.normalize('a/b.md', @vault.tree)
    assert_equal 'b.md', Vault::Path.normalize('a/../b.md', @vault.tree)
    assert_equal 'a b/ё.md', Vault::Path.normalize('a b/ё.md', @vault.tree)
  end

  def test_escapes_are_rejected
    ['../x.md', 'a/../../x.md', '/etc/passwd', '', '.'].each do |path|
      assert_raises(Vault::Path::BadPath, path) { Vault::Path.normalize(path, @vault.tree) }
    end
  end
end
