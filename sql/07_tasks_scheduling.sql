-- Automated scheduling: Stream → Silver → Gold via Snowflake Tasks
-- Co-authored with CoCo

USE DATABASE DE_CHALLENGE;

-- ═══════════════════════════════════════════════════════════════════
-- SILVER TASKS — consume RAW_EVENTS_STREAM every 5 minutes
-- Three child tasks (one per domain) under a single root task
-- WHEN clause checks stream has data before consuming credits
-- ═══════════════════════════════════════════════════════════════════

-- Root task: orchestrator (runs every 5 min, checks stream has rows)
CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.LOAD_SILVER_ROOT
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = '5 MINUTE'
    COMMENT   = 'Root task: triggers Silver load when RAW_EVENTS_STREAM has data'
    WHEN SYSTEM$STREAM_HAS_DATA('DE_CHALLENGE.BRONZE.RAW_EVENTS_STREAM')
AS
    SELECT 1;  -- no-op; children do the work


-- Child 1: Production
CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.LOAD_SILVER_PRODUCTION
    WAREHOUSE = COMPUTE_WH
    AFTER DE_CHALLENGE.SILVER.LOAD_SILVER_ROOT
    COMMENT   = 'Insert production events from stream into SILVER.PRODUCTION_EVENTS'
AS
INSERT INTO DE_CHALLENGE.SILVER.PRODUCTION_EVENTS (
    EVENT_ID, WORK_CENTER, AREA, EVENT_TS, EVENT_TS_LOCAL,
    STATE_CODE, STATUS_CODE, REASON_CODE, IS_PRODUCING,
    DOWNTIME_CATEGORY, COUNTER, SOURCE_PERIOD_SEC, CONNECTED, _SOURCE_TS
)
SELECT
    UUID_STRING(),
    COALESCE(WORK_CENTER, 'UNKNOWN'),
    COALESCE(AREA, 'UNKNOWN'),
    EVENT_TS,
    CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS),
    TRY_CAST(PARSE_JSON(PAYLOAD):n3_state_code::VARCHAR AS NUMBER),
    TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER),
    TRY_CAST(PARSE_JSON(PAYLOAD):n3_reason_code::VARCHAR AS NUMBER),
    CASE WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_state_code::VARCHAR AS NUMBER) = 800 THEN TRUE ELSE FALSE END,
    CASE
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_state_code::VARCHAR AS NUMBER) = 800 THEN 'PRODUCING'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_state_code::VARCHAR AS NUMBER) = 801 THEN 'IDLE'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER) = 803105 THEN 'EXCLUDED_NO_ORDER'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER) = 803101 THEN 'MATERIAL_SHORTAGE'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER) = 803112 THEN 'MECHANICAL_FAULT'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER) = 803102 THEN 'QUALITY_HOLD'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER) = 803103 THEN 'CHANGEOVER'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER) = 803104 THEN 'SCHEDULED_MAINTENANCE'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_status_code::VARCHAR AS NUMBER) = 803111 THEN 'ELECTRICAL_FAULT'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_state_code::VARCHAR AS NUMBER) = 803 THEN 'PLANNED_STOP'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):n3_state_code::VARCHAR AS NUMBER) IS NULL
             AND PARSE_JSON(PAYLOAD):connected::VARCHAR = 'true' THEN 'NO_DATA'
        ELSE 'UNPLANNED_STOP'
    END,
    TRY_CAST(REGEXP_REPLACE(PARSE_JSON(PAYLOAD):source_period::VARCHAR, '[^0-9]', '') AS NUMBER),
    CASE WHEN PARSE_JSON(PAYLOAD):connected::VARCHAR = 'true' THEN TRUE ELSE FALSE END,
    EVENT_TS
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS_STREAM
WHERE SOURCE = 'redlion_cr3000'
  AND EVENT_TS IS NOT NULL;


-- Child 2: Vibration
CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.LOAD_SILVER_VIBRATION
    WAREHOUSE = COMPUTE_WH
    AFTER DE_CHALLENGE.SILVER.LOAD_SILVER_ROOT
    COMMENT   = 'Insert vibration events (v1+v2) from stream into SILVER.VIBRATION_EVENTS'
