# REFLECTION.md — สิ่งที่ผมเรียนรู้

## โจทย์ที่ได้รับ

สร้าง IoT data pipeline เต็มรูปแบบจากข้อมูล sensor ดิบ (27M+ แถว จากโรงงานในชลบุรี) ผ่าน Bronze → Silver → Gold จบที่ dashboard สด ครอบคลุม 3 โดเมน: Production OEE, Vibration monitoring, และ Power metering

---

## ความท้าทายทางเทคนิค

### ปัญหา "3s"

field `source_period` — สำคัญมากสำหรับการคำนวณ uptime — ถูกเก็บเป็น string เช่น `"3s"` แทนที่จะเป็น integer ผมเริ่มแรกสันนิษฐานว่าเป็น 3 วินาทีเสมอ (และเกือบ hard-code ไปแล้ว) แต่พอลอง `SELECT DISTINCT` พบว่ามีค่าอย่าง `"1s"`, `"5s"`, และ `"10s"` ในข้อมูลเก่า วิธีแก้: `REGEXP_REPLACE` เพื่อลบตัวอักษร + `TRY_CAST` เพื่อความปลอดภัย บทเรียน: อย่าสันนิษฐานว่าข้อมูล IoT จะสม่ำเสมอ

### MAIN-MDB: มิเตอร์ผี

ข้อมูล power meter มี device ชื่อ `MAIN-MDB` ที่ดูเหมือนเป็น device แยก แต่จริงๆ แล้วเป็น mirror ระดับ IT ของ `PM-F3` (ชั้น 3) ถ้าไม่จับตรงนี้ได้ การคำนวณพลังงานจะนับซ้ำ 78% ของการใช้ไฟทั้งโรงงาน ผมเลือกตั้ง flag `IS_DUPLICATE_METER = TRUE` ที่ Silver แทนการกรองทิ้ง — รักษาข้อมูลดิบไว้ แต่ง่ายต่อการตัดออก downstream

### Vibration Schema v1 → v2

ตอนแรกคิดว่า vibration สอง schema จะมี field ต่างกัน (ต้องแยก Silver table) แต่พอเปรียบเทียบ payload แล้ว: เหมือนกัน 53 keys ทั้งสอง version firmware update เปลี่ยนแค่ protocol การส่ง ไม่ใช่ data model ใช้ `WHERE SCHEMA_VERSION IN ('v1','v2')` ตัวเดียวจัดการได้หมด

### NULL state_code กับ connected=TRUE

1.2M production rows (~4.8%) รายงาน `connected=TRUE` แต่มี NULL `state_code` เป็น sensor gap จริง — PLC เชื่อมต่อแล้วแต่ยังไม่ได้รายงานสถานะเครื่อง ผมเก็บไว้เป็น `DOWNTIME_CATEGORY = 'NO_DATA'` แทนที่จะกรองทิ้ง เพราะถ้าตัดออกจะทำให้ uptime สูงเกินจริง

---

## การตัดสินใจเชิงออกแบบ (Trade-offs)

### Stream + Task vs Dynamic Table

ผมเลือก Stream + Task เพราะ:
- **Debug ง่าย**: เห็นชัดว่า task แต่ละตัวรันเมื่อไหร่ consume อะไร fail ตรงไหน
- **Schema มั่นคง**: Dynamic Table จะ recompute ใหม่ทั้งหมดเมื่อ DDL เปลี่ยน — เสี่ยงตอนพัฒนา
- **ควบคุมค่าใช้จ่าย**: schedule 5 นาทีชัดเจน; Dynamic Table อาจ trigger บ่อยกว่าที่คาด

Trade-off คือต้องเขียน SQL มากกว่าและจัดการ orchestration เอง สำหรับระบบ production ที่มีทีม DE เฉพาะ Dynamic Table อาจง่ายกว่าในระยะยาว

### Daily vs Hourly Gold Grain

ทุกคำถามทางธุรกิจจากโจทย์เป็นระดับวันหรือกะ Hourly Gold จะเพิ่มจำนวนแถว 24 เท่าโดยไม่มีประโยชน์ทางวิเคราะห์ ถ้า shift-level analysis สำคัญขึ้นมา ผมจะเพิ่ม `GOLD.PRODUCTION_SHIFT` table แทนการลง hourly

### Uptime ถ่วงน้ำหนักด้วย source_period_sec

การนับ "producing rows / total rows" จะให้คำตอบผิดเพราะไม่ใช่ทุก reading จะแทนช่วงเวลาเท่ากัน การถ่วงด้วย `source_period_sec` หมายความว่า reading 10 วินาทีในสถานะ PRODUCING นับมากกว่า reading 1 วินาที 10 เท่า ตรงกับวิธีคำนวณ OEE จริงในอุตสาหกรรม

---

## สิ่งที่เรียนรู้เกี่ยวกับ Snowflake

1. **APPEND_ONLY streams** เป็น default ที่ถูกต้องสำหรับ workload IoT ที่เป็น append-heavy — overhead ต่ำกว่า standard streams และ Bronze ไม่เคย UPDATE หรือ DELETE

