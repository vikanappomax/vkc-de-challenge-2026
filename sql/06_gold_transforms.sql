-- Gold layer: aggregation logic for daily tables
-- Co-authored with CoCo

USE DATABASE DE_CHALLENGE;
USE SCHEMA GOLD;

-- ═══════════════════════════════════════════════════════════════════
-- PRODUCTION_DAILY — weighted uptime by source_period_sec
-- Detects ALWAYS_RUNNING machines: 100% state=800 AND counter never increments
-- ═══════════════════════════════════════════════════════════════════
MERGE INTO PRODUCTION_DAILY tgt
USING (
    WITH shift_assigned AS (
        SELECT
            p.*,
            EVENT_TS_LOCAL::DATE AS event_date,
            CASE
                WHEN HOUR(EVENT_TS_LOCAL) * 60 + MINUTE(EVENT_TS_LOCAL) BETWEEN 45 AND 405       THEN 'Morning'   -- 00:45–06:45
                WHEN HOUR(EVENT_TS_LOCAL) * 60 + MINUTE(EVENT_TS_LOCAL) BETWEEN 405 AND 885      THEN 'Day'       -- 06:45–14:45
                WHEN HOUR(EVENT_TS_LOCAL) * 60 + MINUTE(EVENT_TS_LOCAL) BETWEEN 885 AND 1365     THEN 'Evening'   -- 14:45–22:45
                ELSE 'Night'                                                                                       -- 22:45–00:45
            END AS shift_name
        FROM DE_CHALLENGE.SILVER.PRODUCTION_EVENTS p
    ),
    -- Detect ALWAYS_RUNNING: machines that report 100% producing but counter=0 delta
    always_running AS (
        SELECT
            event_date,
            WORK_CENTER,
            shift_name,
            CASE
                WHEN COUNT_IF(IS_PRODUCING) = COUNT(*) 
                     AND (MAX(COUNTER) - MIN(COUNTER)) = 0
                THEN TRUE
                ELSE FALSE
            END AS is_always_running
        FROM shift_assigned
        GROUP BY event_date, WORK_CENTER, shift_name
    ),
    aggregated AS (
        SELECT
            s.event_date,
            s.WORK_CENTER,
            s.shift_name,
            -- Weighted uptime: producing seconds / total observed seconds
            ROUND(
                SUM(CASE WHEN s.IS_PRODUCING THEN s.SOURCE_PERIOD_SEC ELSE 0 END) * 100.0
                / NULLIF(SUM(s.SOURCE_PERIOD_SEC), 0),
                2
            ) AS uptime_pct,
            SUM(CASE WHEN s.IS_PRODUCING THEN s.SOURCE_PERIOD_SEC ELSE 0 END) AS producing_seconds,
            SUM(s.SOURCE_PERIOD_SEC) AS total_observed_seconds,
            -- Downtime breakdown
            SUM(CASE WHEN s.DOWNTIME_CATEGORY = 'IDLE' THEN s.SOURCE_PERIOD_SEC ELSE 0 END) AS idle_seconds,
            SUM(CASE WHEN s.DOWNTIME_CATEGORY = 'NO_DATA' THEN s.SOURCE_PERIOD_SEC ELSE 0 END) AS no_order_seconds,
            SUM(CASE WHEN s.DOWNTIME_CATEGORY IN ('MATERIAL_SHORTAGE') THEN s.SOURCE_PERIOD_SEC ELSE 0 END) AS material_shortage_seconds,
            SUM(CASE WHEN s.DOWNTIME_CATEGORY = 'UNPLANNED_STOP' THEN s.SOURCE_PERIOD_SEC ELSE 0 END) AS mechanical_fault_seconds,
            SUM(CASE WHEN s.DOWNTIME_CATEGORY = 'PLANNED_STOP' THEN s.SOURCE_PERIOD_SEC ELSE 0 END) AS planned_stop_seconds,
            0 AS changeover_seconds,
            0 AS scheduled_maint_seconds,
            -- Primary downtime reason (mode)
            (SELECT DOWNTIME_CATEGORY FROM shift_assigned s2
             WHERE s2.event_date = s.event_date AND s2.WORK_CENTER = s.WORK_CENTER
               AND s2.shift_name = s.shift_name AND s2.IS_PRODUCING = FALSE
             GROUP BY DOWNTIME_CATEGORY ORDER BY SUM(s2.SOURCE_PERIOD_SEC) DESC LIMIT 1
            ) AS primary_downtime_reason,
            MAX(s.COUNTER) - MIN(s.COUNTER) AS counter_delta,
            ar.is_always_running AS always_running_flag
        FROM shift_assigned s
        JOIN always_running ar
            ON s.event_date = ar.event_date
            AND s.WORK_CENTER = ar.WORK_CENTER
            AND s.shift_name = ar.shift_name
        -- Exclude ALWAYS_RUNNING machines from uptime calculation
        WHERE ar.is_always_running = FALSE
        GROUP BY s.event_date, s.WORK_CENTER, s.shift_name, ar.is_always_running
    )
    SELECT * FROM aggregated
) src
ON tgt.EVENT_DATE = src.event_date
   AND tgt.WORK_CENTER = src.WORK_CENTER
   AND tgt.SHIFT_NAME = src.shift_name
