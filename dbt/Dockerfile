# Pinned to bookworm (Debian 12) explicitly -- "python:3.12-slim" floats to
# whatever Debian release is current (now trixie/13), which dropped apt-key
# entirely and breaks the MS ODBC driver install below. Pinning avoids that
# drift and matches packages.microsoft.com's debian/12 driver package.
FROM python:3.12-slim-bookworm

# dbt-synapse connects via pyodbc -> Microsoft ODBC Driver 18 for SQL
# Server, which isn't a pip package -- it's an OS-level driver Microsoft
# only ships via apt. gettext-base provides envsubst for profiles.yml
# templating (same pattern the AWS project's dbt image used for its own
# profiles.yml.template). Uses the modern signed-by keyring approach, not
# apt-key (deprecated/removed on current Debian).
# Source line written directly rather than downloading Microsoft's own
# prod.list and sed-rewriting it -- that file already ships its own
# [arch=...] bracket, and appending a second [signed-by=...] bracket via
# sed produces two adjacent bracket groups, which apt rejects as a
# malformed entry (confirmed against a real build failure). One bracket,
# both options together, is the only form apt accepts.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg unixodbc-dev gettext-base \
    && curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /dbt
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chmod +x entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
