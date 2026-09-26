# Windows E2E (manual, needs MSYS2 ucrt64 + Edge WebView2 runtime)

```sh
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o hello.exe ./examples/hello
# copy next to hello.exe: libwebview-0.12.dll, WebView2Loader.dll,
# libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll (from ucrt64/bin)
./hello.exe
# click "ping backend" -> status becomes "backend says: pong"
```

Verified 2026-09-26: full JS→V→JS round trip (`window.vails.call('ping')`
→ `bind_cb` → `Router.handle_message` → `ping_handler` → `webview_return`
→ promise resolves). Proof:

![pong proof](pong.png)
