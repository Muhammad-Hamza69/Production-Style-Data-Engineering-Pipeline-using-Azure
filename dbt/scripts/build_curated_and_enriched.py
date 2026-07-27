"""
Curated + Enriched build (Python + deltalake, not dbt SQL models)
────────────────────────────────────────────────────────────────
Run before `dbt test` in entrypoint.sh. See dbt_project.yml's header note
for the full "why" -- short version: Synapse serverless SQL can't
MERGE/UPDATE against external data, so the AWS project's dbt-athena
incremental-merge model (curated_statistics) and its three full-refresh
enriched models are all reimplemented here as pandas transforms writing
Delta tables directly, mirroring exactly the same business logic the
original SQL files encoded (cleaning/dedup rules, aggregation grain,
derived columns) -- only the execution engine changed, not the logic.

Tables written:
    curated/curated_statistics       (incremental, MERGE on video_id+region+trending_date_parsed)
    curated/curated_reference_data   (full-refresh, dedup id+region latest-wins)
    enriched/trending_analytics      (full-refresh)
    enriched/channel_analytics       (full-refresh)
    enriched/category_analytics      (full-refresh)

Environment Variables:
    STORAGE_ACCOUNT_NAME
    AZURE_CLIENT_ID
"""

import logging
import os
import sys

import numpy as np
import pandas as pd
from azure.identity import ManagedIdentityCredential
from deltalake import DeltaTable, write_deltalake
from deltalake.exceptions import TableNotFoundError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

CLIENT_ID = os.environ["AZURE_CLIENT_ID"]
STORAGE_ACCOUNT = os.environ["STORAGE_ACCOUNT_NAME"]

_credential = ManagedIdentityCredential(client_id=CLIENT_ID)


def _storage_options() -> dict:
    token = _credential.get_token("https://storage.azure.com/.default").token
    return {"azure_storage_account_name": STORAGE_ACCOUNT, "azure_storage_token": token}


def _table_uri(container: str, table: str) -> str:
    return f"abfss://{container}@{STORAGE_ACCOUNT}.dfs.core.windows.net/{table}"


def _read_delta(container: str, table: str) -> pd.DataFrame:
    try:
        dt = DeltaTable(_table_uri(container, table), storage_options=_storage_options())
        return dt.to_pandas()
    except TableNotFoundError:
        return pd.DataFrame()


def _overwrite_delta(df: pd.DataFrame, container: str, table: str):
    # No partition_by -- see jobs/raw_transform/main.py's _write_delta()
    # comment: Synapse serverless's Delta external-table reader doesn't
    # reliably reconstruct Hive-partition columns, confirmed against a real
    # dbt test run where every partitioned column came back NULL.
    write_deltalake(
        _table_uri(container, table),
        df,
        mode="overwrite",
        schema_mode="overwrite",
        storage_options=_storage_options(),
    )
    logger.info("Overwrote %d rows in %s/%s", len(df), container, table)


# ── curated_statistics: cleaning/dedup logic ported from
#    dbt/models/curated/curated_statistics.sql (AWS project) ────────────

def _build_curated_statistics_batch(raw_stats: pd.DataFrame, watermark: str) -> pd.DataFrame:
    df = raw_stats[raw_stats["_ingestion_timestamp"] > watermark].copy()
    df = df[df["video_id"].notna() & (df["video_id"] != "")]

    df["region"] = df["region"].str.lower().str.strip()

    def _parse_trending_date(row):
        if row["source"] == "youtube_api_v3":
            return pd.to_datetime(row["trending_date_raw"], utc=True, errors="coerce").date()
        if row["source"] == "kaggle_historical":
            return pd.to_datetime(row["trending_date_raw"], format="%y.%d.%m", errors="coerce").date()
        return None

    df["trending_date_parsed"] = df.apply(_parse_trending_date, axis=1)
    df = df[df["trending_date_parsed"].notna()]

    for col in ("views", "likes", "comment_count"):
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0).astype("int64")
    df["dislikes"] = pd.to_numeric(df["dislikes"], errors="coerce").astype("Int64")

    df["like_ratio"] = np.where(df["views"] > 0, df["likes"] / df["views"], 0.0)
    df["engagement_rate"] = np.where(
        df["views"] > 0, (df["likes"] + df["comment_count"]) / df["views"], 0.0
    )

    # dedup: latest _ingestion_timestamp wins per video_id/region/trending_date
    df = df.sort_values("_ingestion_timestamp", ascending=False).drop_duplicates(
        subset=["video_id", "region", "trending_date_parsed"], keep="first"
    )

    keep_cols = [
        "video_id", "title", "channel_title", "category_id", "publish_time",
        "region", "source", "trending_date_parsed", "tags", "views", "likes",
        "dislikes", "comment_count", "description", "like_ratio",
        "engagement_rate", "_ingestion_timestamp", "_source_file",
    ]
    return df[keep_cols]


