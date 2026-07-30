-- =====================================================================
-- Populate COVID19_PLATFORM.CORE from the existing medallion layers.
--
-- Prerequisite: `dbt run` has built the SILVER models. This script reads
-- only from SILVER -- never from the read-only Marketplace share
-- directly -- so all the cleaning decisions already made in the staging
-- models (ISO-code filtering, name-variant collapsing, deduplication,
-- the US state-level fallback) carry through automatically.
--
-- Every statement is INSERT OVERWRITE, so the script is idempotent:
-- re-running it fully replaces the contents rather than appending.
-- Load order matters -- dimensions before the tables that reference them.
-- =====================================================================

USE WAREHOUSE COVID_WH;
USE DATABASE COVID19_PLATFORM;
USE SCHEMA CORE;


-- ---------------------------------------------------------------------
-- 1. DIM_COUNTRY
--
-- Built from the union of every ISO code appearing anywhere in Silver,
-- not from any single source -- a country with case data but no
-- demographics still needs a dimension row, otherwise its facts would be
-- orphaned.
--
-- Country name: preferred from the OWID indicator feed (cleanest
-- spellings), falling back to whatever the other sources carry. MAX() is
-- the tiebreak, matching what the staging models already do -- sources
-- disagree on spelling for the same ISO code, and an arbitrary but
-- deterministic pick keeps the load reproducible.
-- ---------------------------------------------------------------------
INSERT OVERWRITE INTO DIM_COUNTRY (ISO_CODE, COUNTRY_NAME, CONTINENT)
WITH all_codes AS (
    SELECT iso_code, country_name FROM SILVER.STG_JHU_COVID_19
    UNION ALL
    SELECT iso_code, country_name FROM SILVER.STG_OWID_VACCINATIONS
    UNION ALL
    SELECT iso_code, country_name FROM SILVER.STG_DATABANK_DEMOGRAPHICS
    UNION ALL
    SELECT iso_code, country_name FROM SILVER.STG_COUNTRY_INDICATORS
    UNION ALL
    SELECT iso_code, country_name FROM SILVER.STG_WHO_SITUATION_REPORTS
)
SELECT
    codes.iso_code,
    COALESCE(MAX(ind.country_name), MAX(codes.country_name)) AS country_name,
    MAX(ind.continent)                                        AS continent
FROM all_codes codes
LEFT JOIN SILVER.STG_COUNTRY_INDICATORS ind
    ON ind.iso_code = codes.iso_code
WHERE codes.iso_code IS NOT NULL
GROUP BY codes.iso_code;


-- ---------------------------------------------------------------------
-- 2. DIM_DATE
--
-- Spans the full reporting window across ALL fact sources, not just JHU:
-- the vaccination and WHO series have their own start and end dates, and
-- a date present in a fact but missing from the dimension would be an
-- orphan. Generated with the same GENERATOR pattern the project's EDA
-- queries already use to find missing dates.
-- ---------------------------------------------------------------------
INSERT OVERWRITE INTO DIM_DATE (
    DATE_KEY, CALENDAR_YEAR, CALENDAR_QUARTER, CALENDAR_MONTH, MONTH_NAME,
    DAY_OF_MONTH, DAY_OF_WEEK, DAY_NAME, ISO_WEEK, IS_WEEKEND
)
WITH bounds AS (
    SELECT MIN(report_date) AS min_date, MAX(report_date) AS max_date
    FROM (
        SELECT report_date FROM SILVER.STG_JHU_COVID_19
        UNION ALL
        SELECT report_date FROM SILVER.STG_OWID_VACCINATIONS
        UNION ALL
        SELECT report_date FROM SILVER.STG_WHO_SITUATION_REPORTS
    )
),
calendar AS (
    SELECT DATEADD('day', SEQ4(), b.min_date) AS date_key
    FROM bounds b,
         TABLE(GENERATOR(ROWCOUNT => 5000))   -- ~13 years of headroom; the data spans ~3
    WHERE DATEADD('day', SEQ4(), b.min_date) <= b.max_date
)
SELECT
    date_key,
    YEAR(date_key),
    QUARTER(date_key),
    MONTH(date_key),
    MONTHNAME(date_key),
    DAY(date_key),
    DAYOFWEEKISO(date_key),
    DAYNAME(date_key),
    WEEKISO(date_key),
    DAYOFWEEKISO(date_key) IN (6, 7)   -- ISO: 6 = Saturday, 7 = Sunday
