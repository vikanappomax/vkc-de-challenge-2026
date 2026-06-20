-- Silver layer: typed and cleaned tables for Production, Vibration, and Power Meter
-- Co-authored with CoCo

USE DATABASE DE_CHALLENGE;
USE SCHEMA SILVER;

-- ═══════════════════════════════════════════════════════════════════
-- PRODUCTION EVENTS
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE PRODUCTION_EVENTS (
    EVENT_ID           VARCHAR NOT NULL,
    WORK_CENTER        VARCHAR NOT NULL,
    AREA               VARCHAR NOT NULL,
    EVENT_TS           TIMESTAMP_NTZ NOT NULL,
    EVENT_TS_LOCAL     TIMESTAMP_NTZ NOT NULL,
    STATE_CODE         NUMBER(38,0),
    STATUS_CODE        NUMBER(38,0),
    REASON_CODE        NUMBER(38,0),
    IS_PRODUCING       BOOLEAN,
    DOWNTIME_CATEGORY  VARCHAR,
    COUNTER            NUMBER(38,0),
    SOURCE_PERIOD_SEC  NUMBER(38,0),
    CONNECTED          BOOLEAN,
    INGESTED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_TS         TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Silver: Production events cleaned and typed — grain: group × 3s';

-- ═══════════════════════════════════════════════════════════════════
-- VIBRATION EVENTS
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE VIBRATION_EVENTS (
    EVENT_ID           VARCHAR NOT NULL,
    MOTOR_ID           VARCHAR NOT NULL,
    WORK_CENTER        VARCHAR NOT NULL,
    AREA               VARCHAR NOT NULL,
    SCHEMA_VER         VARCHAR NOT NULL,
    EVENT_TS           TIMESTAMP_NTZ NOT NULL,
    EVENT_TS_LOCAL     TIMESTAMP_NTZ NOT NULL,
    X_RMS_VELOCITY     FLOAT,
    Z_RMS_VELOCITY     FLOAT,
    X_PEAK_VELOCITY    FLOAT,
    Z_PEAK_VELOCITY    FLOAT,
    X_CREST_FACTOR     FLOAT,
    Z_CREST_FACTOR     FLOAT,
    X_KURTOSIS         FLOAT,
    Z_KURTOSIS         FLOAT,
    RPM                FLOAT,
    TEMPERATURE_C      FLOAT,
    DEVICE_AVAILABLE   BOOLEAN,
    QUALITY_DETAIL     VARCHAR,
    IS_VALID_READING   BOOLEAN,
    ISO_ZONE           VARCHAR,
    INGESTED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_TS         TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Silver: Vibration events — grain: motor × reading interval; handles v1+v2 schema evolution';

-- ═══════════════════════════════════════════════════════════════════
-- POWER METER EVENTS
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE POWER_METER_EVENTS (
    EVENT_ID             VARCHAR NOT NULL,
    DEVICE_ID            VARCHAR NOT NULL,
    FLOOR                VARCHAR NOT NULL,
    WORK_CENTER          VARCHAR NOT NULL,
    AREA                 VARCHAR NOT NULL,
    EVENT_TS             TIMESTAMP_NTZ NOT NULL,
    EVENT_TS_LOCAL       TIMESTAMP_NTZ NOT NULL,
    ACTIVE_POWER_KW      FLOAT,
    APPARENT_POWER_KVA   FLOAT,
    REACTIVE_POWER_KVAR  FLOAT,
    POWER_FACTOR         FLOAT,
    FREQUENCY_HZ         FLOAT,
    CURRENT_A            FLOAT,
    CUMULATIVE_KWH       FLOAT,
    IS_DUPLICATE_METER   BOOLEAN,
    INGESTED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_TS           TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Silver: Power meter events — grain: device × ~1min; cumulative_kwh requires delta calc at Gold';