def build_curated_statistics():
    raw_stats = _read_delta("raw", "raw_statistics")
    if raw_stats.empty:
        logger.info("No raw_statistics rows -- skipping curated_statistics build")
        return

    table_uri = _table_uri("curated", "curated_statistics")
    try:
        dt = DeltaTable(table_uri, storage_options=_storage_options())
        existing = dt.to_pandas()
        watermark = existing["_ingestion_timestamp"].max() if not existing.empty else "1970-01-01T00:00:00Z"
        table_exists = True
    except TableNotFoundError:
        watermark = "1970-01-01T00:00:00Z"
        table_exists = False

    batch = _build_curated_statistics_batch(raw_stats, watermark)
    if batch.empty:
        logger.info("No new curated_statistics rows since watermark %s", watermark)
        return

    if not table_exists:
        write_deltalake(
            table_uri, batch, mode="overwrite",
            storage_options=_storage_options(),
        )
        logger.info("Created curated_statistics with %d rows", len(batch))
        return

    dt = DeltaTable(table_uri, storage_options=_storage_options())
    (
        dt.merge(
            source=batch,
            predicate=(
                "target.video_id = source.video_id "
                "AND target.region = source.region "
                "AND target.trending_date_parsed = source.trending_date_parsed"
            ),
            source_alias="source",
            target_alias="target",
        )
        .when_matched_update_all()
        .when_not_matched_insert_all()
        .execute()
    )
    logger.info("Merged %d rows into curated_statistics", len(batch))


# ── curated_reference_data: full-refresh dedup, ported from
#    dbt/models/curated/curated_reference_data.sql (AWS project) ───────

def build_curated_reference_data():
    raw_ref = _read_delta("raw", "raw_reference_data")
    if raw_ref.empty:
        logger.info("No raw_reference_data rows -- skipping curated_reference_data build")
        return

    df = raw_ref[raw_ref["id"].notna()].copy()
    df = df.sort_values("_ingestion_timestamp", ascending=False).drop_duplicates(
        subset=["id", "region"], keep="first"
    )
    df = df.rename(columns={"title": "category_name"})
    df = df[["id", "category_name", "region", "_ingestion_timestamp", "_source_file"]]
    _overwrite_delta(df, "curated", "curated_reference_data")


# ── Enriched aggregations, ported from
#    dbt/models/enriched/*.sql (AWS project) ────────────────────────────

def build_enriched():
    stats = _read_delta("curated", "curated_statistics")
    ref = _read_delta("curated", "curated_reference_data")
    if stats.empty:
        logger.info("No curated_statistics rows -- skipping enriched build")
        return

    # trending_analytics
    trending = (
        stats.groupby(["region", "trending_date_parsed"])
        .agg(
            total_videos=("video_id", "nunique"),
            total_views=("views", "sum"),
            total_likes=("likes", "sum"),
            total_comments=("comment_count", "sum"),
            avg_engagement_rate=("engagement_rate", "mean"),
            avg_like_ratio=("like_ratio", "mean"),
        )
        .reset_index()
    )
    _overwrite_delta(trending, "enriched", "trending_analytics")

    # category_analytics
    joined = stats.merge(
        ref, left_on=["category_id", "region"], right_on=["id", "region"], how="left"
    )
    joined["category_name"] = joined["category_name"].fillna("Unknown")
    category = (
        joined.groupby(["region", "trending_date_parsed", "category_id", "category_name"])
        .agg(total_videos=("video_id", "nunique"), total_views=("views", "sum"))
        .reset_index()
    )
    category["view_share_pct"] = category["total_views"] * 100.0 / category.groupby(
        ["region", "trending_date_parsed"]
    )["total_views"].transform("sum")
    _overwrite_delta(category, "enriched", "category_analytics")

    # channel_analytics
    ch = stats[stats["channel_title"].notna()].copy()
    ch_joined = ch.merge(
        ref, left_on=["category_id", "region"], right_on=["id", "region"], how="left"
    )
    ch_joined["category_name"] = ch_joined["category_name"].fillna("Unknown")
    categories = (
        ch_joined[["channel_title", "region", "category_name"]]
        .drop_duplicates()
        .groupby(["channel_title", "region"])["category_name"]
        .apply(lambda s: ",".join(sorted(s)))
        .reset_index()
        .rename(columns={"category_name": "categories"})
    )
    channel = (
        ch.groupby(["channel_title", "region"])
        .agg(
            total_videos=("video_id", "nunique"),
            total_views=("views", "sum"),
            avg_engagement_rate=("engagement_rate", "mean"),
        )
        .reset_index()
        .merge(categories, on=["channel_title", "region"], how="left")
    )
    channel["rank_in_region"] = channel.groupby("region")["total_views"].rank(
        method="first", ascending=False
    ).astype("int64")
    _overwrite_delta(channel, "enriched", "channel_analytics")


def main() -> int:
    build_curated_statistics()
    build_curated_reference_data()
    build_enriched()
    return 0


if __name__ == "__main__":
    sys.exit(main())
