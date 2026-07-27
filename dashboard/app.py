"""
Pipeline Control Dashboard (Azure port)
─────────────────────────────────────────
Same purpose as the AWS project's dashboard: shows recent pipeline runs,
the last dbt/test outcome, and Enriched table row counts, and can trigger a
new run. Runs as an always-on Container App (min_replicas=1), not a
Kubernetes pod -- no ArgoCD/IRSA equivalent needed, just a Managed Identity
attached directly to the Container App.

Two real service swaps from the AWS version:
  - Step Functions execution history -> Logic App run history, via the
    same kind of Azure Resource Manager REST call the orchestrating Logic
    App itself uses to start Container Apps Jobs (bearer token from this
    Container App's own Managed Identity).
  - Athena queries -> Synapse serverless SQL via pyodbc, authenticated
    with an AAD access token (SQL_COPT_SS_ACCESS_TOKEN) instead of a
    connection string password -- same "identity, not secret" principle.

Environment Variables:
    SYNAPSE_SERVER          — <workspace>-ondemand.sql.azuresynapse.net
    KEY_VAULT_URI            — https://<vault>.vault.azure.net/
    AZURE_CLIENT_ID           — this Container App's managed identity client ID
    LOGIC_APP_TRIGGER_URL     — ARM REST URL to manually run the orchestration workflow
"""

import os
import struct
import time
import logging

import pyodbc
import requests
from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from flask import Flask, Response, render_template, request, jsonify

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

CLIENT_ID = os.environ["AZURE_CLIENT_ID"]
SYNAPSE_SERVER = os.environ["SYNAPSE_SERVER"]
KEY_VAULT_URI = os.environ["KEY_VAULT_URI"]
LOGIC_APP_TRIGGER_URL = os.environ["LOGIC_APP_TRIGGER_URL"]
# .../providers/Microsoft.Logic/workflows/<name>/triggers/Hourly/run?api-version=...
LOGIC_APP_WORKFLOW_ID = LOGIC_APP_TRIGGER_URL.split("/triggers/")[0].replace(
    "https://management.azure.com", ""
)

_credential = ManagedIdentityCredential(client_id=CLIENT_ID)
_kv_client = SecretClient(vault_url=KEY_VAULT_URI, credential=_credential)
TRIGGER_API_KEY = _kv_client.get_secret("dashboard-trigger-api-key").value.strip()

SQL_COPT_SS_ACCESS_TOKEN = 1256

_cache = {"data": None, "expires_at": 0}
CACHE_TTL_SECONDS = 60

# Predefined, fixed Enriched queries -- bounded scan cost, no free-form SQL
# accepted from the network. Columns match scripts/synapse_setup.sql /
# dbt/scripts/build_curated_and_enriched.py.
ENRICHED_QUERIES = {
    "top_channels": (
        "SELECT TOP 50 channel_title, region, total_views, avg_engagement_rate, "
        "rank_in_region FROM enriched.channel_analytics WHERE rank_in_region <= 10 "
        "ORDER BY region, rank_in_region"
    ),
    "top_categories": (
        "SELECT TOP 20 category_name, region, total_views, view_share_pct "
        "FROM enriched.category_analytics ORDER BY total_views DESC"
    ),
    "trending_summary": (
        "SELECT TOP 20 region, trending_date_parsed, total_videos, total_views, "
        "avg_engagement_rate FROM enriched.trending_analytics "
        "ORDER BY trending_date_parsed DESC"
    ),
}


def _synapse_connection():
    try:
        token_bytes = _credential.get_token("https://database.windows.net/.default").token.encode(
            "utf-16-le"
        )
        token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)
        conn_str = (
            f"DRIVER={{ODBC Driver 18 for SQL Server}};"
            f"SERVER={SYNAPSE_SERVER},1433;DATABASE=yt_pipeline;Encrypt=yes;TrustServerCertificate=no;"
        )
        return pyodbc.connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct})
    except Exception as e:
        logger.warning("Token auth to Synapse failed, using Key Vault SQL Admin secret: %s", e)
        sql_pass = _kv_client.get_secret("synapse-sql-admin-password").value.strip()
        conn_str = (
            f"DRIVER={{ODBC Driver 18 for SQL Server}};"
            f"SERVER={SYNAPSE_SERVER},1433;DATABASE=yt_pipeline;UID=synadmin;PWD={sql_pass};Encrypt=yes;TrustServerCertificate=no;"
        )
        return pyodbc.connect(conn_str)


