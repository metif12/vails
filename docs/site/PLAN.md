# Docs Site Plan — Vails intro + documentation (Phase 7)

> وضعیت: **برنامه‌ریزی‌شده، ساخته نشده**. این فایل برنامه و اطلاعات لازم را
> ذخیره می‌کند؛ هیچ خطی از سایت هنوز نوشته نشده و `docs/site/` فقط همین
> فایل را دارد.
> تصمیم‌های قفل‌شده: محتوای سایت **انگلیسی LTR**، خروجی **استاتیک اکسپورت
> (GitHub Pages)**، اسکوپ نسخه اول **داک کامل** (نه MVP خلاصه)، انتشار
> **خودکار از CI** (بخش ۷).

> **تاریخچهٔ این فایل (۲۰۲۶-۱۰-۰۴).** نسخهٔ قبلی سه ایراد داشت که این
> ویرایش آن‌ها را درست می‌کند: می‌گفت ساخت «بعد از اتمام همهٔ فازها و ترک‌ها»
> شروع می‌شود، که شرطی است که هرگز برآورده نمی‌شود (بخش ۱)؛ بازهٔ ADR را
> `۰۰۰۱–۰۰۱۱` نوشته بود در حالی که ۳۷ فایل تا `۰۰۳۹` وجود دارد (بخش ۴)؛ و
> می‌گفت `dist/` به Pages می‌رود بدون آنکه بگوید **چه چیزی** آن را می‌برد
> (بخش ۷، تازه اضافه شد).

## 1. پیش‌شرط شروع (entry criteria)

قبل از شروع ساخت، این‌ها باید تمام شده باشند (رجوع به `ROADMAP.md`):

- Phase 3 (assets/dev) تا Phase 7 (hardening) + ترک‌های T3/T4/T5، M0–M4، C0–C4.
- کاتالوگ سرویس‌ها (S1/S2/S3) نهایی شده باشد، چون هر سرویس یک صفحه داک می‌خواهد.
- `generator` و `vails.json` پایدار شده باشند (مرجع CLI/API از روی `--help`
  واقعی و سورس تولید می‌شود، نه حدس).

### شرطی که تازه اضافه شده: CI باید یک بار سبز شده باشد

بخش ۷ تازه اضافه شد و یک پیش‌نیاز دارد که این فایل قبلاً نداشت: **Publish
کردن با یک `ci.yml` که تاکنون هیچ job سبزی ندارد، یعنی استقرار روی یک دروازهٔ
تست‌نشده.** تا وقتی `ci.yml` یک اجرای واقعیِ سبز گزارش نکرده، افزودن `docs.yml`
یعنی دو سیستم که هیچ‌کدام اثبات نشده‌اند، که بدتر از یکی اثبات‌نشده است.

ترتیب صریح، چون AGENTS.md §3 می‌گوید یک فاز در هر بار:

1. `ci.yml` یک اجرای سبز روی runner واقعی داشته باشد.
2. بعد `docs.yml`.
3. بعد `veb` spike.

اگر این ترتیب رعایت نشود، «سایت منتشر شد» ادعایی است که یک بن‌بست
زیرساختی را پنهان می‌کند.

### و یک شرط که برداشته شد

نسخهٔ قبلی این فایل می‌گفت «ساخت سایت بعد از اتمام **همهٔ** فازها و ترک‌ها
شروع می‌شود». آن شرط هرگز برآورده نمی‌شود: `ROADMAP.md` خودش می‌گوید ≈۵۲ روز
کار باقی مانده و دو ترک روی «تصمیم‌های بستهٔ خودشان» گیر کرده‌اند (X0 Vinix
منتظر یک «بله» است، U1–U4 منتظر یک کانال توزیع). **پارک تا ابد، خودش یک
انتظار است که پایان ندارد.** شرط درست، «پایداری» است نه «پایان»:

> شروع ساخت وقتی مجاز است که `CONTEXT.md`، `cli/vails.v`، `vails.json` و
> مانند آن‌ها **دیگر در حال جابه‌جایی نباشند** — چون هر تغییر بعد از نوشتن
> داک یعنی داک کهنه. ساخت تدریجی و در طول کار مجاز است؛ **منتظر ماندن تا
> «همه‌چیز تمام شد» مجاز نیست.**

این یعنی صفحه‌هایی که از روی سورسِ پایدار تولید می‌شوند (`--help`, `v doc`,
`.d.ts`) زودتر می‌آیند و صفحه‌های دستی دیرتر — که همان ترتیبی است که بخش ۸
توصیه می‌کند.

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
- `docs/ADR/`: خلاصه هر تصمیم برای `/docs/adr`. **بازهٔ درست ۰۰۰۱–۰۰۳۹ است**
  (۳۷ فایل، شمارش‌شده ۲۰۲۶-۱۰-۰۴) — نسخهٔ قبلی این فایل «۰۰۰۱–۰۰۱۱» می‌نوشت
  که ۲۸ تصمیمِ ثبت‌شده را نادیده می‌گرفت. `/docs/adr` باید **خودش فهرست را
  بسازد** (اسکن دایرکتوری)، نه اینکه بازه‌ای دستی در کد بنویسد؛ وگرنه همین
  کهنگی دوباره اتفاق می‌افتد.
- `CHANGELOG.md`: به‌ازای هر نسخه، برای صفحهٔ releases.
- `ROADMAP.md`: جدول اولویت + چک‌باکس‌ها، برای `/docs/roadmap`.
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

## 7. CI و انتشار روی GitHub Pages

