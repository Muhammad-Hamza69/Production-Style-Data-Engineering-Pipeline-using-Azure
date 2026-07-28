// ─────────────────────────────────────────────────────────────────────────────
// Power Query M Code for Azure Synapse Serverless Connection
// Database: yt_pipeline
// Server: ytpl-synapse-387f2fde-ondemand.sql.azuresynapse.net
// ─────────────────────────────────────────────────────────────────────────────

// Table 1: enriched.trending_analytics 
let
    Source = Sql.Database("ytpl-synapse-387f2fde-ondemand.sql.azuresynapse.net", "yt_pipeline"),
    enriched_trending = Source{[Schema="enriched", Item="trending_analytics"]}[Data]
in
    enriched_trending;

// Table 2: enriched.category_analytics
let
    Source = Sql.Database("ytpl-synapse-387f2fde-ondemand.sql.azuresynapse.net", "yt_pipeline"),
    enriched_category = Source{[Schema="enriched", Item="category_analytics"]}[Data]
in
    enriched_category;

// Table 3: enriched.channel_analytics
let
    Source = Sql.Database("ytpl-synapse-387f2fde-ondemand.sql.azuresynapse.net", "yt_pipeline"),
    enriched_channel = Source{[Schema="enriched", Item="channel_analytics"]}[Data]
in
    enriched_channel;
