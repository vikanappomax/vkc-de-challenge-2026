# Plant Health at a Glance — Manufacturing IoT Dashboard (Chonburi, Thailand)
# Co-authored with CoCo
import os
import streamlit as st

st.set_page_config(page_title="Plant Health", page_icon="🏭", layout="wide")

conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))


@st.cache_data(ttl=300)
def load_production_daily():
    return conn.query("""
        SELECT event_date, work_center, shift_name, uptime_pct,
               producing_seconds/3600.0 AS producing_hours,
               idle_seconds, no_order_seconds, material_shortage_seconds,
               mechanical_fault_seconds, planned_stop_seconds,
               changeover_seconds, scheduled_maint_seconds,
               primary_downtime_reason, counter_delta
        FROM DE_CHALLENGE.GOLD.PRODUCTION_DAILY
        ORDER BY event_date, work_center
    """)


@st.cache_data(ttl=300)
def load_vibration_daily():
    return conn.query("""
        SELECT event_date, motor_id, iso_zone_daily, x_rms_avg,
               x_crest_factor_avg, temperature_avg_c
        FROM DE_CHALLENGE.GOLD.VIBRATION_DAILY
        ORDER BY event_date, motor_id
    """)


@st.cache_data(ttl=300)
def load_energy_daily():
    return conn.query("""
        SELECT event_date, device_id, floor, kwh_consumed,
               kwh_peak, kwh_off_peak, estimated_cost_thb,
               pf_avg, readings_below_pf85
        FROM DE_CHALLENGE.GOLD.ENERGY_DAILY
        ORDER BY event_date, device_id
    """)


# --- Load data ---
with st.spinner("Loading plant data..."):
    df_prod = load_production_daily()
    df_vib = load_vibration_daily()
    df_energy = load_energy_daily()

st.title("🏭 Plant Health at a Glance")
st.caption("Chonburi Manufacturing — Real-time IoT Monitoring")

# Refresh button
if st.button("🔄 Refresh Data"):
    load_production_daily.clear()
    load_vibration_daily.clear()
    load_energy_daily.clear()
    st.rerun()

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: Production
# ═══════════════════════════════════════════════════════════════════
st.header("⚙️ Production Uptime")
st.info("Uptime excludes ALWAYS_RUNNING machines (100% state=800 but counter=0 delta) — these are stale PLC signals, not real production.", icon="ℹ️")

latest_date = df_prod["EVENT_DATE"].max()
df_latest_prod = df_prod[df_prod["EVENT_DATE"] == latest_date]

# KPI gauges per work center
groups = sorted(df_latest_prod["WORK_CENTER"].unique())
cols = st.columns(len(groups), border=True)
for col, grp in zip(cols, groups):
    with col:
        grp_data = df_latest_prod[df_latest_prod["WORK_CENTER"] == grp]
        avg_uptime = grp_data["UPTIME_PCT"].mean()
        # Get historical trend for sparkline
        hist = df_prod[df_prod["WORK_CENTER"] == grp].groupby("EVENT_DATE")["UPTIME_PCT"].mean().tail(14)
        delta_val = avg_uptime - hist.iloc[-2] if len(hist) >= 2 else 0
        st.metric(
            grp,
            f"{avg_uptime:.1f}%",
            f"{delta_val:+.1f}%",
            chart_data=hist.tolist(),
            chart_type="line",
        )

# Downtime Pareto
st.subheader("Downtime Pareto (Latest Day)")
downtime_cols = [
    ("IDLE_SECONDS", "Idle"),
    ("NO_ORDER_SECONDS", "No Order"),
    ("MATERIAL_SHORTAGE_SECONDS", "Material Shortage"),
    ("MECHANICAL_FAULT_SECONDS", "Mechanical Fault"),
    ("PLANNED_STOP_SECONDS", "Planned Stop"),
    ("CHANGEOVER_SECONDS", "Changeover"),
    ("SCHEDULED_MAINT_SECONDS", "Scheduled Maint"),
]
pareto_data = {}
for col_name, label in downtime_cols:
    pareto_data[label] = df_latest_prod[col_name].sum() / 3600.0  # hours

import pandas as pd

df_pareto = pd.DataFrame({"Reason": pareto_data.keys(), "Hours": pareto_data.values()})
df_pareto = df_pareto.sort_values("Hours", ascending=False).reset_index(drop=True)
st.bar_chart(df_pareto, x="Reason", y="Hours", horizontal=True)

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: Vibration
# ═══════════════════════════════════════════════════════════════════
st.header("📳 Motor Vibration Health")

latest_vib_date = df_vib["EVENT_DATE"].max()
df_latest_vib = df_vib[df_vib["EVENT_DATE"] == latest_vib_date]

zone_colors = {"A": "🟢", "B": "🟡", "C": "🟠", "D": "🔴"}
zone_labels = {"A": "Good", "B": "Acceptable", "C": "Warning", "D": "DANGER"}

