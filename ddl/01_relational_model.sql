-- =====================================================================
-- Relational model (3NF) for the COVID-19 Data Platform.
--
-- Creates COVID19_PLATFORM.CORE: a normalised layer sitting between
-- SILVER (cleaned) and GOLD (denormalised marts). Silver cleans, Core
-- models, Gold flattens for serving.
--
-- Constraint semantics on Snowflake: only NOT NULL is enforced.
-- PRIMARY KEY / UNIQUE / FOREIGN KEY are metadata -- they document the
-- model, let ERD tools reverse-engineer it, and (with RELY) let the
-- optimiser eliminate redundant joins. They do NOT reject bad data.
-- Snowflake has no CHECK constraints at all, so value domains are
-- enforced by reference tables plus the dbt tests / integrity queries
-- (see ddl/03_integrity_checks.sql).
--
-- RELY is declared only on keys whose uniqueness is independently
-- verified -- an unverified RELY key produces wrong results, because
-- the optimiser trusts it.
--
-- Run order: this file, then 02_load_from_medallion.sql, then
-- 03_integrity_checks.sql.
-- =====================================================================

USE WAREHOUSE COVID_WH;
USE DATABASE COVID19_PLATFORM;

CREATE SCHEMA IF NOT EXISTS CORE
    COMMENT = 'Normalised (3NF) relational core: conformed dimensions and fact tables with declared PK/FK constraints';

USE SCHEMA CORE;


-- =====================================================================
-- 0. TEARDOWN
--
-- Snowflake refuses to drop a table that another table references by a
-- foreign key, so a re-run has to remove them children-first -- reverse
-- dependency order. Without this the script works once and then fails on
-- the second run, which is the sort of thing that only shows up when
-- you're demonstrating it to someone.
--
-- Destructive: this discards CORE's contents. Re-run 02_load_from_
-- medallion.sql afterwards to repopulate.
-- =====================================================================

DROP TABLE IF EXISTS USER_FAVORITE_METRIC;
DROP TABLE IF EXISTS USER_PREFERENCE;
DROP TABLE IF EXISTS ANNOTATION_TAG;
DROP TABLE IF EXISTS SUPPLEMENTARY_SOURCE;
DROP TABLE IF EXISTS ANNOTATION;
DROP TABLE IF EXISTS APP_USER;
DROP TABLE IF EXISTS FACT_WHO_SITUATION_REPORT;
DROP TABLE IF EXISTS FACT_VACCINATION_DAILY;
DROP TABLE IF EXISTS FACT_COVID_DAILY;
DROP TABLE IF EXISTS COUNTRY_INDICATORS;
DROP TABLE IF EXISTS COUNTRY_DEMOGRAPHICS;
DROP TABLE IF EXISTS DIM_SOURCE_TYPE;
DROP TABLE IF EXISTS DIM_METRIC;
DROP TABLE IF EXISTS DIM_DATE;
DROP TABLE IF EXISTS DIM_COUNTRY;


-- =====================================================================
-- 1. DIMENSIONS
-- =====================================================================

-- The conformed country dimension the medallion layers never had --
-- today country attributes are split across two Silver models and the
-- country name is repeated on every fact row. Every other table in this
-- schema points here.
--
-- ISO_CODE is ISO 3166-1 *alpha-2* ('US', not 'USA'): the Marketplace
-- tables use alpha-2, and etl/augment_country_indicators.py converts
-- OWID's alpha-3 on ingest, so alpha-2 is the invariant platform-wide.
CREATE OR REPLACE TABLE DIM_COUNTRY (
    ISO_CODE      VARCHAR(2)   NOT NULL COMMENT 'ISO 3166-1 alpha-2 country code -- the single join key across every table in this model',
    COUNTRY_NAME  VARCHAR(100)          COMMENT 'Display name; sources disagree on spelling, so one is chosen deterministically at load',
    CONTINENT     VARCHAR(50)           COMMENT 'From the OWID indicator feed; null where that feed has no row for the country',

    CONSTRAINT PK_DIM_COUNTRY PRIMARY KEY (ISO_CODE) RELY
)
COMMENT = 'One row per country. Conformed dimension for the whole platform.';


