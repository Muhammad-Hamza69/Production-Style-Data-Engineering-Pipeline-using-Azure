import os
import sys
import logging
import pyodbc

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

server = os.environ.get("SYNAPSE_SERVER", "ytpl-synapse-387f2fde-ondemand.sql.azuresynapse.net")
database = "yt_pipeline"
user = os.environ.get("SYNAPSE_SQL_ADMIN_LOGIN", "synadmin")
password = os.environ.get("SYNAPSE_SQL_ADMIN_PASSWORD", "LtS5Uu@w1IBcj@6AanJGybL$")
driver = "{ODBC Driver 18 for SQL Server}"

conn_str = f"DRIVER={driver};SERVER={server},1433;DATABASE={database};UID={user};PWD={password};Encrypt=yes;TrustServerCertificate=no;"

logger.info(f"Connecting to Synapse ({server}) to run Data Quality tests...")
try:
    conn = pyodbc.connect(conn_str)
    cursor = conn.cursor()
    logger.info("Connected to Synapse SQL successfully!")
except Exception as e:
    logger.error(f"Failed to connect to Synapse: {e}")
    sys.exit(1)

tests = [
    # raw_statistics
    ("raw_statistics freshness", "SELECT MAX(CAST(_ingestion_timestamp AS datetime2)) FROM raw.raw_statistics", lambda rows: len(rows) > 0 and rows[0][0] is not None),
    
    # curated_statistics
    ("curated_statistics min rows (>=10)", "WITH r AS (SELECT COUNT(*) AS n FROM curated.curated_statistics) SELECT n FROM r WHERE n < 10", lambda rows: len(rows) == 0),
    ("curated_statistics video_id not_null", "SELECT COUNT(*) FROM curated.curated_statistics WHERE video_id IS NULL", lambda rows: rows[0][0] == 0),
    ("curated_statistics title null_pct (<=5%)", "WITH stats AS (SELECT COUNT(*) as total_rows, SUM(CASE WHEN title IS NULL THEN 1 ELSE 0 END) as null_rows FROM curated.curated_statistics) SELECT total_rows, null_rows, (null_rows * 100.0 / nullif(total_rows, 0)) as pct FROM stats WHERE (null_rows * 100.0 / nullif(total_rows, 0)) > 5", lambda rows: len(rows) == 0),
    ("curated_statistics channel_title null_pct (<=5%)", "WITH stats AS (SELECT COUNT(*) as total_rows, SUM(CASE WHEN channel_title IS NULL THEN 1 ELSE 0 END) as null_rows FROM curated.curated_statistics) SELECT total_rows, null_rows, (null_rows * 100.0 / nullif(total_rows, 0)) as pct FROM stats WHERE (null_rows * 100.0 / nullif(total_rows, 0)) > 5", lambda rows: len(rows) == 0),
    ("curated_statistics region not_null", "SELECT COUNT(*) FROM curated.curated_statistics WHERE region IS NULL", lambda rows: rows[0][0] == 0),
    ("curated_statistics trending_date_parsed not_null", "SELECT COUNT(*) FROM curated.curated_statistics WHERE trending_date_parsed IS NULL", lambda rows: rows[0][0] == 0),
    ("curated_statistics views range (0..50B)", "SELECT views FROM curated.curated_statistics WHERE views < 0 OR views > 50000000000", lambda rows: len(rows) == 0),
    
    # curated_reference_data
    ("curated_reference_data id not_null", "SELECT COUNT(*) FROM curated.curated_reference_data WHERE id IS NULL", lambda rows: rows[0][0] == 0),
    ("curated_reference_data region not_null", "SELECT COUNT(*) FROM curated.curated_reference_data WHERE region IS NULL", lambda rows: rows[0][0] == 0),
    
    # enriched
    ("trending_analytics region not_null", "SELECT COUNT(*) FROM enriched.trending_analytics WHERE region IS NULL", lambda rows: rows[0][0] == 0),
    ("trending_analytics date not_null", "SELECT COUNT(*) FROM enriched.trending_analytics WHERE trending_date_parsed IS NULL", lambda rows: rows[0][0] == 0),
    ("channel_analytics channel_title not_null", "SELECT COUNT(*) FROM enriched.channel_analytics WHERE channel_title IS NULL", lambda rows: rows[0][0] == 0),
    ("channel_analytics rank not_null", "SELECT COUNT(*) FROM enriched.channel_analytics WHERE rank_in_region IS NULL", lambda rows: rows[0][0] == 0),
    ("category_analytics category_name not_null", "SELECT COUNT(*) FROM enriched.category_analytics WHERE category_name IS NULL", lambda rows: rows[0][0] == 0),
]

failed_tests = []
passed_count = 0

for name, sql, check_fn in tests:
    try:
        cursor.execute(sql)
        rows = cursor.fetchall()
        if check_fn(rows):
            logger.info(f" [PASS] {name}")
            passed_count += 1
        else:
            logger.error(f" [FAIL] {name} - Returned: {rows}")
            failed_tests.append((name, f"Assertion failed: {rows}"))
    except Exception as e:
        logger.error(f" [ERROR] {name}: {e}")
        failed_tests.append((name, str(e)))

conn.close()

logger.info(f"Data Quality Test Summary: {passed_count}/{len(tests)} PASSED.")

if failed_tests:
    logger.error(f" {len(failed_tests)} Data Quality test(s) failed!")
    sys.exit(1)
else:
    logger.info(" ALL DATA QUALITY TESTS PASSED CLEANLY!")
    sys.exit(0)