FROM calendar;


-- ---------------------------------------------------------------------
-- 3. Reference data
--
-- These two are the enums declared in the MongoDB collection validators.
-- Seeded as literals here so the values stay in one place; the integrity
-- checks confirm nothing outside these lists ever reaches CORE.
-- ---------------------------------------------------------------------
INSERT OVERWRITE INTO DIM_METRIC (METRIC_CODE, METRIC_LABEL) VALUES
    ('confirmed_cases',  'Confirmed cases'),
    ('confirmed_deaths', 'Confirmed deaths'),
    ('vaccinations',     'Vaccinations'),
    ('mobility',         'Mobility'),
    ('other',            'Other');

INSERT OVERWRITE INTO DIM_SOURCE_TYPE (SOURCE_TYPE_CODE, SOURCE_TYPE_LABEL) VALUES
    ('news',       'News article'),
    ('government', 'Government report'),
    ('research',   'Research publication'),
    ('other',      'Other');


-- ---------------------------------------------------------------------
-- 4. Country attributes
-- ---------------------------------------------------------------------
INSERT OVERWRITE INTO COUNTRY_DEMOGRAPHICS (
    ISO_CODE, TOTAL_POPULATION, TOTAL_MALE_POPULATION, TOTAL_FEMALE_POPULATION
)
SELECT
    iso_code,
    total_population,
    total_male_population,
    total_female_population
FROM SILVER.STG_DATABANK_DEMOGRAPHICS;


INSERT OVERWRITE INTO COUNTRY_INDICATORS (
    ISO_CODE, POPULATION_DENSITY, MEDIAN_AGE, GDP_PER_CAPITA,
    HOSPITAL_BEDS_PER_THOUSAND, HUMAN_DEVELOPMENT_INDEX, LIFE_EXPECTANCY,
    DIABETES_PREVALENCE, EXTREME_POVERTY
)
SELECT
    iso_code,
    population_density,
    median_age,
    gdp_per_capita,
    hospital_beds_per_thousand,
    human_development_index,
    life_expectancy,
    diabetes_prevalence,
    extreme_poverty
FROM SILVER.STG_COUNTRY_INDICATORS;


-- ---------------------------------------------------------------------
-- 5. Facts
--
-- The daily deltas are computed here, once, instead of in every
-- consumer. LAG over (country, date) is the natural expression of
-- "yesterday's cumulative total for this country".
--
-- The delta is left signed on purpose. A negative value means the source
-- revised its cumulative count downward -- a real reporting correction,
-- which the project's EDA confirmed rather than treated as corrupt data.
-- Clipping to zero here would silently discard that; consumers that need
-- a non-negative series clip at the point of use.
-- ---------------------------------------------------------------------
INSERT OVERWRITE INTO FACT_COVID_DAILY (
    ISO_CODE, REPORT_DATE, CONFIRMED_CASES, CONFIRMED_DEATHS, NEW_CASES, NEW_DEATHS
)
SELECT
    iso_code,
    report_date,
    confirmed_cases,
    confirmed_deaths,
    confirmed_cases - LAG(confirmed_cases) OVER (
        PARTITION BY iso_code ORDER BY report_date
    ) AS new_cases,
    confirmed_deaths - LAG(confirmed_deaths) OVER (
        PARTITION BY iso_code ORDER BY report_date
    ) AS new_deaths
FROM SILVER.STG_JHU_COVID_19;