WHEN MATCHED THEN UPDATE SET
    tgt.UPTIME_PCT = src.uptime_pct,
    tgt.PRODUCING_SECONDS = src.producing_seconds,
    tgt.TOTAL_OBSERVED_SECONDS = src.total_observed_seconds,
    tgt.IDLE_SECONDS = src.idle_seconds,
    tgt.NO_ORDER_SECONDS = src.no_order_seconds,
    tgt.MATERIAL_SHORTAGE_SECONDS = src.material_shortage_seconds,
    tgt.MECHANICAL_FAULT_SECONDS = src.mechanical_fault_seconds,
    tgt.PLANNED_STOP_SECONDS = src.planned_stop_seconds,
    tgt.CHANGEOVER_SECONDS = src.changeover_seconds,
    tgt.SCHEDULED_MAINT_SECONDS = src.scheduled_maint_seconds,
    tgt.PRIMARY_DOWNTIME_REASON = src.primary_downtime_reason,
    tgt.COUNTER_DELTA = src.counter_delta,
    tgt.ALWAYS_RUNNING_FLAG = src.always_running_flag,
    tgt.REFRESHED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    EVENT_DATE, WORK_CENTER, SHIFT_NAME, UPTIME_PCT,
    PRODUCING_SECONDS, TOTAL_OBSERVED_SECONDS,
    IDLE_SECONDS, NO_ORDER_SECONDS, MATERIAL_SHORTAGE_SECONDS,
    MECHANICAL_FAULT_SECONDS, PLANNED_STOP_SECONDS,
    CHANGEOVER_SECONDS, SCHEDULED_MAINT_SECONDS,
    PRIMARY_DOWNTIME_REASON, COUNTER_DELTA, ALWAYS_RUNNING_FLAG
) VALUES (
    src.event_date, src.WORK_CENTER, src.shift_name, src.uptime_pct,
    src.producing_seconds, src.total_observed_seconds,
    src.idle_seconds, src.no_order_seconds, src.material_shortage_seconds,
    src.mechanical_fault_seconds, src.planned_stop_seconds,
    src.changeover_seconds, src.scheduled_maint_seconds,
    src.primary_downtime_reason, src.counter_delta, src.always_running_flag
);