2. **VARIANT + PARSE_JSON** เร็วอย่างน่าประหลาดใจในข้อมูลขนาดใหญ่ 27M แถว parse ได้ในไม่กี่วินาทีด้วย warehouse caching ไม่จำเป็นต้อง flatten ที่ Bronze

3. **CONVERT_TIMEZONE('UTC', 'Asia/Bangkok', ts)** คือ pattern ที่ถูกต้อง — เก็บ UTC คำนวณ local ตอน query ประเทศไทยไม่มี DST จึงปลอดภัย แต่สำหรับพื้นที่ที่มี DST pattern เดียวกันก็ยังใช้ได้

4. **TRY_CAST vs direct cast** — `TRY_CAST` return NULL เมื่อ fail แทนที่จะ error จำเป็นสำหรับข้อมูล IoT ที่ sensor ส่งข้อมูลขยะเป็นบางครั้ง

5. **UUID_STRING()** สำหรับสร้าง event ID ที่ไม่ซ้ำใน Silver — ไม่ต้องใช้ sequence ไม่มี conflict ข้าม parallel task runs

6. **LAG() สำหรับ energy delta** — pattern มิเตอร์สะสม (ค่าเพิ่มขึ้นตลอด) พบบ่อยใน power monitoring `current - LAG(current)` ให้ปริมาณการใช้ต่อช่วง Delta ติดลบ = มิเตอร์ reset ต้องกรองออก

---

## Business Insights ที่ทำให้ประหลาดใจ

1. **ทุกกลุ่มต่ำกว่า 50% uptime** — ผมคาดว่าอย่างน้อยสักกลุ่มจะทำได้ดี แต่พบว่ากลุ่มที่ดีที่สุด (Group1) อยู่ที่แค่ 49% แสดงว่าเป็นปัญหาเชิงระบบ (การวางแผน? นโยบายซ่อมบำรุง?) ไม่ใช่ปัญหาอุปกรณ์เฉพาะจุด

2. **motor_02 อยู่ใน Zone D มาหลายสัปดาห์** — ไม่ใช่ความเสียหายฉับพลัน แต่เป็นการเสื่อมค่อยๆ ที่เห็นได้จากข้อมูล trend นี่คือสิ่งที่ predictive maintenance ควรจับได้ก่อนเครื่องพัง

3. **ชั้น 2 เสี่ยงโดนค่าปรับ Power Factor** — ที่เฉลี่ย PF 0.847 (เกณฑ์คือ 0.85) โรงงานจ่ายค่าปรับ กฟน. ทุกรอบบิล การลงทุน capacitor bank จะคุ้มทุนอย่างรวดเร็ว

4. **ความผิดปกติ 4 มิ.ย.** — 15 เท่าของการใช้ไฟปกติในวันเดียว เกือบทั้งหมดอยู่ในช่วง peak rate เป็นได้ทั้ง production surge นอกแผน (แพง) หรือข้อผิดพลาดของมิเตอร์ ไม่ว่ากรณีใดต้องตรวจสอบทันที

---

## สิ่งที่จะทำต่างออกไป

1. **เริ่มจากคำถาม Gold ก่อน** — ผมสร้าง Bronze → Silver → Gold ตามลำดับ แต่ถ้ารู้คำถามทางธุรกิจขั้นสุดท้ายก่อน จะช่วยออกแบบ column ใน Silver ได้ตรงจุดกว่า (เช่น pre-compute `is_weekend` ที่ Silver แทน Gold)

2. **ใส่ Data Quality DMFs ตั้งแต่ต้น** — Snowflake Data Metric Functions สามารถ monitor NULL rate, schema drift, และ cardinality anomalies อย่างต่อเนื่อง ผมเพิ่ม quality checks เป็น ad-hoc queries; ควรทำเป็น automated

3. **ทดสอบด้วยข้อมูลน้อยก่อน** — ผม backfill 27M แถวทันที ควรทดสอบ pipeline ทั้งหมดด้วย 1000 แถวก่อนเพื่อจับปัญหาอย่าง `device_available` BOOLEAN vs INTEGER ได้เร็วกว่า

4. **เอกสารเรื่อง shift logic ตั้งแต่ต้น** — เวลาเริ่มกะที่ไม่มาตรฐาน (00:45, 06:45 ฯลฯ) ทำให้สับสน ควรสร้าง `REF_SHIFT` ก่อนแล้วอ้างอิงตลอด

---

## สรุปส่งท้าย

สิ่งที่ยากที่สุดไม่ใช่ Snowflake SQL — แต่คือการ *เข้าใจข้อมูล* IoT payload จากโรงงานจริงนั้นยุ่งเหยิง ไม่สม่ำเสมอ และเต็มไปด้วย edge case ที่เข้าใจได้ก็ต่อเมื่อเข้าใจอุปกรณ์ทางกายภาพ Data engineering ที่ดีที่สุดคือส่วนผสมเท่าๆ กันของ SQL craft และความอยากรู้เรื่อง domain
