# BaiduPan-DirectLink

百度网盘 iOS 直链助手 - TrollStore 版

## 功能
- 通过 TrollFools 注入百度网盘 IPA
- 悬浮按钮一键获取文件直链
- 自动重命名骗链（非 PDF 临时加 .pdf 后缀）
- 获取成功后自动复制到剪贴板

## 使用
1. 用 Theos 编译 `make`
2. 通过 TrollFools 将生成的 `BaiduPanTroll.dylib` 注入百度网盘
3. 打开 App，点击悬浮「直链」按钮，输入文件名即可

## 编译
需要安装 [Theos](https://theos.dev/)：
```bash
make