-- ═══════════════════════════════════════════════════════════════════
-- VIBRATION_DAILY — daily per-motor aggregates with ISO zone
-- ═══════════════════════════════════════════════════════════════════
MERGE INTO VIBRATION_DAILY tgt
USING (
    SELECT
        EVENT_TS_LOCAL::DATE                          AS event_date,
        MOTOR_ID,
        MAX(WORK_CENTER)                              AS work_center,
        -- ISO zone for the day based on daily average X RMS
        CASE
            WHEN AVG(X_RMS_VELOCITY) < 1.4  THEN 'A'
            WHEN AVG(X_RMS_VELOCITY) < 2.8  THEN 'B'
            WHEN AVG(X_RMS_VELOCITY) < 7.1  THEN 'C'
            ELSE 'D'
        END                                           AS iso_zone_daily,
        AVG(X_RMS_VELOCITY)                           AS x_rms_avg,
        MAX(X_RMS_VELOCITY)                           AS x_rms_max,
        AVG(Z_RMS_VELOCITY)                           AS z_rms_avg,
        MAX(X_PEAK_VELOCITY)                          AS x_peak_velocity_max,
        AVG(X_CREST_FACTOR)                           AS x_crest_factor_avg,
        AVG(Z_CREST_FACTOR)                           AS z_crest_factor_avg,
        AVG(X_KURTOSIS)                               AS x_kurtosis_avg,
        AVG(TEMPERATURE_C)                            AS temperature_avg_c,
        MAX(TEMPERATURE_C)                            AS temperature_max_c,
        COUNT(*)                                      AS reading_count,
        COUNT_IF(IS_VALID_READING)                    AS valid_reading_count
    FROM DE_CHALLENGE.SILVER.VIBRATION_EVENTS
    WHERE IS_VALID_READING = TRUE
    GROUP BY EVENT_TS_LOCAL::DATE, MOTOR_ID
) src
ON tgt.EVENT_DATE = src.event_date AND tgt.MOTOR_ID = src.MOTOR_ID
WHEN MATCHED THEN UPDATE SET
    tgt.WORK_CENTER = src.work_center,
    tgt.ISO_ZONE_DAILY = src.iso_zone_daily,
    tgt.X_RMS_AVG = src.x_rms_avg,
    tgt.X_RMS_MAX = src.x_rms_max,
    tgt.Z_RMS_AVG = src.z_rms_avg,
    tgt.X_PEAK_VELOCITY_MAX = src.x_peak_velocity_max,
    tgt.X_CREST_FACTOR_AVG = src.x_crest_factor_avg,
    tgt.Z_CREST_FACTOR_AVG = src.z_crest_factor_avg,
    tgt.X_KURTOSIS_AVG = src.x_kurtosis_avg,
    tgt.TEMPERATURE_AVG_C = src.temperature_avg_c,
    tgt.TEMPERATURE_MAX_C = src.temperature_max_c,
    tgt.READING_COUNT = src.reading_count,
    tgt.VALID_READING_COUNT = src.valid_reading_count,
    tgt.REFRESHED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    EVENT_DATE, MOTOR_ID, WORK_CENTER, ISO_ZONE_DAILY,
    X_RMS_AVG, X_RMS_MAX, Z_RMS_AVG, X_PEAK_VELOCITY_MAX,
    X_CREST_FACTOR_AVG, Z_CREST_FACTOR_AVG, X_KURTOSIS_AVG,
    TEMPERATURE_AVG_C, TEMPERATURE_MAX_C, READING_COUNT, VALID_READING_COUNT
) VALUES (
    src.event_date, src.MOTOR_ID, src.work_center, src.iso_zone_daily,
    src.x_rms_avg, src.x_rms_max, src.z_rms_avg, src.x_peak_velocity_max,
    src.x_crest_factor_avg, src.z_crest_factor_avg, src.x_kurtosis_avg,
    src.temperature_avg_c, src.temperature_max_c, src.reading_count, src.valid_reading_count
);


