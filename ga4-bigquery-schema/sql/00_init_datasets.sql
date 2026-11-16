-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 00_init_datasets.sql
-- Description: Initializes BigQuery datasets for GA4 transformations, UDFs, and marts.
-- ==============================================================================

-- 1. Create Analytics Marts Dataset (Where materialized tables live)
CREATE SCHEMA IF NOT EXISTS `ga4_marts`
OPTIONS (
  location = 'US',
  description = 'Materialized dimensional marts for GA4: sessions, transactions, products, and cart events'
);

-- 2. Create Analytics Utilities Dataset (Where scalar UDFs and TVFs live)
CREATE SCHEMA IF NOT EXISTS `ga4_utils`
OPTIONS (
  location = 'US',
  description = 'Reusable scalar functions and parameterized table-valued functions (TVFs) for GA4 parsing'
);

-- 3. Optional: Staging / Raw Mock Dataset for local testing (if not using production analytics_<property_id>)
CREATE SCHEMA IF NOT EXISTS `ga4_staging`
OPTIONS (
  location = 'US',
  description = 'Temporary staging tables and intermediate ETL scratchpads'
);