motors = sorted(df_latest_vib["MOTOR_ID"].unique())
motor_cols = st.columns(len(motors), border=True)
for col, motor in zip(motor_cols, motors):
    with col:
        row = df_latest_vib[df_latest_vib["MOTOR_ID"] == motor].iloc[0]
        zone = row["ISO_ZONE_DAILY"]
        icon = zone_colors.get(zone, "⚪")
        st.markdown(f"### {icon} {motor}")
        st.markdown(f"**Zone {zone}** — {zone_labels.get(zone, 'Unknown')}")
        st.caption(f"RMS: {row['X_RMS_AVG']:.3f} mm/s | Crest: {row['X_CREST_FACTOR_AVG']:.2f} | Temp: {row['TEMPERATURE_AVG_C']:.1f}°C")

# Alert for motor_02
motor02_latest = df_latest_vib[df_latest_vib["MOTOR_ID"] == "motor_02"]
if not motor02_latest.empty and motor02_latest.iloc[0]["ISO_ZONE_DAILY"] == "D":
    st.error("⚠️ **ALERT: motor_02 in Zone D (Danger)** — Bearing fault developing. RMS > 7.1 mm/s. Schedule immediate inspection.")

# Vibration trend chart for motor_02
st.subheader("motor_02 — RMS Trend (ISO 10816-3)")
df_m02 = df_vib[df_vib["MOTOR_ID"] == "motor_02"][["EVENT_DATE", "X_RMS_AVG"]].copy()
df_m02 = df_m02.rename(columns={"X_RMS_AVG": "RMS (mm/s)"})
st.line_chart(df_m02, x="EVENT_DATE", y="RMS (mm/s)")
st.caption("Zone thresholds (ISO 10816-3 Class II, rigid mount): A < 1.4 | B < 2.8 | C < 7.1 | D > 7.1 mm/s")
with st.expander("Why these thresholds?"):
    st.markdown("""
    We use **ISO 10816-3 Class II rigid mount** thresholds (not flexible mount A<1.8, B<4.5, C<11.2, D>11.2).

    **Reasons:**
    - Plant motors are 22–55 kW, bolted to concrete pads (rigid foundation)
    - Conservative thresholds give ~60% earlier warning vs flexible mount
    - Aligns with predictive maintenance strategy: catch Zone C before catastrophic failure
    """)

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: Energy
# ═══════════════════════════════════════════════════════════════════
st.header("⚡ Energy Consumption")

latest_energy_date = df_energy["EVENT_DATE"].max()
df_latest_energy = df_energy[df_energy["EVENT_DATE"] == latest_energy_date]

# KPI row
total_kwh = df_latest_energy["KWH_CONSUMED"].sum()
total_cost = df_latest_energy["ESTIMATED_COST_THB"].sum()
worst_pf = df_latest_energy["PF_AVG"].min()
pf_violations = df_latest_energy["READINGS_BELOW_PF85"].sum()

with st.container(horizontal=True):
    st.metric("Daily kWh", f"{total_kwh:,.1f}", border=True)
    st.metric("Daily Cost", f"฿{total_cost:,.0f}", border=True)
    st.metric("Worst PF", f"{worst_pf:.3f}", delta="Below 0.85!" if worst_pf < 0.85 else "OK", delta_color="inverse" if worst_pf < 0.85 else "normal", border=True)
    st.metric("PF Violations", f"{int(pf_violations)}", border=True)

# Consumption by floor
st.subheader("Consumption by Floor")
df_floor = df_energy.groupby(["EVENT_DATE", "FLOOR"]).agg({"KWH_CONSUMED": "sum"}).reset_index()
# Pivot for stacked-like line chart
df_floor_pivot = df_floor.pivot(index="EVENT_DATE", columns="FLOOR", values="KWH_CONSUMED").reset_index()
st.line_chart(df_floor_pivot, x="EVENT_DATE")

# Cost breakdown: Peak vs Off-Peak (latest day)
st.subheader("Peak vs Off-Peak Split (Latest Day)")
peak_kwh = df_latest_energy["KWH_PEAK"].sum()
offpeak_kwh = df_latest_energy["KWH_OFF_PEAK"].sum()
col1, col2 = st.columns(2)
with col1:
    with st.container(border=True):
        st.markdown("**Peak (08:00-22:00)**")
        st.metric("kWh", f"{peak_kwh:,.1f}")
        st.metric("Rate", "4.1821 THB/kWh")
with col2:
    with st.container(border=True):
        st.markdown("**Off-Peak (22:00-08:00)**")
        st.metric("kWh", f"{offpeak_kwh:,.1f}")
        st.metric("Rate", "2.6369 THB/kWh")

# Power Factor violations
st.subheader("Power Factor by Device")
df_pf = df_energy.groupby("DEVICE_ID").agg({"PF_AVG": "mean", "READINGS_BELOW_PF85": "sum"}).reset_index()
df_pf.columns = ["Device", "Avg PF", "Violations (count)"]
st.dataframe(df_pf.sort_values("Avg PF"), hide_index=True, use_container_width=True)

st.divider()
st.caption(f"Report date: {latest_date} | Data source: DE_CHALLENGE.GOLD | Auto-refresh: 5 min")
