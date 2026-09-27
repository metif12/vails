# Docs Site Plan — Vails intro + documentation (Phase 7, parked)

> وضعیت: **پارک شده**. این فایل فقط برنامه و اطلاعات لازم را ذخیره می‌کند.
> ساخت سایت بعد از اتمام همه فازها و ترک‌ها (آخر Phase 7) شروع می‌شود.
> تصمیم‌های قفل‌شده: محتوای سایت **انگلیسی LTR**، خروجی **استاتیک اکسپورت
> (GitHub Pages)**، اسکوپ نسخه اول **داک کامل** (نه MVP خلاصه).

## 1. پیش‌شرط شروع (entry criteria)

قبل از شروع ساخت، این‌ها باید تمام شده باشند (رجوع به `ROADMAP.md`):

- Phase 3 (assets/dev) تا Phase 7 (hardening) + ترک‌های T3/T4/T5، M0–M4، C0–C4.
- کاتالوگ سرویس‌ها (S1/S2/S3) نهایی شده باشد، چون هر سرویس یک صفحه داک می‌خواهد.
- `generator` و `vails.json` پایدار شده باشند (مرجع CLI/API از روی `--help`
  واقعی و سورس تولید می‌شود، نه حدس).

## 2. ساختار سایت (IA نهایی)

```text
Home (hero + جدول مقایسه Wails/Tauri/Vails + کد ۱۰خطی hello + CTA)
/docs/getting-started  نصب (V 0.5.x، MSYS2 ucrt64، webkitgtk) + vails doctor
/docs/quickstart        init → run → ping→pong
/docs/concepts          app, window, bridge, IPC command-vs-event, events,
                       capabilities, config (از روی CONTEXT.md)
/docs/guides           assets dev/prod، generator d.ts، channels (T3)،
                       state (T4)، CSP (T7)، mobile (M0–M4)، CEF opt-in
/docs/cli              version/doctor/init/run/build [--target] + exit codes
/docs/services         یک صفحه به‌ازای هر سرویس S1/S2 + manifestهای T5
/docs/security         capability matrix + asset scope + threading rule
/docs/api              مرجع خشک هر ماژول (signature + مثال)
/docs/examples         E0–E6 + hello
/docs/troubleshooting  GC ـgc none، Wayland، WebView2، frontend not found + FAQ
/docs/adr              ایندکس ADR-0001 تا 0011 + خلاصه هر تصمیم
/docs/roadmap          + changelog
/llms.txt              نسخه AI-friendly (معادل markdown negotiation در veb)
```

استاندارد بصری (از Examples track در ROADMAP): system type scale،
spacing rhythm، `focus-visible`، `light+dark via prefers-color-scheme`،
vanilla بدون فریمورک UI، انگلیسی LTR.

## 3. نکات فنی veb (تحقیق‌شده روی V 0.5.x، از modules.vlang.io/veb.html)

- اسکلت: `App { veb.StaticHandler }` + `Context { veb.Context }` +
  `veb.run[App, Context](mut app, 8080)`.
- استاتیک: `app.handle_static('static', true)!` برای mount در روت؛
  `index.html` خودکار سرو می‌شود. مثال رسمی: `examples/veb/static_website`.
- دو حالت: dev با `v -d veb_livereload watch run .` (فقط صفحات دارای
  `</html>`)، prod با `v -prod` → سینگل‌باینری شامل تمپلیت‌های
  کامپایل‌شده (خطای تمپلیت در build، نه runtime).
- امکانات آماده: `enable_static_compression` (zstd/gzip، pre-compress با
  `zstd -k`)، `enable_markdown_negotiation` (سرو `path.md` با
  `Accept: text/markdown` — پایه `llms.txt`)، `not_found()` کاستوم برای
  ۴۰۴، middleware (`app.use` / `route_use`)، controllers برای گروه‌بندی.
- نقش veb در این پروژه فقط **SSG + سرور پیش‌نمایش** است: یک دستور export
  همه routeها را crawl و `dist/*.html` می‌نویسد؛ `dist/` به GitHub Pages
  می‌رود (gitignore یا branch جدا).

## 4. موجودی محتوا (از کجا برداشته می‌شود — موقع ساخت دوباره راستی‌آزمایی شود)

- `README.md`: جدول مقایسه، prerequisites، install، troubleshooting.
- `CONTEXT.md`: همه مفاهیم دامنه (App/Window/Bridge/IPC/Capability/Config).
- `docs/ADR/0001–0011`: خلاصه هر تصمیم برای `/docs/adr`.
- `application/`: `AppOptions`، `new`، `register_service`، `has_service`.
- `bridge/`: `Request/Response/Notify`، `register`، `register_validated`،
  `call_from`/`call_json`، `notify`، `handle_envelope_from`،
  `runtime_js`/`runtime_js_bound`، `resolve_js`، پیشوندهای `err_*`.
- `events/`: `on`/`emit`، `to_js`.
- `assets/`: `Server.read`، `content_type`، embed vs dev.
- `generator/`: `MethodSpec`، `generate_dts`.
- `capabilities/`: `grant`، `is_allowed`، ماتریس allow/deny.
- `config/`: `load`/`validate`/`to_registry`/`default_config`، فیلدهای
  `vails.json`.
- `cli/vails.v`: رفتار واقعی `version/doctor/init/run/build`.
- `examples/hello/`: `main.v` + `vails.json` + `frontend/index.html`
  (الگوی کد داخل داک).
- `tests/e2e_windows/README.md` و `tests/e2e_linux/README.md`: شواهد و نکات.

## 5. جانمایی فایل‌ها (موقع ساخت)

```text
docs/site/
  PLAN.md            # همین فایل (برنامه؛ موقع ساخت آپدیت شود)
  content/**/*.md    # هر صفحه یک md + frontmatter (title, nav, order)
  templates/*.html   # لی‌آوت veb (header/nav/footer، dark-mode)
  static/css|js|img  # vanilla، بدون بیلد
  veb_site.v         # routeها + handle_static + export به dist/
  config.json        # درخت nav، ورژن، لینک GitHub
dist/                # خروجی build (منتشر شود، سورس نیست)
```

## 6. مراحل اجرا (موقع ساخت — هر کدام code + test + خط داک)

1. Content inventory: استخراج API واقعی هر ماژول + خلاصه ADRها.
2. IA + `config.json`: درخت nav بخش ۲ + frontmatter.
3. Scaffold `veb_site.v`: routeها (`/`, `/docs/:path...` fallback،
   `/llms.txt`) + `handle_static` + `not_found` + تست pure-V (سبز روی Windows).
4. Templates + CSS: لی‌آوت، highlight کد hello، dark-mode،
   `focus-visible`، جستجوی client-side (index JSON استاتیک).
5. Port محتوا از بخش ۴ (فقط از سورس واقعی، بدون حدس).
6. Export + preview: `v run docs/site --export` → `dist/`؛
   `v -d veb_livereload watch run docs/site` برای نویسندگی.
7. Verify + close: `v fmt -w .`، `v test .` سبز ویندوز؛ لینک Pages؛
   تیک ROADMAP؛ یک خط در CONTEXT.md (قانون Definition of done).

## 7. ریسک‌ها

- تغییر API `veb` بین نسخه‌های 0.5.x → اول spike کوچک `handle_static`.
- رندر Markdown خالص V (`x.markdown`) محدود است → md→HTML در build-time
  با همان تمپلیت veb، بدون dependency جدید.
- اگر Phase 7 دیر شد: اول Home + getting-started + quickstart + یک API
  مرج شود، بقیه incremental.
