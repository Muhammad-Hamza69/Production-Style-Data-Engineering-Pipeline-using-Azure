"""
Container Apps Job: Staging → Raw (Delta Lake)
────────────────────────────────────────────────
Started by the pipeline_workflow Logic App after the ingest job succeeds.
Scans the Staging container for both source shapes this pipeline ever
produces -- live YouTube API JSON responses and the one-time Kaggle
historical CSV/JSON seed -- normalizes each into one stable, uniform schema
per dataset, and writes Delta tables directly to Raw via the `deltalake`
package (delta-rs bindings; no Spark, no separate catalog service --
Synapse serverless SQL discovers these tables by path, via
scripts/synapse_setup.sql's CREATE EXTERNAL TABLE statements, not by a
crawler or an equivalent of the Glue Catalog auto-registration AWS's
awswrangler.athena.to_iceberg() did as a side effect).

Ported 1:1 from lambdas/raw_transform/lambda_function.py: shape-detection
and column-normalization logic is unchanged. Raw is written with
mode="append" for the same reason as the AWS version -- it's an immutable
ingestion log; "latest wins" dedup is dbt's job downstream via incremental
merge, not a Raw-layer concern. Two Delta tables, mirroring the two
datasets: raw_statistics, raw_reference_data.

Environment Variables:
    STORAGE_ACCOUNT_NAME
    AZURE_CLIENT_ID     — this job's user-assigned managed identity client ID
"""

import io
import json
import logging
import os
import sys
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import pandas as pd
from azure.identity import ManagedIdentityCredential
from azure.storage.filedatalake import DataLakeServiceClient
from deltalake import write_deltalake

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

CLIENT_ID = os.environ["AZURE_CLIENT_ID"]
STORAGE_ACCOUNT = os.environ["STORAGE_ACCOUNT_NAME"]

STATS_PREFIX = "youtube/raw_statistics/"
REF_PREFIX = "youtube/raw_statistics_reference_data/"
TABLE_STATS = "raw_statistics"
TABLE_REF = "raw_reference_data"

_credential = ManagedIdentityCredential(client_id=CLIENT_ID)
_dl_service = DataLakeServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT}.dfs.core.windows.net",
    credential=_credential,
)
_staging_fs = _dl_service.get_file_system_client("staging")

# Stable Raw contract for statistics -- every row, regardless of source,
# ends up with exactly these columns. trending_date_raw is left as the
# source's native string (ISO for API, Kaggle's yy.dd.MM for historical) --
# dbt's curated model parses both formats explicitly, this job does not.
STATS_COLUMNS = [
    "video_id", "title", "channel_title", "category_id", "publish_time",
    "trending_date_raw", "tags", "views", "likes", "dislikes",
    "comment_count", "description", "region", "source",
    "_ingestion_timestamp", "_source_file",
]

REF_COLUMNS = [
    "id", "title", "region", "source", "_ingestion_timestamp", "_source_file",
]


def _region_from_key(key: str) -> str:
    for part in key.split("/"):
        if part.startswith("region="):
            return part.split("=", 1)[1]
    return "unknown"


def _list_paths(prefix: str) -> list:
    return [p.name for p in _staging_fs.get_paths(path=prefix) if not p.is_directory]


def _read_json(path: str) -> dict:
    file_client = _staging_fs.get_file_client(path)
    body = file_client.download_file().readall()
    return json.loads(body.decode("utf-8"))


def _read_csv(path: str) -> pd.DataFrame:
    file_client = _staging_fs.get_file_client(path)
    body = file_client.download_file().readall()
    # Kaggle's CSVs are notoriously inconsistent on encoding (latin-1 in a
    # few region files) -- errors="replace" keeps a bad byte from failing
    # the whole run.
    return pd.read_csv(io.BytesIO(body), encoding="utf-8", encoding_errors="replace")


def _normalize_api_statistics(path: str) -> pd.DataFrame:
    data = _read_json(path)
    items = data.get("items", [])
    meta = data.get("_pipeline_metadata", {})
    region = meta.get("region") or _region_from_key(path)
    ingestion_ts = meta.get("ingestion_timestamp", datetime.now(timezone.utc).isoformat())

    rows = []
    for item in items:
        snippet = item.get("snippet", {})
        stats = item.get("statistics", {})
        rows.append({
            "video_id": item.get("id"),
            "title": snippet.get("title"),
            "channel_title": snippet.get("channelTitle"),
            "category_id": snippet.get("categoryId"),
            "publish_time": snippet.get("publishedAt"),
            "trending_date_raw": ingestion_ts,
            "tags": ",".join(snippet.get("tags", [])) if snippet.get("tags") else None,
            "views": stats.get("viewCount"),
            "likes": stats.get("likeCount"),
            "dislikes": None,  # YouTube retired the public dislike count in Dec 2021
            "comment_count": stats.get("commentCount"),
            "description": snippet.get("description"),
            "region": region,
            "source": "youtube_api_v3",
            "_ingestion_timestamp": ingestion_ts,
            "_source_file": path,
        })
    return pd.DataFrame(rows, columns=STATS_COLUMNS)