-- ═══════════════════════════════════════════════════════════════════
-- ENERGY_DAILY — delta-based kWh from cumulative counter
-- Uses LAG() to compute consumption between consecutive readings
-- Excludes negative deltas (meter resets) and MAIN-MDB duplicate
-- TOU pricing: Peak 4.1821 THB/kWh (08:00-22:00), Off-Peak 2.6369 THB/kWh
-- ═══════════════════════════════════════════════════════════════════
MERGE INTO ENERGY_DAILY tgt
USING (
    WITH energy_delta AS (
        SELECT
            EVENT_TS_LOCAL::DATE AS event_date,
            DEVICE_ID,
            FLOOR,
            IS_DUPLICATE_METER,
            CUMULATIVE_KWH,
            POWER_FACTOR,
            EVENT_TS_LOCAL,
            -- Delta = current reading - previous reading for same device
            CUMULATIVE_KWH - LAG(CUMULATIVE_KWH) OVER (
                PARTITION BY DEVICE_ID ORDER BY EVENT_TS
            ) AS kwh_delta,
            -- Peak hours: 08:00–22:00 local time (Thailand TOU rate)
            CASE WHEN HOUR(EVENT_TS_LOCAL) BETWEEN 8 AND 21 THEN TRUE ELSE FALSE END AS is_peak
        FROM DE_CHALLENGE.SILVER.POWER_METER_EVENTS
    ),
    daily_agg AS (
        SELECT
            event_date,
            DEVICE_ID,
            MAX(FLOOR) AS floor,
            -- Total consumption (positive deltas only — negative = meter reset)
            SUM(CASE WHEN kwh_delta > 0 THEN kwh_delta ELSE 0 END) AS kwh_consumed,
            -- Peak/Off-peak split
            SUM(CASE WHEN kwh_delta > 0 AND is_peak THEN kwh_delta ELSE 0 END) AS kwh_peak,
            SUM(CASE WHEN kwh_delta > 0 AND NOT is_peak THEN kwh_delta ELSE 0 END) AS kwh_off_peak,
            -- TOU cost estimate
            SUM(CASE WHEN kwh_delta > 0 AND is_peak THEN kwh_delta * 4.1821 ELSE 0 END)
            + SUM(CASE WHEN kwh_delta > 0 AND NOT is_peak THEN kwh_delta * 2.6369 ELSE 0 END) AS estimated_cost_thb,
            -- Power factor metrics
            AVG(POWER_FACTOR) AS pf_avg,
            MIN(POWER_FACTOR) AS pf_min,
            COUNT_IF(POWER_FACTOR < 0.85) AS readings_below_pf85,
            COUNT(*) AS reading_count,
            -- Weekend flag
            CASE WHEN DAYOFWEEK(event_date) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend,
            MAX(IS_DUPLICATE_METER) AS is_duplicate_meter
        FROM energy_delta
        -- Exclude MAIN-MDB duplicate from aggregation
        WHERE IS_DUPLICATE_METER = FALSE
        GROUP BY event_date, DEVICE_ID
    )
    SELECT * FROM daily_agg
) src
ON tgt.EVENT_DATE = src.event_date AND tgt.DEVICE_ID = src.DEVICE_ID
WHEN MATCHED THEN UPDATE SET
    tgt.FLOOR = src.floor,
    tgt.KWH_CONSUMED = src.kwh_consumed,
    tgt.KWH_PEAK = src.kwh_peak,
    tgt.KWH_OFF_PEAK = src.kwh_off_peak,
    tgt.ESTIMATED_COST_THB = src.estimated_cost_thb,
    tgt.PF_AVG = src.pf_avg,
    tgt.PF_MIN = src.pf_min,
    tgt.READINGS_BELOW_PF85 = src.readings_below_pf85,
    tgt.READING_COUNT = src.reading_count,
    tgt.IS_WEEKEND = src.is_weekend,
    tgt.IS_DUPLICATE_METER = src.is_duplicate_meter,
    tgt.REFRESHED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    EVENT_DATE, DEVICE_ID, FLOOR, KWH_CONSUMED, KWH_PEAK, KWH_OFF_PEAK,
    ESTIMATED_COST_THB, PF_AVG, PF_MIN, READINGS_BELOW_PF85,
    READING_COUNT, IS_WEEKEND, IS_DUPLICATE_METER
) VALUES (
    src.event_date, src.DEVICE_ID, src.floor, src.kwh_consumed, src.kwh_peak, src.kwh_off_peak,
    src.estimated_cost_thb, src.pf_avg, src.pf_min, src.readings_below_pf85,
    src.reading_count, src.is_weekend, src.is_duplicate_meter
);
