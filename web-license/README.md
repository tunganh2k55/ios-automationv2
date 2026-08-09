# iOSAuto — Web bán & verify License (nhiều tool)

Node/Express + **Supabase (Postgres)**. Bán license cho **nhiều tool/app** cùng lúc:

- **Tài khoản**: đăng ký / đăng nhập (token ký HMAC), phân quyền **user** / **admin**.
- **Cửa hàng**: user chọn tool → chọn gói → mua (**thanh toán mock**) → nhận key → **kích hoạt theo serial**.
- **Admin**: tạo/ẩn **tool** + đặt **gói giá**, cấp key thủ công, kích hoạt theo serial, thu hồi/gia hạn, xem user.
- **Verify online**: app/tool gọi `POST /api/verify {tool, machineId, key}`.

## 1. Tạo bảng (migration SQL)
Vào Supabase → **SQL Editor**, mở lần lượt từng file trong `migrations/` rồi **dán & Run theo đúng thứ tự**:
1. `migrations/001_create_users.sql`
2. `migrations/002_create_tools.sql`
3. `migrations/003_create_licenses.sql` *(chạy sau vì có khoá ngoại)*
4. `migrations/004_tool_kind.sql` *(thêm `kind` app/tool + `parent_slug`)*
5. `migrations/005_create_orders.sql` *(đơn mua + thanh toán web2m)*

Các file dùng `create table if not exists` nên chạy lại nhiều lần vẫn an toàn.

## 2. Cấu hình & chạy
1. **Project Settings → API**: lấy `Project URL` + `service_role` **secret** key → điền vào `.env`.
2. Chạy:
```bash
cd Web-license
npm install
npm start
```

- Cửa hàng / user: `http://<host>:8090/` — trang: `/` (đăng nhập), `/dashboard`, `/setting`
- Quản trị: `http://<host>:8090/281admin` — trang: `/281admin`, `/281admin/tools`, `/281admin/licenses`, `/281admin/user`

Frontend tách 2 khu: `public/User/` (phục vụ ở gốc domain) và `public/Admin/` (phục vụ dưới prefix bí mật `/281admin`); asset chung ở `public/assets/`.

### Biến môi trường
| Biến | Ý nghĩa |
|---|---|
| `PORT` | Cổng HTTP (mặc định 8090) |
| `SESSION_SECRET` | Bí mật ký token đăng nhập (chuỗi dài, ngẫu nhiên) |
| `SUPABASE_URL` | Project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | **service_role** secret key (chỉ ở server) |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | *(tuỳ chọn)* tự tạo admin lúc khởi động; không đặt thì làm theo mục dưới |
| `BANK_ID` / `BANK_ACCOUNT` / `BANK_ACCOUNT_NAME` | Tài khoản nhận tiền (sinh QR VietQR). `BANK_ID` = BIN (vd 970436) hoặc short code (VCB…) |
| `BANK_QR_TEMPLATE` | Mẫu QR VietQR: `compact2` (mặc định) · `compact` · `qr_only` · `print` |
| `WEB2M_WEBHOOK_SECRET` | Bí mật xác thực webhook web2m (chuỗi dài ngẫu nhiên) |
| `ORDER_TTL_MINUTES` | Hạn thanh toán mỗi đơn (mặc định 15 phút) |
| `ALLOW_MOCK_PURCHASE` | `=1` để bật `/api/purchase` (cấp key ngay, không thanh toán — chỉ test) |
| `GRANT_ED25519_SEED` | **BẮT BUỘC** cho grant Ed25519 (Nhóm 1). Seed 32-byte (base64) để ký grant `/api/grant`. Sinh: `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"`. ⚠️ Pubkey dẫn xuất PHẢI khớp `GRANT_PUBKEY` nhúng trong `app/daemon/src/grant.m` — đổi seed = phải rebuild + phát hành lại daemon cho mọi máy. THIẾU biến này → `/api/grant` trả `503 server_no_key` → **mọi thiết bị bị khoá**. |
| `GRANT_KEY_ID` | ID khóa ký (mặc định `license-2026-01`); phải khớp `GRANT_KEY_ID` trong `grant.m`. |
| `GRANT_TTL_MINUTES` | TTL grant (mặc định 20 phút). |

