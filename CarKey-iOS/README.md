# CarKey · iOS（TrollStore / 巨魔未签名 IPA 工程）

把「车钥匙」小程序原型封装成可装进 iPhone 的原生 App。界面完全一致，硬件层用 Swift 重写并桥接。

> **本仓库产出的是工程，不是现成 .ipa。** `.ipa` 内必须有 arm64 Mach-O，只能由 macOS 上的 Xcode 编译。
> 巨魔不需要签名证书，所以编译这一步可以用 GitHub Actions 的免费 macOS 虚拟机完成。

> **v2 改版**：界面与新原型一致（新增「继电器设置」页），硬件层改为 6 路点动脉冲模型。
> 脉冲由控制板固件本地计时执行，App 只发一条指令。4G 全控 6 路，NFC 与蓝牙距离仅 1、2 路。
> 详见 `../继电器工作原理与改版说明.md`。出包与巨魔安装流程未变。

## 目录

```
CarKey-iOS/
├── CarKey.xcodeproj/           # 完整 Xcode 工程（零依赖，xcodebuild 直接可用）
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/CarKey.xcscheme
├── CarKey/
│   ├── AppDelegate.swift        # 入口
│   ├── RootViewController.swift # 全屏 WKWebView + 安全区注入
│   ├── CarKeyBridge.swift       # JS ↔ 原生消息桥
│   ├── RelayProtocol.swift      # 继电器指令帧 AA 55 ...
│   ├── BLEManager.swift         # CoreBluetooth 扫描/连接/RSSI/写入
│   ├── ProximityEngine.swift    # RSSI 测距 + 滞回状态机
│   ├── NFCManager.swift         # CoreNFC（默认关闭，需 entitlement）
│   ├── CloudClient.swift        # 4G 云端下发
│   ├── index.html               # 内嵌界面（与小程序原型一致）
│   ├── Info.plist               # 权限、后台模式、启动屏
│   ├── CarKey.entitlements      # NFC entitlement 模板
│   └── Assets.xcassets/         # AppIcon 1024 + 启动屏深色
├── build.sh                    # 一键编译 + ad-hoc 签名 + 打包 .ipa
├── project.yml                 # XcodeGen 描述（可选，便于改配置）
└── .github/workflows/
    └── build-ipa.yml           # 免费 macOS 云端出包
```

## 快速出包

### 有 Mac

```bash
bash build.sh
# → CarKey-unsigned.ipa
```

### 没有 Mac（GitHub Actions，免费）

把**整个目录**（含隐藏的 `.github/`）推到一个 **Public** 仓库根目录：

```bash
git init && git add -A && git commit -m "init"
git remote add origin https://github.com/<你>/carkey-ios.git
git push -u origin main
```

然后 Actions → `Build unsigned IPA for TrollStore` → Run workflow → 下载 `CarKey-unsigned-ipa` 附件。

> 公开仓库的 macOS runner 免费且不限时长；私有仓库按 10 倍系数扣 2000 分钟/月额度，务必用公开仓库。

### 安装

把 `CarKey-unsigned.ipa` 传到 iPhone → 用 TrollStore 打开 → 安装。桌面出现「车钥匙」图标，永久签名不过期。

## 构建原理

`build.sh` 的关键三步：

1. `xcodebuild … CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` —— 不签名编译，不需要开发者账号。
2. `codesign -f -s - --entitlements … --identifier com.carkey.ios.key` —— **ad-hoc 签名**，纯本地、无证书。TrollStore 依赖 CoreTrust 做永久签名，但 `.ipa` 内的 `.app` 需要先有一层签名，否则部分 iOS 版本导入失败或装完闪退。
3. `zip -qry CarKey-unsigned.ipa Payload` —— 标准 `Payload/CarKey.app` 结构。

`IPHONEOS_DEPLOYMENT_TARGET = 14.0`，覆盖巨魔支持的版本区间。

## 接入真实硬件（可选，默认演示模式）

| 步骤 | 位置 |
|---|---|
| 填 BLE 服务/特征 UUID | `BLEManager.swift` 顶部 `serviceUUID` / `writeUUID` / `notifyUUID` |
| 填 4G 云端接口 | `CloudClient.swift` 的 `apiBase` / `token` |
| 启用 NFC | 确认巨魔已注入 NFC entitlement 后，把 `NFCManager.enabled` 设为 `true` |

未配置硬件时，界面照常切换锁态、滑块、扫描模拟，原生层只把指令帧打到日志，**不会向任何设备发指令**。

## 已知边界

- 界面是 WKWebView 壳；iOS 网页无 Web Bluetooth / Web NFC，硬件能力全部由 Swift 层提供。
- 后台蓝牙扫描在 iOS 上会被系统延迟，且用户强杀 App 后状态恢复失效。可靠的「靠近自动解锁」建议让模组同时广播 iBeacon，用 `CLBeaconRegion` 系统级区域监听唤醒，再切 CoreBluetooth 完成认证。
- NFC 在 iOS 上必须弹系统读卡会话，只能作为备用钥匙。
- 指令帧为示例明文，**量产前必须替换为挑战应答 + 滚动码 + AES**；纯 RSSI 测距不能防中继攻击。

详见上级目录 `iOS安装包说明.md`。
