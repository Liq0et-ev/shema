-- =====================================================================
-- Referential-integrity and domain validation for COVID19_PLATFORM.CORE.
--
-- Snowflake enforces only NOT NULL: the PRIMARY KEY and FOREIGN KEY
-- constraints declared in 01_relational_model.sql are metadata, and bad
-- data will load past them without complaint. These queries are what
-- actually verifies the model holds.
--
-- This matters more than usual here because the keys are declared RELY,
-- which tells the query optimiser to trust them for join elimination.
-- A duplicate in a RELY primary key does not just mean untidy data --
-- it means queries can return silently wrong answers. Run this after
-- every load.
--
-- Section 1 is the summary: every VIOLATION_COUNT must be 0. Section 2
-- has the drill-down queries for whichever check fails.
-- =====================================================================

USE WAREHOUSE COVID_WH;
USE DATABASE COVID19_PLATFORM;
USE SCHEMA CORE;


-- ---------------------------------------------------------------------
-- 1. SUMMARY -- every row must show VIOLATION_COUNT = 0
-- ---------------------------------------------------------------------

-- Primary key uniqueness
SELECT 'PK: DIM_COUNTRY (iso_code)' AS check_name, COUNT(*) AS violation_count
FROM (SELECT ISO_CODE FROM DIM_COUNTRY GROUP BY ISO_CODE HAVING COUNT(*) > 1)

UNION ALL SELECT 'PK: DIM_DATE (date_key)', COUNT(*)
FROM (SELECT DATE_KEY FROM DIM_DATE GROUP BY DATE_KEY HAVING COUNT(*) > 1)

UNION ALL SELECT 'PK: COUNTRY_DEMOGRAPHICS (iso_code)', COUNT(*)
FROM (SELECT ISO_CODE FROM COUNTRY_DEMOGRAPHICS GROUP BY ISO_CODE HAVING COUNT(*) > 1)

UNION ALL SELECT 'PK: COUNTRY_INDICATORS (iso_code)', COUNT(*)
FROM (SELECT ISO_CODE FROM COUNTRY_INDICATORS GROUP BY ISO_CODE HAVING COUNT(*) > 1)

UNION ALL SELECT 'PK: FACT_COVID_DAILY (iso_code, report_date)', COUNT(*)
FROM (SELECT ISO_CODE, REPORT_DATE FROM FACT_COVID_DAILY GROUP BY ISO_CODE, REPORT_DATE HAVING COUNT(*) > 1)

UNION ALL SELECT 'PK: FACT_VACCINATION_DAILY (iso_code, report_date)', COUNT(*)
FROM (SELECT ISO_CODE, REPORT_DATE FROM FACT_VACCINATION_DAILY GROUP BY ISO_CODE, REPORT_DATE HAVING COUNT(*) > 1)

UNION ALL SELECT 'PK: FACT_WHO_SITUATION_REPORT (who_report_id)', COUNT(*)
FROM (SELECT WHO_REPORT_ID FROM FACT_WHO_SITUATION_REPORT GROUP BY WHO_REPORT_ID HAVING COUNT(*) > 1)

-- Foreign keys into DIM_COUNTRY
UNION ALL SELECT 'FK: COUNTRY_DEMOGRAPHICS -> DIM_COUNTRY', COUNT(*)
FROM COUNTRY_DEMOGRAPHICS c
WHERE NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = c.ISO_CODE)

UNION ALL SELECT 'FK: COUNTRY_INDICATORS -> DIM_COUNTRY', COUNT(*)
FROM COUNTRY_INDICATORS c
WHERE NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = c.ISO_CODE)

UNION ALL SELECT 'FK: FACT_COVID_DAILY -> DIM_COUNTRY', COUNT(*)
FROM FACT_COVID_DAILY f
WHERE NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = f.ISO_CODE)

UNION ALL SELECT 'FK: FACT_VACCINATION_DAILY -> DIM_COUNTRY', COUNT(*)
FROM FACT_VACCINATION_DAILY f
WHERE NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = f.ISO_CODE)

-- Nullable FK: only non-null values need to resolve
UNION ALL SELECT 'FK: FACT_WHO_SITUATION_REPORT -> DIM_COUNTRY', COUNT(*)
FROM FACT_WHO_SITUATION_REPORT f
WHERE f.ISO_CODE IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = f.ISO_CODE)

-- Foreign keys into DIM_DATE
UNION ALL SELECT 'FK: FACT_COVID_DAILY -> DIM_DATE', COUNT(*)
FROM FACT_COVID_DAILY f
WHERE NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_KEY = f.REPORT_DATE)

UNION ALL SELECT 'FK: FACT_VACCINATION_DAILY -> DIM_DATE', COUNT(*)
FROM FACT_VACCINATION_DAILY f
WHERE NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_KEY = f.REPORT_DATE)

UNION ALL SELECT 'FK: FACT_WHO_SITUATION_REPORT -> DIM_DATE', COUNT(*)
FROM FACT_WHO_SITUATION_REPORT f
WHERE NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_KEY = f.REPORT_DATE)

-- User-content foreign keys. These return 0 trivially until the MongoDB
-- sync has run; they are the checks that matter most once it has, since
-- that data crosses a database boundary with no engine enforcing it.
UNION ALL SELECT 'FK: ANNOTATION -> DIM_COUNTRY', COUNT(*)
FROM ANNOTATION a
WHERE NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = a.ISO_CODE)

UNION ALL SELECT 'FK: ANNOTATION -> DIM_METRIC', COUNT(*)
FROM ANNOTATION a
WHERE NOT EXISTS (SELECT 1 FROM DIM_METRIC m WHERE m.METRIC_CODE = a.METRIC_CODE)

