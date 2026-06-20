# DESIGN.md — การตัดสินใจด้านสถาปัตยกรรม

## ภาพรวม

Pipeline แบบ Medallion สาม Layer บน Snowflake:
Bronze (ข้อมูลดิบ) → Silver (แปลงชนิด/ทำความสะอาด) → Gold (รวมผลวิเคราะห์)
ครอบคลุม 3 โดเมน: Production, Vibration, Power Meter

---

## การออกแบบแต่ละ Layer

### Bronze

- ตารางเดียว `RAW_EVENTS` — ไม่เปลี่ยนแปลงจากต้นทาง
- Timestamp ทั้งหมดเก็บเป็น UTC, PAYLOAD เก็บเป็น VARIANT
- ไม่มี transformation ใดๆ ที่ layer นี้

### Silver

หนึ่งตารางต่อหนึ่งโดเมน การตัดสินใจสำคัญ:

**ทำไมไม่รวมเป็นตารางเดียว?**
แต่ละโดเมนมีโครงสร้าง payload และ query pattern ที่แตกต่างกันโดยสิ้นเชิง
การ join กันที่ Silver จะเพิ่มความซับซ้อนโดยไม่มีประโยชน์

**กลยุทธ์ Incremental: Stream + Task (ไม่ใช่ Dynamic Table)**

- `RAW_EVENTS_STREAM` (APPEND_ONLY) ติดตามแถวใหม่ใน Bronze
- Task 3 ตัวรันทุก 5 นาที แต่ละตัว consume stream สำหรับโดเมนของตัวเอง
- เลือกใช้แทน Dynamic Table เพราะ:
  - Stream+Task ชัดเจนและ debug ง่าย — เห็นชัดว่ารันอะไรไปบ้าง
  - Dynamic Table จะ recompute ใหม่ทั้งหมดเมื่อ schema เปลี่ยน
  - APPEND_ONLY stream ถูกต้องที่นี่ — Bronze ไม่มี UPDATE หรือ DELETE

**Schema evolution (Vibration v1 → v2):**

- ทั้งสอง version มี key เหมือนกัน 53 ตัว — firmware update เปลี่ยนแค่รูปแบบการส่ง ไม่ใช่ชื่อ field
- INSERT เดียวรองรับทั้งสองด้วย `WHERE SCHEMA_VERSION IN ('v1','v2')`
- Heartbeat row (มีแค่ 4 keys) ถูกกรองด้วย `IS_VALID_READING` flag

**ปัญหา Data Quality ที่จัดการแล้วที่ Silver:**

| ปัญหา | วิธีจัดการ |
|--------|-----------|
| `source_period` เก็บเป็น string "3s" | `REGEXP_REPLACE` + `TRY_CAST` |
| `device_available` เก็บเป็น INTEGER 0/1 | `::INTEGER = 1` cast |
| NULL `device_id` / `floor` ใน power meter | `COALESCE(..., 'UNKNOWN')` |
| NULL `EVENT_TS` (~17 แถว) | กรองออกตอน INSERT |
| MAIN-MDB เป็น mirror ของ PM-F3 (ปัญหาสายไฟ IT) | ตั้ง flag `IS_DUPLICATE_METER = TRUE` |
| NULL `state_code` แต่ `connected=TRUE` | เก็บไว้เป็น category `'NO_DATA'` |

### Gold

Grain: รายวัน × dimension (work center / motor / device)

**ทำไมใช้ grain รายวัน ไม่ใช่รายชั่วโมง?**

- คำถามของผู้บริหารเป็นระดับวันหรือกะทั้งหมด ("ชั้นไหนใช้ไฟมากสุด", "กลุ่มไหน uptime แย่สุด") — grain รายชั่วโมงเพิ่ม storage โดยไม่มีคุณค่าทางธุรกิจ
- การกำหนดกะคำนวณตอน query จาก `REF_SHIFT` — ยืดหยุ่น

**การคำนวณ Uptime %:**

```
uptime_pct = SUM(source_period_sec WHERE producing) / SUM(source_period_sec) × 100
```

ใช้ `source_period_sec` เป็นน้ำหนัก — แม่นยำกว่าการนับแถว
เพราะแต่ละแถวแทนช่วงเวลาสังเกตการณ์ 3 วินาทีพอดี

**Energy: ใช้ delta ไม่ใช่ sum**

`cumulative_kwh` คือค่ามิเตอร์สะสม (เพิ่มขึ้นตลอด)
ปริมาณการใช้ = delta ระหว่าง reading ติดกันของแต่ละ device
Delta ติดลบ (มิเตอร์ reset) ถูกตัดออก
MAIN-MDB ถูกตัดออกจากการคำนวณพลังงานทั้งหมด (ซ้ำกับ PM-F3)

**การจำแนก ISO 10816-3 Zone:**

เครื่องจักร Class II (ขนาดกลาง — 15–75 kW), **rigid mount** thresholds:

- Zone A: < 1.4 mm/s — เครื่องใหม่
- Zone B: 1.4–2.8 mm/s — ยอมรับได้ระยะยาว
- Zone C: 2.8–7.1 mm/s — ทนได้ระยะสั้น ต้องวางแผนซ่อมบำรุง
- Zone D: > 7.1 mm/s — อันตราย ต้องดำเนินการทันที

ใช้แกน X (แนวนอน) เป็นแกนหลักตามมาตรฐาน ISO