AS
INSERT INTO DE_CHALLENGE.SILVER.VIBRATION_EVENTS (
    EVENT_ID, MOTOR_ID, WORK_CENTER, AREA, SCHEMA_VER,
    EVENT_TS, EVENT_TS_LOCAL,
    X_RMS_VELOCITY, Z_RMS_VELOCITY, X_PEAK_VELOCITY, Z_PEAK_VELOCITY,
    X_CREST_FACTOR, Z_CREST_FACTOR, X_KURTOSIS, Z_KURTOSIS,
    RPM, TEMPERATURE_C, DEVICE_AVAILABLE, QUALITY_DETAIL,
    IS_VALID_READING, ISO_ZONE, _SOURCE_TS
)
SELECT
    UUID_STRING(),
    COALESCE(ASSET, 'UNKNOWN'),
    COALESCE(WORK_CENTER, 'UNKNOWN'),
    COALESCE(AREA, 'UNKNOWN'),
    COALESCE(SCHEMA_VERSION, 'v1'),
    EVENT_TS,
    CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS),
    TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):z_rms_velocity::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):x_peak_velocity::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):z_peak_velocity::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):x_crest_factor::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):z_crest_factor::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):x_kurtosis::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):z_kurtosis::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):rpm::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):temperature::VARCHAR AS FLOAT),
    CASE WHEN TRY_CAST(PARSE_JSON(PAYLOAD):device_available::VARCHAR AS INTEGER) = 1 THEN TRUE ELSE FALSE END,
    QUALITY,
    CASE WHEN PARSE_JSON(PAYLOAD):x_rms_velocity IS NOT NULL THEN TRUE ELSE FALSE END,
    CASE
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) IS NULL THEN NULL
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) < 1.4  THEN 'A'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) < 2.8  THEN 'B'
        WHEN TRY_CAST(PARSE_JSON(PAYLOAD):x_rms_velocity::VARCHAR AS FLOAT) < 7.1  THEN 'C'
        ELSE 'D'
    END,
    EVENT_TS
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS_STREAM
WHERE SCHEMA_VERSION LIKE 'vibration.raw.%'
  AND EVENT_TS IS NOT NULL;


-- Child 3: Power Meter
CREATE OR REPLACE TASK DE_CHALLENGE.SILVER.LOAD_SILVER_POWER_METER
    WAREHOUSE = COMPUTE_WH
    AFTER DE_CHALLENGE.SILVER.LOAD_SILVER_ROOT
    COMMENT   = 'Insert power meter events from stream into SILVER.POWER_METER_EVENTS'
AS
INSERT INTO DE_CHALLENGE.SILVER.POWER_METER_EVENTS (
    EVENT_ID, DEVICE_ID, FLOOR, WORK_CENTER, AREA,
    EVENT_TS, EVENT_TS_LOCAL,
    ACTIVE_POWER_KW, APPARENT_POWER_KVA, REACTIVE_POWER_KVAR,
    POWER_FACTOR, FREQUENCY_HZ, CURRENT_A, CUMULATIVE_KWH,
    IS_DUPLICATE_METER, _SOURCE_TS
)
SELECT
    UUID_STRING(),
    COALESCE(ASSET, 'UNKNOWN'),
    CASE
        WHEN ASSET ILIKE 'PM-F1%' THEN 'Floor 1'
        WHEN ASSET ILIKE 'PM-F2%' THEN 'Floor 2'
        WHEN ASSET ILIKE 'PM-F3%' THEN 'Floor 3'
        WHEN ASSET ILIKE 'MAIN-MDB%' THEN 'Floor 3'
        ELSE COALESCE(AREA, 'UNKNOWN')
    END,
    COALESCE(WORK_CENTER, 'UNKNOWN'),
    COALESCE(AREA, 'UNKNOWN'),
    EVENT_TS,
    CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', EVENT_TS),
    TRY_CAST(PARSE_JSON(PAYLOAD):active_power_kw::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):apparent_power_kva::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):reactive_power_kvar::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):power_factor::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):frequency_hz::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):current_a::VARCHAR AS FLOAT),
    TRY_CAST(PARSE_JSON(PAYLOAD):cumulative_kwh::VARCHAR AS FLOAT),
    CASE WHEN ASSET ILIKE 'MAIN-MDB%' THEN TRUE ELSE FALSE END,
    EVENT_TS
FROM DE_CHALLENGE.BRONZE.RAW_EVENTS_STREAM
WHERE SCHEMA_VERSION LIKE 'power_meter.raw.%'
  AND EVENT_TS IS NOT NULL;


