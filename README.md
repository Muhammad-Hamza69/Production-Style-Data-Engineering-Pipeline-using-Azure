# YouTube Data Pipeline on Azure — Complete Beginner's Guide

> **Who this guide is for:** Absolute beginners to Azure. You do not need to know Azure deeply. Every step is written as a numbered action — click this, paste that, check this value. Every piece of code you need is included inline or already sits in this repo.
>
> **What you will build:** A fully working, serverless-first YouTube analytics pipeline on Azure — from a scheduled data pull all the way to a BI dashboard — using Azure Container Apps, Azure Data Lake Storage Gen2, Synapse Analytics serverless SQL, Logic Apps, and Power BI.
>
> **Golden Rule:** Follow every step **in the exact order written**. Each phase creates resources that the next phase depends on. Skipping ahead will break things — and several of the gotchas below were only discovered by building this for real, so the order matters more than it looks.

---

## 📋 Table of Contents

| # | Phase | What You Build |
|---|-------|----------------|
| — | [Architecture Overview](#-architecture-overview) | Understand what you're building before touching Azure |
| — | [Prerequisites](#-prerequisites--do-these-before-touching-azure) | Account setup + tools you need |
| 0 | [Resource Group](#phase-0--resource-group) | The container everything else lives inside |
| 1 | [Storage Account (ADLS Gen2)](#phase-1--storage-account-adls-gen2) | The data lake — staging/raw/curated/enriched |
| 2 | [Container Registry](#phase-2--azure-container-registry) | Where your app's Docker images live |
| 3 | [Key Vault](#phase-3--key-vault) | Secure secret storage |
| 4 | [Identities](#phase-4--managed-identities--service-principal) | Managed Identities + the one Service Principal you need |
| 5 | [Log Analytics](#phase-5--log-analytics-workspace) | Where every container's logs land |
| 6 | [Container Apps Environment](#phase-6--container-apps-environment) | The shared runtime for every compute piece |
| 7 | [Build & Push Images](#phase-7--build--push-container-images) | Get your code into the registry |
| 8 | [Container Apps Jobs + Dashboard](#phase-8--container-apps-jobs--dashboard) | The actual compute: ingest, raw-transform, dbt, dashboard |
| 9 | [Synapse Workspace](#phase-9--synapse-analytics-workspace) | Serverless SQL over your data lake |
| 10 | [Synapse Database Setup](#phase-10--synapse-database-setup) | External tables, credentials, permissions |
| 11 | [Logic App Orchestration](#phase-11--logic-app-orchestration) | The scheduler + workflow that ties it all together |
| 12 | [Gmail Notifications](#phase-12--gmail-notification-connector) | Email alerts on success/failure |
| 13 | [Power BI](#phase-13--power-bi-dashboard) | The BI layer on top of Enriched |
| 14 | [End-to-End Verification](#phase-14--end-to-end-verification) | Prove the whole thing actually works |
| 15 | [Cleanup](#phase-15--cleanup--cost-management) | Delete everything in the right order |
| — | [Troubleshooting](#-troubleshooting-guide) | Every real bug hit building this, and its fix |
| — | [Quick Reference](#-quick-reference--all-resource-names) | All resource names in one place |

---

## 🏗 Architecture Overview

### What This Architecture Does

```
════════════════════════════════════════════════════════════════════════
  ORCHESTRATION
════════════════════════════════════════════════════════════════════════

  Logic App "yt-pipeline-orchestration"   (hourly Recurrence trigger)
       │
       ├─► Start Container Apps Job: yt-pipeline-ingest
       │        (pulls YouTube Data API v3 trending videos, 10 regions)
       │        writes JSON  ──────────────────────────────►  Storage: staging/
       │
       ├─► Start Container Apps Job: yt-pipeline-raw-transform
       │        (reads staging JSON, normalizes shape, writes Delta tables)
       │        writes Delta ─────────────────────────────►  Storage: raw/
       │           (raw_statistics, raw_reference_data)
       │
       └─► Start Container Apps Job: yt-pipeline-dbt
                (Python: MERGEs curated_statistics via deltalake,
                 rebuilds curated_reference_data + 3 enriched tables;
                 then dbt: runs data-quality tests against Synapse)
                writes Delta ─────────────────────────────►  Storage: curated/, enriched/
                     │
                     ▼
            Synapse serverless SQL   (reads curated/enriched Delta files
            (external tables)         as external tables — no ETL, no
                     │                 servers, pay only per query)
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
   Container App           Power BI
   "yt-pipeline-dashboard"  (BI dashboard)
   (ops control panel,
    triggers runs manually)
```

### What Each Service Does (Plain English)

> 💡 Read this whole table before touching Azure. It will make every step make sense.

| Service | Plain-English Role |
|---|---|
| **Azure Data Lake Storage Gen2** | One storage account, four containers (`staging`, `raw`, `curated`, `enriched`). This is your entire data lake — everything else just reads and writes files here. |
| **Azure Container Registry (ACR)** | Holds the four Docker images this project runs: `yt-ingest`, `yt-raw-transform`, `yt-dbt`, `yt-dashboard`. |
| **Azure Container Apps Environment** | A shared, serverless runtime. Three **Jobs** (run-to-completion, billed only while running) do the actual ETL work; one regular **Container App** (always listening) hosts the dashboard. |
| **Managed Identities** | Five passwordless identities — one per compute component — so nothing in this project stores a static Azure credential for talking to storage/registry/vault. |
| **Key Vault** | Secure storage for the YouTube API key, the dashboard's trigger API key, and (unused fallback) a SQL password. |
| **Synapse Analytics (serverless SQL pool)** | Pay-per-query SQL engine that reads your Delta Lake files directly as **external tables** — no data warehouse to provision, no cost when idle. This is the Azure equivalent of AWS Athena. |
| **Logic App** | Both your scheduler (hourly trigger) *and* your orchestrator (the sequence of steps) in one resource — unlike AWS, which needs two separate services for this. |
| **Log Analytics Workspace** | Where every container's stdout/stderr lands, queryable with KQL. Your only real debugging window into a Container Apps Job. |
| **Power BI** | The BI layer. Connects to Synapse serverless SQL and reads the `enriched` schema's three tables. |

### Layer Naming

| Layer | Storage Container | Synapse Schema | Written By |
|---|---|---|---|
| Staging | `staging` | *(none — plain JSON, never queried directly)* | `yt-pipeline-ingest` |
| Raw | `raw` | `raw` | `yt-pipeline-raw-transform` |
| Curated | `curated` | `curated` | `yt-pipeline-dbt` (Python + deltalake MERGE) |
| Enriched | `enriched` | `enriched` | `yt-pipeline-dbt` (Python + deltalake overwrite) |

### Why Container Apps Jobs Instead of a Kubernetes Cluster?

A Kubernetes cluster (AKS) bills for its worker nodes 24/7, whether or not anything is actually running on them — for a pipeline that runs a few minutes every hour, that's paying for ~23 hours of idle compute every day. Container Apps **Jobs** scale to zero and bill only for the seconds they actually execute. Same containers, same code, a fraction of the cost.

### Why Synapse Serverless, Not a Dedicated Pool or Microsoft Fabric?

- A **dedicated Synapse SQL pool** is billed by the hour whether you query it or not — same problem as AKS.
- **Microsoft Fabric** needs a paid capacity (F2 minimum, ~$262/month) with no true pay-per-use tier.
- **Serverless SQL pool** has *no* capacity to provision at all — it exists the instant the workspace does, and you're billed per terabyte scanned, only when you actually run a query. Closest match to AWS Athena's cost model.

---

## ✅ Prerequisites — Do These Before Touching Azure

### A.1 — Accounts and Tools Required

| Requirement | Details | How to Get It |
|---|---|---|
| **Azure Account** | Pay-As-You-Go or free trial | [azure.microsoft.com](https://azure.microsoft.com) |
| **YouTube Data API v3 key** | Free, from Google Cloud Console | [console.cloud.google.com](https://console.cloud.google.com) → APIs & Services → Credentials → Create API Key, then enable "YouTube Data API v3" for the project |
| **A Gmail account for alerts** | Any Gmail address you own | — |
| **This repo, cloned locally** | Contains all the application code you'll containerize | `jobs/ingest/`, `jobs/raw_transform/`, `dbt/`, `dashboard/` |

> ⚠️ **You will need Azure Cloud Shell for a handful of steps** — building Docker images, running one SQL setup script, and creating an app registration. These cannot be done with pure mouse clicks (no cloud lets you build a container image by clicking buttons), but Cloud Shell is built directly into the Azure Portal — no local install needed. Click the `>_` icon in the top toolbar of [portal.azure.com](https://portal.azure.com) to open it, choose **Bash**.

### A.2 — Pick a Region: `centralus`, Not `eastus`

> ⚠️ **This matters and is easy to get wrong.** New Azure subscriptions can hit a restriction called `SqlServerRegionDoesNotAllowProvisioning` in `eastus` — a fraud-prevention block on new SQL-server provisioning (Synapse workspaces create a logical SQL server under the hood, so this blocks Synapse creation specifically, confirmed on a real subscription). **`centralus` is confirmed clear.** Use `centralus` for every single resource in this guide.

### A.3 — Cost Awareness

> 💡 Almost everything here is consumption-priced (pay only when running): Container Apps Jobs, Synapse serverless SQL, Log Analytics (5GB/month free). The two things with *any* standing cost are the ADLS Gen2 storage account (pennies/GB/month) and the always-on dashboard Container App (one small instance, a few dollars/month). There is no idle-billing trap anywhere in this design — unlike a literal AKS or dedicated-SQL-pool port would have.

---

## Phase 0 — Resource Group

**Goal:** Create the one resource group everything in this project lives inside.

**Time estimate:** 2 minutes

1. Go to **Azure Portal → Resource groups → Create**
2. Fill in:
   - **Subscription:** your subscription
   - **Resource group:** `HAMZA-RESOURCE-GROUP` (or your own name — just use it consistently for every step below)
   - **Region:** `Central US`
3. Click **Review + create → Create**

---

## Phase 1 — Storage Account (ADLS Gen2)

**Goal:** Create the data lake storage account with hierarchical namespace enabled (that's what makes it ADLS Gen2, not plain Blob Storage), plus the four containers and a lifecycle policy on staging.

**Time estimate:** 10 minutes

> ⚠️ **Hierarchical namespace must be enabled at creation — it cannot be turned on later.** Miss this checkbox and you'll have to delete and recreate the storage account.

### Step 1.1 — Create the Storage Account

1. Go to **Storage accounts → Create**
2. **Basics tab:**
   - **Resource group:** `HAMZA-RESOURCE-GROUP`
   - **Storage account name:** something globally unique, lowercase, no hyphens — e.g. `ytpipelinedatalake01`
   - **Region:** `Central US`
   - **Performance:** Standard
   - **Redundancy:** Locally-redundant storage (LRS) — cheapest, fine for this project
3. **Advanced tab:**
   - **Enable hierarchical namespace:** ✅ **check this** — this is the ADLS Gen2 switch
4. Click **Review + create → Create**

### Step 1.2 — Create the Four Containers

1. Open your new storage account → left menu → **Containers**
2. Click **+ Container**, create each of these one at a time (all **Private** access level):

| Container Name | Purpose |
|---|---|
| `staging` | Raw JSON from the YouTube API, no schema |
| `raw` | Delta tables, append-only ingestion log |
| `curated` | Delta tables, cleaned/deduped |
| `enriched` | Delta tables, the analytics data mart |

### Step 1.3 — Add a Lifecycle Rule on Staging

Staging's raw ingestion history isn't useful after ~90 days — this tiers it down automatically instead of paying standard rates forever.

1. Left menu → **Lifecycle management → + Add a rule**
2. **Rule name:** `staging-archive` | **Rule scope:** Limit blobs with filters
3. **Blob type:** Block blobs | **Blob subtype:** Base blobs
4. **Filter set → Prefix:** `staging/`
5. **Base blobs tab:**
   - Move to cool storage after **30** days since modification
   - Move to archive storage after **90** days since modification
6. Click **Add**

---

## Phase 2 — Azure Container Registry

**Goal:** Create the registry that will hold your four Docker images.

**Time estimate:** 5 minutes

1. Go to **Container registries → Create**
2. Fill in:
   - **Resource group:** `HAMZA-RESOURCE-GROUP`
   - **Registry name:** globally unique — e.g. `ytpipelineacr01`
   - **Location:** `Central US`
   - **SKU:** **Basic** (cheapest tier that supports private repos — plenty for 4 low-traffic images)
3. Click **Review + create → Create**
4. Once created, open it → **Access keys** → note the **Login server** (looks like `ytpipelineacr01.azurecr.io`) — you'll need this constantly.

> 💡 **Admin user stays disabled.** Every compute component pulls images using its own Managed Identity (granted the `AcrPull` role in Phase 4), not a shared admin password.

---

## Phase 3 — Key Vault

**Goal:** Create the secret store and add the two secrets this project actually needs.

**Time estimate:** 10 minutes

### Step 3.1 — Create the Key Vault

1. Go to **Key vaults → Create**
2. Fill in:
   - **Resource group:** `HAMZA-RESOURCE-GROUP`
   - **Key vault name:** globally unique — e.g. `ytpl-kv-01`
   - **Region:** `Central US`
   - **Pricing tier:** Standard
3. **Access configuration tab:**
   - **Permission model:** select **Azure role-based access control (RBAC)** — not the older "Vault access policy" model. This matters: everything in this guide grants access via Azure RBAC role assignments, and the two models don't mix cleanly.
4. Click **Review + create → Create**

### Step 3.2 — Grant Yourself Access to Add Secrets

1. Open the vault → **Access control (IAM) → + Add → Add role assignment**
2. **Role:** `Key Vault Secrets Officer`
3. **Assign access to:** User, group, or service principal → select your own account
4. Click **Review + assign**

> ⚠️ Wait **1-2 minutes** for this role assignment to propagate before continuing — Azure RBAC changes aren't instant.

### Step 3.3 — Add the Secrets

1. Left menu → **Objects → Secrets → + Generate/Import**
2. Create these two:

| Secret Name | Value |
|---|---|
| `youtube-api-key` | Your YouTube Data API v3 key from Prerequisites |
| `dashboard-trigger-api-key` | Any random string — e.g. generate one at [random.org](https://www.random.org/strings/) or run `openssl rand -hex 32` in Cloud Shell |

---

## Phase 4 — Managed Identities + Service Principal

**Goal:** Create one User-Assigned Managed Identity per compute component, plus the one Service Principal this project genuinely needs (explained below), and wire up every RBAC grant they need.

**Time estimate:** 30-40 minutes — this is the most detail-heavy phase, and getting it right here avoids a long chain of permission-denied errors later.

> 💡 **Why five identities and not one shared identity?** Least privilege — the ingest job never needs to touch Synapse, the dashboard never needs to write to storage. Matching AWS's one-IAM-role-per-Lambda pattern.

### Step 4.1 — Create the Five Managed Identities

1. Go to **Managed Identities → Create**
2. **Resource group:** `HAMZA-RESOURCE-GROUP` | **Region:** `Central US`
3. Create one at a time with these names:

| Identity Name | Used By |
|---|---|
| `yt-pipeline-ingest-identity` | ingest job |
| `yt-pipeline-raw-transform-identity` | raw-transform job |
| `yt-pipeline-dbt-identity` | dbt job (storage access only — see Phase 9 for why its Synapse SQL connection needs a *different* identity type) |
| `yt-pipeline-dashboard-identity` | dashboard app |
| `yt-pipeline-logicapp-identity` | the Logic App itself |

### Step 4.2 — Storage RBAC

For each identity below, go to your **storage account → Access control (IAM) → + Add → Add role assignment**, pick the role, then under **Members** choose **Managed identity → select the identity**.

| Identity | Role |
|---|---|
| `yt-pipeline-ingest-identity` | Storage Blob Data Contributor |
| `yt-pipeline-raw-transform-identity` | Storage Blob Data Contributor |
| `yt-pipeline-dbt-identity` | Storage Blob Data Contributor |
| `yt-pipeline-dashboard-identity` | Storage Blob Data Reader |

### Step 4.3 — Key Vault RBAC

On your **Key Vault → Access control (IAM)**, grant **Key Vault Secrets User** to:
- `yt-pipeline-ingest-identity`
- `yt-pipeline-dashboard-identity`
- `yt-pipeline-logicapp-identity`

### Step 4.4 — ACR Pull RBAC

On your **Container Registry → Access control (IAM)**, grant **AcrPull** to all four compute identities: `yt-pipeline-ingest-identity`, `yt-pipeline-raw-transform-identity`, `yt-pipeline-dbt-identity`, `yt-pipeline-dashboard-identity`.

### Step 4.5 — The One Service Principal: `yt-pipeline-dbt-sp`

> ⚠️ **Read this before skipping ahead — it's the single most confusing part of this whole build, discovered only by actually testing it.**
>
> Every other component in this project uses a Managed Identity — no stored secret, fully passwordless. dbt's connection to Synapse is the **one deliberate exception**, forced by two stacked, confirmed platform limitations:
>
> 1. The ODBC driver's native Managed-Identity authentication mode expects the classic Azure VM instance-metadata endpoint (`169.254.169.254`). Container Apps exposes identity through a *different*, App-Service-style local endpoint instead — the driver's built-in code doesn't know about that path, so it just hangs and times out (`Login timeout expired`).
> 2. Plain SQL username/password login is *also* blocked — the specific dbt-Synapse adapter version used here internally reuses Microsoft's dbt-Fabric connection code, which hard-refuses SQL authentication outright (`SQL Authentication is not supported by Microsoft Fabric`), even though you're really talking to Synapse, not Fabric.
>
> The one AAD auth mode that works from inside a container, because it needs neither instance metadata nor SQL auth, is a real **Service Principal** using the client-credentials OAuth flow. That's what this step creates.

1. Go to **Microsoft Entra ID → App registrations → + New registration**
2. **Name:** `yt-pipeline-dbt-sp` | leave everything else default → **Register**
3. Copy the **Application (client) ID** and **Directory (tenant) ID** from the Overview page — you'll need both shortly.
4. Left menu → **Certificates & secrets → Client secrets → + New client secret**
5. **Description:** `dbt-synapse-connection` | **Expires:** 12 months
6. Click **Add**, then **immediately copy the secret's Value** (it's only shown once)

### Step 4.6 — Store the Service Principal's Secret in Key Vault

1. Go back to your **Key Vault → Secrets → + Generate/Import**
2. **Name:** `dbt-sp-client-secret` | **Value:** the secret you just copied

---

## Phase 5 — Log Analytics Workspace

**Goal:** Create the workspace every container's logs will flow into.

**Time estimate:** 5 minutes

1. Go to **Log Analytics workspaces → Create**
2. **Resource group:** `HAMZA-RESOURCE-GROUP` | **Name:** `yt-pipeline-logs` | **Region:** `Central US`
3. Click **Review + create → Create**
4. Once created, open it → **Overview** → copy the **Workspace ID** (a GUID) — you'll need it for every log query in this guide and in Troubleshooting.

---

## Phase 6 — Container Apps Environment

**Goal:** Create the shared serverless runtime that both the Jobs and the dashboard live inside.

**Time estimate:** 5 minutes

1. Go to **Container Apps → Container Apps Environments → Create**
2. **Resource group:** `HAMZA-RESOURCE-GROUP` | **Name:** `yt-pipeline-env` | **Region:** `Central US`
3. **Logs Destination tab:** Log Analytics → select `yt-pipeline-logs` (created in Phase 5)
4. Click **Review + create → Create**

---

## Phase 7 — Build & Push Container Images

**Goal:** Get all four Docker images (already written in this repo) into your Container Registry.

**Time estimate:** 15 minutes

> 💡 **Why Cloud Shell here, not a local Docker install?** Two reasons: it needs zero local setup, and it sidesteps a real, confirmed problem — local Docker Desktop's newer "containerd" image store produces a manifest format some Azure services reject. `az acr build` builds *in the cloud*, avoiding that entirely, and is the officially recommended path either way.

1. Open **Cloud Shell** (the `>_` icon, top-right of the Portal) → choose **Bash**
2. Upload this repo, or clone it if it's on GitHub:
   ```bash
   git clone <your-repo-url>
   cd Youtube-Data-Pipeline-using-Python-and-Azure
   ```
3. Build and push all four images (replace `ytpipelineacr01` with your actual registry name):

```bash
ACR=ytpipelineacr01

az acr build --registry $ACR --image yt-ingest:v1 ./jobs/ingest
az acr build --registry $ACR --image yt-raw-transform:v1 ./jobs/raw_transform
az acr build --registry $ACR --image yt-dbt:v1 ./dbt
az acr build --registry $ACR --image yt-dashboard:v1 ./dashboard
```

> ⚠️ Each build takes 1-2 minutes. Wait for `Run ID: ... Succeeded` before moving to the next one. If you see a manifest/JSON-related crash in the Cloud Shell output but the run still shows `Succeeded` when you check, it's a known cosmetic terminal-encoding glitch in some `az` CLI versions — verify with `az acr repository show-tags --name $ACR --repository yt-dbt` instead of trusting the crash.

---

## Phase 8 — Container Apps Jobs + Dashboard

**Goal:** Create the three run-to-completion Jobs and the one always-on dashboard Container App.

**Time estimate:** 30 minutes

> ⚠️ **Images must already exist in ACR before you create the Jobs (Phase 7 first).** Referencing a tag that doesn't exist yet fails Job creation outright — there's no "create now, push the image later" order that works.

### Step 8.1 — Get Your Synapse Endpoint Ready (placeholder for now)

You'll need a Synapse SQL endpoint string for these Jobs' environment variables, but Synapse doesn't exist until Phase 9. **Use a placeholder now** (e.g., `placeholder.sql.azuresynapse.net`) and come back to update it after Phase 9 — every Job/App below has an environment variable update step noted for exactly this.

### Step 8.2 — Create the `yt-pipeline-ingest` Job

1. Go to **Container Apps → Container Apps Jobs → Create**
2. **Basics:** Resource group `HAMZA-RESOURCE-GROUP` | Name `yt-pipeline-ingest` | Region `Central US` | Container Apps Environment: `yt-pipeline-env`
3. **Job type:** Manual trigger — this Job is started by the Logic App, not on its own schedule
4. **Trigger tab:** Replica timeout: `300` seconds | Replica retry limit: `0`
5. **Container tab:**
   - Image source: **Azure Container Registry** → your registry → `yt-ingest:v1`
   - CPU/Memory: 0.5 CPU, 1 Gi
   - **Environment variables:**

| Name | Value |
|---|---|
| `STORAGE_ACCOUNT_NAME` | your storage account name |
| `YOUTUBE_REGIONS` | `US,GB,CA,DE,FR,IN,JP,KR,MX,RU` |
| `KEY_VAULT_URI` | `https://<your-vault-name>.vault.azure.net/` |
| `AZURE_CLIENT_ID` | the **Client ID** of `yt-pipeline-ingest-identity` (find it on the identity's Overview page) |

6. **Identity tab:** Add → User assigned → `yt-pipeline-ingest-identity` (this is also what pulls the image — select it under "Registry authentication" too)
7. Click **Review + create → Create**

### Step 8.3 — Create the `yt-pipeline-raw-transform` Job

Same process as 8.2, with:
- **Name:** `yt-pipeline-raw-transform` | Replica timeout: `600` | CPU/Memory: 1.0 CPU, 2 Gi
- Image: `yt-raw-transform:v1`
- Identity: `yt-pipeline-raw-transform-identity`
- Env vars: `STORAGE_ACCOUNT_NAME`, `AZURE_CLIENT_ID` (this identity's client ID)

### Step 8.4 — Create the `yt-pipeline-dbt` Job

- **Name:** `yt-pipeline-dbt` | Replica timeout: `900` | CPU/Memory: 1.0 CPU, 2 Gi
- Image: `yt-dbt:v1`
- Identity: `yt-pipeline-dbt-identity` (for storage + ACR pull)
- **Secrets tab** (this Job needs 2 secrets, not just env vars):

| Secret Name | Value |
|---|---|
| `dbt-sp-client-secret` | the Service Principal secret from Phase 4.5 |

- **Environment variables:**

| Name | Value |
|---|---|
| `SYNAPSE_SERVER` | placeholder for now, update after Phase 9 |
| `STORAGE_ACCOUNT_NAME` | your storage account name |
| `AZURE_CLIENT_ID` | `yt-pipeline-dbt-identity`'s client ID |
| `AZURE_TENANT_ID` | your tenant ID from Phase 4.5 |
| `DBT_SP_CLIENT_ID` | `yt-pipeline-dbt-sp`'s application (client) ID from Phase 4.5 |
| `DBT_SP_CLIENT_SECRET` | reference the secret above (in the Portal: choose "Reference a secret" for this variable) |

### Step 8.5 — Create the `yt-pipeline-dashboard` Container App

This one is a regular always-on **Container App**, not a Job.

1. **Container Apps → Create**
2. **Name:** `yt-pipeline-dashboard` | Environment: `yt-pipeline-env`
3. **Container tab:** Image `yt-dashboard:v1` | CPU/Memory 0.5/1 Gi
4. **Ingress tab:** Enabled ✅ | Ingress traffic: **Accepting traffic from anywhere** | Target port: `8080`
5. **Identity:** User-assigned → `yt-pipeline-dashboard-identity`
6. **Scale tab:** Min replicas: `1` (keeps one instance always warm, avoiding cold-start on every visit) | Max replicas: `2`
7. **Environment variables:**

| Name | Value |
|---|---|
| `SYNAPSE_SERVER` | placeholder for now |
| `KEY_VAULT_URI` | your vault's URI |
| `AZURE_CLIENT_ID` | `yt-pipeline-dashboard-identity`'s client ID |
| `LOGIC_APP_TRIGGER_URL` | placeholder for now, update after Phase 11 |

8. Click **Create**. Once running, note the app's public **Application Url** from the Overview page.

---

## Phase 9 — Synapse Analytics Workspace

**Goal:** Create the serverless SQL engine that reads your Delta Lake files.

**Time estimate:** 15 minutes + a few minutes for provisioning

> ⚠️ Region must be **Central US** — see Prerequisites A.2 for why.

### Step 9.1 — Create a Storage Account for Synapse's Own Metadata

Synapse needs its own small ADLS Gen2 account for workspace metadata — separate from your project's data lake.

1. **Storage accounts → Create** → Name e.g. `ytplsynapsemeta01` | Region `Central US` | **Enable hierarchical namespace ✅**
2. Create it, then inside it create one container: `synapsefs`

### Step 9.2 — Create the Synapse Workspace

1. Go to **Azure Synapse Analytics → Create**
2. **Basics:** Resource group `HAMZA-RESOURCE-GROUP` | Workspace name `ytpl-synapse-01` | Region `Central US`
3. **Account Settings:** Select the storage account from 9.1, filesystem `synapsefs`
4. **Security tab:** Set a SQL admin login (`synadmin`) and a strong password — **write this down**, you'll use it repeatedly
5. Click **Review + create → Create** (takes 3-5 minutes)

### Step 9.3 — Grant the Workspace's Own Identity Storage Access

> ⚠️ **This is a genuinely easy step to miss, and everything downstream silently fails without it.** The workspace gets its own system-assigned Managed Identity automatically — and the `CREATE DATABASE SCOPED CREDENTIAL ... WITH IDENTITY = 'Managed Identity'` statement you'll run in Phase 10 uses *this* identity, not any of the ones from Phase 4. Without this grant, every query against an external table fails with `Content of directory ... cannot be listed`.

1. Open your Synapse workspace → **Identity** (left menu) → confirm **System assigned** is On, copy the **Object (principal) ID**
2. Go to your **data-lake storage account** (from Phase 1, not the Synapse metadata one) → **Access control (IAM) → + Add role assignment**
3. **Role:** Storage Blob Data Contributor | **Assign access to:** Managed identity → select your Synapse workspace

### Step 9.4 — Allow Your Own IP to Connect

1. Synapse workspace → **Networking → Firewall rules → + Add client IP**
2. This adds your current public IP automatically — click **Save**

> 💡 If you ever get `Client with IP address ... is not allowed to access the server`, your IP changed (common on home ISPs) — just repeat this step with the new IP.

### Step 9.5 — Update Your Placeholder Environment Variables

Now that Synapse exists, go back and update the `SYNAPSE_SERVER` placeholder everywhere you left one:

1. Get the endpoint: Synapse workspace → **Overview** → **Serverless SQL endpoint** (looks like `ytpl-synapse-01-ondemand.sql.azuresynapse.net`)
2. Update this env var on: `yt-pipeline-dbt` Job (Phase 8.4), `yt-pipeline-dashboard` app (Phase 8.5)

---

## Phase 10 — Synapse Database Setup

**Goal:** Create a dedicated database, register your storage as an external data source, define external tables over your Delta files, and grant every principal the exact permissions it needs.

**Time estimate:** 20 minutes

> ⚠️ **Everything in this phase must run inside a dedicated database, never `master`.** Synapse serverless flatly refuses `CREATE EXTERNAL TABLE`, `CREATE USER`, and `CREATE DATABASE SCOPED CREDENTIAL` inside `master` (`"...is not supported in master database"`). The very first statement below creates that dedicated database — don't skip it.

### Step 10.1 — Open Synapse Studio

1. Synapse workspace → **Overview → Open Synapse Studio**
2. Left menu → **Develop → + → SQL script**
3. At the top of the script pane, make sure **Connect to** is set to **Built-in** (this is the serverless pool)

### Step 10.2 — Run the Setup Script

Paste and run each block below **one at a time** (Synapse Studio runs the whole pane as one batch by default — for statements marked "run separately," highlight just that statement and click **Run** on the selection instead of the whole script).

**Block 1 — create the dedicated database, then switch into it:**
```sql
CREATE DATABASE yt_pipeline;
```
Now, in the top toolbar, change the **Use database** dropdown from `master` to `yt_pipeline` before continuing.

**Block 2 — master key and credential** (replace `<STORAGE_ACCOUNT>` with your Phase 1 storage account name, run each statement separately):
```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'PickAStrongLocalPassword!2026';
```
```sql
CREATE DATABASE SCOPED CREDENTIAL ManagedIdentityCredential
WITH IDENTITY = 'Managed Identity';
```

**Block 3 — external data sources (one per container, run separately):**
```sql
CREATE EXTERNAL DATA SOURCE yt_pipeline_lake
WITH (LOCATION = 'abfss://raw@<STORAGE_ACCOUNT>.dfs.core.windows.net', CREDENTIAL = ManagedIdentityCredential);
```
```sql
CREATE EXTERNAL DATA SOURCE yt_pipeline_curated_lake
WITH (LOCATION = 'abfss://curated@<STORAGE_ACCOUNT>.dfs.core.windows.net', CREDENTIAL = ManagedIdentityCredential);
```
```sql
CREATE EXTERNAL DATA SOURCE yt_pipeline_enriched_lake
WITH (LOCATION = 'abfss://enriched@<STORAGE_ACCOUNT>.dfs.core.windows.net', CREDENTIAL = ManagedIdentityCredential);
```

**Block 4 — the Delta file format and the three schemas (run separately):**
```sql
CREATE EXTERNAL FILE FORMAT DeltaFormat WITH (FORMAT_TYPE = DELTA);
```
```sql
CREATE SCHEMA raw;
```
```sql
CREATE SCHEMA curated;
```
```sql
CREATE SCHEMA enriched;
```

**Block 5 — the seven external tables** (these can all run together as one batch):
```sql
CREATE EXTERNAL TABLE raw.raw_statistics (
    video_id varchar(50), title varchar(500), channel_title varchar(200),
    category_id varchar(10), publish_time varchar(50), trending_date_raw varchar(50),
    tags varchar(4000), views bigint, likes bigint, dislikes bigint,
    comment_count bigint, description varchar(4000), region varchar(10),
    source varchar(50), _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'raw_statistics/', DATA_SOURCE = yt_pipeline_lake, FILE_FORMAT = DeltaFormat);

CREATE EXTERNAL TABLE raw.raw_reference_data (
    id varchar(10), title varchar(200), region varchar(10),
    source varchar(50), _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'raw_reference_data/', DATA_SOURCE = yt_pipeline_lake, FILE_FORMAT = DeltaFormat);

CREATE EXTERNAL TABLE curated.curated_statistics (
    video_id varchar(50), title varchar(500), channel_title varchar(200),
    category_id varchar(10), publish_time varchar(50), region varchar(10),
    source varchar(50), trending_date_parsed date, tags varchar(4000),
    views bigint, likes bigint, dislikes bigint, comment_count bigint,
    description varchar(4000), like_ratio float, engagement_rate float,
    _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'curated_statistics/', DATA_SOURCE = yt_pipeline_curated_lake, FILE_FORMAT = DeltaFormat);

CREATE EXTERNAL TABLE curated.curated_reference_data (
    id varchar(10), category_name varchar(200), region varchar(10),
    _ingestion_timestamp varchar(50), _source_file varchar(500)
)
WITH (LOCATION = 'curated_reference_data/', DATA_SOURCE = yt_pipeline_curated_lake, FILE_FORMAT = DeltaFormat);

CREATE EXTERNAL TABLE enriched.trending_analytics (
    region varchar(10), trending_date_parsed date, total_videos bigint,
    total_views bigint, total_likes bigint, total_comments bigint,
    avg_engagement_rate float, avg_like_ratio float
)
WITH (LOCATION = 'trending_analytics/', DATA_SOURCE = yt_pipeline_enriched_lake, FILE_FORMAT = DeltaFormat);

CREATE EXTERNAL TABLE enriched.category_analytics (
    region varchar(10), trending_date_parsed date, category_id varchar(10),
    category_name varchar(200), total_videos bigint, total_views bigint,
    view_share_pct float
)
WITH (LOCATION = 'category_analytics/', DATA_SOURCE = yt_pipeline_enriched_lake, FILE_FORMAT = DeltaFormat);

CREATE EXTERNAL TABLE enriched.channel_analytics (
    channel_title varchar(200), region varchar(10), total_videos bigint,
    total_views bigint, avg_engagement_rate float, categories varchar(2000),
    rank_in_region bigint
)
WITH (LOCATION = 'channel_analytics/', DATA_SOURCE = yt_pipeline_enriched_lake, FILE_FORMAT = DeltaFormat);
```

### Step 10.3 — Grant Every Principal Its Permissions

> ⚠️ **This is the single densest gotcha chain in the whole project — five separate, real permission errors, each confirmed by an actual failed test run, are fixed by the five grants below.** Skipping any one of them produces a *different*, confusing error each time. Run every line.

Run these one statement at a time, for **both** `yt-pipeline-dbt-sp` (the Service Principal — the display name you set in Phase 4.5) and `yt-pipeline-dashboard-identity` (the Managed Identity):

```sql
CREATE USER [yt-pipeline-dbt-sp] FROM EXTERNAL PROVIDER;
CREATE USER [yt-pipeline-dashboard-identity] FROM EXTERNAL PROVIDER;

GRANT SELECT ON SCHEMA::raw TO [yt-pipeline-dbt-sp];
GRANT SELECT ON SCHEMA::curated TO [yt-pipeline-dbt-sp];
GRANT SELECT ON SCHEMA::enriched TO [yt-pipeline-dbt-sp];
GRANT SELECT ON SCHEMA::enriched TO [yt-pipeline-dashboard-identity];

-- Needed to query ANY external table that depends on the credential --
-- schema-level SELECT alone is not enough (confirmed against a real
-- "Cannot find the CREDENTIAL... or you do not have permission" error).
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::ManagedIdentityCredential TO [yt-pipeline-dbt-sp];
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::ManagedIdentityCredential TO [yt-pipeline-dashboard-identity];

-- dbt's test framework creates temporary views to run checks against --
-- CREATE VIEW alone isn't enough either; it also needs ALTER on the
-- specific schema the view gets placed in (confirmed against a real
-- "CREATE VIEW permission denied" then "specified schema name ...
-- does not exist or you do not have permission" pair of errors).
GRANT CREATE VIEW TO [yt-pipeline-dbt-sp];
GRANT ALTER ON SCHEMA::raw TO [yt-pipeline-dbt-sp];
GRANT ALTER ON SCHEMA::curated TO [yt-pipeline-dbt-sp];
GRANT ALTER ON SCHEMA::enriched TO [yt-pipeline-dbt-sp];
```

> 💡 **Important — `CREATE USER ... FROM EXTERNAL PROVIDER` only works if you're connected to Synapse Studio with your own Azure AD login** (which you are, by default, when using Synapse Studio's web UI — this is exactly why we're doing this step here and not via the SQL admin login). If you ever try to run this same statement via a plain SQL-authenticated connection, it fails with `Only connections established with Active Directory accounts can create other Active Directory users.`

---

## Phase 11 — Logic App Orchestration

**Goal:** Build the hourly-scheduled workflow that runs Ingest → Raw-Transform → dbt in sequence, with failure notifications at every step.

**Time estimate:** 30-40 minutes

> 💡 On AWS this same job needs two services (EventBridge for the schedule, Step Functions for the workflow). A Logic App is both at once — the trigger *is* the entry point into the same resource that holds the workflow.

### Step 11.1 — Create the Logic App

1. Go to **Logic Apps → Create**
2. **Resource group:** `HAMZA-RESOURCE-GROUP` | **Name:** `yt-pipeline-orchestration` | **Region:** `Central US`
3. **Plan type:** Consumption (pay-per-execution — the cheapest, and all this workflow needs)
4. Click **Review + create → Create**

### Step 11.2 — Attach the Logic App's Managed Identity

1. Open the Logic App → **Identity** (left menu) → **User assigned tab → + Add**
2. Select `yt-pipeline-logicapp-identity`

### Step 11.3 — Grant the Logic App Permission to Run Each Job

For **each** of the three Container Apps Jobs (`yt-pipeline-ingest`, `yt-pipeline-raw-transform`, `yt-pipeline-dbt`):
1. Open the Job → **Access control (IAM) → + Add role assignment**
2. **Role:** Contributor | **Assign access to:** Managed identity → `yt-pipeline-logicapp-identity`

### Step 11.4 — Set Up the Gmail Connection

Do this now, before building the workflow, so it's available to select in the next step.

1. In the Logic App, go to **Logic app designer** (or **Workflows → your workflow → Designer**)
2. Search the connector gallery for **Gmail** and select the **"Send email (V2)"** action once (you can delete it after — this step's only purpose is to create the underlying connection)
3. Click **Sign in** and authorize with your Gmail account from Prerequisites A.1 — a real browser OAuth consent screen, one-time only
4. Once authorized, you can remove that placeholder action — the connection itself now persists under **API Connections** in your resource group and is ready to reference

> ⚠️ **This authorization is a genuinely manual, one-time human step — it cannot be scripted or automated**, the same way AWS SNS needs a one-time "confirm subscription" email click. Do it here, once, and never again.

### Step 11.5 — Build the Workflow (Code View)

The workflow's branching logic (start a job → poll until done → check success/failure → notify) is easiest to get exactly right by pasting it as one block, then reviewing it visually in the Designer afterward.

1. In your Logic App, go to **Development Tools → Logic app code view**
2. Replace the entire contents with the JSON below — but first, replace every placeholder:
   - `<SUBSCRIPTION_ID>` — find it under **Subscriptions** in the Portal search bar
   - `<RESOURCE_GROUP>` — `HAMZA-RESOURCE-GROUP`
   - `<LOGICAPP_IDENTITY_RESOURCE_ID>` — open `yt-pipeline-logicapp-identity` → copy its full Resource ID from the Overview/JSON view (looks like `/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/yt-pipeline-logicapp-identity`)
   - `<YOUR_GMAIL_ADDRESS>` — where alert emails should go

```json
{
  "definition": {
    "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
      "$connections": { "type": "Object", "defaultValue": {} }
    },
    "triggers": {
      "Hourly": {
        "type": "Recurrence",
        "recurrence": { "frequency": "Hour", "interval": 1 }
      }
    },
    "actions": {
      "Start_Ingest_Job": {
        "type": "Http",
        "runAfter": {},
        "inputs": {
          "method": "POST",
          "uri": "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.App/jobs/yt-pipeline-ingest/start?api-version=2024-03-01",
          "authentication": { "type": "ManagedServiceIdentity", "identity": "<LOGICAPP_IDENTITY_RESOURCE_ID>" }
        }
      },
      "Poll_Ingest_Job": {
        "type": "Until",
        "runAfter": { "Start_Ingest_Job": ["Succeeded"] },
        "expression": "@or(equals(body('Get_Ingest_Status')?['properties']?['status'], 'Succeeded'), equals(body('Get_Ingest_Status')?['properties']?['status'], 'Failed'))",
        "limit": { "count": 40, "timeout": "PT10M" },
        "actions": {
          "Wait_Ingest": { "type": "Wait", "runAfter": {}, "inputs": { "interval": { "unit": "Second", "count": 15 } } },
          "Get_Ingest_Status": {
            "type": "Http",
            "runAfter": { "Wait_Ingest": ["Succeeded"] },
            "inputs": {
              "method": "GET",
              "uri": "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.App/jobs/yt-pipeline-ingest/executions/@{body('Start_Ingest_Job')?['name']}?api-version=2024-03-01",
              "authentication": { "type": "ManagedServiceIdentity", "identity": "<LOGICAPP_IDENTITY_RESOURCE_ID>" }
            }
          }
        }
      },
      "Check_Ingest_Result": {
        "type": "If",
        "runAfter": { "Poll_Ingest_Job": ["Succeeded"] },
        "expression": { "equals": ["@body('Get_Ingest_Status')?['properties']?['status']", "Succeeded"] },
        "actions": {
          "Start_RawTransform_Job": {
            "type": "Http",
            "runAfter": {},
            "inputs": {
              "method": "POST",
              "uri": "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.App/jobs/yt-pipeline-raw-transform/start?api-version=2024-03-01",
              "authentication": { "type": "ManagedServiceIdentity", "identity": "<LOGICAPP_IDENTITY_RESOURCE_ID>" }
            }
          },
          "Poll_RawTransform_Job": {
            "type": "Until",
            "runAfter": { "Start_RawTransform_Job": ["Succeeded"] },
            "expression": "@or(equals(body('Get_RawTransform_Status')?['properties']?['status'], 'Succeeded'), equals(body('Get_RawTransform_Status')?['properties']?['status'], 'Failed'))",
            "limit": { "count": 60, "timeout": "PT20M" },
            "actions": {
              "Wait_RawTransform": { "type": "Wait", "runAfter": {}, "inputs": { "interval": { "unit": "Second", "count": 15 } } },
              "Get_RawTransform_Status": {
                "type": "Http",
                "runAfter": { "Wait_RawTransform": ["Succeeded"] },
                "inputs": {
                  "method": "GET",
                  "uri": "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.App/jobs/yt-pipeline-raw-transform/executions/@{body('Start_RawTransform_Job')?['name']}?api-version=2024-03-01",
                  "authentication": { "type": "ManagedServiceIdentity", "identity": "<LOGICAPP_IDENTITY_RESOURCE_ID>" }
                }
              }
            }
          },
          "Check_RawTransform_Result": {
            "type": "If",
            "runAfter": { "Poll_RawTransform_Job": ["Succeeded"] },
            "expression": { "equals": ["@body('Get_RawTransform_Status')?['properties']?['status']", "Succeeded"] },
            "actions": {
              "Start_Dbt_Job": {
                "type": "Http",
                "runAfter": {},
                "inputs": {
                  "method": "POST",
                  "uri": "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.App/jobs/yt-pipeline-dbt/start?api-version=2024-03-01",
                  "authentication": { "type": "ManagedServiceIdentity", "identity": "<LOGICAPP_IDENTITY_RESOURCE_ID>" }
                }
              },
              "Poll_Dbt_Job": {
                "type": "Until",
                "runAfter": { "Start_Dbt_Job": ["Succeeded"] },
                "expression": "@or(equals(body('Get_Dbt_Status')?['properties']?['status'], 'Succeeded'), equals(body('Get_Dbt_Status')?['properties']?['status'], 'Failed'))",
                "limit": { "count": 60, "timeout": "PT20M" },
                "actions": {
                  "Wait_Dbt": { "type": "Wait", "runAfter": {}, "inputs": { "interval": { "unit": "Second", "count": 15 } } },
                  "Get_Dbt_Status": {
                    "type": "Http",
                    "runAfter": { "Wait_Dbt": ["Succeeded"] },
                    "inputs": {
                      "method": "GET",
                      "uri": "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.App/jobs/yt-pipeline-dbt/executions/@{body('Start_Dbt_Job')?['name']}?api-version=2024-03-01",
                      "authentication": { "type": "ManagedServiceIdentity", "identity": "<LOGICAPP_IDENTITY_RESOURCE_ID>" }
                    }
                  }
                }
              },
              "Check_Dbt_Result": {
                "type": "If",
                "runAfter": { "Poll_Dbt_Job": ["Succeeded"] },
                "expression": { "equals": ["@body('Get_Dbt_Status')?['properties']?['status']", "Succeeded"] },
                "actions": {
                  "Notify_Success": {
                    "type": "ApiConnection",
                    "runAfter": {},
                    "inputs": {
                      "method": "post",
                      "path": "/v2/Mail",
                      "host": { "connection": { "name": "@parameters('$connections')['gmail']['connectionId']" } },
                      "body": { "To": "<YOUR_GMAIL_ADDRESS>", "Subject": "[YT Pipeline] SUCCESS", "Body": "Pipeline run completed successfully." }
                    }
                  }
                },
                "else": {
                  "actions": {
                    "Notify_Dbt_Failure": {
                      "type": "ApiConnection",
                      "runAfter": {},
                      "inputs": {
                        "method": "post",
                        "path": "/v2/Mail",
                        "host": { "connection": { "name": "@parameters('$connections')['gmail']['connectionId']" } },
                        "body": { "To": "<YOUR_GMAIL_ADDRESS>", "Subject": "[YT Pipeline] FAILURE -- dbt build failed", "Body": "@{string(body('Get_Dbt_Status'))}" }
                      }
                    }
                  }
                }
              }
            },
            "else": {
              "actions": {
                "Notify_RawTransform_Failure": {
                  "type": "ApiConnection",
                  "runAfter": {},
                  "inputs": {
                    "method": "post",
                    "path": "/v2/Mail",
                    "host": { "connection": { "name": "@parameters('$connections')['gmail']['connectionId']" } },
                    "body": { "To": "<YOUR_GMAIL_ADDRESS>", "Subject": "[YT Pipeline] FAILURE -- raw-transform failed", "Body": "@{string(body('Get_RawTransform_Status'))}" }
                  }
                }
              }
            }
          }
        },
        "else": {
          "actions": {
            "Notify_Ingest_Failure": {
              "type": "ApiConnection",
              "runAfter": {},
              "inputs": {
                "method": "post",
                "path": "/v2/Mail",
                "host": { "connection": { "name": "@parameters('$connections')['gmail']['connectionId']" } },
                "body": { "To": "<YOUR_GMAIL_ADDRESS>", "Subject": "[YT Pipeline] FAILURE -- ingest failed", "Body": "@{string(body('Get_Ingest_Status'))}" }
              }
            }
          }
        }
      }
    },
    "outputs": {}
  },
  "parameters": {
    "$connections": {
      "value": {
        "gmail": {
          "connectionId": "<GMAIL_API_CONNECTION_RESOURCE_ID>",
          "connectionName": "gmail",
          "id": "/subscriptions/<SUBSCRIPTION_ID>/providers/Microsoft.Web/locations/centralus/managedApis/gmail"
        }
      }
    }
  }
}
```

> 📋 To find `<GMAIL_API_CONNECTION_RESOURCE_ID>`: go to **Resource groups → HAMZA-RESOURCE-GROUP**, find the resource named `gmail` (type "API Connection"), open it, copy its full Resource ID from the **JSON View**.

3. Click **Save**

> ⚠️ **Every `Http` action's `authentication` block needs the explicit `"identity"` field pointing at your user-assigned identity's resource ID.** Omitting it makes the Logic App default to looking for a *system-assigned* identity that doesn't exist on this resource — confirmed against a real `InvalidWorkflowManagedIdentitySpecified` error otherwise.

### Step 11.6 — Update the Dashboard's Trigger URL

Now that the Logic App exists, go back to the `yt-pipeline-dashboard` Container App (Phase 8.5) and update its `LOGIC_APP_TRIGGER_URL` environment variable to:
```
https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.Logic/workflows/yt-pipeline-orchestration/triggers/Hourly/run?api-version=2019-05-01
```

---

## Phase 12 — Gmail Notification Connector

> ⚠️ **Google Security Constraint (`GmailConnectorPolicyViolation`):** Azure Logic Apps prohibits mixing Gmail connector actions and generic `Http` REST actions (such as Azure management API calls to start Container Apps Jobs) inside the *same* workflow.
>
> **The Decoupled Notifier Architecture:** We use a dedicated, decoupled notifier Logic App (`yt-pipeline-notifier`) containing ONLY the Gmail connector action `Send email (V2)`. `yt-pipeline-orchestration` calls `yt-pipeline-notifier` via HTTP POST upon job completion.

### Step 12.1 — Create the `yt-pipeline-notifier` Logic App
1. Go to **Logic Apps → Create**
2. **Resource group:** `HAMZA-RESOURCE-GROUP` | **Name:** `yt-pipeline-notifier` | **Region:** `Central US` | **Plan:** Consumption
3. Click **Review + create → Create**

### Step 12.2 — Authorize Gmail API Connection
1. In `yt-pipeline-notifier`, open **Logic app designer**.
2. Add the **HTTP Request** trigger (When an HTTP request is received).
3. Add the **Gmail — Send email (V2)** action:
   - **To:** `muhammadhamzasiddiqui883@gmail.com`
   - **Subject:** `[YT Pipeline] SUCCESS`
   - **Body:** `Pipeline run completed successfully.`
4. Click **Sign in** to authorize your Gmail account (`muhammadhamzasiddiqui883@gmail.com`).
5. Click **Save**.

---


## Phase 13 — Power BI Dashboard

**Goal:** Connect Power BI Desktop to your Synapse serverless SQL endpoint and build a report over the `enriched` schema.

**Time estimate:** 20 minutes

1. Install **Power BI Desktop** (free) from [powerbi.microsoft.com](https://powerbi.microsoft.com)
2. Open it → **Get Data → Azure → Azure Synapse Analytics SQL**
3. **Server:** your serverless SQL endpoint from Phase 9.5 | **Database:** `yt_pipeline`
4. **Data Connectivity mode:** Import (loads a snapshot into Power BI — the closest equivalent to QuickSight's SPICE)
5. Sign in with your Azure AD account when prompted
6. In the Navigator, check the three tables under `enriched`: `trending_analytics`, `channel_analytics`, `category_analytics` → **Load**
7. Build visuals: a KPI card for total views, a bar chart of top channels, a pie chart of category share — matching the same shape as a typical QuickSight dashboard.

> 💡 Personal viewing/authoring in Power BI Desktop is entirely free. You only need a **Power BI Pro** license (~$10/month) if you want to publish and share this report with other people via the Power BI Service.

---

## Phase 14 — End-to-End Verification

**Goal:** Prove the whole pipeline actually works, start to finish.

### Step 14.1 — Trigger a Run Manually

1. Open your `yt-pipeline-dashboard` app's public URL (from Phase 8.5) in a browser
2. Log in with the Basic Auth prompt — any username, password = your `dashboard-trigger-api-key` secret value
3. Click **Trigger Pipeline Run**

### Step 14.2 — Watch It Progress

1. Go to **Logic Apps → yt-pipeline-orchestration → Overview → Runs history**
2. Click the newest run → watch each action turn green in sequence: `Start_Ingest_Job` → `Poll_Ingest_Job` → `Check_Ingest_Result` → (repeats for raw-transform, then dbt)

### Step 14.3 — Verify Data Landed

Back in **Synapse Studio → Develop → SQL script** (connected to `yt_pipeline`, Built-in pool):
```sql
SELECT COUNT(*) FROM raw.raw_statistics;
SELECT COUNT(*) FROM curated.curated_statistics;
SELECT COUNT(*) FROM enriched.trending_analytics;
SELECT COUNT(*) FROM enriched.channel_analytics;
SELECT COUNT(*) FROM enriched.category_analytics;
```

> ✅ All five should return real, non-zero row counts. If they do, the entire pipeline works end-to-end.

### Step 14.4 — Check Your Email

You should receive a `[YT Pipeline] SUCCESS` email within a few minutes of the run completing.

---

## Phase 15 — Cleanup & Cost Management

> ⚠️ Deleting the resource group deletes **everything** inside it, in one action. There is no undo.

1. Go to **Resource groups → HAMZA-RESOURCE-GROUP → Delete resource group**
2. Type the resource group's name to confirm → **Delete**
3. Separately, go to **Microsoft Entra ID → App registrations → yt-pipeline-dbt-sp → Delete** (App registrations live outside resource groups and aren't cleaned up by the step above)

---

## 🔧 Troubleshooting Guide

Every entry below is a real error hit while building this project for real, not a hypothetical.

| Error | Real Cause | Fix |
|---|---|---|
| `SqlServerRegionDoesNotAllowProvisioning` | New-subscription anti-fraud block on SQL-server provisioning in `eastus` specifically | Use `centralus` for every resource (see Prerequisites A.2) |
| `MANIFEST_UNKNOWN` when a Container App/Job tries to start | The image tag referenced doesn't exist in ACR yet | Build & push images (Phase 7) *before* creating Jobs/Apps that reference them |
| `InvalidWorkflowManagedIdentitySpecified` on a Logic App HTTP action | `authentication: ManagedServiceIdentity` defaults to a system-assigned identity that doesn't exist | Add the explicit `"identity": "<resource-id>"` field pointing at your user-assigned identity |
| `The workflow parameter '$connections' is not found` | Parameter *values* were set without first declaring the parameter's *schema* inside the workflow definition | Ensure `"parameters": {"$connections": {"type": "Object", "defaultValue": {}}}` exists inside `definition`, separate from the actual value |
| `Content of directory ... cannot be listed` | The Synapse workspace's own system-assigned identity has no storage RBAC | Grant it Storage Blob Data Contributor on your data-lake storage account (Phase 9.3) |
| `Login timeout expired (SQLDriverConnect)` from dbt | ODBC driver's native Managed-Identity auth expects the classic Azure-VM metadata endpoint; Container Apps uses a different one | Don't use MSI for dbt's Synapse connection — use the Service Principal setup in Phase 4.5/8.4 |
| `SQL Authentication is not supported by Microsoft Fabric` | This dbt-Synapse adapter version internally shares code with dbt-Fabric, which hard-blocks SQL auth | Same fix — Service Principal auth, not SQL login |
| `Cannot find the CREDENTIAL 'ManagedIdentityCredential' ... or you do not have permission` | Schema-level `SELECT` doesn't imply rights to use the credential an external table depends on | `GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::ManagedIdentityCredential TO [principal]` |
| `CREATE VIEW permission denied` | dbt's test framework creates temporary views; the connecting principal lacked that permission | `GRANT CREATE VIEW TO [principal]` |
| `The specified schema name "X" ... does not exist or you do not have permission to use it` (right after fixing CREATE VIEW) | `CREATE VIEW` permission alone doesn't let you place the view in a specific schema | `GRANT ALTER ON SCHEMA::<schema> TO [principal]` for every schema in use |
| Every `not_null` test returns NULL for a partitioned column | Delta tables written with `partition_by=["region"]` store that column only in the folder path (`region=us/...`), not inside the files — Synapse's external-table reader doesn't reconstruct Hive-partition columns | Don't partition Delta tables you plan to query through Synapse serverless external tables — write them flat |
| `Incorrect syntax near '='` from a `dbt_expectations` test | That package's T-SQL/Synapse dialect dispatch macros have real, confirmed gaps | Replace with hand-written custom generic tests (see `dbt/tests/generic/`) instead of relying on the package for range/row-count checks |
| `Cannot open server '...' requested by the login. Client with IP address '...' is not allowed` | Your public IP changed (common on home ISPs) since the last firewall rule was added | Synapse workspace → Networking → Firewall rules → Add client IP again |
| Gmail "Send email" action fails with an HTML-looking parse error | The connection was never authorized (or the OAuth token expired) | Resource groups → find the `gmail` API Connection → Edit API connection → Authorize |

---

## 📎 Quick Reference — All Resource Names

| Resource | Name Used in This Guide |
|---|---|
| Resource Group | `HAMZA-RESOURCE-GROUP` |
| Region | `Central US` |
| Storage Account (data lake) | `ytpipelinedatalake01` |
| Storage Account (Synapse metadata) | `ytplsynapsemeta01` |
| Container Registry | `ytpipelineacr01` |
| Key Vault | `ytpl-kv-01` |
| Log Analytics Workspace | `yt-pipeline-logs` |
| Container Apps Environment | `yt-pipeline-env` |
| Container Apps Jobs | `yt-pipeline-ingest`, `yt-pipeline-raw-transform`, `yt-pipeline-dbt` |
| Container App | `yt-pipeline-dashboard` |
| Managed Identities | `yt-pipeline-ingest-identity`, `yt-pipeline-raw-transform-identity`, `yt-pipeline-dbt-identity`, `yt-pipeline-dashboard-identity`, `yt-pipeline-logicapp-identity` |
| App Registration / Service Principal | `yt-pipeline-dbt-sp` |
| Synapse Workspace | `ytpl-synapse-01` |
| Synapse Database | `yt_pipeline` |
| Logic App | `yt-pipeline-orchestration` |
| Storage Containers | `staging`, `raw`, `curated`, `enriched` |
| Synapse Schemas | `raw`, `curated`, `enriched` |
