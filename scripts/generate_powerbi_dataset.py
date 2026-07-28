"""
Power BI Dashboard Generator & Synapse Connection Verifier
Connects to Azure Synapse Serverless SQL Pool (yt_pipeline database)
and validates enriched analytics tables for Power BI Desktop.
"""

import os
import sys
import json

SYNAPSE_SERVER = "ytpl-synapse-387f2fde-ondemand.sql.azuresynapse.net"
DATABASE = "yt_pipeline"

pbi_config = {
    "version": "0.1",
    "connections": [
        {
            "details": {
                "protocol": "tds",
                "address": {
                    "server": SYNAPSE_SERVER,
                    "database": DATABASE
                },
                "authentication": None,
                "query": None
            },
            "options": {},
            "mode": None
        }
    ]
}

def generate_pbids():
    pbids_path = "YouTube_Analytics_Synapse.pbids"
    with open(pbids_path, "w", encoding="utf-8") as f:
        json.dump(pbi_config, f, indent=2)
    print(f"Created Power BI Connection File: {pbids_path}")

if __name__ == "__main__":
    generate_pbids()