-- ═══════════════════════════════════════════════════════════════════
-- GOLD TASK — runs after Silver completes, refreshes Gold tables
-- Scheduled independently at 15-minute intervals (allows Silver to
-- accumulate multiple runs before Gold re-aggregates)
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TASK DE_CHALLENGE.GOLD.REFRESH_GOLD_DAILY
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = '15 MINUTE'
    COMMENT   = 'Refreshes all Gold daily tables from Silver — MERGE upsert pattern'
AS
    CALL DE_CHALLENGE.GOLD.SP_REFRESH_GOLD();


-- ═══════════════════════════════════════════════════════════════════
-- Stored procedure wrapping Gold refresh (allows multi-statement exec)
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE DE_CHALLENGE.GOLD.SP_REFRESH_GOLD()
    RETURNS VARCHAR
    LANGUAGE SQL
    EXECUTE AS CALLER
    COMMENT = 'Runs all Gold MERGE statements in sequence'
AS
BEGIN
    -- Production Gold
    MERGE INTO DE_CHALLENGE.GOLD.PRODUCTION_DAILY tgt
    USING (
        SELECT
            EVENT_TS_LOCAL::DATE AS event_date,
            WORK_CENTER,
            CASE
                WHEN HOUR(EVENT_TS_LOCAL)*60+MINUTE(EVENT_TS_LOCAL) BETWEEN 45 AND 585 THEN 'Morning'
                WHEN HOUR(EVENT_TS_LOCAL)*60+MINUTE(EVENT_TS_LOCAL) BETWEEN 585 AND 765 THEN 'Day'
                WHEN HOUR(EVENT_TS_LOCAL)*60+MINUTE(EVENT_TS_LOCAL) BETWEEN 765 AND 1305 THEN 'Evening'
                ELSE 'Night'
            END AS shift_name,
            ROUND(SUM(CASE WHEN IS_PRODUCING THEN SOURCE_PERIOD_SEC ELSE 0 END)*100.0
                  / NULLIF(SUM(SOURCE_PERIOD_SEC),0), 2) AS uptime_pct,
            SUM(CASE WHEN IS_PRODUCING THEN SOURCE_PERIOD_SEC ELSE 0 END) AS producing_seconds,
            SUM(SOURCE_PERIOD_SEC) AS total_observed_seconds,
            SUM(CASE WHEN DOWNTIME_CATEGORY='IDLE' THEN SOURCE_PERIOD_SEC ELSE 0 END) AS idle_seconds,
            SUM(CASE WHEN DOWNTIME_CATEGORY IN ('NO_DATA','EXCLUDED_NO_ORDER') THEN SOURCE_PERIOD_SEC ELSE 0 END) AS no_order_seconds,
            SUM(CASE WHEN DOWNTIME_CATEGORY='MATERIAL_SHORTAGE' THEN SOURCE_PERIOD_SEC ELSE 0 END) AS material_shortage_seconds,
            SUM(CASE WHEN DOWNTIME_CATEGORY IN ('MECHANICAL_FAULT','ELECTRICAL_FAULT','UNPLANNED_STOP') THEN SOURCE_PERIOD_SEC ELSE 0 END) AS mechanical_fault_seconds,
            SUM(CASE WHEN DOWNTIME_CATEGORY IN ('PLANNED_STOP','SCHEDULED_MAINTENANCE','QUALITY_HOLD') THEN SOURCE_PERIOD_SEC ELSE 0 END) AS planned_stop_seconds,
            SUM(CASE WHEN DOWNTIME_CATEGORY='CHANGEOVER' THEN SOURCE_PERIOD_SEC ELSE 0 END) AS changeover_seconds,
            SUM(CASE WHEN DOWNTIME_CATEGORY='SCHEDULED_MAINTENANCE' THEN SOURCE_PERIOD_SEC ELSE 0 END) AS scheduled_maint_seconds,
            MAX(COUNTER)-MIN(COUNTER) AS counter_delta
        FROM DE_CHALLENGE.SILVER.PRODUCTION_EVENTS
        GROUP BY event_date, WORK_CENTER, shift_name
    ) src
    ON tgt.EVENT_DATE=src.event_date AND tgt.WORK_CENTER=src.WORK_CENTER AND tgt.SHIFT_NAME=src.shift_name
    WHEN MATCHED THEN UPDATE SET
        tgt.UPTIME_PCT=src.uptime_pct, tgt.PRODUCING_SECONDS=src.producing_seconds,
        tgt.TOTAL_OBSERVED_SECONDS=src.total_observed_seconds,
        tgt.IDLE_SECONDS=src.idle_seconds, tgt.NO_ORDER_SECONDS=src.no_order_seconds,
        tgt.MECHANICAL_FAULT_SECONDS=src.mechanical_fault_seconds,
        tgt.PLANNED_STOP_SECONDS=src.planned_stop_seconds,
        tgt.COUNTER_DELTA=src.counter_delta, tgt.REFRESHED_AT=CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (EVENT_DATE,WORK_CENTER,SHIFT_NAME,UPTIME_PCT,PRODUCING_SECONDS,
        TOTAL_OBSERVED_SECONDS,IDLE_SECONDS,NO_ORDER_SECONDS,MECHANICAL_FAULT_SECONDS,
        PLANNED_STOP_SECONDS,COUNTER_DELTA)
    VALUES (src.event_date,src.WORK_CENTER,src.shift_name,src.uptime_pct,src.producing_seconds,
        src.total_observed_seconds,src.idle_seconds,src.no_order_seconds,
        src.mechanical_fault_seconds,src.planned_stop_seconds,src.counter_delta);

    -- Vibration Gold
    MERGE INTO DE_CHALLENGE.GOLD.VIBRATION_DAILY tgt
    USING (
        SELECT
            EVENT_TS_LOCAL::DATE AS event_date, MOTOR_ID, MAX(WORK_CENTER) AS work_center,
            CASE WHEN AVG(X_RMS_VELOCITY)<1.4 THEN 'A' WHEN AVG(X_RMS_VELOCITY)<2.8 THEN 'B'
                 WHEN AVG(X_RMS_VELOCITY)<7.1 THEN 'C' ELSE 'D' END AS iso_zone_daily,
            AVG(X_RMS_VELOCITY) AS x_rms_avg, MAX(X_RMS_VELOCITY) AS x_rms_max,
            AVG(Z_RMS_VELOCITY) AS z_rms_avg, MAX(X_PEAK_VELOCITY) AS x_peak_velocity_max,
            AVG(X_CREST_FACTOR) AS x_crest_factor_avg, AVG(Z_CREST_FACTOR) AS z_crest_factor_avg,
            AVG(X_KURTOSIS) AS x_kurtosis_avg, AVG(TEMPERATURE_C) AS temperature_avg_c,
            MAX(TEMPERATURE_C) AS temperature_max_c, COUNT(*) AS reading_count,
            COUNT_IF(IS_VALID_READING) AS valid_reading_count
        FROM DE_CHALLENGE.SILVER.VIBRATION_EVENTS WHERE IS_VALID_READING=TRUE
        GROUP BY event_date, MOTOR_ID
    ) src
    ON tgt.EVENT_DATE=src.event_date AND tgt.MOTOR_ID=src.MOTOR_ID
    WHEN MATCHED THEN UPDATE SET
        tgt.WORK_CENTER=src.work_center, tgt.ISO_ZONE_DAILY=src.iso_zone_daily,
        tgt.X_RMS_AVG=src.x_rms_avg, tgt.X_RMS_MAX=src.x_rms_max,
        tgt.Z_RMS_AVG=src.z_rms_avg, tgt.X_PEAK_VELOCITY_MAX=src.x_peak_velocity_max,
        tgt.X_CREST_FACTOR_AVG=src.x_crest_factor_avg, tgt.Z_CREST_FACTOR_AVG=src.z_crest_factor_avg,
        tgt.X_KURTOSIS_AVG=src.x_kurtosis_avg, tgt.TEMPERATURE_AVG_C=src.temperature_avg_c,
        tgt.TEMPERATURE_MAX_C=src.temperature_max_c, tgt.READING_COUNT=src.reading_count,
        tgt.VALID_READING_COUNT=src.valid_reading_count, tgt.REFRESHED_AT=CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (EVENT_DATE,MOTOR_ID,WORK_CENTER,ISO_ZONE_DAILY,X_RMS_AVG,X_RMS_MAX,
        Z_RMS_AVG,X_PEAK_VELOCITY_MAX,X_CREST_FACTOR_AVG,Z_CREST_FACTOR_AVG,X_KURTOSIS_AVG,
        TEMPERATURE_AVG_C,TEMPERATURE_MAX_C,READING_COUNT,VALID_READING_COUNT)
    VALUES (src.event_date,src.MOTOR_ID,src.work_center,src.iso_zone_daily,src.x_rms_avg,src.x_rms_max,
        src.z_rms_avg,src.x_peak_velocity_max,src.x_crest_factor_avg,src.z_crest_factor_avg,
        src.x_kurtosis_avg,src.temperature_avg_c,src.temperature_max_c,src.reading_count,src.valid_reading_count);

    -- Energy Gold (delta-based)
    MERGE INTO DE_CHALLENGE.GOLD.ENERGY_DAILY tgt
    USING (
        WITH deltas AS (
            SELECT EVENT_TS_LOCAL::DATE AS event_date, DEVICE_ID, FLOOR, IS_DUPLICATE_METER,
                   POWER_FACTOR, EVENT_TS_LOCAL,
                   CUMULATIVE_KWH - LAG(CUMULATIVE_KWH) OVER (PARTITION BY DEVICE_ID ORDER BY EVENT_TS) AS kwh_delta,
                   CASE WHEN HOUR(EVENT_TS_LOCAL) BETWEEN 8 AND 21 THEN TRUE ELSE FALSE END AS is_peak
            FROM DE_CHALLENGE.SILVER.POWER_METER_EVENTS
            WHERE IS_DUPLICATE_METER = FALSE
        )
        SELECT event_date, DEVICE_ID, MAX(FLOOR) AS floor,
               SUM(CASE WHEN kwh_delta>0 THEN kwh_delta ELSE 0 END) AS kwh_consumed,
               SUM(CASE WHEN kwh_delta>0 AND is_peak THEN kwh_delta ELSE 0 END) AS kwh_peak,
               SUM(CASE WHEN kwh_delta>0 AND NOT is_peak THEN kwh_delta ELSE 0 END) AS kwh_off_peak,
               SUM(CASE WHEN kwh_delta>0 AND is_peak THEN kwh_delta*4.1821 ELSE 0 END)
               + SUM(CASE WHEN kwh_delta>0 AND NOT is_peak THEN kwh_delta*2.6369 ELSE 0 END) AS estimated_cost_thb,
               AVG(POWER_FACTOR) AS pf_avg, MIN(POWER_FACTOR) AS pf_min,
               COUNT_IF(POWER_FACTOR<0.85) AS readings_below_pf85, COUNT(*) AS reading_count,
               CASE WHEN DAYOFWEEK(event_date) IN (0,6) THEN TRUE ELSE FALSE END AS is_weekend
        FROM deltas GROUP BY event_date, DEVICE_ID
    ) src
    ON tgt.EVENT_DATE=src.event_date AND tgt.DEVICE_ID=src.DEVICE_ID
    WHEN MATCHED THEN UPDATE SET
        tgt.FLOOR=src.floor, tgt.KWH_CONSUMED=src.kwh_consumed, tgt.KWH_PEAK=src.kwh_peak,
        tgt.KWH_OFF_PEAK=src.kwh_off_peak, tgt.ESTIMATED_COST_THB=src.estimated_cost_thb,
        tgt.PF_AVG=src.pf_avg, tgt.PF_MIN=src.pf_min, tgt.READINGS_BELOW_PF85=src.readings_below_pf85,
        tgt.READING_COUNT=src.reading_count, tgt.IS_WEEKEND=src.is_weekend, tgt.REFRESHED_AT=CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (EVENT_DATE,DEVICE_ID,FLOOR,KWH_CONSUMED,KWH_PEAK,KWH_OFF_PEAK,
        ESTIMATED_COST_THB,PF_AVG,PF_MIN,READINGS_BELOW_PF85,READING_COUNT,IS_WEEKEND)
    VALUES (src.event_date,src.DEVICE_ID,src.floor,src.kwh_consumed,src.kwh_peak,src.kwh_off_peak,
        src.estimated_cost_thb,src.pf_avg,src.pf_min,src.readings_below_pf85,src.reading_count,src.is_weekend);

    RETURN 'Gold refresh complete';
END;


-- ═══════════════════════════════════════════════════════════════════
-- RESUME ALL TASKS (tasks are created in SUSPENDED state by default)
-- ═══════════════════════════════════════════════════════════════════
ALTER TASK DE_CHALLENGE.SILVER.LOAD_SILVER_PRODUCTION RESUME;
ALTER TASK DE_CHALLENGE.SILVER.LOAD_SILVER_VIBRATION RESUME;
ALTER TASK DE_CHALLENGE.SILVER.LOAD_SILVER_POWER_METER RESUME;
ALTER TASK DE_CHALLENGE.SILVER.LOAD_SILVER_ROOT RESUME;
ALTER TASK DE_CHALLENGE.GOLD.REFRESH_GOLD_DAILY RESUME;
