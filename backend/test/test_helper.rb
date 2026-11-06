# Tests run against a fresh temp dir each: VAULTS_DIR holding vault `test`, and next to it DB_DIR's database (a file: with
# `:memory:` every pool connection would get its own) with that vault and one device for it, with the app's own error
# mapping. Run: make test
require 'tmpdir'
require 'fileutils'
ENV['RACK_ENV'] = 'test'
ENV['ZEITWERK_RELOAD'] = 'false'
# The request log (mcp_test.rb checks what it leaves out): on whatever the developer's .env says
ENV['VERBOSE_HTTP_LOGS'] = 'true'
# dotenv doesn't override what's set; each test sets its own
ENV['VAULTS_DIR'] = Dir.mktmpdir('vault-test-')
ENV['DB_DIR'] = ENV['VAULTS_DIR']
# Admin panel (admin_test.rb): set here, so the developer's .env.local doesn't decide
ENV['ADMIN_USER'] = 'admin'
ENV['ADMIN_PASSWORD'] = 'correct horse'
ENV['ADMIN_TOTP_SECRET'] = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP'
ENV['SESSION_SECRET'] = 's' * 64
ENV['PUBLIC_URL'] = 'https://notes.example.com'
# The tests mount the apps themselves (admin_test.rb, mcp_test.rb), boot_test.rb sets ENABLED_APPS per boot. Empty, not
# unset: a developer's .env.local with the old MCP_ENABLED would stop every boot
ENV['ENABLED_APPS'] = 'sync,mcp,admin'
ENV['MCP_ENABLED'] = ''

require_relative '../app'
require 'minitest/autorun'
require 'rack/test'
require 'digest'

class VaultTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('vault-test-')
    @vaults_dir = File.join(@root, 'vaults')
    ENV['VAULTS_DIR'] = @vaults_dir
    Dir.mkdir(@vaults_dir)
    ENV['DB_DIR'] = @root
    @vault = Vault.create('test')
    @token = add_token('test-device', 'test')
  end

  def teardown
    DB.close
    FileUtils.rm_rf(@root)
  end

  # A new device for the vault; returns its token
  def add_token(name, vault)
    Devices.create(name:, vault:).last
  end

  def blob(content)
    Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
  end

  def tree_file(path, vault: 'test')
    File.join(@vaults_dir, vault, 'tree', path)
  end

  def git(*args, vault: 'test')
    IO.popen(['git', "--git-dir=#{@vaults_dir}/#{vault}/repo.git", *args], err: File::NULL, &:read)
  end

  # A committed version, straight through git (independent of the services under test); returns its blob hash
  def commit_file(path, content)
    FileUtils.mkdir_p(File.dirname(tree_file(path)))
    File.binwrite(tree_file(path), content)
    @vault.git.add(path)
    @vault.commit("TEST #{path}")
    blob(content)
  end

  def last_commit_message
    git('log', '-1', '--format=%s').chomp
  end

  def commit_count(vault: 'test')
    git('rev-list', '--count', '--all', vault:).to_i
  end
end
