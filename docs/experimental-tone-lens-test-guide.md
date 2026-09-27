# LumiBase 1.12.1 — 重新校準 Shadows／Whites／Dehaze

這是接續 1.12.0 的獨立測試版。根據第一次實測：**Contrast 演算法保持原樣；Texture 舊版較合適時，請將 Texture 的 A/B 開關關掉**。Whites 負值現在應更明顯壓暗亮部；Shadows 正值使用較強的暗部曝光補償；Dehaze 負值新增中性霧層與褪色效果，正值加強有界的局部去霧。

請在同一張照片只切換一項開關，特別試 **Shadows +50／+100、Whites −50／−90、Dehaze −85／+85**；觀察 100%、暗部噪點、雲的白色細節與膚色。這仍不是 Adobe 像素級實作或對每張照片都相差固定 EV 的承諾。

# LumiBase 1.12.0 — 獨立演算法與鏡頭校正測試指南

此版本是 **隔離的實驗 App**，尚未合併到正式 `main`。實驗演算法參考公開的影像處理方法，**不是 Adobe Lightroom／Photoshop Camera Raw 的程式碼或鏡頭描述檔**。正式驗收前請使用 RAW/JPEG 的副本；此 App 與舊版共用照片旁的 XMP sidecar，舊版重寫 XMP 時可能移除新欄位。不要讓兩個版本同時寫入同一資料夾。

## 一個一個測

1. 在 **Tone** 與 **Presence** 先只修改一個滑桿，例如 Shadows +60；其他滑桿歸零。依次在 **Experimental Algorithms · A/B** 只切換對應的選項，觀察同一張圖的 Fit、100% 及匯出 JPEG。關閉代表原有演算法；打開才是新演算法。零值時切換不應改畫面。
2. 單測 Contrast：看灰階漸層、深藍／紅色塊和膚色，檢查色偏、暗部裁切。單測 Shadows：看背光、暗部噪點、樹枝與天空交界；再試 +100 和負值。單測 Whites：看雲、白衣、過曝純白區，注意**純白已無 RAW 資訊時無法重建**。單測 Dehaze：先用真正有霧的照片，再用無霧照片檢查誤增對比。單測 Texture：100% 看毛髮、皮膚和高反差邊緣。最後才試兩項以上同時開啟。
3. **Lens Corrections · Manual** 在 Presence 下方。Distortion：以直線建築或方格檢查桶形／枕形及四角，100% 使用全幅渲染可能較慢。Defringe Purple／Green：用逆光枝條與白底高對比邊緣，另檢查真正的紫／綠花朵是否褪色。Vignetting：以均勻牆面與實景檢查畫面中心、四角。每個滑桿可個別歸零；沒有自動鏡頭識別或 Adobe 設定檔。
4. 試完關閉 App 再開資料夾，核對滑桿、A/B 開關、鏡頭值及 JPEG 匯出。Sync Settings 中的 **Manual Lens Corrections** 預設不勾選；「Modified Only」會依來源照片決定。

## 有意保留的界線

- Lightroom／Camera Raw 的同一張 RAW 需使用同一白平衡、曝光、色彩設定與輸出色域，才可比較；不能以單張外觀宣稱像素級一致。
- 新實驗路徑只在開關為 On 時替代對應舊路徑；舊的 Clarity／Highlights 與一般色彩設定仍可能影響邊緣或色彩。碰到怪邊先將它們歸零，再逐項恢復。
- Distortion 改變空間取樣；為避免局部 ROI 位置錯誤，100% 檢視使用較慢的全幅路徑。
