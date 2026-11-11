# rs-assistant/steamac：自己 build 與安裝

這個 fork 以 [fxgl/steamac](https://github.com/fxgl/steamac) 為基礎，加上安全性與可驗證性的修改
（清單見文末）。本文件是在自己的 Mac 上從原始碼 build、安裝、驗證的步驟。產出是 ad-hoc 簽章的
`FX Steam Launcher.app`，不需要 Apple Developer ID，只在 build 的那台 Mac 上使用。

原始說明（英文）在 [README.md](README.md)。

## 1. 前置條件（只做一次）

- Apple Silicon Mac、macOS 15 以上、約 150 GB 可用空間（磁碟映像是 sparse 檔，實際用量隨遊戲增加）。
- **Xcode 26**（完整版，不是只有 Command Line Tools）。從 App Store 安裝，開啟一次同意授權，然後：

  ```bash
  sudo xcode-select -s /Applications/Xcode.app
  ```

- **Homebrew**：<https://brew.sh>
- **Homebrew 套件**：

  ```bash
  brew install meson ninja pkg-config dtc xz lld go
  ```

- **rustup**（二選一）：

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

  或 `brew install rustup && rustup default stable`（Homebrew 版要依安裝後的提示把路徑加進 `~/.zshrc`）。
  需要的 Rust 版本由 `host/libkrun/build.sh` 自己下載。

- **OrbStack**（提供 Docker，用來 build guest 端）：

  ```bash
  brew install --cask orbstack
  ```

  裝好後開啟 OrbStack 一次。每次 build 前它都要在背景執行。確認：

  ```bash
  docker run --rm --privileged --platform linux/arm64 alpine uname -m
  ```

  輸出 `aarch64` 即可。

## 2. 取得程式碼

```bash
git clone https://github.com/rs-assistant/steamac
```

```bash
cd steamac
```

## 3. Build

先 build guest，再 build host（app 打包時會檢查 guest 產物的 receipt）。

```bash
guest/kernel/build.sh
```

```bash
scripts/build-image.sh builder rootfs
```

```bash
guest/mesa/build.sh
```

```bash
scripts/build-image.sh initramfs layer
```

```bash
./build.sh host
```

- `rootfs` 這一步會從 Valve 下載數 GB 的 SteamOS 映像並驗證簽章與 sha256。
- 不需要 `scripts/build-image.sh disk`：磁碟由 app 第一次啟動時建立。
- 不要執行 `./build.sh dxmt`：DXMT/wmtr 是實驗功能，啟用後 guest 程式可以在 Mac 上以你的權限執行程式碼
  （README 的 Security 段落），而且 build 時會下載第三方預建的 Wine。
- macOS 26 以上會多 build KosmicKrisp，時間較長。
- 產出：`work/out/FX Steam Launcher.app`。

## 4. 檢查

```bash
work/out/steamac-vm --selftest-settings --selftest-out ~/steamac-selftest
```

最後一行應為 `selftest-settings: PASS`。

確認 app 是哪個 commit build 的：

```bash
/usr/libexec/PlistBuddy -c 'Print :SteamacGitCommit' "work/out/FX Steam Launcher.app/Contents/Info.plist"
```

應與 `git rev-parse --short=10 HEAD` 相同。

## 5. 安裝與第一次啟動

```bash
cp -R "work/out/FX Steam Launcher.app" /Applications/
```

這個 app 的 Info.plist 記錄了 build 目錄的路徑（含你的使用者名稱），不要把它交給別人。

第一次啟動：

1. 「Send crash reports and diagnostics」應為**未勾選**（這個 fork 預設關閉）。
2. **Create New Disk…** → 分支 stable → 勾選同意 Valve 授權 → 建立。會下載約 4.4 GB 並組出 10 GB 的
   rootfs，可以 Stop 後再 Resume。
3. macOS 詢問「存取可移除磁碟」或「區域網路」時按允許。

## 6. 使用上的注意事項

- **複製貼上用 Ctrl+C / Ctrl+V**，不是 ⌘C / ⌘V（⌘ 在 SteamOS 裡是 Super 鍵）。Mac 與 SteamOS 的剪貼簿
  會互通；SteamOS 只有在 app 位於前景時才能改寫 Mac 的剪貼簿。
- **設定**：⌘, 或選單 FX Steam Launcher → Settings…。
- **剛裝好時比較慢是正常的**：Steam 會在背景處理 Vulkan 著色器，每個都要在 Mac 上用 Metal 編譯。
  處理完就會恢復；要關閉可到 Steam → 設定 → 下載 → 「允許在背景處理 Vulkan 著色器」。
- **預設值（與 upstream 不同或值得知道的）**：
  - crash report：關閉。
  - SSH：關閉（Settings → Advanced 可開啟）。
  - 分享遊戲統計：關閉；關閉時 Games 分頁也不會向統計服務查詢推薦設定。
  - LAN Remote Play：關閉；開啟時只在 Mac 的區域網路位址上接受連線。
- **更新通知**：自己 build 的版本只會提示 upstream 有新版，不會自動安裝。視窗的按鈕是 **View Release**，
  只會打開 upstream 的 release 頁面，不會下載 DMG。要更新請依第 8 節重新 build，不要安裝 upstream 的 DMG
  （它不含這個 fork 的修改）。這個 fork 第一次啟動時會把「crash report 關閉」明確寫進設定檔，所以就算
  裝了 upstream 版，crash report 仍維持關閉。
- **log**：`~/Library/Logs/es.fxgam.steamac/steamac-vm.log`

## 7. 建議確認的項目

| 項目 | 做法 | 預期 |
|---|---|---|
| 開機與進度畫面 | 啟動 SteamOS | 進度畫面走到 Steam |
| 網路 | Steam 登入、開商店 | 可連線 |
| 剪貼簿 | Mac 複製，SteamOS 裡 Ctrl+V | 可貼上 |
| SSH | Settings → Advanced | 預設關閉 |
| crash report | Settings → General | 預設關閉 |

出問題時，附上卡住的畫面或訊息，以及：

```bash
tail -100 ~/Library/Logs/es.fxgam.steamac/steamac-vm.log
```

## 8. 更新

```bash
git pull
```

然後重跑第 3 節的 build（沒變動的步驟會很快跳過或重用快取），再重新複製 app 到 `/Applications`。
SteamOS 磁碟不需要重建。

## 9. 這個 fork 改了什麼

- **預設值**：crash report、SSH 預設關閉；guest 的 `fx.progress` / `fx.clipboard` port 只給 session 使用者。
- **供應鏈**：gvproxy、desync 由鎖定版本的原始碼 build，不下載預建 binary；快取的 rootfs 使用前重新驗證雜湊。
- **Host 處理 guest 輸入**：尺寸、長度、數量都有上限（focus 尺寸、log、PNG、遊戲名稱、HID report、GPT）；
  run dir 不沿用既有目錄；libkrun 追加 patch 0026–0031（重複映射、2D 資源尺寸、console port id、
  音效擷取配置、scanout 記錄、共享資料夾限制在資料夾內）。
- **Guest**：kernel 記憶體防護選項、agent 的暫存檔與 marker、env 白名單與黑名單、凍結遊戲的復原。
- **CI**（`.github/workflows/`）：macOS 上 build host 全套並跑 selftest；arm64 Linux 上 build kernel
  （QEMU 開機測試）、initramfs、agent。`app-build.yml` 跑完整流程：Mesa（aarch64、x86）、rootfs、
  Mesa verify、layer，最後在 macOS 上組出 `.app` 並檢查簽章與 receipt（產物保留 7 天）。CI 的 `.app`
  不含 KosmicKrisp（runner 的 GPU 過不了它的 probe）。GitHub 的 runner 無法開 VM，開機與遊戲只能在實體
  Mac 上驗證。

逐項內容見 `git log upstream/main..HEAD`（upstream = fxgl/steamac）。
