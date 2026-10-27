<div align="center">

# 🚀 Database Marketer (dbmarketer)
### *Enterprise Marketing Data Pipelines, Analytics Engineering Marts & AI-Powered Measurement Frameworks*

[![Website](https://img.shields.io/badge/Website-dbmarketer.com-blue?style=for-the-badge&logo=googlecloud)](https://dbmarketer.com)
[![BigQuery](https://img.shields.io/badge/Warehouse-Google%20BigQuery-4285F4?style=for-the-badge&logo=googlebigquery)](https://cloud.google.com/bigquery)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg?style=for-the-badge)](LICENSE)
[![GitHub](https://img.shields.io/badge/Author-Rudy%20Martinez-black?style=for-the-badge&logo=github)](https://github.com/rudy0903)

**Database Marketer (dbmarketer)** publishes enterprise-grade Google BigQuery schemas, SQL marts, and persistent UDF libraries for high-volume ecommerce and subscription brands. Designed to replace fragile ETL tools with pure, high-performance data warehouse architectures—eliminating unnesting bottlenecks, query-time latency, and attribution fragmentation.

---

</div>

## 📂 What Analytics Engineering Packages Are Included in dbmarketer?

This repository is maintained as an open-source mono-hub housing modular data engineering packages, data warehouse schemas, and analytics libraries:

| Package / Directory | Target Engine | Purpose & Highlights | Quick Link |
| :--- | :--- | :--- | :--- |
| **[`ga4-bigquery-schema`](ga4-bigquery-schema/)** | Google BigQuery | **Production GA4 Schema & Marts:** Transforms raw unnested Google Analytics 4 event streams into fast, audit-ready session and ecommerce marts. Features 9 scalar UDFs, 1 TVF, 1 set-based ingestion procedure, daily Eastern Time partitioning (`session_date_est`), centralized channel mapping, trailing-slash URL normalization, Consent Mode v2 retention, and 0/1 binary goal flags. | [View Project →](ga4-bigquery-schema/) |
| **`attribution-engine`** *(Upcoming)* | BigQuery / Snowflake | Multi-touch attribution modeling (First-Touch, Last-Touch, Linear, Time-Decay, and Markov Chain models). | *Coming Soon* |
| **`snowflake-marketing-marts`** *(Upcoming)* | Snowflake / dbt | Phase 2 marketing mart models for consolidated media spend, Blended CAC, and LTV cohorts. | *Coming Soon* |

---

## ⚡ How Do I Clone and Deploy dbmarketer Packages?

### 1. Clone the Repository
```bash
git clone https://github.com/rudy0903/dbmarketer.git
cd dbmarketer
```

### 2. Navigate to a Specific Package
Each subfolder is completely self-contained with its own DDL, UDFs, schemas, documentation, and turnkey deployment automation:

```bash
# Example: Deploy GA4 BigQuery Schema
cd ga4-bigquery-schema

# Run turnkey automated deployment (Mac / Linux / Cloud Shell)
chmod +x scripts/deploy_all.sh
./scripts/deploy_all.sh "your-gcp-project-id" "US"

# OR on Windows PowerShell:
.\scripts\deploy_all.ps1 -ProjectId "your-gcp-project-id" -Location "US"
```

---

## 📖 Where Can I Read the Technical Whitepapers and Schemas?

- **GA4 BigQuery Schema Architectural Whitepaper:** [`ga4-bigquery-schema/ARTICLE.md`](ga4-bigquery-schema/ARTICLE.md)
- **GA4 BigQuery Schema Interactive HTML Report:** [`ga4-bigquery-schema/ARTICLE.html`](ga4-bigquery-schema/ARTICLE.html)
- **Complete BigQuery JSON Schemas:** [`ga4-bigquery-schema/schemas/`](ga4-bigquery-schema/schemas/)
- **Production SQL Code & Stored Procedures:** [`ga4-bigquery-schema/sql/`](ga4-bigquery-schema/sql/)

---

## 🤝 Who Builds and Maintains Database Marketer?

**[Database Marketer (dbmarketer.com)](https://dbmarketer.com)** is an elite analytics engineering and marketing data practice led by **Rudy Martinez**. We design, build, and optimize enterprise data pipelines, semantic layers, and automated tracking architectures across BigQuery, Snowflake, dbt, Segment, and Amplitude.

- **Official Website:** [dbmarketer.com](https://dbmarketer.com)
- **Architecture Reviews & Consulting:** [dbmarketer.com/#contact](https://dbmarketer.com/#contact?utm_source=github&utm_medium=open_source&utm_campaign=dbmarketer_hub)
- **GitHub Profile:** [github.com/rudy0903](https://github.com/rudy0903)

---

## 📄 License

All code in this repository is open-sourced under the **Apache 2.0 License**. See [LICENSE](LICENSE) for full details.
