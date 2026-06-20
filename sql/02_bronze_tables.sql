-- Bronze layer: raw events table ingested from S3
-- Co-authored with CoCo

USE DATABASE DE_CHALLENGE;
USE SCHEMA BRONZE;

CREATE OR REPLACE TABLE RAW_EVENTS (
    EVENT_TS          TIMESTAMP_NTZ(9),
    ENTERPRISE        VARCHAR,
    SITE              VARCHAR,
    AREA              VARCHAR,
    WORK_CENTER       VARCHAR,
    WORK_CELL         VARCHAR,
    ASSET             VARCHAR,
    ASSET_PATH        VARCHAR,
    NAMESPACE         VARCHAR,
    QUALITY           VARCHAR,
    PAYLOAD           VARCHAR,
    INGESTED_TS       TIMESTAMP_NTZ(9),
    SCHEMA_VERSION    VARCHAR,
    SOURCE            VARCHAR,
    CORRELATION_ID    VARCHAR
);

-- Stream for incremental Silver loads
CREATE OR REPLACE STREAM RAW_EVENTS_STREAM
    ON TABLE RAW_EVENTS
    APPEND_ONLY = TRUE
    COMMENT = 'Tracks new rows in RAW_EVENTS for incremental Silver load';