INSERT OVERWRITE INTO FACT_VACCINATION_DAILY (
    ISO_CODE, REPORT_DATE, TOTAL_VACCINATIONS, PEOPLE_VACCINATED,
    PEOPLE_FULLY_VACCINATED, DAILY_VACCINATIONS, TOTAL_VACCINATIONS_PER_HUNDRED,
    PEOPLE_VACCINATED_PER_HUNDRED, PEOPLE_FULLY_VACCINATED_PER_HUNDRED
)
SELECT
    iso_code,
    report_date,
    total_vaccinations,
    people_vaccinated,
    people_fully_vaccinated,
    daily_vaccinations,
    total_vaccinations_per_hundred,
    people_vaccinated_per_hundred,
    people_fully_vaccinated_per_hundred
FROM SILVER.STG_OWID_VACCINATIONS;


-- WHO_REPORT_ID is AUTOINCREMENT, so it is omitted from the column list
-- and assigned by Snowflake. Rows with a null ISO_CODE are kept -- the
-- column is nullable by design, and dropping them would silently lose
-- reporting entities that have no ISO 3166-1 code.
INSERT OVERWRITE INTO FACT_WHO_SITUATION_REPORT (
    ISO_CODE, REPORT_DATE, TOTAL_CASES, CASES_NEW, DEATHS, DEATHS_NEW,
    TRANSMISSION_CLASSIFICATION, DAYS_SINCE_LAST_REPORTED_CASE
)
SELECT
    iso_code,
    report_date,
    total_cases,
    cases_new,
    deaths,
    deaths_new,
    transmission_classification,
    days_since_last_reported_case
FROM SILVER.STG_WHO_SITUATION_REPORTS;


-- ---------------------------------------------------------------------
-- 6. User-generated content -- NOT loadable from SQL alone
--
-- APP_USER, ANNOTATION, ANNOTATION_TAG, SUPPLEMENTARY_SOURCE,
-- USER_PREFERENCE and USER_FAVORITE_METRIC mirror MongoDB collections.
-- Snowflake cannot read MongoDB, so there is no SELECT that fills them,
-- and none is invented here.
--
-- The sync is a Python job reusing what the platform already has
-- (mongo/client.py to read, common/snowflake_client.upload_dataframe to
-- write). It:
--
--   1. reads each collection into a DataFrame;
--   2. explodes the array fields -- annotations.tags and
--      user_preferences.favorite_metrics -- into their own flat frames,
--      one row per parent id plus value, which is exactly the shape of
--      ANNOTATION_TAG and USER_FAVORITE_METRIC;
--   3. derives the distinct set of author / added_by / user_id strings
--      into APP_USER, so the foreign keys resolve;
--   4. uploads each frame to a transient CORE.STG_MONGO_* table;
--   5. runs the MERGE statements below.
--
-- MERGE rather than INSERT OVERWRITE because MongoDB stays the system of
-- record and the sync is incremental -- a document edited in Mongo
-- should update its row here, not duplicate it.
--
-- Uncomment once the staging tables exist.
-- ---------------------------------------------------------------------