> ⚠️ `service_role` key **bỏ qua RLS** — chỉ để ở server, KHÔNG đưa vào client/web tĩnh.
> ⚠️ `GRANT_ED25519_SEED` là **bí mật ký bản quyền** — chỉ đặt ở env server production, KHÔNG commit vào git. Lấy giá trị hiện dùng từ `web-license/.env` local (pubkey của nó đã khớp daemon đang phát hành).

## Tạo tài khoản admin
1. Vào cửa hàng `http://<host>:8090/` → **Tạo tài khoản** (đăng ký như user thường).
2. Vào Supabase → **SQL Editor**, nâng quyền tài khoản đó:
   ```sql
   update public.users set role = 'admin' where email = 'ban@email.com';
   ```
3. Vào `http://<host>:8090/281admin`, đăng nhập lại để lấy token mới (có `role=admin`).

> Token đăng nhập nhớ role tại thời điểm cấp — sau khi đổi role phải **đăng nhập lại**.

## API
### Auth
| Method | Path | Body | |
|---|---|---|---|
| POST | `/api/auth/register` | `{email, password, name?}` | → `{token, user}` |
| POST | `/api/auth/login` | `{email, password}` | → `{token, user}` |
| GET  | `/api/auth/me` | — (Bearer) | thông tin tài khoản |

### Public / User (Bearer token cho user)
| Method | Path | Body | Dùng cho |
|---|---|---|---|
| GET  | `/api/tools` | — | Danh sách tool đang bán + gói (kèm `kind`, `parentSlug`) |
| POST | `/api/verify` | `{tool, machineId, key}` | Kiểm tra **1** license (app **hoặc** 1 tool) — cần key |
| POST | `/api/verify/device` | `{tool, machineId}` | Kiểm theo **SERIAL** (KHÔNG cần key): máy này còn quyền dùng tool không? → `{valid, reason, plan, expiresAt}` |
| POST | `/api/verify/app` | `{app, appKey, machineId, tools:[{tool,key}]}` | Kiểm tra **GỘP**: license app iosauto + từng tool con (1 lần gọi) |
| GET  | `/api/me/licenses` | — | License của tôi |
| GET  | `/api/me/orders` | — | Đơn mua của tôi |
| POST | `/api/orders` | `{toolId, plan, machineId?}` | **Tạo đơn** → `{code, amount, qrUrl, bank, transferContent}` (gói giá 0 → cấp key ngay) |
| GET  | `/api/orders/:code` | — | Poll trạng thái đơn → `{status, key}` |
| POST | `/api/purchase` | `{toolId, plan, machineId?}` | Mua **mock** (chỉ khi `ALLOW_MOCK_PURCHASE=1`) |
| POST | `/api/activate` | `{key, machineId}` | Gắn serial cho key của mình |

### Webhook (web2m — không cần token đăng nhập, xác thực bằng secret)
| Method | Path | Body | |
|---|---|---|---|
| POST | `/api/webhook/web2m?secret=<WEB2M_WEBHOOK_SECRET>` | payload biến động số dư | Đối soát `(mã nội dung + số tiền)` → cấp key |
| POST | `/api/me/profile` | `{name}` | Đổi tên hiển thị |
| POST | `/api/me/password` | `{oldPassword, newPassword}` | Đổi mật khẩu |

