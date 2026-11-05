class Config
  require 'dotenv'
  require 'uri'
  Dotenv.load('.env.local', '.env')

  class EnvValueNotDefined < StandardError
    attr_accessor :var

    def initialize(var)
      self.var = var
    end

    def message
      "Environment variable `#{var}` must be defined."
    end
  end

  # Names the variable, never its value
  class EnvValueInvalid < StandardError; end

  # The admin panel's credentials (admin.rb). Values are secrets: never logged, not even in errors
  Admin = Data.define(:user, :password, :totp_secret, :session_secret)
  ADMIN_ENV = %w[ADMIN_USER ADMIN_PASSWORD ADMIN_TOTP_SECRET SESSION_SECRET].freeze
  ADMIN_OPTIONAL = %w[ADMIN_TOTP_SECRET].freeze

  def self.zeitwerk_reload?
    %w[true 1].include? ENV['ZEITWERK_RELOAD'].to_s
  end
  def self.vaults_dir
    ENV['VAULTS_DIR'] || raise(EnvValueNotDefined, 'VAULTS_DIR')
  end

  # The database's directory: vaults and device tokens. Outside VAULTS_DIR on purpose: storage that isn't mounted must
  # not look like a fresh install. Dev: next to data/, outside the repo
  def self.db_dir
    ENV['DB_DIR'] || File.expand_path('../../config', __dir__)
  end

  def self.database_path = File.join(db_dir, 'vault-sync.db')

  # Puma's max threads (config/puma.rb); the DB pool has as many connections
  def self.max_threads = 16

  # nil when none of ADMIN_ENV is set (admin panel off); a required one missing, a TOTP secret that isn't base32 or a
  # short session secret → raises. No TOTP secret: password only
  def self.admin
    values = ENV.values_at(*ADMIN_ENV).map { _1.to_s.empty? ? nil : _1 }
    return if values.none?

    missing = ADMIN_ENV.zip(values).filter_map { |var, value| var unless value || ADMIN_OPTIONAL.include?(var) }
    raise EnvValueNotDefined, missing.join('`, `') if missing.any?

    user, password, totp_secret, session_secret = values
    require 'rotp'
    unless totp_secret.nil? || (totp_secret.match?(/\A[A-Z2-7]+=*\z/i) && ROTP::Base32.decode(totp_secret).bytesize >= 16)
      raise EnvValueInvalid, 'ADMIN_TOTP_SECRET must be base32, at least 128 bits (ROTP::Base32.random)'
    end
    raise EnvValueInvalid, 'SESSION_SECRET must be at least 64 bytes' if session_secret.bytesize < 64

    public_url
    Admin.new(user:, password:, totp_secret:, session_secret:)
  end

  # The address devices reach this server at (https://notes.example.com): the admin panel hands it out with a connection
  # code, and can't tell it from a request (it may be reached elsewhere). Required with the panel, checked at boot
  def self.public_url
    url = ENV['PUBLIC_URL'].to_s.chomp('/')
    raise EnvValueNotDefined, 'PUBLIC_URL' if url.empty?

    uri = URI.parse(url) rescue nil
    unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && !uri.query && !uri.fragment
      raise EnvValueInvalid, 'PUBLIC_URL must be the http(s) address devices reach this server at'
    end

    url
  end

  # What a boot makes from the environment (EnvInit)
  Init = Data.define(:vault, :code)
  INIT_ENV = %w[INIT_VAULT_NAME INIT_VAULT_CODE].freeze

  # nil when neither is set; a code without a vault, or not 6 digits → raises
  def self.init
    vault, code = ENV.values_at(*INIT_ENV).map { _1.to_s.empty? ? nil : _1 }
    return unless vault || code

    raise EnvValueNotDefined, 'INIT_VAULT_NAME' unless vault
    raise EnvValueInvalid, 'INIT_VAULT_CODE must be 6 digits' if code && !code.match?(/\A\d{6}\z/)

    Init.new(vault:, code:)
  end

  # Bytes; larger request bodies get 413 (Puma: before reading them)
  def self.max_file_size
    Integer(ENV.fetch('MAX_FILE_SIZE', 100 * 1024 * 1024))
  end

  # Bytes: the most an MCP tool call may write (write_file's content, append_file's text)
  def self.mcp_max_write
    Integer(ENV.fetch('MCP_MAX_WRITE', 1024 * 1024))
  end

  # The MCP endpoint at /mcp and the admin panel's scoped tokens; off unless asked for
  def self.mcp_enabled? = %w[true 1].include?(ENV['MCP_ENABLED'].to_s)

  # The server's origin for the MCP URL the admin panel shows, when Claude reaches it elsewhere than devices do (only
  # /mcp in public); unset → public_url
  def self.mcp_base_url = ENV['MCP_BASE_URL'].to_s.chomp('/').then { _1.empty? ? nil : _1 }

  def self.verbose_http_logs?
    %w[true 1].include? ENV['VERBOSE_HTTP_LOGS'].to_s
  end
end