-- Calendar dimension. Beyond the usual convenience, IS_WEEKEND earns its
-- place here specifically: the project's EDA established that COVID
-- reporting has a weekly cadence (fewer cases logged at weekends), which
-- is a reporting artifact rather than an epidemiological one. Having the
-- flag on the dimension makes that correction a join instead of a
-- date-function call repeated in every query.
CREATE OR REPLACE TABLE DIM_DATE (
    DATE_KEY          DATE        NOT NULL COMMENT 'The calendar day itself -- a natural key, no surrogate integer needed',
    CALENDAR_YEAR     NUMBER(4,0) NOT NULL,
    CALENDAR_QUARTER  NUMBER(1,0) NOT NULL,
    CALENDAR_MONTH    NUMBER(2,0) NOT NULL,
    MONTH_NAME        VARCHAR(10) NOT NULL COMMENT 'Snowflake MONTHNAME() returns the abbreviated form, e.g. Jan',
    DAY_OF_MONTH      NUMBER(2,0) NOT NULL,
    DAY_OF_WEEK       NUMBER(1,0) NOT NULL COMMENT 'ISO numbering: 1 = Monday .. 7 = Sunday',
    DAY_NAME          VARCHAR(10) NOT NULL,
    ISO_WEEK          NUMBER(2,0) NOT NULL,
    IS_WEEKEND        BOOLEAN     NOT NULL,

    CONSTRAINT PK_DIM_DATE PRIMARY KEY (DATE_KEY) RELY
)
COMMENT = 'One row per calendar day spanning the reporting period.';


-- The metric enum from the MongoDB annotations validator, promoted to a
-- table. Worth a dimension (rather than a bare string) because the
-- dashboard filters annotations per chart by metric -- it is an
-- analytical axis, not just a label.
CREATE OR REPLACE TABLE DIM_METRIC (
    METRIC_CODE   VARCHAR(30)  NOT NULL COMMENT 'Matches the MongoDB annotations.scope.metric enum exactly',
    METRIC_LABEL  VARCHAR(100) NOT NULL COMMENT 'Human-readable form for UI display',

    CONSTRAINT PK_DIM_METRIC PRIMARY KEY (METRIC_CODE) RELY
)
COMMENT = 'Metrics an annotation can be attached to.';


CREATE OR REPLACE TABLE DIM_SOURCE_TYPE (
    SOURCE_TYPE_CODE   VARCHAR(20) NOT NULL COMMENT 'Matches the MongoDB supplementary_sources.source_type enum exactly',
    SOURCE_TYPE_LABEL  VARCHAR(50) NOT NULL,

    CONSTRAINT PK_DIM_SOURCE_TYPE PRIMARY KEY (SOURCE_TYPE_CODE) RELY
)
COMMENT = 'Categories of supplementary external source.';


-- In MongoDB, the author of an annotation and the owner of a preference
-- document are unrelated free-text strings that happen to hold the same
-- email. Normalising them into one entity is what makes "everything this
-- person contributed" a single join rather than a string match.
CREATE OR REPLACE TABLE APP_USER (
    USER_ID       VARCHAR(255) NOT NULL COMMENT 'Email address or application user id -- whatever the annotation author / preference owner string holds',
    DISPLAY_NAME  VARCHAR(200),
    CREATED_AT    TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),

    CONSTRAINT PK_APP_USER PRIMARY KEY (USER_ID) RELY
)
COMMENT = 'One row per person who has authored an annotation, added a source, or saved preferences.';


-- =====================================================================
-- 2. COUNTRY ATTRIBUTES (1:1 with DIM_COUNTRY)
--
-- Kept as two separate tables rather than folded into DIM_COUNTRY: they
-- have different sources, different refresh cadences and different
-- coverage. A country with no indicator data is then a missing row
-- rather than eight nulls, and reloading one does not disturb the other.
-- =====================================================================

CREATE OR REPLACE TABLE COUNTRY_DEMOGRAPHICS (
    ISO_CODE                 VARCHAR(2)   NOT NULL,
    TOTAL_POPULATION         NUMBER(38,0) COMMENT 'Never negative -- asserted by the dbt accepted_range test on the Silver model',
    TOTAL_MALE_POPULATION    NUMBER(38,0),
    TOTAL_FEMALE_POPULATION  NUMBER(38,0),

    CONSTRAINT PK_COUNTRY_DEMOGRAPHICS PRIMARY KEY (ISO_CODE) RELY,
    CONSTRAINT FK_COUNTRY_DEMOGRAPHICS_COUNTRY FOREIGN KEY (ISO_CODE) REFERENCES DIM_COUNTRY (ISO_CODE)
)
COMMENT = 'Population figures per country, from the Marketplace DATABANK_DEMOGRAPHICS table.';