### Admin (Bearer token role=admin)
| Method | Path | Body | |
|---|---|---|---|
| GET   | `/api/admin/tools` | — | Liệt kê tool + `defaultPlans` |
| POST  | `/api/admin/tools` | `{name, slug?, description?, plans?}` | Tạo tool |
| PATCH | `/api/admin/tools/:id` | `{name?, description?, plans?, active?}` | Sửa/ẩn tool |
| GET   | `/api/admin/licenses` | `?tool=<id>` | Liệt kê license |
| POST  | `/api/admin/issue` | `{toolId, plan, userEmail?, machineId?, note?}` | Cấp key |
| POST  | `/api/admin/activate` | `{key, machineId}` | Kích hoạt theo serial |
| POST  | `/api/admin/revoke` | `{key}` | Thu hồi |
| POST  | `/api/admin/extend` | `{key, days}` | Gia hạn |
| GET   | `/api/admin/users` | — | Liệt kê user |

`reason` của verify: `ok` · `not_found` · `tool_mismatch` · `revoked` · `not_activated` · `machine_mismatch` · `expired`.

## Mô hình dữ liệu
- **users**(id, email, password_hash, name, role) — mật khẩu băm **scrypt**.
- **tools**(id, slug, name, description, **kind** `app`|`tool`, **parent_slug**, **plans** jsonb, active) — app mẹ (`kind='app'`) + tool con (`kind='tool'`, `parent_slug` trỏ về slug app); mỗi tool có gói riêng: `[{id,label,days,price}]`, `days=null` = vĩnh viễn.
- **licenses**(key, tool_id/slug/name, user_id/email, machine_id, plan, expires_at, status, paid, note) — `machine_id` null = **chưa kích hoạt**.
- **orders**(code, tool_id/slug/name, user_id/email, plan, amount, machine_id, status, license_key, tx_ref, expires_at, paid_at) — `code` = nội dung CK đối soát; `status`: `pending`→`paid`/`expired`; `tx_ref` unique = chống xử lý trùng giao dịch.

## Mô hình app iosauto + tool con
- **1 license cho APP** (`tools.kind='app'`, vd slug `iosauto`) — mở app.
- **Mỗi TOOL con 1 license riêng** (`kind='tool'`, `parentSlug='iosauto'`) — vd `ocr`, `tap`, `video`.
- App phải hợp lệ mới chạy; từng tool con lại cần license riêng của nó.

Đánh dấu app mẹ + gán tool con (chạy 1 lần sau migration 004, trong Supabase SQL Editor):
```sql
update public.tools set kind='app' where slug='iosauto';
update public.tools set parent_slug='iosauto' where slug in ('ocr','tap','video');
```
Hoặc qua admin API khi tạo tool: `POST /api/admin/tools {name, kind:"app"}` (app) / `{name, kind:"tool", parentSlug:"iosauto"}` (tool con).

## Nối vào app/tool
**Cách 1 — verify từng cái:** mỗi tool gọi `POST /api/verify {tool:"<slug>", machineId, key}`; `valid=false` → khoá.

**Cách 2 (khuyên dùng) — verify gộp 1 lần lúc mở app iosauto:**
```jsonc
POST /api/verify/app
{ "app":"iosauto", "appKey":"IOSA-XXXX-XXXX-XXXX", "machineId":"<serial>",
  "tools":[ {"tool":"ocr","key":"OCR-..."}, {"tool":"tap","key":"TAP-..."} ] }
// →
{ "ok":true,
  "app":  { "slug":"iosauto", "valid":true, "reason":"ok", "plan":"365d", "expiresAt":"..." },
  "tools":{ "ocr":{ "valid":true,  "enabled":true,  "reason":"ok",      "plan":"30d", "expiresAt":"..." },
            "tap":{ "valid":false, "enabled":false, "reason":"expired", "plan":"30d", "expiresAt":"..." } } }
```
Client: `app.valid=false` → khoá cả app; mỗi tool bật khi `tools[slug].enabled=true` (đã gồm điều kiện app hợp lệ). Key + serial do user nhập/kích hoạt.

