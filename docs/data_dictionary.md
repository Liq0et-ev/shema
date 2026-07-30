# Data dictionary

Column-level reference for `COVID19_PLATFORM.CORE`, the relational model
defined in [`ddl/01_relational_model.sql`](../ddl/01_relational_model.sql).
For the diagram and the reasoning behind the design, see the
[README](../README.md).

Conventions used throughout:

- **Key** — `PK` primary key, `FK` foreign key, `PK,FK` both.
- **Null** — whether the column accepts nulls. Only `NOT NULL` is actually
  enforced by Snowflake; see the note on constraint enforcement in the README.
- Types are Snowflake types. `NUMBER(38,0)` is an exact integer,
  `FLOAT` a double-precision approximation, `TIMESTAMP_NTZ` a timestamp
  without time zone.

---

## Dimensions

### `DIM_COUNTRY`

The conformed country dimension. One row per country; every other table in
the model references it.

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `ISO_CODE` | `VARCHAR(2)` | no | PK | ISO 3166-1 **alpha-2** code (`US`, `DE`). The single join key across the whole platform, including MongoDB. |
| `COUNTRY_NAME` | `VARCHAR(100)` | yes | | Display name. Sources spell the same country differently; the load picks deterministically, preferring the OWID indicator feed. |
| `CONTINENT` | `VARCHAR(50)` | yes | | From the OWID indicator feed. Null where that feed has no row for the country. |

Alpha-2 rather than alpha-3 because that is what the Marketplace tables use.
The Bronze ETL converts OWID's alpha-3 codes on ingest, so alpha-2 holds
everywhere without a special case at join time.

### `DIM_DATE`

One row per calendar day, spanning the union of all fact date ranges.

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `DATE_KEY` | `DATE` | no | PK | The day itself — a natural key; no surrogate integer. |
| `CALENDAR_YEAR` | `NUMBER(4,0)` | no | | |
| `CALENDAR_QUARTER` | `NUMBER(1,0)` | no | | 1–4. |
| `CALENDAR_MONTH` | `NUMBER(2,0)` | no | | 1–12. |
| `MONTH_NAME` | `VARCHAR(10)` | no | | Abbreviated (`Jan`) — Snowflake's `MONTHNAME()` returns the short form. |
| `DAY_OF_MONTH` | `NUMBER(2,0)` | no | | 1–31. |
| `DAY_OF_WEEK` | `NUMBER(1,0)` | no | | ISO numbering: 1 = Monday … 7 = Sunday. |
| `DAY_NAME` | `VARCHAR(10)` | no | | Abbreviated (`Mon`). |
| `ISO_WEEK` | `NUMBER(2,0)` | no | | ISO 8601 week number. |
| `IS_WEEKEND` | `BOOLEAN` | no | | True for Saturday and Sunday. |

`IS_WEEKEND` is not decoration. The project's EDA established that COVID
reporting follows a weekly cadence — fewer cases logged at weekends — which is
an artifact of reporting practice, not of transmission. Any analysis that has
to account for that (wave detection smooths a 7-day window precisely because of
it) can join to this flag instead of recomputing a date function.

### `DIM_METRIC`

The metric enum from the MongoDB annotations validator, as a table.

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `METRIC_CODE` | `VARCHAR(30)` | no | PK | Matches the MongoDB enum exactly. |
| `METRIC_LABEL` | `VARCHAR(100)` | no | | Human-readable form for the UI. |

Values: `confirmed_cases`, `confirmed_deaths`, `vaccinations`, `mobility`,
`other`.

### `DIM_SOURCE_TYPE`

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `SOURCE_TYPE_CODE` | `VARCHAR(20)` | no | PK | Matches the MongoDB enum exactly. |
| `SOURCE_TYPE_LABEL` | `VARCHAR(50)` | no | | |

Values: `news`, `government`, `research`, `other`.

### `APP_USER`

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `USER_ID` | `VARCHAR(255)` | no | PK | Email address or application user id. |
| `DISPLAY_NAME` | `VARCHAR(200)` | yes | | |
| `CREATED_AT` | `TIMESTAMP_NTZ` | no | | Defaults to `CURRENT_TIMESTAMP()`. |

In MongoDB, `annotations.author`, `supplementary_sources.added_by` and
`user_preferences.user_id` are three unrelated free-text strings that happen to
hold the same email. Normalising them into one entity is what turns
"everything this person contributed" from a string match into a join.

---

## Country attributes