def _normalize_kaggle_statistics(path: str) -> pd.DataFrame:
    df = _read_csv(path)
    region = _region_from_key(path)
    ingestion_ts = datetime.now(timezone.utc).isoformat()

    out = pd.DataFrame()
    out["video_id"] = df.get("video_id")
    out["title"] = df.get("title")
    out["channel_title"] = df.get("channel_title")
    out["category_id"] = df.get("category_id").astype(str) if "category_id" in df else None
    out["publish_time"] = df.get("publish_time")
    out["trending_date_raw"] = df.get("trending_date")
    out["tags"] = df.get("tags")
    out["views"] = df.get("views")
    out["likes"] = df.get("likes")
    out["dislikes"] = df.get("dislikes")
    out["comment_count"] = df.get("comment_count")
    out["description"] = df.get("description")
    out["region"] = region
    out["source"] = "kaggle_historical"
    out["_ingestion_timestamp"] = ingestion_ts
    out["_source_file"] = path
    return out[STATS_COLUMNS]


def _normalize_reference_data(path: str) -> pd.DataFrame:
    # Kaggle's *_category_id.json files ARE YouTube API videoCategories
    # responses (same shape) -- no source-shape branching needed here.
    data = _read_json(path)
    items = data.get("items", [])
    region = (data.get("_pipeline_metadata") or {}).get("region") or _region_from_key(path)
    ingestion_ts = (data.get("_pipeline_metadata") or {}).get(
        "ingestion_timestamp", datetime.now(timezone.utc).isoformat()
    )
    source = "youtube_api_v3" if "_pipeline_metadata" in data else "kaggle_historical"

    rows = [
        {
            "id": item.get("id"),
            "title": item.get("snippet", {}).get("title"),
            "region": region,
            "source": source,
            "_ingestion_timestamp": ingestion_ts,
            "_source_file": path,
        }
        for item in items
    ]
    return pd.DataFrame(rows, columns=REF_COLUMNS)


def _delta_storage_options() -> dict:
    # deltalake (delta-rs) authenticates to ADLS Gen2 via a bearer token
    # here -- no static account key stored anywhere, same "identity, not
    # secret" principle as everything else in this project. The token is
    # scoped to the Storage resource provider's own audience.
    token = _credential.get_token("https://storage.azure.com/.default").token
    return {
        "azure_storage_account_name": STORAGE_ACCOUNT,
        "azure_storage_token": token,
    }


def _write_delta(df: pd.DataFrame, table: str):
    if df.empty:
        logger.info("No rows to write for %s, skipping", table)
        return
    # Explicit numeric casts before write -- "dislikes" is always null for
    # live API rows (YouTube retired the public dislike count), and an
    # all-null pandas column infers as dtype "object", which Delta/Arrow
    # can't map to int64 cleanly. Same failure mode the AWS version's
    # ICEBERG_DTYPES dict existed to prevent, ported here as explicit casts.
    for col in ("views", "likes", "dislikes", "comment_count"):
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("Int64")

    # No partition_by -- Synapse serverless's Delta external-table reader
    # doesn't reliably reconstruct Hive-partition columns (they live only in
    # the directory path, e.g. region=us/, not inside the Parquet files
    # themselves), confirmed against a real dbt test run where every
    # partitioned column came back NULL through the external table. Data
    # volumes here don't need partitioning anyway.
    table_uri = f"abfss://raw@{STORAGE_ACCOUNT}.dfs.core.windows.net/{table}"
    write_deltalake(
        table_uri,
        df,
        mode="append",
        storage_options=_delta_storage_options(),
    )
    logger.info("Wrote %d rows to raw/%s", len(df), table)


def main() -> int:
    errors = []
    stats_frames = []
    ref_frames = []

    for path in _list_paths(STATS_PREFIX):
        path = unquote_plus(path)
        try:
            if path.endswith(".json"):
                stats_frames.append(_normalize_api_statistics(path))
            elif path.endswith(".csv"):
                stats_frames.append(_normalize_kaggle_statistics(path))
        except Exception as e:
            logger.error("Failed to normalize %s: %s", path, e, exc_info=True)
            errors.append({"path": path, "error": str(e)})

    for path in _list_paths(REF_PREFIX):
        path = unquote_plus(path)
        try:
            if path.endswith(".json"):
                ref_frames.append(_normalize_reference_data(path))
        except Exception as e:
            logger.error("Failed to normalize %s: %s", path, e, exc_info=True)
            errors.append({"path": path, "error": str(e)})

    stats_df = pd.concat(stats_frames, ignore_index=True) if stats_frames else pd.DataFrame(columns=STATS_COLUMNS)
    ref_df = pd.concat(ref_frames, ignore_index=True) if ref_frames else pd.DataFrame(columns=REF_COLUMNS)

    _write_delta(stats_df, TABLE_STATS)
    _write_delta(ref_df, TABLE_REF)

    if errors:
        logger.error("Partial failures: %s", json.dumps(errors))

    if not stats_frames and not ref_frames:
        # Nothing at all found in Staging is a real failure, not a quiet
        # no-op -- the ingest job is expected to have written something first.
        logger.error("No staging files found under %s or %s", STATS_PREFIX, REF_PREFIX)
        return 1

    logger.info("statistics_rows=%d reference_rows=%d errors=%d", len(stats_df), len(ref_df), len(errors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
