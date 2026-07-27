# Pinned to bookworm (Debian 12) -- see dbt/Dockerfile's comment; same
# apt-key removal issue applies here.
FROM python:3.12-slim-bookworm

# pyodbc -> Microsoft ODBC Driver 18 for SQL Server, same OS-level
# dependency as the dbt image, same modern signed-by keyring approach.
# See dbt/Dockerfile's comment -- source line written directly, not
# sed-rewritten from Microsoft's own list file (that produces two adjacent
# bracket groups, which apt rejects).
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg unixodbc-dev \
    && curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
