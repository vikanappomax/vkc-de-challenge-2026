# Snowflake Trial Account

| Property | Value |
|----------|-------|
| Account Locator | `KU15469` |
| Region | `AWS_AP_SOUTHEAST_1` (Singapore) |
| Snowsight URL | `https://app.snowflake.com/ku15469/` |
| Username | `VIKAN` |
| Role | `ACCOUNTADMIN` |
| Warehouse | `COMPUTE_WH` |
| Database | `DE_CHALLENGE` |
| Snowflake Version | `10.21.102` |

## Schemas

- `DE_CHALLENGE.BRONZE` — Raw IoT events (27M+ rows)
- `DE_CHALLENGE.SILVER` — Cleaned/typed domain tables + Tasks
- `DE_CHALLENGE.GOLD` — Daily aggregated tables + stored procedures

## Connection (SnowSQL / Python)

```
account = "ku15469.ap-southeast-1"
user = "VIKAN"
warehouse = "COMPUTE_WH"
database = "DE_CHALLENGE"
```

> **Note:** No passwords or secrets are stored here. Authenticate via Snowsight SSO or externally managed credentials.
