# The hosts MCP's download_file may fetch from (DownloadHosts), the admin's list: `example.com` (that host), or
# `*.example.com` (its subdomains). None: no download_file at all
Sequel.migration do
  change do
    create_table(:download_hosts) do
      primary_key :id
      String :host, null: false, unique: true
      DateTime :created_at, null: false
      constraint(:download_host, Sequel.lit("host NOT GLOB '*[^a-z0-9.*-]*'"))
    end
  end
end