## Thanh toán (mua license qua web2m)
Luồng tự động, không cần thao tác tay:
1. User chọn tool + gói → `POST /api/orders`. Server tạo **đơn pending** với **mã nội dung** duy nhất (vd `IA7K3M9QAB`) và trả về **ảnh QR VietQR** (kèm sẵn số tiền + nội dung).
2. Frontend hiện QR + thông tin CK, rồi **poll** `GET /api/orders/:code` mỗi ~4s.
3. User chuyển khoản (nội dung = mã đơn). **web2m** phát hiện tiền về → gọi **webhook** `POST /api/webhook/web2m`.
4. Server đối soát: nội dung chứa mã đơn **và** số tiền ≥ giá gói → đổi đơn sang **paid**, **cấp license key** ngay, chống xử lý trùng theo mã giao dịch.
5. Lần poll kế tiếp thấy `status=paid` → frontend hiện key.

**Cấu hình:**
1. Điền `BANK_ID`, `BANK_ACCOUNT`, `BANK_ACCOUNT_NAME`, `WEB2M_WEBHOOK_SECRET` trong `.env`.
2. Trong bảng điều khiển **web2m**, đặt URL webhook:
   `https://<domain>/api/webhook/web2m?secret=<WEB2M_WEBHOOK_SECRET>`
   *(server cũng nhận secret qua header `X-Webhook-Secret` hoặc `Authorization`.)*

> Webhook parse **linh hoạt** nhiều tên trường (`transferAmount`/`amount`, `content`/`description`…) và cả payload `{data:[...]}` lẫn object đơn lẻ. Nếu web2m gửi định dạng lạ, xem log server (`webhook web2m: không khớp…`) để chỉnh `normalizeTx()` trong `server.js`.

## Bảo mật (đã tích hợp)
| Lớp | Cơ chế |
|---|---|
| HTTP headers | `helmet` — CSP (`script-src 'self'`), `nosniff`, `X-Frame-Options`, ẩn `X-Powered-By`, HSTS khi HTTPS |
| Rate limit | `express-rate-limit` — auth & đổi mật khẩu 30/15′; verify & mua 60/1′ (theo IP) |
| Body limit | `express.json({ limit: '16kb' })` chống payload phình |
| Mật khẩu | băm **scrypt** + salt; so sánh `timingSafeEqual` |
| Token | ký **HMAC-SHA256**, có hạn (`TOKEN_TTL_DAYS`, mặc định 7); không token → API admin trả 403 |
| Phân quyền | mọi `/api/admin/*` qua `requireAdmin`; đăng ký luôn tạo `role='user'` (không tự nâng quyền được) |
| Cô lập DB | server dùng `service_role` (chỉ ở server); RLS bật sẵn chặn anon key |

Biến môi trường bảo mật thêm: `TOKEN_TTL_DAYS` (hạn token), `TRUST_PROXY=1` (**chỉ** bật khi chạy sau reverse proxy).

**Giấu khu admin:** khi đăng nhập, server đặt thêm cookie `ia_token` (**HttpOnly**). Truy cập bất kỳ đường dẫn `/281admin*` sẽ bị `adminGate` chặn **ngay khi điều hướng** — không phải admin thì trả **404** (dùng chung `public/404.html`), không hề gửi HTML/JS của trang admin. Bảo vệ API vẫn là `requireAdmin` (Bearer). Cookie chỉ để gác trang, không dùng cho mutation → không lo CSRF; đặt `COOKIE_SECURE=1` khi chạy HTTPS.

## Lên production
- **Không** đặt `ALLOW_MOCK_PURCHASE` (giữ trống) → tắt cấp key miễn phí; chỉ cấp qua webhook web2m khi tiền thật về.
- Cấu hình `BANK_*` + `WEB2M_WEBHOOK_SECRET` và khai báo URL webhook cho web2m (xem mục *Thanh toán*).
- Chạy sau **HTTPS** (reverse proxy) và đặt `TRUST_PROXY=1` để rate-limit đọc đúng IP.
- Đổi `SESSION_SECRET` (nếu để mặc định + `NODE_ENV=production` server sẽ cảnh báo); giữ `service_role` key bí mật.
