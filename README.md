# k8s-connection-probe

**Probe ก่อน Deploy** — Claude skill ที่หาว่า service ต้องต่อกับอะไรบ้าง (database, Redis, Kafka, API, …) แล้วยิงทดสอบทุกการเชื่อมต่อจาก pod ชั่วคราวใน cluster จริง ด้วยตัวตนเดียวกับ service ก่อนจะ deploy

🎬 คลิปอธิบาย: https://youtube.com/shorts/69UYRKZAr70

## ทำไม
การเชื่อมต่อไม่ใช่สวิตช์ แต่คือบันได 7 ขั้น: DNS → เครือข่าย → TLS → ตัวตน → สิทธิ์ → สิทธิ์ย่อย → เส้นทาง
ข้อผิดพลาดจะบอกแค่ขั้นแรกที่พัง ถ้า deploy แล้วค่อยแก้ ก็จะเจอปัญหาทีละรอบ
probe ทุกขั้นของทุกการเชื่อมต่อก่อน = เห็นทุกปัญหาในรอบเดียว ขอทีม platform ครั้งเดียว

## ติดตั้ง
```bash
git clone https://github.com/suratgoing/k8s-connection-probe ~/.claude/skills/k8s-connection-probe
```
แล้วใน Claude Code พิมพ์ประมาณ: *"เช็ค connection ของ service orders ใน namespace staging ก่อน deploy"*

### ต้องมี
- `kubectl` ที่เข้า cluster ปลายทางได้ และมีสิทธิ์สร้าง / exec / ลบ pod ใน namespace นั้น
- `python3` (ใช้สร้าง pod spec)
- cluster ต้องดึง image `nicolaka/netshoot`, `edenhill/kcat`, `redis`, `postgres`, `mysql` ได้ (เปลี่ยนเป็น registry ตัวเองได้ด้วย `NETSHOOT_IMAGE` / `KCAT_IMAGE` / `REDIS_IMAGE` / `POSTGRES_IMAGE` / `MYSQL_IMAGE`)

## ใช้สคริปต์ตรงๆ (ไม่ผ่าน Claude ก็ได้)
```bash
P="scripts/probe.sh --context my-staging -n orders"
$P can-i
$P up --like orders-api            # pod ทดสอบ ที่ใช้ serviceAccount / env / secret ชุดเดียวกับ deployment
$P dns  db.example.internal        # DNS_OK 10.0.3.12
$P tcp  db.example.internal 5432   # OPEN | REFUSED | BLOCKED_OR_TIMEOUT
$P tls  kafka.example.internal 9093
$P http https://api.example.internal/v1/ping -H 'X-Source: orders'
$P client-up redis --like orders-api
$P redis orders-cache 6379 --pass-env REDIS_PASS          # REDIS_OK | AUTH_REQUIRED | AUTH_FAILED
$P client-up mysql --like orders-api
$P mysql billing-db 3306 billing --user-env DB_USER --pass-env DB_PASS --grants   # MYSQL_OK + READ_ONLY | CAN_WRITE
$P kafka-up --like orders-api
$P kafka read kafka.example.internal:9093 orders -- -X security.protocol=SASL_SSL -X sasl.mechanisms=SCRAM-SHA-512 \
     -X sasl.username='$KAFKA_USER' -X sasl.password='$KAFKA_PASS'
$P down                            # ลบ pod ทุกครั้ง (pod ลบตัวเองเองหลัง 30 นาทีด้วย)
```
ผลลัพธ์แต่ละแบบแปลว่าอะไร และใครต้องแก้: [`references/layers.md`](references/layers.md)

## ความปลอดภัย
- ต้องระบุ `--context` และ `--namespace` ทุกครั้ง สคริปต์จะไม่เดา cluster เอง
- ไม่พิมพ์ค่า secret ออกมา รหัสผ่านถูกอ้างเป็นชื่อตัวแปรที่ขยายข้างใน pod เท่านั้น
- อ่านอย่างเดียวโดย default: ไม่เขียนข้อมูล ไม่สร้าง topic / table / สิทธิ์ เพื่อให้เทสผ่าน
- pod มีอายุสูงสุด 30 นาที และใช้ CPU/memory น้อย

---

## English

A Claude Code skill that finds every outbound connection a service needs and proves each one live from a
throwaway pod inside the target cluster, using the service's own identity — before you deploy.
An error only shows the first broken layer (DNS → network → TLS → identity → permission → sub-resource →
route), so deploy-and-see finds one problem per cycle; probing every layer up front finds them all at once,
sorted into "ask the platform team" vs. "fix it ourselves".

Install: `git clone https://github.com/suratgoing/k8s-connection-probe ~/.claude/skills/k8s-connection-probe`
Requirements: `kubectl` access with permission to create/exec/delete pods, `python3`, pullable
`nicolaka/netshoot` and `edenhill/kcat` images (override with `NETSHOOT_IMAGE` / `KCAT_IMAGE`).
Safety: explicit `--context`/`--namespace` always, secrets never printed, read-only by default,
30-minute pod lifetime.

MIT License.
