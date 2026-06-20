-- Silver layer: incremental INSERT logic from RAW_EVENTS_STREAM into domain tables
-- Co-authored with CoCo

USE DATABASE DE_CHALLENGE;
USE SCHEMA SILVER;

-- ═══════════════════════════════════════════════════════════════════
-- PRODUCTION: Stream → SILVER.PRODUCTION_EVENTS
-- ═══════════════════════════════════════════════════════════════════
INSERT INTO PRODUCTION_EVENTS (
    EVENT_ID, WORK_CENTER, AREA, EVENT_TS, EVENT_TS_LOCAL,
    STATE_CODE, STATUS_CODE, REASON_CODE, IS_PRODUCING,
    DOWNTIME_CATEGORY, COUNTER, SOURCE_PERIOD_SEC, CONNECTED,
    _SOURCE_TS
)
SELECT
    UUID_STRING()                                              AS EVENT_ID,
    COALESCE(WORK_CENTER, 'UNKNOWN')                          AS WORK_CENTER,
    COALESCE(AREA, 'UNKNOWN')                                 AS AREA,
    EVENT_TS,
    CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)          AS EVENT_TS_LOCAL,
    TRY_CAST(PARSE_JSON(PAYLOAD):state_code::VARCHAR AS NUMBER)       AS STATE_CODE,
    TRY_CAST(PARSE_JSON(PAYLOAD):status_code::VARCHAR AS NUMBER)      AS STATUS_CODE,
    TRY_CAST(PARSE_JSON(PAYLOAD):reason_code::VARCHAR AS NUMBER)      AS REASON_CODE,
    -- State 800 = producing per PLC standard
    CASE WHEN TRY_CAST(PARSE_JSON(PAYLOAD):state_code::VARCHAR AS NUMBER) = 800
         THEN TRUE ELSE FALSE END                             AS IS_PRODUCING,
    -- Downtime categorization by state code
    CASE
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):state_code::VARCHAR AS NUMBER) = 800 THEN 'PRODUCING'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):state_code::VARCHAR AS NUMBER) = 801 THEN 'IDLE'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):state_code::VARCHAR AS NUMBER) = 803 THEN 'PLANNED_STOP'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):state_code::VARCHAR AS NUMBER) IS NULL
             AND TRY_CAST(PARSE_JSON(PAYLOAD):connected::VARCHAR AS BOOLEAN) = TRUE
             THEN 'NO_DATA'
        ELSE 'UNPLANNED_STOP'
    END                                                        AS DOWNTIME_CATEGORY,
    TRY_CAST(PARSE_JSON(PAYLOAD):counter::VARCHAR AS NUMBER)   AS COUNTER,
    -- source_period stored as "3s", "5s" etc — strip unit suffix
    TRY_CAST(
        REGEXP_REPLACE(PARSE_JSON(PAYLOAD):source_period::VARCHAR, '[^0-9]', '')
    AS NUMBER)                                                 AS SOURCE_PERIOD_SEC,
    TRY_CAST(PARSE_JSON(PAYLOAD):connected::VARCHAR AS BOOLEAN) AS CONNECTED,
    EVENT_TS                                                   AS _SOURCE_TS
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS_STREAM
WHERE SOURCE = 'production'
  AND EVENT_TS IS NOT NULL;


-- ═══════════════════════════════════════════════════════════════════
-- VIBRATION: Stream → SILVER.VIBRATION_EVENTS
-- Handles both v1 and v2 schema (same 53 payload keys)
-- Heartbeat rows (only 4 keys, no RMS data) filtered via IS_VALID_READING
-- ═══════════════════════════════════════════════════════════════════
INSERT INTO VIBRATION_EVENTS (
    EVENT_ID, MOTOR_ID, WORK_CENTER, AREA, SCHEMA_VER,
    EVENT_TS, EVENT_TS_LOCAL,
    X_RMS_VELOCITY, Z_RMS_VELOCITY, X_PEAK_VELOCITY, Z_PEAK_VELOCITY,
    X_CREST_FACTOR, Z_CREST_FACTOR, X_KURTOSIS, Z_KURTOSIS,
    RPM, TEMPERATURE_C, DEVICE_AVAILABLE, QUALITY_DETAIL,
    IS_VALID_READING, ISO_ZONE, _SOURCE_TS
)
SELECT
    UUID_STRING()                                              AS EVENT_ID,
    COALESCE(ASSET, 'UNKNOWN')                                AS MOTOR_ID,
    COALESCE(WORK_CENTER, 'UNKNOWN')                          AS WORK_CENTER,
    COALESCE(AREA, 'UNKNOWN')                                 AS AREA,
    COALESCE(SCHEMA_VERSION, 'v1')                            AS SCHEMA_VER,
    EVENT_TS,
    CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)          AS EVENT_TS_LOCAL,
    TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT)    AS X_RMS_VELOCITY,
    TRY_CAST(PARSE_JSON(PAYLOAD):z_rms_velocity::VARCHAR AS FLOAT)    AS Z_RMS_VELOCITY,
    TRY_CAST(PARSE_JSON(PAYLOAD):x_peak_velocity::VARCHAR AS FLOAT)   AS X_PEAK_VELOCITY,
    TRY_CAST(PARSE_JSON(PAYLOAD):z_peak_velocity::VARCHAR AS FLOAT)   AS Z_PEAK_VELOCITY,
    TRY_CAST(PARSE_JSON(PAYLOAD):x_crest_factor::VARCHAR AS FLOAT)    AS X_CREST_FACTOR,
    TRY_CAST(PARSE_JSON(PAYLOAD):z_crest_factor::VARCHAR AS FLOAT)    AS Z_CREST_FACTOR,
    TRY_CAST(PARSE_JSON(PAYLOAD):x_kurtosis::VARCHAR AS FLOAT)        AS X_KURTOSIS,
    TRY_CAST(PARSE_JSON(PAYLOAD):z_kurtosis::VARCHAR AS FLOAT)        AS Z_KURTOSIS,
    TRY_CAST(PARSE_JSON(PAYLOAD):rpm::VARCHAR AS FLOAT)               AS RPM,
    TRY_CAST(PARSE_JSON(PAYLOAD):temperature::VARCHAR AS FLOAT)       AS TEMPERATURE_C,
    CASE WHEN TRY_CAST(PARSE_JSON(PAYLOAD):device_available::VARCHAR AS INTEGER) = 1
         THEN TRUE ELSE FALSE END                             AS DEVICE_AVAILABLE,
    QUALITY                                                    AS QUALITY_DETAIL,
    -- Heartbeat rows have NULL x_rms_velocity
    CASE WHEN PARSE_JSON(PAYLOAD):x_rms_velocity IS NOT NULL
         THEN TRUE ELSE FALSE END                             AS IS_VALID_READING,
    -- ISO 10816-3 Class II, rigid mount (15-75 kW motors)
    -- Conservative thresholds: more sensitive for early fault detection
    CASE
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) IS NULL THEN NULL
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) < 1.4  THEN 'A'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) < 2.8  THEN 'B'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) < 7.1  THEN 'C'
        ELSE 'D'
    END                                                        AS ISO_ZONE,
    EVENT_TS                                                   AS _SOURCE_TS
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS_STREAM
WHERE SOURCE = 'vibration'
  AND SCHEMA_VERSION IN ('v1', 'v2')
  AND EVENT_TS IS NOT NULL;


