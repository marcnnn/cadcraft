# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cadcraft_server,
  namespace: CADCraftServer,
  ecto_repos: [CADCraftServer.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  ash_domains: [CADCraftServer.Accounts, CADCraftServer.Design]

# Base-map layers served next to a drawing's CAD layer, from tables osm2pgsql (or anything
# else) loaded into the same database. Each needs a geometry column in Web Mercator, an id and
# a jsonb tags column; see docs/collab-postgis.md. Empty: tiles carry the CAD layer only.
config :cadcraft_server, :base_layers, []

config :ash, :policies, show_policy_breakdowns?: true
config :ash, default_string_length_count: :codepoints

# Configure the endpoint
config :cadcraft_server, CADCraftServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: CADCraftServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CADCraftServer.PubSub,
  live_view: [signing_salt: "J3qeH+JG"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
