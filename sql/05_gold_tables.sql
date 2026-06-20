-- Gold layer: aggregated daily tables for Production, Vibration, and Energy
-- Co-authored with CoCo

USE DATABASE DE_CHALLENGE;
USE SCHEMA GOLD;

-- ═══════════════════════════════════════════════════════════════════
-- PRODUCTION_DAILY — grain: work_center × date × shift
-- Clustering key on EVENT_DATE for time-range scans
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE PRODUCTION_DAILY (
    EVENT_DATE                   DATE NOT NULL,
    WORK_CENTER                  VARCHAR NOT NULL,
    SHIFT_NAME                   VARCHAR NOT NULL,
    UPTIME_PCT                   FLOAT,
    PRODUCING_SECONDS            NUMBER(38,0),
    TOTAL_OBSERVED_SECONDS       NUMBER(38,0),
    IDLE_SECONDS                 NUMBER(38,0),
    NO_ORDER_SECONDS             NUMBER(38,0),
    MATERIAL_SHORTAGE_SECONDS    NUMBER(38,0),
    MECHANICAL_FAULT_SECONDS     NUMBER(38,0),
    PLANNED_STOP_SECONDS         NUMBER(38,0),
    CHANGEOVER_SECONDS           NUMBER(38,0),
    SCHEDULED_MAINT_SECONDS      NUMBER(38,0),
    PRIMARY_DOWNTIME_REASON      VARCHAR,
    COUNTER_DELTA                NUMBER(38,0),
    ALWAYS_RUNNING_FLAG          BOOLEAN DEFAULT FALSE,
    REFRESHED_AT                 TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (EVENT_DATE)
COMMENT = 'Gold: daily production uptime weighted by source_period_sec — excludes ALWAYS_RUNNING machines';


-- ═══════════════════════════════════════════════════════════════════
-- VIBRATION_DAILY — grain: motor_id × date
-- Clustering key on MOTOR_ID for per-motor trend queries
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE VIBRATION_DAILY (
    EVENT_DATE                   DATE NOT NULL,
    MOTOR_ID                     VARCHAR NOT NULL,
    WORK_CENTER                  VARCHAR,
    ISO_ZONE_DAILY               VARCHAR,
    X_RMS_AVG                    FLOAT,
    X_RMS_MAX                    FLOAT,
    Z_RMS_AVG                    FLOAT,
    X_PEAK_VELOCITY_MAX          FLOAT,
    X_CREST_FACTOR_AVG           FLOAT,
    Z_CREST_FACTOR_AVG           FLOAT,
    X_KURTOSIS_AVG               FLOAT,
    TEMPERATURE_AVG_C            FLOAT,
    TEMPERATURE_MAX_C            FLOAT,
    READING_COUNT                NUMBER(38,0),
    VALID_READING_COUNT          NUMBER(38,0),
    REFRESHED_AT                 TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (MOTOR_ID, EVENT_DATE)
COMMENT = 'Gold: daily vibration summary per motor — ISO 10816-3 Class II rigid mount classification';


-- ═══════════════════════════════════════════════════════════════════
-- ENERGY_DAILY — grain: device_id × date
-- Clustering key on EVENT_DATE for time-range energy reporting
-- Excludes MAIN-MDB duplicate meter from consumption totals
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE ENERGY_DAILY (
    EVENT_DATE                   DATE NOT NULL,
    DEVICE_ID                    VARCHAR NOT NULL,
    FLOOR                        VARCHAR NOT NULL,
    KWH_CONSUMED                 FLOAT,
    KWH_PEAK                     FLOAT,
    KWH_OFF_PEAK                 FLOAT,
    ESTIMATED_COST_THB           FLOAT,
    PF_AVG                       FLOAT,
    PF_MIN                       FLOAT,
    READINGS_BELOW_PF85          NUMBER(38,0),
    READING_COUNT                NUMBER(38,0),
    IS_WEEKEND                   BOOLEAN,
    IS_DUPLICATE_METER           BOOLEAN DEFAULT FALSE,
    REFRESHED_AT                 TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (EVENT_DATE)
COMMENT = 'Gold: daily energy per device — delta-based kWh from cumulative counter, peak/off-peak split with TOU pricing';
