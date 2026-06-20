-- Reference table: shift definitions for the Chonburi plant
-- Co-authored with CoCo

USE DATABASE DE_CHALLENGE;
USE SCHEMA GOLD;

-- ═══════════════════════════════════════════════════════════════════
-- REF_SHIFT — maps time-of-day to shift names
-- Non-standard shift boundaries (Thai manufacturing 4-shift rotation)
-- Times are in Asia/Bangkok local time
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE REF_SHIFT (
    SHIFT_NAME       VARCHAR NOT NULL,
    START_TIME       TIME NOT NULL,
    END_TIME         TIME NOT NULL,
    SHIFT_ORDER      NUMBER(1,0) NOT NULL,
    DESCRIPTION      VARCHAR,
    CONSTRAINT PK_REF_SHIFT PRIMARY KEY (SHIFT_NAME)
)
COMMENT = 'Reference: shift schedule boundaries — Chonburi plant 4-shift rotation';

INSERT INTO REF_SHIFT (SHIFT_NAME, START_TIME, END_TIME, SHIFT_ORDER, DESCRIPTION)
VALUES
    ('Night',    '21:45:00', '00:45:00', 1, 'Night shift — 21:45 to 00:45 (crosses midnight)'),
    ('Morning',  '00:45:00', '09:45:00', 2, 'Morning shift — 00:45 to 09:45'),
    ('Day',      '09:45:00', '12:45:00', 3, 'Day shift — 09:45 to 12:45 (short shift / break rotation)'),
    ('Evening',  '12:45:00', '21:45:00', 4, 'Evening shift — 12:45 to 21:45');


-- ═══════════════════════════════════════════════════════════════════
-- REF_ISO_THRESHOLDS — ISO 10816-3 vibration severity zones
-- Class II, Group 1 (rigid foundation, 15-75 kW)
--
-- DESIGN DECISION: We use Class II rigid mount thresholds (A<1.4, B<2.8,
-- C<7.1, D>7.1 mm/s) rather than the more permissive flexible mount values
-- (A<1.8, B<4.5, C<11.2, D>11.2). Rationale:
--   1. Motors in this plant are bolted to concrete pads (rigid mount)
--   2. Conservative thresholds provide earlier warning — appropriate for
--      a predictive maintenance strategy where catching Zone C early
--      prevents catastrophic Zone D failures
--   3. The 15-75 kW range matches the motor nameplate data in the vibration
--      sensor metadata (most motors are 22-55 kW)
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE REF_ISO_THRESHOLDS (
    ZONE_CODE        VARCHAR(1) NOT NULL,
    ZONE_NAME        VARCHAR NOT NULL,
    MIN_RMS_MM_S     FLOAT NOT NULL,
    MAX_RMS_MM_S     FLOAT,
    ACTION_REQUIRED  VARCHAR,
    ISO_CLASS        VARCHAR DEFAULT 'Class II',
    MOUNT_TYPE       VARCHAR DEFAULT 'Rigid',
    CONSTRAINT PK_REF_ISO PRIMARY KEY (ZONE_CODE)
)
COMMENT = 'Reference: ISO 10816-3 vibration severity zones — Class II rigid mount';

INSERT INTO REF_ISO_THRESHOLDS (ZONE_CODE, ZONE_NAME, MIN_RMS_MM_S, MAX_RMS_MM_S, ACTION_REQUIRED)
VALUES
    ('A', 'Good',        0.0,  1.4,  'No action — newly commissioned machine condition'),
    ('B', 'Acceptable',  1.4,  2.8,  'Acceptable for long-term operation — monitor trend'),
    ('C', 'Warning',     2.8,  7.1,  'Tolerable short-term only — plan maintenance within 2 weeks'),
    ('D', 'Danger',      7.1,  NULL, 'IMMEDIATE ACTION — risk of damage, schedule emergency shutdown');


-- ═══════════════════════════════════════════════════════════════════
-- REF_TOU_RATES — Time-of-Use electricity tariff (Thailand MEA/PEA)
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE REF_TOU_RATES (
    PERIOD_NAME      VARCHAR NOT NULL,
    START_HOUR       NUMBER(2,0) NOT NULL,
    END_HOUR         NUMBER(2,0) NOT NULL,
    RATE_THB_PER_KWH FLOAT NOT NULL,
    EFFECTIVE_DATE   DATE DEFAULT '2024-01-01',
    CONSTRAINT PK_REF_TOU PRIMARY KEY (PERIOD_NAME)
)
COMMENT = 'Reference: TOU electricity rates — Thailand industrial tariff';

INSERT INTO REF_TOU_RATES (PERIOD_NAME, START_HOUR, END_HOUR, RATE_THB_PER_KWH)
VALUES
    ('Peak',     8, 22, 4.1821),
    ('Off-Peak', 22,  8, 2.6369);