> اضافه‌شده ۲۰۲۶-۱۰-۰۴. بخش ۷ قبلاً فقط «`dist/` به GitHub Pages می‌رود» می‌گفت
> بدون اینکه بگوید **چه کسی** آن را می‌برد. جواب یک workflow جداست، و چون
> `ci.yml` از قبل یک precedent دارد، این بخش به‌جای یک فایل تازه همان
> قرارداد را دنبال می‌کند.

### چرا یک workflow جدا و نه یک step در `ci.yml`

`ci.yml` سه job دارد (`linux` / `windows` / `release`) و هر سه **دروازه** هستند:
اگر `v test .` قرمز شود، انتشار نباید اتفاق بیفتد. اما سایت یک محصول جانبی است
و دو خاصیت متفاوت دارد:

- **سریع است.** یک SSG که ۲۰ صفحه را می‌سازد، ثانیه‌ها طول می‌کشد؛ کش کردن
  کل `docker build` تصویر V برای آن، اتلاف وقت runner است.
- **شکستش نباید قرمزِ سبز را قرمز کند.** یک لینک شکسته در داک، دلیلی ندارد که
  build دسکتاپ را متوقف کند؛ اما اگر در همان workflow باشد، `required check`
  ها برای PRها همه‌چیز را گروگان می‌گیرند.

پس: `docs.yml` جدا، با `paths`-فیلتر روی `docs/site/**` و فایل‌هایی که داک از
آن‌ها ساخته می‌شود.

### شکل workflow

```yaml
name: Docs

on:
  push:
    branches: [main]
    paths: ['docs/site/**', 'CONTEXT.md', 'docs/ADR/**', 'v.mod', '.github/workflows/docs.yml']
  pull_request:
    paths: [همان فهرست بالا]   # همچنین باید تغییر داک، PR را بررسی کند
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write          # لازم برای artifact deployment

concurrency:
  group: pages
  cancel-in-progress: true # یک استقرار همزمان برای یک شاخه، بی‌معنا

jobs:
  build:
    # یک container لازم نیست: سایت هیچ Cای کامپایل نمی‌کند (فقط veb خالص V)،
    # پس یک V در vlib کافی است. این عمداً از linux job جدا نوشته شده.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-v@v2
        with: { version: 'v0.5.2' }
      - run: v -prod run docs/site -- --export     # dist/ را می‌نویسد
      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with: { path: docs/site/dist }
```

### چهار تصمیم که باید آگاهانه گرفته شوند

1. **`v -prod` در build، نه `v run`.** دلیلش در بخش ۳ هست: با `-prod` تمپلیت‌ها
   کامپایل می‌شوند، پس **خطای تمپلیت در CI می‌ترکد** نه در بازدیدکننده. این تنها
   دلیلی است که این مرحله وجود دارد و نباید با «سریع‌تر است» توجیه شود.
2. **`dist/` کامیت نمی‌شود.** دو گزینه است: gitignore (ساده) یا branch جدا مثل
   `gh-pages`. branch جدا برای SEO بهتر است (URL پایدار) ولی یک تنظیم
   deployment اضافه می‌خواهد؛ **پیش‌فرض: gitignore + artifact deployment**،
   و اگر روزی index‌شدن لازم شد، مهاجرت به branch جدا یک تغییر است نه بازنویسی.
3. **`404.html` لازم است.** GitHub Pages برای مسیر ناشناخته `404.html`
   می‌خواهد؛ `not_found()` کاستوم veb باید دقیقاً همین نام را تولید کند، وگرنه
   یک صفحه ۴۰۴ پیش‌فرض Pages با لینک‌های شکسته نمایش داده می‌شود.
4. **`llms.txt` باید در artifact باشد**، نه فقط پشت `enable_markdown_negotiation`
   زنده. Pages یک CDN است و مذاکرهٔ هدر روی آن قابل اتکا نیست؛ اگر مسیر
   `/docs/x` با `Accept: text/markdown` جواب می‌دهد ولی `/x.md` نه، آن قابلیت
   روی Pages یک رفتار متفاوت از preview است. **باید هر دو تولید شوند.**

### آنچه هنوز اثبات نشده

هیچ‌کدام از این‌ها اجرا نشده. `ci.yml` در این ریپو هنوز **هیچ job سبزی
ندارد** (ROADMAP «B2+B3 — اجرا شده، درست شده، اثبات نشده»)، پس «Pages
استقرار می‌دهد» ادعایی است که فقط یک اجرای واقعی می‌تواند بی‌معنا یا
اشتباهش کند. ترتیب درست: اول `docs.yml` را اضافه کن، بعد **یک push واقعی به
`main` بفرست و خروجی را بخوان**، و بعد در `ROADMAP.md` یک خط بنویس که چه شد.

خود `veb` هم اثبات نشده: `handle_static` و `--export` روی V 0.5.2 در این
ریپو **هیچ‌وقت کامپایل نشده‌اند** (بخش ۷ قدیم، ریسک اول). یک spike ده‌خطی قبل
از هر چیز.

## 8. ریسک‌ها

- تغییر API `veb` بین نسخه‌های 0.5.x → اول spike کوچک `handle_static`.
- رندر Markdown خالص V (`x.markdown`) محدود است → md→HTML در build-time
  با همان تمپلیت veb، بدون dependency جدید.
- اگر Phase 7 دیر شد: اول Home + getting-started + quickstart + یک API
  مرج شود، بقیه incremental.
- **داک و سایت هم‌زمان کهنه می‌شوند.** یک صفحه داک که دستی نوشته شده بعد از
  یک release غلط است. قاعده‌ای که پیشنهاد می‌شود: هر چیزی که *می‌تواند* از
  سورس تولید شود (`vails --help`، `v doc`، `--out d.ts`) تولید شود، و متن
  دستی فقط جایی بماند که تولیدش ممکن نیست. این تصمیم است، نه کارآمدی.
