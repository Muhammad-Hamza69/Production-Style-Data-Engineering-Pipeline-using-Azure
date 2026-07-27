# 📊 Power BI Dashboard Implementation Guide for Azure YouTube Data Pipeline

This document details how to connect **Power BI Desktop & Power BI Service** to your **Azure Synapse Serverless SQL Pool** to build interactive KPI dashboards over the `enriched` Delta Parquet analytics layer.

---

## 🏗️ Architecture & Data Sources

- **Database**: `yt_pipeline`
- **Serverless SQL Endpoint**: `ytpl-synapse-387f2fde-ondemand.sql.azuresynapse.net`
- **Authentication**: Azure Active Directory (Entra ID) / Service Principal / SQL Auth
- **Tables**:
  - `enriched.trending_analytics`: High-level daily & regional aggregates (views, likes, comments, engagement rates).
  - `enriched.category_analytics`: View share %, category breakdown per region.
  - `enriched.channel_analytics`: Top creator channel rankings (`rank_in_region`), views, and multi-category tagging.

---

## 🚀 Quick Start: Connect via `.pbids` File

1. Open Power BI Desktop.
2. Open the included **[YouTube_Analytics_Synapse.pbids](file:///d:/yt%20pipeline/Youtube-Data-Pipeline-using-Python-and-Azure/YouTube_Analytics_Synapse.pbids)** file in the root repository folder.
3. Select **Microsoft Account (OAuth2 / Entra ID)** or **Database Admin Credentials**.
4. Choose **DirectQuery** (for real-time pipeline monitoring) or **Import** (for high-speed offline visualization).

---

## 📈 Power BI KPI Dashboard Layout & Pages

### Page 1: Executive KPI Overview
- **Header Card Cluster**:
  - **Total Trending Views** (`SUM(trending_analytics[total_views])`)
  - **Total Tracked Videos** (`SUM(trending_analytics[total_videos])`)
  - **Avg Engagement Rate** (`AVERAGE(trending_analytics[avg_engagement_rate])`)
  - **Active Channels** (`DISTINCTCOUNT(channel_analytics[channel_title])`)
- **Visuals**:
  - **Map / Filled Map**: Views and Engagement Rate by `region` (`US`, `GB`, `CA`, `DE`, `FR`, `IN`, `JP`, `KR`, `MX`, `RU`).
  - **Line Chart**: Daily Views trend over `trending_date_parsed`.

### Page 2: Category & Content Share Analysis
- **Visuals**:
  - **Treemap / Donut Chart**: `category_analytics[view_share_pct]` by `category_name`.
  - **Clustered Bar Chart**: Top Categories by Views across regions.
  - **Scatter Plot**: Video Count vs. View Share % per Category.

### Page 3: Creator & Channel Performance Ranking
- **Visuals**:
  - **Rank 1 Creator Cards**: Highlights `#1 Channel in Region` filterable by Slicer.
  - **Table Grid**: `channel_title`, `region`, `rank_in_region`, `total_views`, `avg_engagement_rate`.

---

## 🔒 Security & Service Principal Access
For Power BI Service scheduled refresh, grant the Power BI Service Principal or Gateway access to the `enriched` schema in Synapse:

```sql
USE yt_pipeline;
GRANT SELECT ON SCHEMA::enriched TO [yt-pipeline-dbt-sp];
```
