# AirHeadMouse — 用 AirPods 頭控 macOS 鼠標

戴上 AirPods Pro 2 / AirPods 4（或 Pro 1 / AirPods 3 / Max），**轉頭移動光標**，**按耳機柄點擊**，**點頭粘貼**，**搖頭暫停**。

| 輸入 | 默認動作 |
|---|---|
| 單擊耳機柄 | 左鍵點擊 |
| 雙擊耳機柄 | 右鍵點擊 |
| 三擊耳機柄 | 複製 ⌘C |
| 點頭（快速 下→上） | 粘貼 ⌘V |
| 搖頭（快速 左→右→左） | 暫停 / 恢復頭控 |

所有映射可在「設置 → 手勢映射」裡改，可選：左/右/中鍵、雙擊、拖拽（按住/鬆開左鍵）、複製、粘貼、剪切、撤銷、全選、暫停、回中。
長按耳機柄被系統佔用（降噪切換），無法使用。

## 要求
- macOS 14 Sonoma 或更新（`CMHeadphoneMotionManager` 在 macOS 上從 14 開始提供）
- Xcode 15+（或 Command Line Tools，含 Swift 5.9+）
- 帶運動傳感器的 AirPods：Pro / Pro 2 / 3 / 4 / Max（AirPods 1、2 不行）

## 構建與運行
```bash
git clone <this repo> && cd AirHeadMouse
scripts/bundle.sh          # 生成 build/AirHeadMouse.app
open build/AirHeadMouse.app
```
> 必須以 `.app` 運行（不要用 `swift run`），否則系統不會彈出「運動與健身」權限。

首次運行：
1. **輔助功能**：系統會提示，前往「系統設置 → 隱私與安全性 → 輔助功能」，打開 AirHeadMouse。（用於移動光標和發送點擊/按鍵）
2. **運動與健身**：戴上 AirPods 後會彈出請求，點允許。
3. 菜單欄出現 AirPods 圖標即表示頭控中。

> ad-hoc 簽名在每次重新構建後會被系統視為新 App，需要在「輔助功能」裡刪除舊條目重新勾選。
> 如有開發者證書：`SIGN_IDENTITY="Apple Development: 你的名字" scripts/bundle.sh` 可避免此問題。

## 使用技巧
- **移動是相對的**（像搖桿/觸控板）：轉頭的速度決定光標移動量，停住頭光標就停。轉到舒服角度後搖頭暫停 → 回正頭 → 搖頭恢復，即可「換手」。
- 太靈敏/太遲鈍：調「靈敏度」「加速度」；光標自己漂：調大「死區」。
- 點擊時系統要等約 0.3 秒判斷單/雙/三擊，程序會把光標退回到按下那一刻（吸附半徑內）再點，避免點偏。
- 點頭/搖頭時光標會被帶動，識別成功後會自動還原到手勢開始前的位置。
- 如果打開了 Music / Spotify / 瀏覽器視頻，耳機按壓可能被它們搶走 → 菜單裡點「重新獲取耳機按鍵」。
- 本程序播放靜音音頻來接收耳機按壓，聽音樂時耳機按鍵將由本程序接管。

## 故障排查：轉頭光標不動
打開菜單欄圖標 →「調試數據」，看這幾行：

| 現象 | 說明 / 處理 |
|---|---|
| 授權 = 未決定 / 已拒絕 | 系統設置 → 隱私與安全性 → 運動與健身，打開 AirHeadMouse |
| 樣本數 = 0 | 沒收到數據：確認 AirPods 已戴上、是當前音頻輸出；點「重啟頭部追蹤」 |
| 樣本數增長，但姿態恆為 0 | 程序會自動改用陀螺儀（數據來源顯示「陀螺儀」）；也可在 設置 → 數據來源 手動選 |
| 陀螺儀 x/y/z 也恆為 0 | 耳機沒在推送運動數據：控制中心 → 聲音 → AirPods →「空間音頻」改為「頭部追蹤」，摘下重戴一次 |
| 光標方向反了 / 上下左右錯軸 | 設置 → 數據來源：轉頭時看哪個 gyro 軸變化最大，選該軸，方向反了勾「反向」 |
| 狀態 = 速度低於死區 | 頭在動卻顯示此項 → 調小 設置 → 光標 → 死區 |

查看日誌：
```bash
log stream --predicate 'subsystem == "com.example.airheadmouse"'
```

## 項目結構
```
Sources/HeadMouseCore/      純邏輯（只依賴 Foundation，可測試、可移植到 Windows/iPhone 橋接）
  OneEuroFilter.swift       去抖濾波
  MotionSample.swift        姿態 → 角速度（處理 yaw ±π 跳變）
  HeadRateSource.swift      姿態 / 陀螺儀 / 自動切換 的角速度來源
  PointerMapper.swift       角速度 → 像素位移（死區、加速曲線、亞像素累積）
  HeadGestureDetector.swift 點頭/搖頭識別
  PositionHistory.swift     光標歷史，用於手勢後還原
  Actions.swift             觸發源、動作、設置
Sources/AirHeadMouse/       macOS App
  HeadMotionSource.swift    CMHeadphoneMotionManager
  PressGestureSource.swift  靜音 Now Playing + MPRemoteCommandCenter 攔截按壓
  MacInputSink.swift        CGEvent 注入鼠標/鍵盤
  AppController.swift       串聯所有組件
  Views.swift / AirHeadMouseApp.swift  菜單欄與設置界面
```

## 測試
```bash
swift test
```
覆蓋濾波、角速度估計、指針映射、點頭/搖頭識別（含慢速低頭、單次轉頭、斜向甩頭等誤觸場景）、設置序列化。

## 路線圖
- Windows：iPhone 橋接 App 讀取 AirPods 姿態與按壓 → Wi‑Fi/UDP → Windows Python 代理（`SendInput`）。`HeadMouseCore` 可直接複用。