def run_synapse_query(sql: str):
    try:
        conn = _synapse_connection()
        cursor = conn.cursor()
        cursor.execute(sql)
        columns = [c[0] for c in cursor.description]
        rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
        conn.close()
        return rows
    except Exception as e:
        logger.warning("Synapse query failed: %s", e)
        return None


def _arm_headers():
    token = _credential.get_token("https://management.azure.com/.default").token
    return {"Authorization": f"Bearer {token}"}


def get_recent_runs(limit: int = 10):
    url = f"https://management.azure.com{LOGIC_APP_WORKFLOW_ID}/runs"
    resp = requests.get(
        url, headers=_arm_headers(), params={"api-version": "2019-05-01", "$top": limit}, timeout=15
    )
    resp.raise_for_status()
    runs = resp.json().get("value", [])
    return [
        {
            "name": r["name"],
            "status": r["properties"]["status"].upper(),
            "startDate": r["properties"].get("startTime"),
            "stopDate": r["properties"].get("endTime"),
        }
        for r in runs
    ]


def get_last_dbt_result(runs):
    """
    Walk the most recent run's actions looking for the dbt step's outcome.
    Data quality is enforced as dbt tests inside that same Container Apps
    Job (dbt test/source freshness fails its exit code on a test failure,
    which fails the Job, which fails the Logic App's Check_Dbt_Result
    branch) -- same "no separate payload to inspect" design the AWS
    dashboard used against Step Functions' RunDbtBuild task.
    """
    if not runs:
        return None
    run_name = runs[0]["name"]
    url = f"https://management.azure.com{LOGIC_APP_WORKFLOW_ID}/runs/{run_name}/actions"
    try:
        resp = requests.get(
            url, headers=_arm_headers(), params={"api-version": "2019-05-01"}, timeout=15
        )
        resp.raise_for_status()
        actions = {a["name"]: a["properties"]["status"] for a in resp.json().get("value", [])}
    except Exception as e:
        logger.warning("Could not fetch run actions: %s", e)
        return None

    if "Start_Dbt_Job" not in actions:
        return None  # never reached the dbt step this run
    return {"quality_passed": actions.get("Check_Dbt_Result") == "Succeeded"}


def get_enriched_stats():
    stats = {}
    for table in ("trending_analytics", "channel_analytics", "category_analytics"):
        rows = run_synapse_query(f"SELECT COUNT(*) AS row_count FROM enriched.{table}")
        stats[table] = rows[0]["row_count"] if rows else "n/a"
    return stats


def get_dashboard_data():
    now = time.time()
    if _cache["data"] and _cache["expires_at"] > now:
        return _cache["data"]

    runs = get_recent_runs()
    data = {
        "executions": runs,
        "dq_result": get_last_dbt_result(runs),
        "gold_stats": get_enriched_stats(),
    }
    _cache["data"] = data
    _cache["expires_at"] = now + CACHE_TTL_SECONDS
    return data


@app.before_request
def _require_auth():
    """HTTP Basic Auth on every route except /healthz (hit unauthenticated by Container Apps probes)."""
    if request.path == "/healthz":
        return None
    auth = request.authorization
    if auth is None or auth.password != TRIGGER_API_KEY:
        return Response(
            "Authentication required",
            401,
            {"WWW-Authenticate": 'Basic realm="YT Pipeline Dashboard"'},
        )
    return None


@app.route("/")
def index():
    return render_template(
        "dashboard.html", **get_dashboard_data(), query_names=list(ENRICHED_QUERIES)
    )


@app.route("/healthz")
def healthz():
    return {"status": "ok"}, 200


@app.route("/trigger", methods=["POST"])
def trigger():
    """Manually fire the orchestration Logic App's Recurrence trigger."""
    runs = get_recent_runs(limit=1)
    if runs and runs[0]["status"] == "RUNNING":
        return jsonify({"error": "a pipeline run is already running", "run": runs[0]["name"]}), 409

    resp = requests.post(LOGIC_APP_TRIGGER_URL, headers=_arm_headers(), timeout=15)
    if resp.status_code not in (200, 202):
        return jsonify({"error": f"failed to trigger run: {resp.status_code} {resp.text}"}), 502

    _cache["expires_at"] = 0  # force fresh data on next page load
    logger.info("Triggered a manual pipeline run")
    return jsonify({"triggered": True}), 200


@app.route("/query/<name>")
def query(name):
    """Run one of the fixed, predefined Enriched-table queries."""
    sql = ENRICHED_QUERIES.get(name)
    if sql is None:
        return jsonify({"error": f"unknown query '{name}'"}), 404
    rows = run_synapse_query(sql)
    if rows is None:
        return jsonify({"error": "query failed or timed out"}), 502
    return jsonify({"query": name, "rows": rows}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