UNION ALL SELECT 'FK: ANNOTATION -> APP_USER', COUNT(*)
FROM ANNOTATION a
WHERE a.AUTHOR_USER_ID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM APP_USER u WHERE u.USER_ID = a.AUTHOR_USER_ID)

UNION ALL SELECT 'FK: ANNOTATION_TAG -> ANNOTATION', COUNT(*)
FROM ANNOTATION_TAG t
WHERE NOT EXISTS (SELECT 1 FROM ANNOTATION a WHERE a.ANNOTATION_ID = t.ANNOTATION_ID)

UNION ALL SELECT 'FK: SUPPLEMENTARY_SOURCE -> DIM_COUNTRY', COUNT(*)
FROM SUPPLEMENTARY_SOURCE s
WHERE NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = s.ISO_CODE)

UNION ALL SELECT 'FK: SUPPLEMENTARY_SOURCE -> DIM_SOURCE_TYPE', COUNT(*)
FROM SUPPLEMENTARY_SOURCE s
WHERE NOT EXISTS (SELECT 1 FROM DIM_SOURCE_TYPE t WHERE t.SOURCE_TYPE_CODE = s.SOURCE_TYPE_CODE)

UNION ALL SELECT 'FK: USER_PREFERENCE -> APP_USER', COUNT(*)
FROM USER_PREFERENCE p
WHERE NOT EXISTS (SELECT 1 FROM APP_USER u WHERE u.USER_ID = p.USER_ID)

UNION ALL SELECT 'FK: USER_PREFERENCE -> DIM_COUNTRY', COUNT(*)
FROM USER_PREFERENCE p
WHERE p.DEFAULT_COUNTRY_ISO IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM DIM_COUNTRY d WHERE d.ISO_CODE = p.DEFAULT_COUNTRY_ISO)

UNION ALL SELECT 'FK: USER_FAVORITE_METRIC -> DIM_METRIC', COUNT(*)
FROM USER_FAVORITE_METRIC f
WHERE NOT EXISTS (SELECT 1 FROM DIM_METRIC m WHERE m.METRIC_CODE = f.METRIC_CODE)

-- Value domains. Snowflake has no CHECK constraints, so the enums that
-- are not backed by a dimension table are verified here instead.
UNION ALL SELECT 'DOMAIN: USER_PREFERENCE.theme in (light, dark)', COUNT(*)
FROM USER_PREFERENCE
WHERE THEME IS NOT NULL AND THEME NOT IN ('light', 'dark')

UNION ALL SELECT 'DOMAIN: DIM_COUNTRY.iso_code is 2 characters', COUNT(*)
FROM DIM_COUNTRY
WHERE LENGTH(ISO_CODE) <> 2

-- Cross-fact consistency: cumulative series must never decrease. Unlike
-- the checks above this one is expected to find rows -- the project's
-- EDA established that sources do revise counts downward. It is reported
-- so the number stays visible and explainable rather than unnoticed.
UNION ALL SELECT 'INFO: FACT_COVID_DAILY days with a downward revision', COUNT(*)
FROM FACT_COVID_DAILY
WHERE NEW_CASES < 0

ORDER BY violation_count DESC, check_name;


-- ---------------------------------------------------------------------
-- 2. DRILL-DOWN -- run whichever matches a failing check above
-- ---------------------------------------------------------------------

-- Which countries have facts but no dimension row?
-- (Should be empty: DIM_COUNTRY is built from the union of all sources.)
SELECT DISTINCT f.ISO_CODE
FROM FACT_COVID_DAILY f
LEFT JOIN DIM_COUNTRY d ON d.ISO_CODE = f.ISO_CODE
WHERE d.ISO_CODE IS NULL;

-- Which dates appear in a fact but not in DIM_DATE?
-- (Should be empty: the calendar spans the union of all fact date ranges.)
SELECT DISTINCT f.REPORT_DATE
FROM FACT_VACCINATION_DAILY f
LEFT JOIN DIM_DATE d ON d.DATE_KEY = f.REPORT_DATE
WHERE d.DATE_KEY IS NULL
ORDER BY 1;

-- Duplicate grain in the main fact -- the check that most needs to pass,
-- because PK_FACT_COVID_DAILY is declared RELY.
SELECT ISO_CODE, REPORT_DATE, COUNT(*) AS row_count
FROM FACT_COVID_DAILY
GROUP BY ISO_CODE, REPORT_DATE
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 20;

-- Coverage: countries with case data but no demographics, and vice
-- versa. Not an integrity failure -- the 1:1 attribute tables are
-- optional by design -- but worth knowing how complete the model is.
SELECT
    COUNT(DISTINCT c.ISO_CODE)                                          AS countries_total,
    COUNT(DISTINCT CASE WHEN dem.ISO_CODE IS NULL THEN c.ISO_CODE END)  AS without_demographics,
    COUNT(DISTINCT CASE WHEN ind.ISO_CODE IS NULL THEN c.ISO_CODE END)  AS without_indicators
FROM DIM_COUNTRY c
LEFT JOIN COUNTRY_DEMOGRAPHICS dem ON dem.ISO_CODE = c.ISO_CODE
LEFT JOIN COUNTRY_INDICATORS  ind ON ind.ISO_CODE = c.ISO_CODE;

-- The largest downward revisions, if the informational check above
-- returns a surprising number.
SELECT ISO_CODE, REPORT_DATE, CONFIRMED_CASES, NEW_CASES
FROM FACT_COVID_DAILY
WHERE NEW_CASES < 0
ORDER BY NEW_CASES ASC
LIMIT 20;