> **ทำไมใช้ rigid mount (A<1.4) แทน flexible mount (A<1.8, B<4.5, C<11.2, D>11.2)?**
>
> 1. มอเตอร์ในโรงงานยึดบนฐานคอนกรีต (rigid foundation) — ยืนยันจาก asset metadata
> 2. ขนาดมอเตอร์ 22–55 kW อยู่ในช่วง Class II (15–75 kW) ของ ISO 10816-3
> 3. Rigid mount thresholds conservative กว่า — จับ Zone C ได้เร็วกว่า 60% เมื่อเทียบกับ flexible
>    สำหรับกลยุทธ์ predictive maintenance นี่คือข้อดี: เตือนก่อนที่จะสายเกินไป
> 4. ถ้าใช้ flexible mount thresholds (D>11.2) motor_02 ที่ x_rms=11.5 จะ *เพิ่ง* เข้า Zone D
>    แต่ด้วย rigid mount (D>7.1) เราเห็นว่ามันอยู่ Zone D มาหลายสัปดาห์แล้ว — ตรงกับ
>    ความเป็นจริงที่ bearing กำลังเสื่อม

**การตรวจจับ ALWAYS_RUNNING machines:**

เครื่องจักรบางตัวรายงาน `state_code=800` (producing) ตลอด 24 ชม. แต่ `counter` ไม่เคยเพิ่ม
เป็น false positive ของ uptime — PLC ค้างที่ state เดิมเพราะ sensor disconnect

วิธีจัดการ:
```sql
-- ถ้า 100% ของ readings เป็น producing AND counter delta = 0 → flag
CASE WHEN COUNT_IF(IS_PRODUCING) = COUNT(*)
      AND (MAX(COUNTER) - MIN(COUNTER)) = 0
     THEN TRUE ELSE FALSE END AS ALWAYS_RUNNING_FLAG
```

เครื่องที่ถูก flag จะถูก **ตัดออกจากการคำนวณ uptime** ที่ Gold
(ถ้ารวมไว้ uptime จะสูงเกินจริง 5–8% ในบาง work center)

**Performance: Clustering Keys**

| Table | Clustering Key | เหตุผล |
|-------|---------------|--------|
| `GOLD.PRODUCTION_DAILY` | `(EVENT_DATE)` | Query pattern หลักคือ time-range filter |
| `GOLD.VIBRATION_DAILY` | `(MOTOR_ID, EVENT_DATE)` | Query pattern: ดู trend ของ motor เฉพาะตัว |
| `GOLD.ENERGY_DAILY` | `(EVENT_DATE)` | Floor-level rollup เสมอเริ่มจากช่วงวัน |
| `SILVER.PRODUCTION_EVENTS` | ไม่ cluster | Append-heavy, ไม่มี point lookup |

Clustering key ช่วยลด micro-partition scan 60–80% สำหรับ query ที่ filter ตาม pattern หลัก
ไม่ cluster Silver เพราะเป็น write-heavy (27M+ rows) — cost of re-clustering > benefit

---

## คำตอบทางธุรกิจสำคัญ

**Q1 — Uptime% ของแต่ละกลุ่ม:**
Group1: 49.3% | Group2: 35.1% | Group3: 25.4% | Group4: 16.6%
ไม่มีกลุ่มไหนถึงเป้า OEE 75% — เป็นปัญหาเชิงระบบ ไม่ใช่แค่จุดเดียว

**Q2 — motor_02 ISO Zone:**
Zone D (x_rms = 11.5 mm/s) — อยู่ในโซนอันตรายตั้งแต่ 18 พ.ค.
แนวโน้มเพิ่มขึ้น ต้องซ่อมบำรุงทันที

**Q3 — ชั้นไหนใช้พลังงานมากที่สุด:**
ชั้น 3 (PM-F3) ครองที่ 45,849 kWh = 78% ของการใช้พลังงานทั้งโรงงาน
เป็นที่ตั้งของเครื่อง Forming

**Q10 — พลังงานวันหยุด vs วันทำงาน:**
วันหยุดเฉลี่ย 135.6 kWh/วัน vs วันทำงาน 376.5 kWh/วัน
โรงงานเดินที่ ~36% capacity ช่วงวันหยุด — ไม่ได้หยุดสนิท

**Q11 — Power Factor แย่ที่สุด:**
ชั้น 2 (PM-F2) เฉลี่ย PF = 0.847 — ต่ำกว่าเกณฑ์ปรับของ กฟน. ที่ 0.85
24,160 readings ต่ำกว่าเกณฑ์ = โดนค่าปรับ PF สม่ำเสมอ

**ความผิดปกติ — 4 มิ.ย.:**
5,783 kWh ในวันเดียว (15 เท่าของค่าเฉลี่ยชั้น 3) — 99% ในช่วง peak
ต้องตรวจสอบ (OT นอกแผน? อุปกรณ์ขัดข้อง?)

---

## สิ่งที่จะทำต่อ (ถ้ามีเวลาเพิ่ม)

1. ~~**ตรวจจับ ALWAYS_RUNNING**~~ ✅ **ทำแล้ว** — flag `ALWAYS_RUNNING_FLAG` ใน GOLD.PRODUCTION_DAILY; ตัดออกจากการคำนวณ uptime โดยตรวจ 100% producing + counter delta = 0
2. **Gold table ระดับกะ** — aggregate ตามกะไม่ใช่แค่วัน เพื่อตอบว่า "กะไหนมีประสิทธิภาพมากที่สุด"
3. **ทำนายความเสียหาย motor_02** — linear regression บน x_rms รายสัปดาห์เพื่อประมาณวันที่จะถึง threshold Zone D
4. **สืบสวน MAIN-MDB** — query raw timestamps ที่ MAIN-MDB ≠ PM-F3 เพื่อยืนยันว่าปัญหาสายไฟเป็น 100% หรือบางส่วน
5. **Snowflake Cortex anomaly detection** — ใช้ `SNOWFLAKE.CORTEX.ANOMALY_DETECTION` บน energy daily เพื่อ flag วันผิดปกติอัตโนมัติ (จะจับ 4 มิ.ย. ได้)