CREATE OR REPLACE TABLE COUNTRY_INDICATORS (
    ISO_CODE                    VARCHAR(2) NOT NULL,
    POPULATION_DENSITY          FLOAT,
    MEDIAN_AGE                  FLOAT,
    GDP_PER_CAPITA              FLOAT,
    HOSPITAL_BEDS_PER_THOUSAND  FLOAT,
    HUMAN_DEVELOPMENT_INDEX     FLOAT,
    LIFE_EXPECTANCY             FLOAT,
    DIABETES_PREVALENCE         FLOAT,
    EXTREME_POVERTY             FLOAT,

    CONSTRAINT PK_COUNTRY_INDICATORS PRIMARY KEY (ISO_CODE) RELY,
    CONSTRAINT FK_COUNTRY_INDICATORS_COUNTRY FOREIGN KEY (ISO_CODE) REFERENCES DIM_COUNTRY (ISO_CODE)
)
COMMENT = 'Economic and health-system indicators per country, fetched from Our World in Data by the Bronze ETL. Population is deliberately absent -- it lives in COUNTRY_DEMOGRAPHICS.';


-- =====================================================================
-- 3. FACTS
-- =====================================================================

-- Cumulative counts come from the source; the daily deltas are derived
-- once here rather than re-derived by every consumer (forecasting, wave
-- detection, the dashboard's daily charts all difference the series).
--
-- NEW_CASES / NEW_DEATHS are signed: negatives are kept, not clipped.
-- The project's EDA established that negative deltas are legitimate
-- reporting corrections, so clipping here would destroy real information.
-- Consumers needing a non-negative series clip at the point of use.
CREATE OR REPLACE TABLE FACT_COVID_DAILY (
    ISO_CODE          VARCHAR(2)   NOT NULL,
    REPORT_DATE       DATE         NOT NULL,
    CONFIRMED_CASES   NUMBER(38,0) COMMENT 'Cumulative confirmed cases as at REPORT_DATE',
    CONFIRMED_DEATHS  NUMBER(38,0) COMMENT 'Cumulative confirmed deaths as at REPORT_DATE',
    NEW_CASES         NUMBER(38,0) COMMENT 'Day-over-day delta, signed; null on a country''s first day',
    NEW_DEATHS        NUMBER(38,0) COMMENT 'Day-over-day delta, signed; null on a country''s first day',

    CONSTRAINT PK_FACT_COVID_DAILY PRIMARY KEY (ISO_CODE, REPORT_DATE) RELY,
    CONSTRAINT FK_FACT_COVID_DAILY_COUNTRY FOREIGN KEY (ISO_CODE) REFERENCES DIM_COUNTRY (ISO_CODE),
    CONSTRAINT FK_FACT_COVID_DAILY_DATE FOREIGN KEY (REPORT_DATE) REFERENCES DIM_DATE (DATE_KEY)
)
CLUSTER BY (ISO_CODE, REPORT_DATE)
COMMENT = 'Confirmed cases and deaths per country per day (Johns Hopkins). Grain asserted by a dbt uniqueness test on the Silver model.';


CREATE OR REPLACE TABLE FACT_VACCINATION_DAILY (
    ISO_CODE                             VARCHAR(2)   NOT NULL,
    REPORT_DATE                          DATE         NOT NULL,
    TOTAL_VACCINATIONS                   NUMBER(38,0) COMMENT 'Cumulative doses administered',
    PEOPLE_VACCINATED                    NUMBER(38,0) COMMENT 'Cumulative people with at least one dose',
    PEOPLE_FULLY_VACCINATED              NUMBER(38,0),
    DAILY_VACCINATIONS                   NUMBER(38,0) COMMENT 'Provided by the source directly, unlike FACT_COVID_DAILY where it is derived',
    TOTAL_VACCINATIONS_PER_HUNDRED       FLOAT,
    PEOPLE_VACCINATED_PER_HUNDRED        FLOAT,
    PEOPLE_FULLY_VACCINATED_PER_HUNDRED  FLOAT,

    CONSTRAINT PK_FACT_VACCINATION_DAILY PRIMARY KEY (ISO_CODE, REPORT_DATE) RELY,
    CONSTRAINT FK_FACT_VACCINATION_DAILY_COUNTRY FOREIGN KEY (ISO_CODE) REFERENCES DIM_COUNTRY (ISO_CODE),
    CONSTRAINT FK_FACT_VACCINATION_DAILY_DATE FOREIGN KEY (REPORT_DATE) REFERENCES DIM_DATE (DATE_KEY)
)
CLUSTER BY (ISO_CODE, REPORT_DATE)
COMMENT = 'Vaccination rollout per country per day (Our World in Data). Grain asserted by a dbt uniqueness test on the Silver model.';


-- The one fact that needs a surrogate key. The other two are uniquely
-- identified by (country, date) and dbt tests prove it; the WHO staging
-- model asserts no such uniqueness and does not drop rows with a null
-- ISO_CODE, so (country, date) is not a candidate key here. That is a
-- real difference between the sources, not an inconsistency -- WHO
-- published situation reports irregularly over a much shorter window
-- than the JHU series covers.
CREATE OR REPLACE TABLE FACT_WHO_SITUATION_REPORT (
    WHO_REPORT_ID                  NUMBER(38,0) NOT NULL AUTOINCREMENT START 1 INCREMENT 1,
    ISO_CODE                       VARCHAR(2)   COMMENT 'Nullable: the source includes reporting entities with no ISO 3166-1 code',
    REPORT_DATE                    DATE         NOT NULL,
    TOTAL_CASES                    NUMBER(38,0),
    CASES_NEW                      NUMBER(38,0),
    DEATHS                         NUMBER(38,0),
    DEATHS_NEW                     NUMBER(38,0),
    TRANSMISSION_CLASSIFICATION    VARCHAR(100),
    DAYS_SINCE_LAST_REPORTED_CASE  NUMBER(38,0),

    CONSTRAINT PK_FACT_WHO_SITUATION_REPORT PRIMARY KEY (WHO_REPORT_ID) RELY,
    CONSTRAINT FK_FACT_WHO_COUNTRY FOREIGN KEY (ISO_CODE) REFERENCES DIM_COUNTRY (ISO_CODE),
    CONSTRAINT FK_FACT_WHO_DATE FOREIGN KEY (REPORT_DATE) REFERENCES DIM_DATE (DATE_KEY)
)
COMMENT = 'WHO situation-report figures -- an independent cross-check against FACT_COVID_DAILY, not a second primary series.';


-- =====================================================================
-- 4. USER-GENERATED CONTENT
--
-- The relational projection of the MongoDB collections. MongoDB remains
-- the system of record: these tables are populated by a sync job, and
-- the *_ID primary keys carry the source ObjectId hex so any row can be
-- traced back to its document.
-- =====================================================================

CREATE OR REPLACE TABLE ANNOTATION (
    ANNOTATION_ID    VARCHAR(24)   NOT NULL COMMENT 'MongoDB ObjectId hex, preserved so a row traces back to its source document',
    ISO_CODE         VARCHAR(2)    NOT NULL COMMENT 'The join key that ties user content to the warehouse -- same code used throughout',
    METRIC_CODE      VARCHAR(30)   NOT NULL,
    ANNOTATION_DATE  DATE          COMMENT 'Nullable by design: an annotation may concern one specific day, or the country generally',
    AUTHOR_USER_ID   VARCHAR(255),
    COMMENT_TEXT     VARCHAR(2000) NOT NULL COMMENT 'Named COMMENT_TEXT, not COMMENT -- COMMENT is a Snowflake keyword',
    CREATED_AT       TIMESTAMP_NTZ NOT NULL,
    UPDATED_AT       TIMESTAMP_NTZ,

    CONSTRAINT PK_ANNOTATION PRIMARY KEY (ANNOTATION_ID) RELY,
    CONSTRAINT FK_ANNOTATION_COUNTRY FOREIGN KEY (ISO_CODE) REFERENCES DIM_COUNTRY (ISO_CODE),
    CONSTRAINT FK_ANNOTATION_METRIC FOREIGN KEY (METRIC_CODE) REFERENCES DIM_METRIC (METRIC_CODE),
    CONSTRAINT FK_ANNOTATION_DATE FOREIGN KEY (ANNOTATION_DATE) REFERENCES DIM_DATE (DATE_KEY),
    CONSTRAINT FK_ANNOTATION_AUTHOR FOREIGN KEY (AUTHOR_USER_ID) REFERENCES APP_USER (USER_ID)
)
COMMENT = 'User comments attached to a country, a metric and optionally a date.';


-- In the document model this is the `tags` array inside an annotation.
-- First normal form has no repeating groups, so it becomes a child table
-- keyed on the parent plus the value.
CREATE OR REPLACE TABLE ANNOTATION_TAG (
    ANNOTATION_ID  VARCHAR(24) NOT NULL,
    TAG            VARCHAR(50) NOT NULL,

    CONSTRAINT PK_ANNOTATION_TAG PRIMARY KEY (ANNOTATION_ID, TAG) RELY,
    CONSTRAINT FK_ANNOTATION_TAG_ANNOTATION FOREIGN KEY (ANNOTATION_ID) REFERENCES ANNOTATION (ANNOTATION_ID)
)
COMMENT = 'Normalised form of annotations.tags[] -- one row per tag on an annotation.';


CREATE OR REPLACE TABLE SUPPLEMENTARY_SOURCE (
    SOURCE_ID          VARCHAR(24)    NOT NULL COMMENT 'MongoDB ObjectId hex',
    ISO_CODE           VARCHAR(2)     NOT NULL,
    SOURCE_TYPE_CODE   VARCHAR(20)    NOT NULL,
    TITLE              VARCHAR(500)   NOT NULL,
    URL                VARCHAR(2000)  NOT NULL,
    DESCRIPTION        VARCHAR(4000),
    ADDED_BY_USER_ID   VARCHAR(255),
    CREATED_AT         TIMESTAMP_NTZ  NOT NULL,

    CONSTRAINT PK_SUPPLEMENTARY_SOURCE PRIMARY KEY (SOURCE_ID) RELY,
    CONSTRAINT FK_SUPPLEMENTARY_SOURCE_COUNTRY FOREIGN KEY (ISO_CODE) REFERENCES DIM_COUNTRY (ISO_CODE),
    CONSTRAINT FK_SUPPLEMENTARY_SOURCE_TYPE FOREIGN KEY (SOURCE_TYPE_CODE) REFERENCES DIM_SOURCE_TYPE (SOURCE_TYPE_CODE),
    CONSTRAINT FK_SUPPLEMENTARY_SOURCE_USER FOREIGN KEY (ADDED_BY_USER_ID) REFERENCES APP_USER (USER_ID)
)
COMMENT = 'External sources not present in the Marketplace dataset -- news, government reports, research.';


CREATE OR REPLACE TABLE USER_PREFERENCE (
    USER_ID              VARCHAR(255)  NOT NULL,
    DEFAULT_COUNTRY_ISO  VARCHAR(2),
    THEME                VARCHAR(10)   COMMENT 'Domain: light | dark. No dimension table -- a UI setting, never an analytical axis',
    UPDATED_AT           TIMESTAMP_NTZ,

    CONSTRAINT PK_USER_PREFERENCE PRIMARY KEY (USER_ID) RELY,
    CONSTRAINT FK_USER_PREFERENCE_USER FOREIGN KEY (USER_ID) REFERENCES APP_USER (USER_ID),
    CONSTRAINT FK_USER_PREFERENCE_COUNTRY FOREIGN KEY (DEFAULT_COUNTRY_ISO) REFERENCES DIM_COUNTRY (ISO_CODE)
)
COMMENT = 'One row per user. 1:1 with APP_USER -- a user may exist without having saved preferences.';


-- The `favorite_metrics` array, normalised the same way as tags.
CREATE OR REPLACE TABLE USER_FAVORITE_METRIC (
    USER_ID      VARCHAR(255) NOT NULL,
    METRIC_CODE  VARCHAR(30)  NOT NULL,

    CONSTRAINT PK_USER_FAVORITE_METRIC PRIMARY KEY (USER_ID, METRIC_CODE) RELY,
    CONSTRAINT FK_USER_FAVORITE_METRIC_USER FOREIGN KEY (USER_ID) REFERENCES APP_USER (USER_ID),
    CONSTRAINT FK_USER_FAVORITE_METRIC_METRIC FOREIGN KEY (METRIC_CODE) REFERENCES DIM_METRIC (METRIC_CODE)
)
COMMENT = 'Normalised form of user_preferences.favorite_metrics[] -- resolves the many-to-many between users and metrics.';


-- =====================================================================
-- 5. VERIFY
-- =====================================================================

SHOW TABLES IN SCHEMA CORE;

-- The declared constraints are queryable -- this is what lets an ERD
-- tool reverse-engineer the diagram in README.md straight from the
-- live database.
SHOW IMPORTED KEYS IN SCHEMA CORE;