-- ═══════════════════════════════════════════════════════════════════
-- POWER METER: Stream → SILVER.POWER_METER_EVENTS
-- Flags MAIN-MDB as duplicate of PM-F3 (IT mirror — same physical meter)
-- ═══════════════════════════════════════════════════════════════════
INSERT INTO POWER_METER_EVENTS (
    EVENT_ID, DEVICE_ID, FLOOR, WORK_CENTER, AREA,
    EVENT_TS, EVENT_TS_LOCAL,
    ACTIVE_POWER_KW, APPARENT_POWER_KVA, REACTIVE_POWER_KVAR,
    POWER_FACTOR, FREQUENCY_HZ, CURRENT_A, CUMULATIVE_KWH,
    IS_DUPLICATE_METER, _SOURCE_TS
)
SELECT
    UUID_STRING()                                              AS EVENT_ID,
    COALESCE(ASSET, 'UNKNOWN')                                AS DEVICE_ID,
    -- Floor derivation: PM-F1→Floor 1, PM-F2→Floor 2, PM-F3→Floor 3, MAIN-MDB→Floor 3 (mirror)
    CASE
        WHEN ASSET ILIKE 'PM-F1%' THEN 'Floor 1'
        WHEN ASSET ILIKE 'PM-F2%' THEN 'Floor 2'
        WHEN ASSET ILIKE 'PM-F3%' THEN 'Floor 3'
        WHEN ASSET ILIKE 'MAIN-MDB%' THEN 'Floor 3'
        ELSE COALESCE(AREA, 'UNKNOWN')
    END                                                        AS FLOOR,
    COALESCE(WORK_CENTER, 'UNKNOWN')                          AS WORK_CENTER,
    COALESCE(AREA, 'UNKNOWN')                                 AS AREA,
    EVENT_TS,
    CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS)          AS EVENT_TS_LOCAL,
    TRY_CAST(PARSE_JSON(PAYLOAD):active_power_kw::VARCHAR AS FLOAT)      AS ACTIVE_POWER_KW,
    TRY_CAST(PARSE_JSON(PAYLOAD):apparent_power_kva::VARCHAR AS FLOAT)   AS APPARENT_POWER_KVA,
    TRY_CAST(PARSE_JSON(PAYLOAD):reactive_power_kvar::VARCHAR AS FLOAT)  AS REACTIVE_POWER_KVAR,
    TRY_CAST(PARSE_JSON(PAYLOAD):power_factor::VARCHAR AS FLOAT)         AS POWER_FACTOR,
    TRY_CAST(PARSE_JSON(PAYLOAD):frequency_hz::VARCHAR AS FLOAT)         AS FREQUENCY_HZ,
    TRY_CAST(PARSE_JSON(PAYLOAD):current_a::VARCHAR AS FLOAT)            AS CURRENT_A,
    TRY_CAST(PARSE_JSON(PAYLOAD):cumulative_kwh::VARCHAR AS FLOAT)       AS CUMULATIVE_KWH,
    -- Flag MAIN-MDB as duplicate (IT mirror of PM-F3 due to wiring issue)
    CASE WHEN ASSET ILIKE 'MAIN-MDB%' THEN TRUE ELSE FALSE END AS IS_DUPLICATE_METER,
    EVENT_TS                                                   AS _SOURCE_TS
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS_STREAM
WHERE SOURCE = 'power_meter'
  AND EVENT_TS IS NOT NULL;
