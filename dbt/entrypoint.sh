#!/usr/bin/env bash
set -euo pipefail

# Step 1: the real transform work -- builds curated_statistics (MERGE),
# curated_reference_data, and all 3 enriched tables via Python + deltalake.
# See dbt_project.yml's header note for why this isn't dbt SQL models.
python /dbt/scripts/build_curated_and_enriched.py

# Step 2: dbt's role here is testing what step 1 just wrote, not building
# it. All 5 tables are declared as sources (models/sources.yml) with the
# same generic tests (not_null, test_null_percentage, dbt_expectations
# range/row-count) the AWS project ran as dbt tests against real models --
# a failing test here still fails this script's exit code, which is what
# fails the Container Apps Job, which is what the orchestrating Logic App's
# polling loop treats as a failed run. Same "test failure = pipeline
# failure" chain the AWS project had, one layer relocated.
mkdir -p ~/.dbt
envsubst < /dbt/profiles/profiles.yml.template > ~/.dbt/profiles.yml

cd /dbt
dbt deps
# --debug temporarily, to see the real underlying pyodbc/database error --
# dbt's normal-verbosity "Database Error" wrapper hides the actual driver
# exception, and every test failing identically after ~38s (a suspiciously
# uniform pattern across unrelated tables) points at a connection/auth-level
# problem, not a per-table data issue -- direct SQL-auth queries against the
# same tables already proved the data itself is readable.
dbt --debug test --select source:*

# Source freshness (the 5th ported DQ check) is a separate invocation, same
# as the AWS project -- must also gate the container's exit code.
dbt source freshness