Both tables are 1:1 with `DIM_COUNTRY` and both are optional — a country may
have a dimension row and no attribute row. They are kept separate rather than
folded into the dimension because they have different sources, refresh
cadences and coverage.

### `COUNTRY_DEMOGRAPHICS`

Source: `SILVER.STG_DATABANK_DEMOGRAPHICS` (Marketplace).

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `ISO_CODE` | `VARCHAR(2)` | no | PK, FK | → `DIM_COUNTRY` |
| `TOTAL_POPULATION` | `NUMBER(38,0)` | yes | | Never negative — asserted by a dbt `accepted_range` test upstream. |
| `TOTAL_MALE_POPULATION` | `NUMBER(38,0)` | yes | | |
| `TOTAL_FEMALE_POPULATION` | `NUMBER(38,0)` | yes | | |

Population comes from here, not from the OWID feed. The Marketplace dataset
already carries it at country level, so the Bronze ETL deliberately excludes
population from what it fetches rather than duplicating a metric the platform
already has.

### `COUNTRY_INDICATORS`

Source: `SILVER.STG_COUNTRY_INDICATORS`, ultimately Our World in Data via the
Bronze ETL.

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `ISO_CODE` | `VARCHAR(2)` | no | PK, FK | → `DIM_COUNTRY` |
| `POPULATION_DENSITY` | `FLOAT` | yes | | People per km². |
| `MEDIAN_AGE` | `FLOAT` | yes | | Years. |
| `GDP_PER_CAPITA` | `FLOAT` | yes | | Constant international dollars. |
| `HOSPITAL_BEDS_PER_THOUSAND` | `FLOAT` | yes | | Health-system capacity proxy. |
| `HUMAN_DEVELOPMENT_INDEX` | `FLOAT` | yes | | 0–1. |
| `LIFE_EXPECTANCY` | `FLOAT` | yes | | Years at birth. |
| `DIABETES_PREVALENCE` | `FLOAT` | yes | | Percent of population aged 20–79. |
| `EXTREME_POVERTY` | `FLOAT` | yes | | Percent of population. |

Coverage is thinner than demographics — notably `HUMAN_DEVELOPMENT_INDEX` and
`EXTREME_POVERTY` are missing for a meaningful number of countries. Treat nulls
here as "not published", not as zero.

---

## Facts

### `FACT_COVID_DAILY`

Grain: one row per country per day. Source: `SILVER.STG_JHU_COVID_19`
(Johns Hopkins). Clustered on `(ISO_CODE, REPORT_DATE)`.

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `ISO_CODE` | `VARCHAR(2)` | no | PK, FK | → `DIM_COUNTRY` |
| `REPORT_DATE` | `DATE` | no | PK, FK | → `DIM_DATE` |
| `CONFIRMED_CASES` | `NUMBER(38,0)` | yes | | **Cumulative** total as at `REPORT_DATE`. |
| `CONFIRMED_DEATHS` | `NUMBER(38,0)` | yes | | **Cumulative** total as at `REPORT_DATE`. |
| `NEW_CASES` | `NUMBER(38,0)` | yes | | Day-over-day delta, **signed**. Null on a country's first day. |
| `NEW_DEATHS` | `NUMBER(38,0)` | yes | | Day-over-day delta, **signed**. Null on a country's first day. |

Two things worth knowing before using this table.

**The deltas can be negative.** A negative value means the source revised its
cumulative count downward — a legitimate reporting correction, which the
project's EDA confirmed rather than treating as corruption. The values are
stored signed so that information survives; consumers that need a non-negative
series clip at the point of use, as the forecasting module does.

**Some countries' figures are summed from sub-national rows.** The upstream
staging model prefers the source's country-level row, but several countries —
the United States most severely — stop having one within months of the pandemic
starting, after which the source only publishes state-level detail. The staging
model falls back to summing states for those dates. Without that fallback those
countries' history would simply end in early 2020.

### `FACT_VACCINATION_DAILY`

