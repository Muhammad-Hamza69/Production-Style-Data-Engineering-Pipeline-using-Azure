"""
Container Apps Job: YouTube Data API Ingestion (Staging Layer)
────────────────────────────────────────────────────────────────
Started by the pipeline_workflow Logic App (its Recurrence trigger fires
hourly, same cadence the AWS project's EventBridge rule used). Pulls
trending videos from the YouTube Data API for each configured region and
writes raw JSON responses to the Staging container.

Ported from lambdas/youtube_api_integstion/lambda_function.py in the AWS
project -- fetch logic and JSON shape are unchanged; only the AWS SDK calls
(S3 write, Secrets Manager read) became their Azure equivalents (ADLS Gen2
blob write, Key Vault read). There's no SNS-equivalent partial-failure alert
here: failures are logged to stdout (captured by the Container Apps
environment's Log Analytics workspace) and a non-zero exit code is what
tells the Logic App's polling loop this run failed -- same "let the
orchestrator's own failure handling do the alerting" principle the AWS
dbt_trigger Lambda used, applied one layer earlier.

Environment Variables:
    KEY_VAULT_URI          — https://<vault>.vault.azure.net/
    STORAGE_ACCOUNT_NAME    — ADLS Gen2 account holding the staging container
    YOUTUBE_REGIONS         — comma-separated region codes
    AZURE_CLIENT_ID          — this job's user-assigned managed identity client ID
"""

import json
import os
import sys
import logging
from datetime import datetime, timezone
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode

from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.filedatalake import DataLakeServiceClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

CLIENT_ID = os.environ["AZURE_CLIENT_ID"]
KEY_VAULT_URI = os.environ["KEY_VAULT_URI"]
STORAGE_ACCOUNT = os.environ["STORAGE_ACCOUNT_NAME"]
REGIONS = os.environ.get("YOUTUBE_REGIONS", "US,GB,CA,DE,FR,IN,JP,KR,MX,RU").split(",")
API_BASE = "https://www.googleapis.com/youtube/v3"
MAX_RESULTS = 50

_credential = ManagedIdentityCredential(client_id=CLIENT_ID)


def _load_youtube_api_key() -> str:
    client = SecretClient(vault_url=KEY_VAULT_URI, credential=_credential)
    # .strip() defends against a stray trailing \r\n embedded in the secret
    # value (e.g. pasted from a Windows text file) -- percent-encodes into
    # the API request's key= parameter, turning a valid key into an
    # invalid one with no visible symptom beyond a generic 403 from Google.
    return client.get_secret("youtube-api-key").value.strip()


API_KEY = _load_youtube_api_key()

_dl_service = DataLakeServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT}.dfs.core.windows.net",
    credential=_credential,
)
_staging_fs = _dl_service.get_file_system_client("staging")


def fetch_trending_videos(region_code: str) -> dict:
    params = urlencode(
        {
            "part": "snippet,statistics,contentDetails",
            "chart": "mostPopular",
            "regionCode": region_code,
            "maxResults": MAX_RESULTS,
            "key": API_KEY,
        }
    )
    url = f"{API_BASE}/videos?{params}"
    req = Request(url, headers={"Accept": "application/json"})
    with urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_video_categories(region_code: str) -> dict:
    params = urlencode({"part": "snippet", "regionCode": region_code, "key": API_KEY})
    url = f"{API_BASE}/videoCategories?{params}"
    req = Request(url, headers={"Accept": "application/json"})
    with urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def write_to_staging(data: dict, path: str) -> None:
    body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
    file_client = _staging_fs.get_file_client(path)
    file_client.upload_data(
        body,
        overwrite=True,
        metadata={
            "ingestion_timestamp": datetime.now(timezone.utc).isoformat(),
            "source": "youtube_data_api_v3",
        },
    )


def main() -> int:
    now = datetime.now(timezone.utc)
    date_partition = now.strftime("%Y-%m-%d")
    hour_partition = now.strftime("%H")
    ingestion_id = now.strftime("%Y%m%d_%H%M%S")

    results = {"success": [], "failed": []}

    for region in REGIONS:
        region = region.strip().lower()
        logger.info("Processing region: %s", region)

        try:
            trending_data = fetch_trending_videos(region)
            video_count = len(trending_data.get("items", []))
            trending_data["_pipeline_metadata"] = {
                "ingestion_id": ingestion_id,
                "region": region,
                "ingestion_timestamp": now.isoformat(),
                "video_count": video_count,
                "source": "youtube_data_api_v3",
            }
            path = (
                f"youtube/raw_statistics/region={region}/"
                f"date={date_partition}/hour={hour_partition}/{ingestion_id}.json"
            )
            write_to_staging(trending_data, path)
            logger.info("  Wrote %d videos -> staging/%s", video_count, path)
        except (HTTPError, URLError) as e:
            logger.error("  API error for %s trending: %s", region, e)
            results["failed"].append({"region": region, "type": "trending", "error": str(e)})
            continue
        except Exception as e:
            logger.error("  Unexpected error for %s trending: %s", region, e)
            results["failed"].append({"region": region, "type": "trending", "error": str(e)})
            continue

        try:
            category_data = fetch_video_categories(region)
            category_data["_pipeline_metadata"] = {
                "ingestion_id": ingestion_id,
                "region": region,
                "ingestion_timestamp": now.isoformat(),
                "source": "youtube_data_api_v3",
            }
            ref_path = (
                f"youtube/raw_statistics_reference_data/region={region}/"
                f"date={date_partition}/{region}_category_id.json"
            )
            write_to_staging(category_data, ref_path)
            logger.info("  Wrote categories -> staging/%s", ref_path)
        except (HTTPError, URLError) as e:
            logger.error("  API error for %s categories: %s", region, e)
            results["failed"].append({"region": region, "type": "categories", "error": str(e)})
            continue

        results["success"].append(region)

    summary = (
        f"Ingestion {ingestion_id} complete. "
        f"Success: {len(results['success'])}/{len(REGIONS)} regions. "
        f"Failed: {len(results['failed'])}."
    )
    logger.info(summary)

    if results["failed"]:
        logger.error("Partial failure detail: %s", json.dumps(results["failed"]))

    if not results["success"]:
        # Every region failed -- nothing was written at all, a real failure,
        # not a partial one. Matches the AWS raw-transform Lambda's own
        # "nothing found is a real failure" principle, applied here to
        # ingestion instead. A partial failure (some regions ok, some not)
        # intentionally still exits 0 -- same tolerance the original Lambda
        # had (log + continue), so one flaky region doesn't skip
        # raw-transform/dbt for every region that DID succeed.
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