/*
MERGE INTO APP_USER tgt
USING CORE.STG_MONGO_APP_USER src
    ON tgt.USER_ID = src.USER_ID
WHEN NOT MATCHED THEN INSERT (USER_ID, DISPLAY_NAME)
    VALUES (src.USER_ID, src.DISPLAY_NAME);

MERGE INTO ANNOTATION tgt
USING CORE.STG_MONGO_ANNOTATION src
    ON tgt.ANNOTATION_ID = src.ANNOTATION_ID
WHEN MATCHED THEN UPDATE SET
    tgt.COMMENT_TEXT = src.COMMENT_TEXT,
    tgt.METRIC_CODE  = src.METRIC_CODE,
    tgt.UPDATED_AT   = src.UPDATED_AT
WHEN NOT MATCHED THEN INSERT (
    ANNOTATION_ID, ISO_CODE, METRIC_CODE, ANNOTATION_DATE,
    AUTHOR_USER_ID, COMMENT_TEXT, CREATED_AT, UPDATED_AT
) VALUES (
    src.ANNOTATION_ID, src.ISO_CODE, src.METRIC_CODE, src.ANNOTATION_DATE,
    src.AUTHOR_USER_ID, src.COMMENT_TEXT, src.CREATED_AT, src.UPDATED_AT
);

-- Tags are replaced wholesale per annotation rather than merged: an edit
-- in Mongo can remove a tag, and a MERGE with no DELETE branch would
-- leave the removed tag behind.
DELETE FROM ANNOTATION_TAG
WHERE ANNOTATION_ID IN (SELECT ANNOTATION_ID FROM CORE.STG_MONGO_ANNOTATION_TAG);

INSERT INTO ANNOTATION_TAG (ANNOTATION_ID, TAG)
SELECT ANNOTATION_ID, TAG FROM CORE.STG_MONGO_ANNOTATION_TAG;

MERGE INTO SUPPLEMENTARY_SOURCE tgt
USING CORE.STG_MONGO_SUPPLEMENTARY_SOURCE src
    ON tgt.SOURCE_ID = src.SOURCE_ID
WHEN NOT MATCHED THEN INSERT (
    SOURCE_ID, ISO_CODE, SOURCE_TYPE_CODE, TITLE, URL,
    DESCRIPTION, ADDED_BY_USER_ID, CREATED_AT
) VALUES (
    src.SOURCE_ID, src.ISO_CODE, src.SOURCE_TYPE_CODE, src.TITLE, src.URL,
    src.DESCRIPTION, src.ADDED_BY_USER_ID, src.CREATED_AT
);

MERGE INTO USER_PREFERENCE tgt
USING CORE.STG_MONGO_USER_PREFERENCE src
    ON tgt.USER_ID = src.USER_ID
WHEN MATCHED THEN UPDATE SET
    tgt.DEFAULT_COUNTRY_ISO = src.DEFAULT_COUNTRY_ISO,
    tgt.THEME               = src.THEME,
    tgt.UPDATED_AT          = src.UPDATED_AT
WHEN NOT MATCHED THEN INSERT (USER_ID, DEFAULT_COUNTRY_ISO, THEME, UPDATED_AT)
    VALUES (src.USER_ID, src.DEFAULT_COUNTRY_ISO, src.THEME, src.UPDATED_AT);

DELETE FROM USER_FAVORITE_METRIC
WHERE USER_ID IN (SELECT USER_ID FROM CORE.STG_MONGO_USER_FAVORITE_METRIC);

INSERT INTO USER_FAVORITE_METRIC (USER_ID, METRIC_CODE)
SELECT USER_ID, METRIC_CODE FROM CORE.STG_MONGO_USER_FAVORITE_METRIC;
*/


-- ---------------------------------------------------------------------
-- 7. Row counts -- a quick sanity check after loading
-- ---------------------------------------------------------------------
SELECT 'DIM_COUNTRY'               AS table_name, COUNT(*) AS row_count FROM DIM_COUNTRY
UNION ALL SELECT 'DIM_DATE',                      COUNT(*) FROM DIM_DATE
UNION ALL SELECT 'DIM_METRIC',                    COUNT(*) FROM DIM_METRIC
UNION ALL SELECT 'DIM_SOURCE_TYPE',               COUNT(*) FROM DIM_SOURCE_TYPE
UNION ALL SELECT 'COUNTRY_DEMOGRAPHICS',          COUNT(*) FROM COUNTRY_DEMOGRAPHICS
UNION ALL SELECT 'COUNTRY_INDICATORS',            COUNT(*) FROM COUNTRY_INDICATORS
UNION ALL SELECT 'FACT_COVID_DAILY',              COUNT(*) FROM FACT_COVID_DAILY
UNION ALL SELECT 'FACT_VACCINATION_DAILY',        COUNT(*) FROM FACT_VACCINATION_DAILY
UNION ALL SELECT 'FACT_WHO_SITUATION_REPORT',     COUNT(*) FROM FACT_WHO_SITUATION_REPORT
ORDER BY table_name;