Grain: one row per country per day. Source: `SILVER.STG_OWID_VACCINATIONS`.
Clustered on `(ISO_CODE, REPORT_DATE)`.

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `ISO_CODE` | `VARCHAR(2)` | no | PK, FK | → `DIM_COUNTRY` |
| `REPORT_DATE` | `DATE` | no | PK, FK | → `DIM_DATE` |
| `TOTAL_VACCINATIONS` | `NUMBER(38,0)` | yes | | Cumulative doses administered. |
| `PEOPLE_VACCINATED` | `NUMBER(38,0)` | yes | | Cumulative people with at least one dose. |
| `PEOPLE_FULLY_VACCINATED` | `NUMBER(38,0)` | yes | | Cumulative people with a complete initial course. |
| `DAILY_VACCINATIONS` | `NUMBER(38,0)` | yes | | Supplied by the source directly — unlike `FACT_COVID_DAILY`, where the daily figure is derived. |
| `TOTAL_VACCINATIONS_PER_HUNDRED` | `FLOAT` | yes | | Population-adjusted. |
| `PEOPLE_VACCINATED_PER_HUNDRED` | `FLOAT` | yes | | Population-adjusted. |
| `PEOPLE_FULLY_VACCINATED_PER_HUNDRED` | `FLOAT` | yes | | Population-adjusted. |

This series starts much later than `FACT_COVID_DAILY` — there were no
vaccinations to report for the first year of the pandemic. Joining the two
facts on `(ISO_CODE, REPORT_DATE)` must be an outer join from cases to
vaccinations, never an inner one, or the whole of 2020 disappears.

### `FACT_WHO_SITUATION_REPORT`

Grain: one row per WHO situation-report line. Source:
`SILVER.STG_WHO_SITUATION_REPORTS`.

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `WHO_REPORT_ID` | `NUMBER(38,0)` | no | PK | Surrogate, `AUTOINCREMENT`. |
| `ISO_CODE` | `VARCHAR(2)` | **yes** | FK | → `DIM_COUNTRY`. Nullable: the source includes reporting entities with no ISO 3166-1 code. |
| `REPORT_DATE` | `DATE` | no | FK | → `DIM_DATE` |
| `TOTAL_CASES` | `NUMBER(38,0)` | yes | | Cumulative, per WHO. |
| `CASES_NEW` | `NUMBER(38,0)` | yes | | |
| `DEATHS` | `NUMBER(38,0)` | yes | | Cumulative, per WHO. |
| `DEATHS_NEW` | `NUMBER(38,0)` | yes | | |
| `TRANSMISSION_CLASSIFICATION` | `VARCHAR(100)` | yes | | WHO's own categorisation of local transmission. |
| `DAYS_SINCE_LAST_REPORTED_CASE` | `NUMBER(38,0)` | yes | | |

This is the only fact with a surrogate key, and the reason is a real property
of the data rather than a stylistic choice. The other two facts are uniquely
identified by `(country, date)` and dbt tests prove it. The WHO staging model
asserts no such uniqueness and does not drop rows with a null `ISO_CODE`, so
`(country, date)` is not a candidate key here.

Treat this as a **cross-check series, not a second primary one**. WHO published
situation reports irregularly and over a much shorter window than the JHU
series covers, and the two sources do not agree exactly — quantifying that
disagreement is the point of the existing `JHU_WHO_CROSS_CHECK` mart.

---

## User-generated content

The relational projection of the MongoDB collections. **MongoDB remains the
system of record**; these tables are populated by a sync job, and the `*_ID`
primary keys carry the source `ObjectId` hex so any row traces back to its
document.

### `ANNOTATION`

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `ANNOTATION_ID` | `VARCHAR(24)` | no | PK | MongoDB `ObjectId` hex. |
| `ISO_CODE` | `VARCHAR(2)` | no | FK | → `DIM_COUNTRY`. The key that ties user content to the warehouse. |
| `METRIC_CODE` | `VARCHAR(30)` | no | FK | → `DIM_METRIC` |
| `ANNOTATION_DATE` | `DATE` | yes | FK | → `DIM_DATE`. Nullable by design: an annotation may concern one specific day, or the country generally. |
| `AUTHOR_USER_ID` | `VARCHAR(255)` | yes | FK | → `APP_USER` |
| `COMMENT_TEXT` | `VARCHAR(2000)` | no | | The comment. Length limit mirrors the MongoDB validator. |
| `CREATED_AT` | `TIMESTAMP_NTZ` | no | | |
| `UPDATED_AT` | `TIMESTAMP_NTZ` | yes | | Null until first edited. |

Named `COMMENT_TEXT` rather than `COMMENT` because `COMMENT` is a Snowflake
keyword — it is the syntax for attaching descriptions to objects, and using it
as a column name causes parse errors in enough contexts to be worth avoiding.

### `ANNOTATION_TAG`

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `ANNOTATION_ID` | `VARCHAR(24)` | no | PK, FK | → `ANNOTATION` |
| `TAG` | `VARCHAR(50)` | no | PK | |

