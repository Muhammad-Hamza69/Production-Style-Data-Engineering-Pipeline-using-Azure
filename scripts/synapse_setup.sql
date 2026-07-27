-- One-time setup for the Synapse serverless ("Built-in") SQL pool.
-- Deliberately not Terraform-managed -- same reasoning as the AWS
-- project's QuickSight dashboard JSON: this is schema/content, not
-- infrastructure shape, and iterates far faster run directly against the
-- SQL endpoint than through Terraform's HCL translation of the same DDL.
--
-- Run once against the workspace's serverless endpoint (via sqlcmd, Azure
-- Data Studio, or the Synapse Studio web UI) after the first terraform
-- apply. Uses a Managed Identity credential, not a storage account key --
-- consistent with the "identity, not secret" pattern everywhere else in
-- this project.
--
-- Replace ytpipeline387f2fde below with the real storage account name
-- (terraform output storage_account_name).

-- Synapse serverless restricts external data sources/tables/users/scoped
-- credentials to a user database -- none of it is allowed in master
-- (confirmed against real errors: "CREATE EXTERNAL TABLE is not supported
-- in master database", etc.). Create a dedicated database and switch into
-- it before anything else.
CREATE DATABASE yt_pipeline;
GO

USE yt_pipeline;
GO

CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'ReplaceWithAStrongLocalPassword!2026';
GO

CREATE DATABASE SCOPED CREDENTIAL ManagedIdentityCredential
WITH IDENTITY = 'Managed Identity';
GO

CREATE EXTERNAL DATA SOURCE yt_pipeline_lake
WITH (
    LOCATION   = 'abfss://raw@ytpipeline387f2fde.dfs.core.windows.net',
    CREDENTIAL = ManagedIdentityCredential
);
GO

CREATE EXTERNAL DATA SOURCE yt_pipeline_curated_lake
WITH (
    LOCATION   = 'abfss://curated@ytpipeline387f2fde.dfs.core.windows.net',
    CREDENTIAL = ManagedIdentityCredential
);
GO

CREATE EXTERNAL DATA SOURCE yt_pipeline_enriched_lake
WITH (
    LOCATION   = 'abfss://enriched@ytpipeline387f2fde.dfs.core.windows.net',
    CREDENTIAL = ManagedIdentityCredential
);
GO

CREATE EXTERNAL FILE FORMAT DeltaFormat WITH (FORMAT_TYPE = DELTA);
GO

CREATE SCHEMA raw;
GO
CREATE SCHEMA curated;
GO
CREATE SCHEMA enriched;
GO

-- ── raw ──────────────────────────────────────────────────────────────
CREATE EXTERNAL TABLE raw.raw_statistics (
    video_id varchar(50), title varchar(500), channel_title varchar(200),
    category_id varchar(10), publish_time varchar(50), trending_date_raw varchar(50),
    tags varchar(4000), views bigint, likes bigint, dislikes bigint,
    comment_count bigint, description varchar(4000), region varchar(10),
    source varchar(50), _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'raw_statistics/', DATA_SOURCE = yt_pipeline_lake, FILE_FORMAT = DeltaFormat);
GO

CREATE EXTERNAL TABLE raw.raw_reference_data (
    id varchar(10), title varchar(200), region varchar(10),
    source varchar(50), _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'raw_reference_data/', DATA_SOURCE = yt_pipeline_lake, FILE_FORMAT = DeltaFormat);
GO

-- ── curated ──────────────────────────────────────────────────────────
CREATE EXTERNAL TABLE curated.curated_statistics (
    video_id varchar(50), title varchar(500), channel_title varchar(200),
    category_id varchar(10), publish_time varchar(50), region varchar(10),
    source varchar(50), trending_date_parsed date, tags varchar(4000),
    views bigint, likes bigint, dislikes bigint, comment_count bigint,
    description varchar(4000), like_ratio float, engagement_rate float,
    _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'curated_statistics/', DATA_SOURCE = yt_pipeline_curated_lake, FILE_FORMAT = DeltaFormat);
GO

CREATE EXTERNAL TABLE curated.curated_reference_data (
    id varchar(10), category_name varchar(200), region varchar(10),
    _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'curated_reference_data/', DATA_SOURCE = yt_pipeline_curated_lake, FILE_FORMAT = DeltaFormat);
GO

-- ── enriched ─────────────────────────────────────────────────────────
CREATE EXTERNAL TABLE enriched.trending_analytics (
    region varchar(10), trending_date_parsed date, total_videos bigint,
    total_views bigint, total_likes bigint, total_comments bigint,
    avg_engagement_rate float, avg_like_ratio float
)
WITH (LOCATION = 'trending_analytics/', DATA_SOURCE = yt_pipeline_enriched_lake, FILE_FORMAT = DeltaFormat);
GO

CREATE EXTERNAL TABLE enriched.category_analytics (
    region varchar(10), trending_date_parsed date, category_id varchar(10),
    category_name varchar(200), total_videos bigint, total_views bigint,
    view_share_pct float
)
WITH (LOCATION = 'category_analytics/', DATA_SOURCE = yt_pipeline_enriched_lake, FILE_FORMAT = DeltaFormat);
GO

CREATE EXTERNAL TABLE enriched.channel_analytics (
    channel_title varchar(200), region varchar(10), total_videos bigint,
    total_views bigint, avg_engagement_rate float, categories varchar(2000),
    rank_in_region bigint
)
WITH (LOCATION = 'channel_analytics/', DATA_SOURCE = yt_pipeline_enriched_lake, FILE_FORMAT = DeltaFormat);
GO

-- Grant the dashboard's identity read access (it already has "Synapse
-- User" via Azure RBAC, terraform/modules/synapse -- this is the
-- SQL-level GRANT that RBAC role alone doesn't imply).
CREATE USER [yt-pipeline-dashboard-identity] FROM EXTERNAL PROVIDER;
GO
GRANT SELECT ON SCHEMA::enriched TO [yt-pipeline-dashboard-identity];

-- The dbt job's identity ("Synapse SQL Administrator" via RBAC) already
-- has full access -- no additional SQL-level grant needed for it.
