# Prompt chung: Tích hợp một service bất kỳ với credential-vault (cv)

> **Đây là prompt CHUNG, dùng cho MỌI service consumer (hiện tại: hero, cms, autobuild; và mọi service mới sau này).**
> Mục tiêu: chỉ ra **định hướng + luồng + các vấn đề phải bao quát** khi code tích hợp một service với cv — KHÔNG đi sâu code từng dòng. Khi áp dụng cho 1 service cụ thể, agent tự chọn cách hiện thực theo stack/pattern sẵn có của service đó.
> Khi cv thay đổi liên quan tới tích hợp (SSO, grant, provisioning, env, contract), **cập nhật file này trước** (xem rule trong `CLAUDE.md`).

## 1. Vai trò & mô hình

- **cv = IdP trung tâm + Service Access Registry.** cv xác thực user (Authorization Code + PKCE, ký JWT **RS256**), giữ danh sách **service** và **grant** (ai được vào service nào).
- **Service = consumer/RP.** Nhận đăng nhập qua cv, verify token offline, và (tùy chọn) để cv **tạo/khoá account local** khi admin cấp/thu quyền.
- Mỗi service có một bản ghi trong cv với `slug` = `client_id`, một `client_secret`, và `callback_url`.

Ba luồng cần bao quát: **(A) SSO login**, **(B) Provisioning khi cấp quyền**, **(C) Revoke/deprovision**. Tùy nhu cầu service có thể chỉ làm A, hoặc A+B+C.

## 2. cv-side setup (admin làm 1 lần, trước khi service chạy)

1. Tạo service trong cv UI (Services → Tạo): `slug` (=client_id), `type=internal`, `callback_url`, `login_url`.
2. `callback_url` PHẢI **bằng chính xác** `redirect_uri` service gửi (`<APP>_PUBLIC_URL/sso/callback`) — cv so khớp **string tuyệt đối**, không wildcard. Host phải nằm trong env cv `CV_ALLOWED_REDIRECT_HOSTS`.
3. Rotate secret → copy `client_secret` (hiện 1 lần) vào env service.
4. **Nếu muốn auto-provision (luồng B):** đặt `Provider Kind = http`, tick `auto_provision`, nhập `provision_url`, rồi **rotate secret 1 lần SAU khi bật** (cv chỉ nạp `provision_secret` lúc tạo/rotate khi `auto_provision` đang bật). Đổi `provider_kind` của service đã tồn tại được hỗ trợ ở UI Sửa service.

## 3. Env vars phía service (đặt tên theo app)

- `CV_BASE_URL` — gốc API cv.
- `CV_CLIENT_ID` — = slug service.
- `CV_CLIENT_SECRET` — secret cv cấp (dùng cho token exchange VÀ verify Bearer provisioning).
- `CV_JWT_PUBLIC_KEY` (hoặc fetch JWKS từ cv) — verify access token RS256 offline.
- `CV_ISSUER` — `credential-vault`.
- `<APP>_PUBLIC_URL` — gốc của `/sso/callback`.
- `<APP>_SESSION_SECRET` — ký cookie pre-callback (state + verifier).

## 4. Luồng A — SSO login (Authorization Code + PKCE)

Định hướng (không token-in-URL, không implicit):