In the document model this is the `tags` array inside an annotation. First
normal form does not permit a repeating group in a column, so it becomes a
child table keyed on the parent plus the value. The sync replaces all tags for
an annotation on each run rather than merging them — an edit in MongoDB can
*remove* a tag, and a merge with no delete branch would leave it behind.

### `SUPPLEMENTARY_SOURCE`

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `SOURCE_ID` | `VARCHAR(24)` | no | PK | MongoDB `ObjectId` hex. |
| `ISO_CODE` | `VARCHAR(2)` | no | FK | → `DIM_COUNTRY` |
| `SOURCE_TYPE_CODE` | `VARCHAR(20)` | no | FK | → `DIM_SOURCE_TYPE` |
| `TITLE` | `VARCHAR(500)` | no | | |
| `URL` | `VARCHAR(2000)` | no | | |
| `DESCRIPTION` | `VARCHAR(4000)` | yes | | |
| `ADDED_BY_USER_ID` | `VARCHAR(255)` | yes | FK | → `APP_USER` |
| `CREATED_AT` | `TIMESTAMP_NTZ` | no | | |

### `USER_PREFERENCE`

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `USER_ID` | `VARCHAR(255)` | no | PK, FK | → `APP_USER` |
| `DEFAULT_COUNTRY_ISO` | `VARCHAR(2)` | yes | FK | → `DIM_COUNTRY` |
| `THEME` | `VARCHAR(10)` | yes | | Domain: `light` \| `dark`. |
| `UPDATED_AT` | `TIMESTAMP_NTZ` | yes | | |

`THEME` has no dimension table, unlike `metric` and `source_type`. The
distinction is whether a value is ever an analytical axis: annotations get
filtered and grouped by metric, so metric earns a dimension; nobody groups
anything by UI theme. Its domain is checked in
[`ddl/03_integrity_checks.sql`](../ddl/03_integrity_checks.sql) instead.

### `USER_FAVORITE_METRIC`

| Column | Type | Null | Key | Description |
|---|---|---|---|---|
| `USER_ID` | `VARCHAR(255)` | no | PK, FK | → `APP_USER` |
| `METRIC_CODE` | `VARCHAR(30)` | no | PK, FK | → `DIM_METRIC` |

The `favorite_metrics` array, normalised the same way as tags. This is the
model's only true many-to-many relationship, and this table is its resolution.

---

## Where each table comes from

| Core table | Silver / MongoDB source | Original source |
|---|---|---|
| `DIM_COUNTRY` | union of all Silver models | derived |
| `DIM_DATE` | generated | derived |
| `DIM_METRIC` | seeded literals | MongoDB validator enum |
| `DIM_SOURCE_TYPE` | seeded literals | MongoDB validator enum |
| `APP_USER` | derived during MongoDB sync | derived |
| `COUNTRY_DEMOGRAPHICS` | `STG_DATABANK_DEMOGRAPHICS` | Marketplace `DATABANK_DEMOGRAPHICS` |
| `COUNTRY_INDICATORS` | `STG_COUNTRY_INDICATORS` | Our World in Data, via Bronze ETL |
| `FACT_COVID_DAILY` | `STG_JHU_COVID_19` | Marketplace `JHU_COVID_19` |
| `FACT_VACCINATION_DAILY` | `STG_OWID_VACCINATIONS` | Marketplace `OWID_VACCINATIONS` |
| `FACT_WHO_SITUATION_REPORT` | `STG_WHO_SITUATION_REPORTS` | Marketplace `WHO_SITUATION_REPORTS` |
| `ANNOTATION` | `annotations` | user-generated |
| `ANNOTATION_TAG` | `annotations.tags[]` | user-generated |
| `SUPPLEMENTARY_SOURCE` | `supplementary_sources` | user-generated |
| `USER_PREFERENCE` | `user_preferences` | user-generated |
| `USER_FAVORITE_METRIC` | `user_preferences.favorite_metrics[]` | user-generated |

## Relationship to the Gold layer

This model does not replace `GOLD.COUNTRY_DAILY_ENRICHED`. That table is the
denormalised join of cases, vaccinations, demographics and indicators, with
population-adjusted rates computed on top, and it exists so the API and
dashboard can serve a country's full history without joining anything.

`CORE` is the normalised statement of what the data *is*; `GOLD` is a
performance-shaped view of it for serving. Both are legitimate, and a warehouse
usually wants both — the normalised core is where integrity and meaning live,
the mart is where query latency is won. Reconstructing `COUNTRY_DAILY_ENRICHED`
from `CORE` is a four-table join on `ISO_CODE` and `REPORT_DATE`.
