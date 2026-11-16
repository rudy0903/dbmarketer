<div align="center">

# 🚀 Database Marketer (dbmarketer)
### *Enterprise Data Pipelines, Analytics Engineering Marts & Applied AI Systems*

[![Website](https://img.shields.io/badge/Website-dbmarketer.com-blue?style=for-the-badge&logo=googlecloud)](https://dbmarketer.com)
[![BigQuery](https://img.shields.io/badge/Warehouse-Google%20BigQuery-4285F4?style=for-the-badge&logo=googlebigquery)](https://cloud.google.com/bigquery)
[![License](https://img.shields.io/badge/License-Mixed%20Per--Package%20(See%20Licensing)-0ea5e9?style=for-the-badge)](#licensing)
[![GitHub](https://img.shields.io/badge/Author-Rudy%20Martinez-black?style=for-the-badge&logo=github)](https://github.com/rudy0903)

**Database Marketer (dbmarketer)** publishes open-source Google BigQuery warehouse utilities alongside source-available applied AI and machine learning portfolio demonstrations built by **Rudy Martinez**. Designed to connect trustworthy upstream data capture, governed warehouse modeling, and decision-ready analytics.

---

</div>

## 📂 Included Packages

This mono-repository houses modular data engineering utilities and runnable portfolio demonstrations under a **package-specific licensing model** (see [Licensing](#licensing) below):

| Package / Directory | Stack / Target Engine | Purpose & Highlights | Distribution Model | Quick Links |
| :--- | :--- | :--- | :--- | :--- |
| **[`ai-nutrition-intelligence`](ai-nutrition-intelligence/)** | React 19, Gemini, Zod, dbt, BigQuery ML, `node:sqlite` | **AI Nutrition & Ingredient Intelligence (Synthetic Showcase):** A privacy-safe, zero-credential demonstration of multimodal AI orchestration, governed Medallion pipelines (`Bronze -> Silver -> Gold`), and longitudinal analytics. Features a 3-stage conversational ambiguity Gatekeeper, `410/410` `Zod`-to-SQLite window parity (`seed = 20261114`), sanitized `XGBoost` & `ARIMA_PLUS` models, chronological holdouts, and `abs(r) >= 0.35` collinearity guardrails (`12/12` automated tests). | **Source-Available** ([Evaluation License](ai-nutrition-intelligence/LICENSE)) | [View Showcase ->](ai-nutrition-intelligence/) • [Read Case Study ->](https://dbmarketer.com/case-studies/ai-nutrition-intelligence) |
| **[`ga4-bigquery-schema`](ga4-bigquery-schema/)** | Google BigQuery | **Production GA4 Schema & Marts:** Transforms raw unnested Google Analytics 4 event streams into fast, audit-ready session and ecommerce marts. Features 10 scalar UDFs, 1 TVF, 1 metadata-driven hourly reconciliation procedure, daily Eastern Time partitioning (`session_date_est`), centralized channel mapping, trailing-slash URL normalization, Consent Mode v2 retention with explicit traffic typing, and 0/1 binary goal flags. | **Open-Source** ([Apache 2.0](LICENSE)) | [View SQL Code ->](ga4-bigquery-schema/) • [Read Web Playbook ->](https://dbmarketer.com/playbooks/ga4-bigquery-schema) |

---

## ⚡ Quickstart

### 1. Clone the Repository
```bash
git clone https://github.com/rudy0903/dbmarketer.git
cd dbmarketer
```

### 2. Navigate to a Specific Package
Each subfolder is self-contained with its own schemas, documentation, license terms, and execution scripts:

#### Option A: Run the AI Nutrition & Ingredient Intelligence Showcase (100% Offline, Zero Credentials)
```bash
cd ai-nutrition-intelligence

# Install dependencies (Node.js >= 22.5 required)
npm install

# Run the 12 automated verification specs & CLI pipeline walkthrough
npm test
npm run demo:pipeline

# Launch the interactive React 19 workbench at http://localhost:4173
npm run dev
```

#### Option B: Deploy the GA4 BigQuery Schema
```bash
cd ga4-bigquery-schema

# Run turnkey automated deployment (Mac / Linux / Cloud Shell)
chmod +x scripts/deploy_all.sh
./scripts/deploy_all.sh "your-gcp-project-id" "US"

# OR on Windows PowerShell:
.\scripts\deploy_all.ps1 -ProjectId "your-gcp-project-id" -Location "US"
```

---

## 📖 Documentation & Case Studies

### AI Nutrition & Ingredient Intelligence
- **Primary Case Study (Human Story, Product Decisions & Analytics):** [https://dbmarketer.com/case-studies/ai-nutrition-intelligence](https://dbmarketer.com/case-studies/ai-nutrition-intelligence)
- **Executive Case Study (`/work`):** [https://dbmarketer.com/work/ai-nutrition-intelligence](https://dbmarketer.com/work/ai-nutrition-intelligence)
- **Engineering Architecture Deep Dive (`/engineering`):** [https://dbmarketer.com/engineering/ai-nutrition-intelligence-architecture](https://dbmarketer.com/engineering/ai-nutrition-intelligence-architecture)
- **Runnable Synthetic Showcase & Tests:** [`ai-nutrition-intelligence/`](ai-nutrition-intelligence/)

### Production GA4 BigQuery Schema
- **Live Interactive Web Playbook:** [https://dbmarketer.com/playbooks/ga4-bigquery-schema](https://dbmarketer.com/playbooks/ga4-bigquery-schema)
- **GA4 BigQuery Schema Architectural Whitepaper (Markdown):** [ga4-bigquery-schema/ARTICLE.md](ga4-bigquery-schema/ARTICLE.md)
- **Complete BigQuery JSON Schemas:** [`ga4-bigquery-schema/schemas/`](ga4-bigquery-schema/schemas/)
- **Production SQL Code & Stored Procedures:** [`ga4-bigquery-schema/sql/`](ga4-bigquery-schema/sql/)

---

## 🤝 About Database Marketer

**[Database Marketer (dbmarketer.com)](https://dbmarketer.com)** is a principal analytics engineering, applied AI, and marketing data practice led by **Rudy Martinez**. We design, build, and govern data pipelines, semantic layers, experimentation architectures, and AI orchestration workflows across BigQuery, Snowflake, dbt, Segment, and Amplitude.

- **Official Website:** [dbmarketer.com](https://dbmarketer.com)
- **Case Studies:** [dbmarketer.com/case-studies](https://dbmarketer.com/case-studies)
- **Architecture Reviews & Consulting:** [dbmarketer.com/#contact](https://dbmarketer.com/#contact)
- **GitHub Profile:** [github.com/rudy0903](https://github.com/rudy0903)

---

## Licensing

DBMarketer uses a package-specific licensing model. Different directories within this repository may be distributed under different licenses.

### 1. Open-Source Packages - Apache License 2.0
Unless explicitly identified otherwise, original DBMarketer-owned code in packages without a separate package `LICENSE` file is licensed under the **Apache License, Version 2.0**.

This includes:
- [`ga4-bigquery-schema/`](ga4-bigquery-schema/)

These packages may be used, modified, and distributed commercially or non-commercially, subject to the Apache 2.0 license terms.

See the repository's root [`LICENSE`](LICENSE) file.

### 2. Source-Available Portfolio Packages - Restricted Evaluation License
Certain projects are publicly available (source-available, not OSI open-source) to demonstrate DBMarketer's engineering, analytics, and AI development capabilities without granting unrestricted commercial reuse rights.

The following package is governed by a separate license:
- [`ai-nutrition-intelligence/`](ai-nutrition-intelligence/)

**License:** Database Marketer Source-Available Portfolio & Evaluation License  
See [`ai-nutrition-intelligence/LICENSE`](ai-nutrition-intelligence/LICENSE) for the complete terms.

Subject to that license, this package is available for:
- Viewing and reviewing its source code.
- Cloning, installing, and executing the demonstration locally.
- Running automated tests and examining synthetic datasets.
- Personal, educational, and non-commercial technical study.
- Internal, nonproduction technical evaluation by prospective employers, hiring teams, and organizations considering DBMarketer's services.
- Making local modifications necessary for permitted evaluation.

Commercial production use, redistribution outside permitted GitHub platform functionality, sublicensing, resale, and incorporation into commercial products or services are not authorized without separate written permission from the applicable copyright holder.

### 3. Package License Precedence
Where a package contains its own `LICENSE` file, that license governs the original DBMarketer-owned materials specifically identified within that package.

The repository's root Apache 2.0 license does not independently grant additional rights to those separately licensed materials.

Existing third-party licenses, attribution requirements, and any previously granted licenses remain applicable.

### 4. Commercial Licensing
Organizations interested in commercial licensing, custom implementations, enterprise integrations, or consulting services can contact:

**Database Marketer**  
[https://dbmarketer.com](https://dbmarketer.com)

### 5. Copyright and Ownership
Copyright (c) 2026 Rudy Martinez, d/b/a Database Marketer (`dbmarketer.com`).

All rights not expressly granted under the applicable package license are reserved.

Public availability of source code does not imply permission for unrestricted commercial use.