1. **`GET /sso/login`**: sinh PKCE `code_verifier` + `code_challenge` (S256) + `state` ngẫu nhiên; lưu `{verifier, state, returnTo}` vào **cookie signed, HttpOnly, SameSite=Lax, short-lived (~5'); cùng origin với callback**; redirect tới cv `/api/sso/authorize` kèm `client_id, redirect_uri, state, code_challenge`.
2. **`GET /sso/callback`**: đọc cookie tx; verify `state` khớp (CSRF); POST cv `/api/sso/token` (`code, code_verifier, client_id, client_secret, redirect_uri`) lấy `access_token`; **verify JWT offline** (RS256 qua public key/JWKS, `iss=credential-vault`, `aud=client_id`); kiểm tra token có grant cho service (claim `services` chứa `client_id`) — không có → 403; thiết lập session.
3. **Thiết lập session — chọn 1 kiểu:**
   - **Cookie cv-session** (như hero/cms): set cookie HttpOnly chứa access_token, các route bọc middleware verify. Vẫn có bảng user local để lưu dữ liệu app.
   - **Federated/mint-local** (như autobuild): map cv-user → user local theo email (find-or-create) rồi mint token bản địa của app; phần còn lại của app chạy nguyên.
   - **Stateless — KHÔNG bảng user** (dùng cv hoàn toàn): service không có bảng user / không có login user-password riêng; cookie chứa access_token, mỗi request verify offline + dùng claims làm danh tính. **Bỏ luồng B & C.** Xem mục **4b**.
4. **`/sso/logout`**: RP-Initiated Logout — clear session local rồi redirect cv logout; `post_logout_redirect_uri` phải **cùng origin** với callback_url.

**Phải bao quát:** `redirect_uri` khớp tuyệt đối + host allowlist; chống open-redirect ở `returnTo` (chỉ nhận path bắt đầu `/`, không `//`); cookie first-party Lax (`secure` ở production); verify **offline** để revoke key có hiệu lực; state-mismatch → 400 không set cookie.

## 4b. Chế độ KHÔNG bảng user (stateless — dùng cv hoàn toàn)

**Khi nào dùng:** service **không có bảng user** và **không có login user/password riêng** (vd tool nội bộ, dashboard chỉ-đọc, service mới chưa có user store). Danh tính đến HOÀN TOÀN từ cv — không tạo/không đồng bộ bảng user ở service.

**Cơ chế:**
1. Login y hệt luồng A tới bước lấy `access_token` (PKCE + callback + verify offline + check grant).
2. **KHÔNG** map/tạo user local. Set cookie phiên **HttpOnly, SameSite=Lax, `secure` ở prod** chứa **chính `access_token`** (không mint token local, không lưu DB). TTL cookie ≤ TTL token.
3. **Middleware mọi route bảo vệ:** đọc cookie → **verify JWT offline** (JWKS, `iss=credential-vault`, `aud=client_id`) → gán `req.user = claims` (`sub, email, role, name, services`). Check `services` chứa `client_id` → không thì 403. **KHÔNG truy DB.**
4. **Định danh user = `claims.sub`** (id cv, ổn định). Nếu service cần lưu dữ liệu theo user (settings, log) thì key theo `sub` — đây chỉ là *tham chiếu*, KHÔNG phải bảng user (không lưu email/password/hồ sơ).
5. **Token hết hạn** (cv TTL ~24h, không có refresh token ở Phase 1):
   - Request điều hướng trang → redirect `/sso/login?return=<path>`. Nếu cookie `cv_session` (ở cv, ~7 ngày) còn sống → cv cấp code mới **không hỏi lại** (re-auth im lặng) → callback → cookie mới. Nếu hết → user thấy form login cv.
   - Request API/XHR → trả **401**; client tự trigger full-page redirect tới `/sso/login`.
6. **Bỏ luồng B (provisioning) & C (deprovision):** không có account local để tạo/khoá; **grant ở cv là đủ** (claim `services` phản ánh grant). Cấp/thu quyền chỉ đổi trạng thái grant ở cv.
7. **Hồ sơ hiển thị:** `email/name/role` có sẵn trong token. Field khác (avatar/team/…) không có trong token → nếu cần, fetch từ cv (endpoint hồ sơ của cv) tại thời điểm hiển thị.
8. **Logout:** clear cookie + RP-Initiated Logout tới cv (như luồng A).

**Đánh đổi phải hiểu:**
- **Revoke không tức thời:** verify offline không biết grant bị thu hồi giữa chừng → token đang sống vẫn vào được tới khi hết hạn (TTL cv hiện ~24h → độ trễ revoke tối đa 24h). Nếu cần revoke NGAY thì gọi cv `GET /api/sso/userinfo` (Bearer token) để cv re-check grant/`isActive` mỗi-request hoặc định kỳ — đánh đổi mất tính offline + thêm latency + phụ thuộc cv online.
- **Phụ thuộc cv:** cv down → không login MỚI được (token đang sống vẫn dùng). Không có dữ liệu user local để join/hiển thị nhanh.
- **Ưu:** đơn giản nhất, không đồng bộ user, không migration, cv là nguồn danh tính duy nhất.

## 5. Luồng B — Provisioning (cv chủ động tạo account khi admin cấp quyền)

> Service **stateless (mục 4b) BỎ QUA cả section 5 và 6** — không có account local.


Khi admin cấp quyền user cho service (Ma trận quyền) và service cấu hình `http`+`auto_provision`, cv POST sang `provision_url` để **tạo sẵn account local ngay lúc grant** (không đợi user login).

**`POST <provision_url>`** (vd `/sso/provision`):
- **Auth:** header `Authorization: Bearer <client_secret>` — verify bằng so sánh **hằng-thời-gian** với `CV_CLIENT_SECRET`; sai/thiếu → 401.
- **Body — chỉ trường cơ bản:** `{ email, name, role, link_remote_id? }`. `role`=quyền auth cv (`admin|user`); `name` có thể `null`. Hồ sơ chi tiết (phone/team/position/level) giữ ở cv, không gửi sang consumer.
- **Xử lý:**
  - Nếu có **`link_remote_id`** → **LINK** account local có id đó với danh tính cv (set `sso_email`/mapping = email), cập nhật name/role nếu cần. (admin đã chọn account ở cv).
  - Không có `link_remote_id` → **find-or-create theo `email`, idempotent**. **Tìm rộng theo email** (cả account local tạo trước SSO chưa map): nếu đã có account cùng email → **LINK** (set mapping) thay vì insert — **tránh lỗi 409 unique** khi account đã tồn tại. Chưa có → tạo mới, password random.
- **Response:** `200 { remote_user_id }` — kể cả khi đã tồn tại/link. **KHÔNG trả 409** cho account đã tồn tại (phải link, idempotent).

> Thiếu endpoint này → cv grant chỉ tạo grant phía cv, account local KHÔNG được tạo tự động (SSO vẫn chạy, mất auto-provision).

### Liệt kê user (cho cv chọn account để link)
Để admin **chọn account sẵn có** ở service khi cấp quyền (thay vì luôn tạo mới), cv gọi:

**`GET <users_url>?q=&limit=`** (mặc định `users_url` = `provision_url` đổi `/provision`→`/users`, vd `/sso/users`):
- **Auth:** `Authorization: Bearer <client_secret>` (như provision).
- **Query:** `q` (lọc theo email/tên, optional), `limit` (vd 50).
- **Response:** `[{ remote_user_id, email, name }]` (hoặc `{ users: [...] }`). Chỉ trả trường cơ bản; có search để scale.
- cv hiển thị danh sách này, admin chọn 1 account → gọi provision kèm `link_remote_id`, hoặc "tạo mới" → provision không kèm.

## 6. Luồng C — Revoke / Deprovision

- **(Optional) `POST /sso/deprovision` body `{ email }`**: khoá/disable user local khi cv revoke; khai báo `config.deprovision_url` ở cv.
- **Lưu ý revoke không tức thời:** nếu service mint token local TTL dài, revoke bên cv không cắt session đang sống. Xử lý: TTL session ngắn (1–2h) để buộc re-auth, hoặc check `is_active`/grant ở guard.

## 7. Dual-auth & migration (nếu service đã có user/login cũ)

- Giữ login password cũ song song SSO (không regression).
- Migration user hiện có sang cv (map theo email) nếu cần một nguồn grant tập trung.

## 8. Checklist "bao quát hết vấn đề" (rà trước khi xong)

- [ ] `redirect_uri` == `callback_url` (string tuyệt đối) + host trong `CV_ALLOWED_REDIRECT_HOSTS`.
- [ ] PKCE S256; `state` verify; cookie tx signed/HttpOnly/Lax/short-lived/cùng origin.
- [ ] Verify JWT **offline** (RS256, iss, aud=client_id); revoke key có hiệu lực.
- [ ] Check grant (`services` chứa client_id) → 403 nếu không có.
- [ ] Chống open-redirect ở `returnTo`.
- [ ] **Nếu stateless (mục 4b):** cookie chứa access_token; verify offline mỗi request; danh tính = `claims.sub`; KHÔNG bảng user; xử lý token hết hạn (redirect trang / 401 cho XHR); revoke bằng TTL ngắn hoặc userinfo-recheck; **BỎ** provisioning & deprovision. (Các mục provisioning bên dưới KHÔNG áp dụng.)
- [ ] Provisioning: Bearer constant-time; find-or-create **idempotent**; trả `remote_user_id`; 401 khi sai secret.
- [ ] Provision **không 409**: account đã tồn tại (kể cả tạo trước SSO) → LINK (set mapping) thay vì insert.
- [ ] Provision nhận `link_remote_id` → link account chỉ định.
- [ ] Endpoint `GET /sso/users?q=&limit=` (Bearer secret) → `[{remote_user_id,email,name}]` cho cv chọn account link.
- [ ] Mapping user theo `email`; field hồ sơ nullable.
- [ ] Revoke: chiến lược TTL/`is_active` để có hiệu lực.
- [ ] Dual-auth không regression; logout RP-initiated đúng origin.
- [ ] Tests: login happy / state-mismatch / no-grant / inactive; provision happy / 401 / idempotent.

## 9. Áp dụng cho service cụ thể

Khi tích hợp service X: lấy prompt này làm khung, rồi điều chỉnh theo stack & pattern của X (Express/Next/…), đặt tên env `<X>_*`, đặt route theo cấu trúc X. Các prompt riêng `*-cv-integration.md` (hero/cms/autobuild) là ví dụ chi tiết tham chiếu khi cần code mẫu.
