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
# Step 2: Data Quality validation suite (executing all 15 DQ tests defined
# in sources.yml directly against Synapse SQL Serverless)
python /dbt/scripts/run_dq_tests.py
